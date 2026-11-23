defmodule Yoke.CI.FixFromReviewTest do
  @moduledoc """
  Tests for `yoke fix --from-review` (`docs/YAAS.md` §5.4).

  The safety properties matter more than the feature: applying fixes mutates a
  working tree, so a moved checkout or a stale artifact must abort rather than
  edit the wrong code.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.FixFromReview
  alias Yoke.Json

  # Artifact findings use string keys; `load/1` normalises them to atoms for the
  # fix-prompt builder. This helper builds the *artifact* shape, and
  # `atom_finding/1` builds the normalised shape the prompt functions expect.
  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 1,
        "file" => "lib/foo.ex",
        "line" => 42,
        "title" => "Handle the error tuple",
        "description" => "The caller crashes on {:error, _}.",
        "severity" => "high",
        "kind" => "issue",
        "fix_suggestion" => "Match {:error, _}."
      },
      overrides
    )
  end

  defp atom_finding(overrides \\ %{}) do
    finding()
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
    |> Map.merge(overrides)
  end

  defp atom_endorsement do
    atom_finding(%{
      id: 2,
      file: "lib/foo.ex",
      line: 1,
      title: "Nice work",
      description: "Good.",
      severity: "info",
      kind: "endorsement",
      fix_suggestion: ""
    })
  end

  defp write_artifact(dir, findings, identity \\ %{"head_sha" => "abc123"}) do
    path = Path.join(dir, "artifact.json")

    File.write!(
      path,
      Json.encode!(%{"findings" => findings, "identity" => identity}, pretty: true)
    )

    path
  end

  describe "load/1" do
    test "reads findings from an artifact", %{tmp_dir: dir} do
      path = write_artifact(dir, [finding()])

      assert {:ok, %{findings: [only]}} = FixFromReview.load(path)
      assert only.title == "Handle the error tuple"
      assert only.file == "lib/foo.ex"
      assert only.line == 42
    end

    test "excludes endorsements from fix candidates", %{tmp_dir: dir} do
      endorsement =
        finding(%{
          "id" => 2,
          "kind" => "endorsement",
          "severity" => "info",
          "fix_suggestion" => ""
        })

      path = write_artifact(dir, [finding(), endorsement])

      assert {:ok, %{findings: [only]}} = FixFromReview.load(path)
      assert only.kind == "issue"
    end

    test "returns the artifact identity", %{tmp_dir: dir} do
      path = write_artifact(dir, [finding()], %{"head_sha" => "deadbeef", "pr_number" => "15"})

      assert {:ok, %{identity: identity}} = FixFromReview.load(path)
      assert identity["head_sha"] == "deadbeef"
    end

    test "an empty findings list is not an error", %{tmp_dir: dir} do
      path = write_artifact(dir, [])

      assert {:ok, %{findings: []}} = FixFromReview.load(path)
    end

    test "a missing artifact is a diagnostic, not a crash", %{tmp_dir: dir} do
      assert {:error, reason} = FixFromReview.load(Path.join(dir, "nope.json"))
      assert reason =~ "No artifact at"
    end

    test "a non-object artifact is rejected", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "[1,2,3]")

      assert {:error, reason} = FixFromReview.load(path)
      assert reason =~ "not a JSON object"
    end

    test "malformed JSON is rejected", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "{not json")

      assert {:error, _reason} = FixFromReview.load(path)
    end
  end

  describe "verify_checkout/2" do
    test "refuses an artifact with no head commit", %{tmp_dir: dir} do
      assert {:error, reason} = FixFromReview.verify_checkout(%{}, dir)
      assert reason =~ "does not record the reviewed head commit"
    end

    test "refuses an artifact whose head_sha is blank", %{tmp_dir: dir} do
      assert {:error, _reason} = FixFromReview.verify_checkout(%{"head_sha" => ""}, dir)
    end

    test "refuses a directory that is not the reviewed head", %{tmp_dir: dir} do
      # A real git repo whose HEAD cannot match the fabricated sha.
      init_repo(dir)
      path = write_artifact(dir, [finding()], %{"head_sha" => String.duplicate("a", 40)})

      assert {:ok, %{identity: identity}} = FixFromReview.load(path)
      assert {:error, reason} = FixFromReview.verify_checkout(identity, dir)
      assert reason =~ "Fixes were not applied"
    end

    test "refuses a dirty checkout at the reviewed head", %{tmp_dir: dir} do
      init_repo(dir)
      head = git_head(dir)
      File.write!(Path.join(dir, "dirty.txt"), "uncommitted")

      assert {:error, _reason} =
               FixFromReview.verify_checkout(%{"head_sha" => head}, dir)
    end

    test "accepts a clean checkout at the reviewed head", %{tmp_dir: dir} do
      init_repo(dir)
      head = git_head(dir)

      assert :ok = FixFromReview.verify_checkout(%{"head_sha" => head}, dir)
    end
  end

  describe "build_prompt/1" do
    test "includes each finding's title and location" do
      prompt = FixFromReview.build_prompt([atom_finding()])

      assert prompt =~ "Handle the error tuple"
      assert prompt =~ "lib/foo.ex:42"
    end

    test "forbids committing and pushing" do
      prompt = FixFromReview.build_prompt([atom_finding()])

      assert prompt =~ "Do not commit"
      assert prompt =~ "do not push"
    end

    test "permits skipping a finding the agent judges wrong" do
      # A review comment can be mistaken. The agent must be allowed to say so
      # rather than editing code to satisfy a bad comment.
      prompt = FixFromReview.build_prompt([atom_finding()])

      assert prompt =~ "skip it"
    end

    test "is empty when there is nothing to fix" do
      assert FixFromReview.build_prompt([]) == ""
    end

    test "excludes endorsements" do
      prompt = FixFromReview.build_prompt([atom_finding(), atom_endorsement()])

      refute prompt =~ "Nice work"
    end
  end

  describe "summary/1" do
    test "counts actionable findings" do
      assert FixFromReview.summary([atom_finding(), atom_finding(%{id: 2})]) ==
               "2 actionable finding(s) to fix"
    end
  end

  describe "usage/0" do
    test "documents the new flags" do
      usage = FixFromReview.usage()

      for flag <- ~w(--from-review --artifact --dry-run) do
        assert usage =~ flag, "usage is missing #{flag}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp init_repo(dir) do
    git!(dir, ["init", "--quiet"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "README.md"), "hello\n")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "--quiet", "-m", "initial"])
  end

  defp git_head(dir) do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{out}")
    end
  end
end

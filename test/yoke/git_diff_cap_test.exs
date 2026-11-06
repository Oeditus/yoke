defmodule Yoke.Git.DiffCapTest do
  @moduledoc """
  The review-diff size cap (`docs/CI_PLAN.md` Phase 1.3).

  A 300 KB default bounds both the model's context cost and the CI job's
  runtime. Repositories may tighten it via `max_diff_bytes` in
  `.yoke/policy.json`, but never loosen it past what the policy allows.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Git
  alias Yoke.Interaction.Policy

  setup do
    prior = System.get_env("YOKE_POLICY")
    System.delete_env("YOKE_POLICY")

    on_exit(fn ->
      System.delete_env("YOKE_POLICY")
      if prior, do: System.put_env("YOKE_POLICY", prior)
    end)

    :ok
  end

  describe "max_diff_bytes/1" do
    test "defaults to 300 KB", %{tmp_dir: dir} do
      assert Git.max_diff_bytes(dir) == 300_000
    end

    test "honours a policy override", %{tmp_dir: dir} do
      Policy.write(dir, %{"max_diff_bytes" => 50_000})
      assert Git.max_diff_bytes(dir) == 50_000
    end

    test "ignores a nonsensical override", %{tmp_dir: dir} do
      Policy.write(dir, %{"max_diff_bytes" => -1})
      assert Git.max_diff_bytes(dir) == 300_000

      Policy.write(dir, %{"max_diff_bytes" => "lots"})
      assert Git.max_diff_bytes(dir) == 300_000
    end
  end

  describe "diff_branches/3 enforcement" do
    test "rejects a diff larger than the configured cap", %{tmp_dir: dir} do
      repo = Path.join(dir, "repo")
      File.mkdir_p!(repo)

      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.email", "cap@example.invalid"])
      git!(repo, ["config", "user.name", "Cap Test"])
      File.write!(Path.join(repo, "big.txt"), "small\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "initial"])

      git!(repo, ["checkout", "-q", "-b", "feature"])
      # A diff comfortably larger than the cap we are about to set.
      File.write!(Path.join(repo, "big.txt"), String.duplicate("x", 5_000) <> "\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "big change"])

      Policy.write(repo, %{"max_diff_bytes" => 1_000})

      assert {:error, reason} = Git.diff_branches("main", "feature", repo)
      assert reason =~ "exceeds"
      assert reason =~ "KB"
    end

    test "allows a diff within the cap", %{tmp_dir: dir} do
      repo = Path.join(dir, "repo")
      File.mkdir_p!(repo)

      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.email", "cap@example.invalid"])
      git!(repo, ["config", "user.name", "Cap Test"])
      File.write!(Path.join(repo, "small.txt"), "a\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "initial"])

      git!(repo, ["checkout", "-q", "-b", "feature"])
      File.write!(Path.join(repo, "small.txt"), "b\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "change"])

      assert {:ok, data} = Git.diff_branches("main", "feature", repo)
      assert data.raw_diff =~ "small.txt"
    end
  end

  defp git!(repo, args) do
    {out, status} = System.cmd("git", ["--no-pager" | args], cd: repo, stderr_to_stdout: true)
    assert status == 0, out
    String.trim(out)
  end
end

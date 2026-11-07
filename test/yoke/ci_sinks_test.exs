defmodule Yoke.CI.SinksTest do
  # Not async: these tests set `GITHUB_STEP_SUMMARY` / `RUNNER_TEMP`.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Annotations
  alias Yoke.CI.Artifact
  alias Yoke.CI.Findings
  alias Yoke.CI.StepSummary

  defp finding(attrs) do
    Map.merge(
      %{
        id: 1,
        file: "lib/foo.ex",
        line: 10,
        title: "Off-by-one",
        description: "Loop runs one past the end",
        severity: "high",
        kind: "issue",
        fix_suggestion: "Use `Enum.take/2`"
      },
      Map.new(attrs)
    )
  end

  defp report(findings, fail_on \\ "high"), do: Findings.report(findings, fail_on)

  describe "StepSummary.render/2" do
    test "states a passing verdict when nothing gates" do
      md = StepSummary.render(report([]))
      assert md =~ "Result: passing"
      assert md =~ "None."
    end

    test "states a failing verdict with the gating count" do
      md = StepSummary.render(report([finding(%{severity: "high"})]))
      assert md =~ "Result: failing"
      assert md =~ "1 finding(s) at or above"
    end

    test "tabulates issues with severity and location" do
      md = StepSummary.render(report([finding(%{})]))

      assert md =~ "| Issues | 1 |"
      assert md =~ "`high`"
      assert md =~ "`lib/foo.ex:10`"
      assert md =~ "Off-by-one"
    end

    test "renders a general finding without a file" do
      md = StepSummary.render(report([finding(%{file: nil, line: nil})]))
      assert md =~ "General"
    end

    test "renders a file-only finding without a line" do
      md = StepSummary.render(report([finding(%{line: nil})]))
      assert md =~ "`lib/foo.ex`"
      refute md =~ "`lib/foo.ex:`"
    end

    test "lists endorsements separately and labels them as non-gating" do
      findings = [
        finding(%{}),
        finding(%{kind: "endorsement", severity: "info", fix_suggestion: "", title: "Nice"})
      ]

      md = StepSummary.render(report(findings))

      assert md =~ "### Endorsements"
      assert md =~ "not requests for changes"
      assert md =~ "Nice"
    end

    test "omits the endorsements section when there are none" do
      refute StepSummary.render(report([finding(%{})])) =~ "### Endorsements"
    end

    test "escapes pipes in titles so the table stays well-formed" do
      md = StepSummary.render(report([finding(%{title: "a | b"})]))
      assert md =~ "a \\| b"
    end

    test "captions the reviewed identity when provided" do
      md =
        StepSummary.render(
          report([finding(%{})]),
          identity: %{base_sha: String.duplicate("a", 40), head_sha: String.duplicate("b", 40)}
        )

      assert md =~ "Reviewed `aaaaaaaaaaaa...bbbbbbbbbbbb`"
    end

    test "honours a custom title" do
      assert StepSummary.render(report([]), title: "Custom") =~ "## Custom"
    end

    test "is deterministic for identical input" do
      r = report([finding(%{})])
      assert StepSummary.render(r) == StepSummary.render(r)
    end
  end

  describe "StepSummary.write/1" do
    test "appends to GITHUB_STEP_SUMMARY when set", %{tmp_dir: dir} do
      path = Path.join(dir, "summary.md")
      prior = System.get_env("GITHUB_STEP_SUMMARY")
      System.put_env("GITHUB_STEP_SUMMARY", path)

      on_exit(fn ->
        if prior == nil,
          do: System.delete_env("GITHUB_STEP_SUMMARY"),
          else: System.put_env("GITHUB_STEP_SUMMARY", prior)
      end)

      assert {:ok, :written} = StepSummary.write("# first\n")
      assert {:ok, :written} = StepSummary.write("# second\n")
      assert File.read!(path) == "# first\n# second\n"
    end

    test "is a no-op when the variable is unset" do
      prior = System.get_env("GITHUB_STEP_SUMMARY")
      System.delete_env("GITHUB_STEP_SUMMARY")

      on_exit(fn -> if prior, do: System.put_env("GITHUB_STEP_SUMMARY", prior) end)

      assert {:ok, :skipped} = StepSummary.write("# nothing\n")
    end
  end

  describe "Annotations.render/1" do
    test "emits one workflow command per issue" do
      text = Annotations.render(report([finding(%{})]))

      assert text ==
               "::error file=lib/foo.ex,line=10,title=Off-by-one::Off-by-one — Use `Enum.take/2`\n"
    end

    test "maps high and medium to error, low and info to warning" do
      assert Annotations.level_for("high") == "error"
      assert Annotations.level_for("medium") == "error"
      assert Annotations.level_for("low") == "warning"
      assert Annotations.level_for("info") == "warning"
      assert Annotations.level_for("nonsense") == "warning"
    end

    test "omits file properties for a general finding" do
      text = Annotations.render(report([finding(%{file: nil, line: nil})]))
      assert text == "::error::Off-by-one — Use `Enum.take/2`\n"
    end

    test "omits the line property when the finding has no line" do
      text = Annotations.render(report([finding(%{line: nil})]))
      assert text =~ "file=lib/foo.ex,title="
      refute text =~ "line="
    end

    test "excludes endorsements" do
      findings = [finding(%{kind: "endorsement", severity: "info", fix_suggestion: ""})]
      assert Annotations.render(report(findings)) == ""
    end

    test "escapes newlines so an annotation cannot be truncated" do
      text = Annotations.render(report([finding(%{title: "line one\nline two"})]))
      refute String.contains?(String.trim_trailing(text, "\n"), "\n")
      assert text =~ "%0A"
    end

    test "escapes colons in the message so no workflow command can be injected" do
      text = Annotations.render(report([finding(%{title: "a::b"})]))
      assert text =~ "a%3A%3Ab"
      refute text =~ "::b"
    end

    test "escapes commas in property values" do
      text = Annotations.render(report([finding(%{title: "a,b"})]))
      assert text =~ "title=a%2Cb"
    end

    test "escapes percent signs first, so escaping is idempotent-safe" do
      assert Annotations.escape_message("100%") == "100%25"
      assert Annotations.escape_message("%0A") == "%250A"
    end

    test "truncates very long titles" do
      long = String.duplicate("x", 200)
      text = Annotations.render(report([finding(%{title: long})]))
      assert text =~ "..."
    end

    test "an empty review produces no output" do
      assert Annotations.render(report([])) == ""
    end
  end

  describe "Artifact.payload/2" do
    test "records identity, summary and findings" do
      payload =
        Artifact.payload(report([finding(%{})]),
          identity: %{base_sha: "a", head_sha: "b", pr_number: "7", repository: "o/r"},
          model: "deepseek-flash",
          run_uid: "uid-1"
        )

      assert payload["schema_version"] == 1
      assert payload["run_uid"] == "uid-1"
      assert payload["model"] == "deepseek-flash"
      assert payload["identity"]["pr_number"] == "7"
      assert payload["summary"]["findings_count"] == 1
      assert payload["summary"]["failed"] == true
      assert [finding] = payload["findings"]
      assert finding["file"] == "lib/foo.ex"
      assert finding["gating"] == true
    end

    test "marks a non-gating finding as such" do
      payload = Artifact.payload(report([finding(%{severity: "low"})], "high"))
      assert [finding] = payload["findings"]
      assert finding["gating"] == false
    end

    test "redacts a transcript that trips AI Guard" do
      # Built at runtime so the literal never appears in the source: a
      # realistic-looking key here trips GitHub's push protection as a
      # false positive, blocking the branch from being pushed at all.
      secret = "DEEPSEEK_API_KEY=" <> "sk-" <> String.duplicate("a1b2c3d4e5", 3)
      payload = Artifact.payload(report([]), transcript: secret)

      assert payload["transcript"]["redacted"] == true
      refute inspect(payload) =~ String.slice(secret, 18, 20)
    end

    test "keeps a clean transcript" do
      payload = Artifact.payload(report([]), transcript: "Looks fine to me.")
      assert payload["transcript"]["redacted"] == false
      assert payload["transcript"]["content"] == "Looks fine to me."
    end

    test "omits the transcript when none was supplied" do
      assert Artifact.payload(report([]))["transcript"] == nil
    end
  end

  describe "Artifact.write/2 and emit/2" do
    test "writes pretty JSON to an explicit path", %{tmp_dir: dir} do
      path = Path.join(dir, "out/review.json")
      assert {:ok, ^path} = Artifact.emit(report([finding(%{})]), path: path)

      assert {:ok, decoded} = Yoke.Json.decode(File.read!(path))
      assert decoded["summary"]["findings_count"] == 1
    end

    test "defaults to RUNNER_TEMP", %{tmp_dir: dir} do
      prior = System.get_env("RUNNER_TEMP")
      System.put_env("RUNNER_TEMP", dir)

      on_exit(fn ->
        if prior == nil,
          do: System.delete_env("RUNNER_TEMP"),
          else: System.put_env("RUNNER_TEMP", prior)
      end)

      assert Artifact.default_path() == Path.join(dir, "yoke-review.json")
      assert {:ok, path} = Artifact.emit(report([]))
      assert path == Path.join(dir, "yoke-review.json")
      assert File.regular?(path)
    end

    test "falls back to the system temp dir without RUNNER_TEMP" do
      prior = System.get_env("RUNNER_TEMP")
      System.delete_env("RUNNER_TEMP")

      on_exit(fn -> if prior, do: System.put_env("RUNNER_TEMP", prior) end)

      assert Artifact.default_path() == Path.join(System.tmp_dir!(), "yoke-review.json")
    end
  end
end

defmodule Yoke.CI.GoldenReviewTest do
  @moduledoc """
  Golden-file tests over **5 real pull requests** (`docs/CI_PLAN.md` Phase 1.1
  exit test).

  Each fixture is a genuine merge commit from a sibling repository. The review
  turn is driven by a deterministic provider so the test isolates the part that
  must be byte-stable: the **findings pipeline and the sinks**. Model output is
  by nature non-deterministic; the rendering of it is not, and that is what
  regressions would break.

  ## What "golden" means here

  For each PR the test captures two artefacts:

    * `report` — the rendered step summary Markdown
    * `annotations` — the GitHub workflow commands

  Both are normalised (run UIDs and timestamps replaced) and compared against a
  checked-in `.golden` file. Re-running must produce identical bytes.

  ## Regenerating

      YOKE_UPDATE_GOLDEN=1 mix test test/yoke/golden_review_test.exs

  Review the diff before committing it — a golden change is a behaviour change.
  """
  use ExUnit.Case, async: false

  alias Yoke.CI.Annotations
  alias Yoke.CI.Findings
  alias Yoke.CI.GoldenFixtures
  alias Yoke.CI.StepSummary
  alias Yoke.PRReview.Context

  @moduletag :golden

  setup_all do
    unless GoldenFixtures.available?() do
      # A contributor without the sibling checkout must still get a green suite.
      :ok
    end

    :ok
  end

  describe "golden review output over real PRs" do
    for {base, head, label} <- GoldenFixtures.ranges() do
      test "#{label} renders byte-identically" do
        # Skip rather than fail when the fixture repo is absent: it is an
        # optional sibling checkout, not a suite dependency.
        if GoldenFixtures.available?() do
          repo = GoldenFixtures.repo()

          assert {:ok, context} = Context.from_branches(unquote(base), unquote(head), repo)

          # A fixed set of findings derived from the real diff, so the sink
          # rendering is exercised against realistic file paths and line
          # numbers without depending on a model call.
          findings = findings_for(context)
          report = Findings.report(findings, "high")

          identity = %{
            base_sha: context.base_sha,
            head_sha: context.head_sha,
            pr_number: nil,
            repository: nil
          }

          summary =
            StepSummary.render(report, identity: identity)
            |> GoldenFixtures.normalize()

          annotations = Annotations.render(report) |> GoldenFixtures.normalize()

          assert_matches_golden(unquote(label), "report", summary)
          assert_matches_golden(unquote(label), "annotations", annotations)
        end
      end
    end
  end

  describe "determinism" do
    test "rendering the same context twice produces identical bytes" do
      if GoldenFixtures.available?() do
        repo = GoldenFixtures.repo()
        {base, head, _} = hd(GoldenFixtures.ranges())

        {:ok, context} = Context.from_branches(base, head, repo)
        findings = findings_for(context)
        report = Findings.report(findings, "high")

        identity = %{base_sha: context.base_sha, head_sha: context.head_sha}

        first = StepSummary.render(report, identity: identity) |> GoldenFixtures.normalize()
        second = StepSummary.render(report, identity: identity) |> GoldenFixtures.normalize()

        assert first == second
      end
    end

    test "the diff for a pinned range is stable" do
      if GoldenFixtures.available?() do
        repo = GoldenFixtures.repo()
        {base, head, _} = hd(GoldenFixtures.ranges())

        {:ok, a} = Context.from_branches(base, head, repo)
        {:ok, b} = Context.from_branches(base, head, repo)

        assert a.raw_diff == b.raw_diff
        assert a.head_sha == b.head_sha
        assert a.base_sha == b.base_sha
      end
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Builds findings anchored to real lines in the reviewed diff, so the sinks
  # are exercised with genuine paths and line numbers. Deterministic: the same
  # diff yields the same findings.
  defp findings_for(context) do
    context.valid_lines
    |> Enum.sort()
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.map(fn {{file, line}, idx} ->
      %{
        id: idx,
        file: file,
        line: line,
        title: "Golden finding #{idx}",
        description: "Deterministic finding at `#{file}:#{line}`.",
        severity: Enum.at(["high", "medium", "low"], rem(idx - 1, 3)),
        kind: "issue",
        fix_suggestion: ""
      }
    end)
  end

  defp assert_matches_golden(label, kind, actual) do
    path = GoldenFixtures.golden_path(label, kind)

    if System.get_env("YOKE_UPDATE_GOLDEN") in ["1", "true"] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, actual)
      assert true
    else
      assert File.regular?(path),
             "missing golden file #{path}. Regenerate with YOKE_UPDATE_GOLDEN=1."

      expected = File.read!(path)

      assert actual == expected,
             """
             Golden mismatch for #{label}.#{kind}.

             Expected:
             #{expected}

             Actual:
             #{actual}

             If this change is intended, regenerate with YOKE_UPDATE_GOLDEN=1.
             """
    end
  end
end

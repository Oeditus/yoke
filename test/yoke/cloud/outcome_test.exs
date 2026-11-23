defmodule Yoke.Cloud.OutcomeTest do
  @moduledoc """
  Classification rules for `docs/YAAS.md` Phase 0.

  These tests pin the precedence order in `Yoke.Cloud.Outcome.classify/2` and
  the precision arithmetic in `score/2`. Both are load-bearing: the entire
  paid thesis is "precision converges", and that claim is only meaningful if
  the scoring is unambiguous and stable.
  """
  use ExUnit.Case, async: true

  alias Yoke.Cloud.Outcome

  defp issue(attrs \\ %{}) do
    Map.merge(
      %{
        id: 1,
        file: "lib/foo.ex",
        line: 42,
        title: "Unchecked return value",
        description: "The error tuple is discarded.",
        severity: "high",
        kind: "issue",
        fix_suggestion: "Match on the error tuple."
      },
      attrs
    )
  end

  defp endorsement(attrs \\ %{}) do
    issue(Map.merge(%{severity: "info", kind: "endorsement", fix_suggestion: ""}, attrs))
  end

  describe "classify/2 precedence" do
    test "a review-fix commit outranks line movement" do
      # A fix can address a finding without moving the anchored line, so the
      # commit signal must be checked before `line_present`. This is the case
      # that made an early measurement of this repository read 14% instead of
      # 93%: three commits titled "CR by Robby Ott" fixed findings whose
      # anchored lines never moved.
      evidence = %{line_present: true, file_present: true, pr_merged: true, review_fix: true}

      assert Outcome.classify(issue(), evidence) == :acted_on
    end

    test "a direct reaction outranks a review-fix commit" do
      # A thumbs-up is a human judgement about *this comment*; a review-fix
      # commit only says the file was touched. Checking the inference first
      # would mask the strong signal and make the tally under-report how often
      # reviewers explicitly agreed.
      evidence = %{
        line_present: true,
        review_fix: true,
        resolved: true,
        reactions: %{"THUMBS_UP" => 2},
        pr_merged: true
      }

      assert Outcome.classify(issue(), evidence) == :reacted_up
    end

    test "a direct reaction outranks line movement" do
      evidence = %{
        line_present: false,
        resolved: true,
        reactions: %{"THUMBS_UP" => 3},
        pr_merged: true
      }

      assert Outcome.classify(issue(), evidence) == :reacted_up
    end

    test "GitHub's THUMBS_UP content counts as a positive reaction" do
      # GraphQL returns `THUMBS_UP`, not `+1`. Matching only `+1` silently
      # ignored every real reaction on this repository.
      assert Outcome.classify(issue(), %{reactions: %{"THUMBS_UP" => 1}}) == :reacted_up
    end

    test "GitHub's THUMBS_DOWN content counts as a negative reaction" do
      assert Outcome.classify(issue(), %{reactions: %{"THUMBS_DOWN" => 1}}) == :reacted_down
    end

    test "a changed line wins over a review-fix inference" do
      evidence = %{line_present: false, review_fix: true, pr_merged: true}

      assert Outcome.classify(issue(), evidence) == :acted_on
    end

    test "a deleted file counts as acted on" do
      assert Outcome.classify(issue(), %{file_present: false}) == :acted_on
    end

    test "an accepted suggestion is a positive reaction" do
      assert Outcome.classify(issue(), %{reactions: %{"+1" => 1}}) == :reacted_up
    end

    test "a positive reaction outranks a resolved thread" do
      evidence = %{"+1" => 1}
      evidence = %{reactions: evidence, resolved: true}

      assert Outcome.classify(issue(), evidence) == :reacted_up
    end

    test "a resolved thread with the line untouched is acknowledgement" do
      assert Outcome.classify(issue(), %{resolved: true, line_present: true}) == :resolved
    end

    test "a thumbs-down is negative" do
      assert Outcome.classify(issue(), %{reactions: %{"-1" => 1}}) == :reacted_down
    end

    test "a merged PR with the line untouched is ignored" do
      evidence = %{pr_merged: true, line_present: true}

      assert Outcome.classify(issue(), evidence) == :ignored
    end

    test "a merged PR whose line changed is still acted on" do
      evidence = %{pr_merged: true, line_present: false}

      assert Outcome.classify(issue(), evidence) == :acted_on
    end

    test "an open PR with nothing happening is pending" do
      assert Outcome.classify(issue(), %{pr_merged: false, line_present: true}) == :pending
    end

    test "no evidence at all is pending, never ignored" do
      assert Outcome.classify(issue()) == :pending
    end
  end

  describe "positive?/1 and negative?/1" do
    test "resolved counts as positive, not as a miss" do
      assert Outcome.positive?(:resolved)
      refute Outcome.negative?(:resolved)
    end

    test "pending is neither positive nor negative" do
      refute Outcome.positive?(:pending)
      refute Outcome.negative?(:pending)
    end

    test "ignored and reacted_down are the only negatives" do
      assert Outcome.negative?(:ignored)
      assert Outcome.negative?(:reacted_down)
      refute Outcome.negative?(:acted_on)
      refute Outcome.negative?(:reacted_up)
    end
  end

  describe "score/2" do
    test "returns nil when there is nothing decisive" do
      assert Outcome.score([{issue(), :pending}]) == nil
      assert Outcome.score([]) == nil
    end

    test "a single acted-on finding is 2/3 after smoothing" do
      # (1 + 1) / (1 + 0 + 2)
      assert Outcome.score([{issue(), :acted_on}]) == 0.6667
    end

    test "a single ignored finding is 1/3 after smoothing" do
      # (0 + 1) / (0 + 1 + 2)
      assert Outcome.score([{issue(), :ignored}]) == 0.3333
    end

    test "a perfect record approaches 1.0 as evidence accumulates" do
      classified = for _ <- 1..10, do: {issue(), :acted_on}
      assert Outcome.score(classified) > 0.9
    end

    test "a uniformly ignored reviewer stays below the suppression floor" do
      classified = for _ <- 1..10, do: {issue(), :ignored}
      assert Outcome.score(classified) < 0.2
    end

    test "pending findings do not dilute the score" do
      mixed = [{issue(), :acted_on}, {issue(), :pending}, {issue(), :pending}]
      alone = [{issue(), :acted_on}]

      assert Outcome.score(mixed) == Outcome.score(alone)
    end

    test "endorsements are excluded by default" do
      classified = [{issue(), :ignored}, {endorsement(), :ignored}]

      # Only the issue is scored: (0 + 1) / (0 + 1 + 2)
      assert Outcome.score(classified) == 0.3333
    end

    test "kind: :all scores endorsements too" do
      classified = [{issue(), :ignored}, {endorsement(), :ignored}]

      # Two negatives: (0 + 1) / (0 + 2 + 2)
      assert Outcome.score(classified, kind: :all) == 0.25
    end
  end

  describe "report/2" do
    test "splits decisive from pending and counts each verdict" do
      classified = [
        {issue(), :acted_on},
        {issue(), :ignored},
        {issue(), :pending},
        {issue(), :pending}
      ]

      report = Outcome.report(classified)

      assert report.total == 4
      assert report.scored == 2
      assert report.pending == 2
      assert report.by_verdict == %{acted_on: 1, ignored: 1, pending: 2}
      assert report.acted_on_rate == 0.5
    end

    test "precision is nil when nothing is decisive" do
      report = Outcome.report([{issue(), :pending}])

      assert report.precision == nil
      assert report.acted_on_rate == nil
    end
  end
end

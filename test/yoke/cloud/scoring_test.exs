defmodule Yoke.Cloud.ScoringTest do
  @moduledoc """
  Tests for the scoring engine (`docs/YAAS.md` §4.2).

  The properties that matter are the ones that decide whether the product is
  honest: smoothing must not promote on a single observation, suppression must
  need more evidence than promotion, and every decision must carry the counts
  that produced it.
  """
  use ExUnit.Case, async: true

  alias Yoke.Cloud.Scoring

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        file: "lib/foo.ex",
        line: 10,
        title: "Missing index on `user_id`",
        description: "d",
        severity: "medium",
        kind: "issue",
        fix_suggestion: ""
      },
      overrides
    )
  end

  defp tally(overrides) do
    Map.merge(
      %{
        file: "lib/foo.ex",
        title: "missing index on userid",
        acted_on: 0,
        ignored: 0,
        pending: 0
      },
      overrides
    )
  end

  describe "tally/1" do
    test "groups findings by file and normalised title" do
      classified = [
        {finding(), :acted_on},
        {finding(%{id: 2}), :ignored}
      ]

      assert [only] = Scoring.tally(classified)
      assert only.file == "lib/foo.ex"
      assert only.acted_on == 1
      assert only.ignored == 1
    end

    test "separates distinct titles in the same file" do
      classified = [
        {finding(), :acted_on},
        {finding(%{title: "Unchecked nil"}), :ignored}
      ]

      assert [first, second] = Scoring.tally(classified)
      assert first.title != second.title
    end

    test "excludes endorsements from every count" do
      endorsement = finding(%{kind: "endorsement", severity: "info", fix_suggestion: ""})

      classified = [
        {finding(), :acted_on},
        {endorsement, :ignored}
      ]

      assert [only] = Scoring.tally(classified)
      assert only.acted_on == 1
      assert only.ignored == 0
    end

    test "counts pending separately" do
      assert [only] = Scoring.tally([{finding(), :pending}])
      assert only.pending == 1
      assert only.acted_on == 0
      assert only.ignored == 0
    end
  end

  describe "score/1 smoothing" do
    test "a single acted-on observation does not promote" do
      # (1 + 1) / (1 + 0 + 2) = 0.667, which clears the score bar, but one
      # observation is not evidence. This is the case smoothing exists for.
      verdict = Scoring.score(tally(%{acted_on: 1}))

      assert verdict.score == 0.6667
      assert verdict.decision == :observe
    end

    test "no decisive observations yields a nil score" do
      verdict = Scoring.score(tally(%{pending: 3}))

      assert verdict.score == nil
      assert verdict.decision == :observe
      assert verdict.reason =~ "no decisive observations"
    end

    test "a single ignored observation does not suppress" do
      verdict = Scoring.score(tally(%{ignored: 1}))

      assert verdict.score == 0.3333
      assert verdict.decision == :observe
    end

    test "smoothing pulls a small sample toward 0.5" do
      small = Scoring.score(tally(%{acted_on: 1, ignored: 0}))
      large = Scoring.score(tally(%{acted_on: 10, ignored: 0}))

      assert small.score < large.score
    end
  end

  describe "score/1 decisions" do
    test "promotes a frequent, consistently acted-on pattern" do
      verdict = Scoring.score(tally(%{acted_on: 5}))

      assert verdict.decision == :promote
      assert verdict.reason =~ "promoted"
    end

    test "suppresses a frequent, consistently ignored pattern" do
      verdict = Scoring.score(tally(%{ignored: 6}))

      assert verdict.decision == :suppress
      assert verdict.reason =~ "suppressed"
    end

    test "suppression needs more evidence than promotion" do
      # Four acted-on observations promote; four ignored ones do not suppress.
      assert Scoring.score(tally(%{acted_on: 4})).decision == :promote
      assert Scoring.score(tally(%{ignored: 4})).decision == :observe
    end

    test "a mixed pattern is observed, never promoted or suppressed" do
      verdict = Scoring.score(tally(%{acted_on: 3, ignored: 3}))

      assert verdict.decision == :observe
      assert verdict.score == 0.5
    end

    test "pending observations do not count toward the threshold" do
      # Five pending plus one ignored is one decisive observation, not six.
      verdict = Scoring.score(tally(%{ignored: 1, pending: 5}))

      assert verdict.decision == :observe
    end

    test "the reason names the counts that produced the decision" do
      verdict = Scoring.score(tally(%{ignored: 6}))

      assert verdict.reason =~ "6 decisive observations"
    end
  end

  describe "score_all/1" do
    test "orders promotions first, then suppressions, then observations" do
      verdicts =
        Scoring.score_all([
          tally(%{title: "observed", acted_on: 1, ignored: 1}),
          tally(%{title: "suppressed", ignored: 6}),
          tally(%{title: "promoted", acted_on: 5})
        ])

      assert [first, second, third] = verdicts
      assert first.decision == :promote
      assert second.decision == :suppress
      assert third.decision == :observe
    end

    test "breaks ties within a decision by occurrence count" do
      verdicts =
        Scoring.score_all([
          tally(%{title: "fewer", ignored: 6}),
          tally(%{title: "more", ignored: 20})
        ])

      assert [first, _second] = verdicts
      assert first.tally.title == "more"
    end
  end

  describe "to_baseline_entries/2" do
    test "emits an entry only for suppressed patterns" do
      verdicts =
        Scoring.score_all([
          tally(%{title: "suppressed", ignored: 6}),
          tally(%{title: "promoted", acted_on: 5})
        ])

      entries = Scoring.to_baseline_entries(verdicts, [])

      assert [only] = entries
      assert only.title == "suppressed"
      assert only.ignored_count == 6
    end

    test "carries the highest severity observed for the pattern" do
      # Six ignored observations clears the suppression bar; the entry must
      # then carry the highest severity seen, not the first or a default.
      classified =
        for _ <- 1..5, do: {finding(%{severity: "low"}), :ignored}

      classified = classified ++ [{finding(%{severity: "medium"}), :ignored}]

      verdicts = Scoring.score_all(Scoring.tally(classified))
      entries = Scoring.to_baseline_entries(verdicts, classified)

      assert [only] = entries
      assert only.severity == "medium"
    end

    test "defaults to low severity when no findings are supplied" do
      verdicts = Scoring.score_all([tally(%{ignored: 6})])
      entries = Scoring.to_baseline_entries(verdicts, [])

      assert [only] = entries
      assert only.severity == "low"
    end

    test "produces no entries when nothing is suppressed" do
      verdicts = Scoring.score_all([tally(%{acted_on: 5})])

      assert Scoring.to_baseline_entries(verdicts, []) == []
    end
  end

  describe "thresholds" do
    test "suppression requires strictly more evidence than promotion" do
      assert Scoring.suppress_min_occurrences() > Scoring.promote_min_occurrences()
    end

    test "the promotion occurrence bar matches the repository-local convention" do
      # `Yoke.PRReview.Patterns` promotes at `Seen: 3+`; the cloud must agree or
      # the two stores will disagree about what "frequent" means.
      assert Scoring.promote_min_occurrences() == 3
    end
  end
end

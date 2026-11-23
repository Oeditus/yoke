defmodule Yoke.Cloud.Scoring do
  @moduledoc """
  Turns observed review outcomes into suppression and promotion decisions
  (`docs/YAAS.md` §4.2).

  This is the part of the paid service with real design content: the HTTP
  service around it is a thin wrapper that stores runs and serves the result of
  this module. Keeping the rule pure means it can be tested exhaustively without
  a database, a network, or a provider.

  ## The rule

  For each `{file, normalised title}` pattern, count how often findings matching
  it were acted on versus ignored, then compute Laplace-smoothed precision:

  ```
  score = (acted_on + 1) / (acted_on + ignored + 2)
  ```

  Smoothing matters because a pattern seen twice with one hit would otherwise
  score 0.5 with no evidence, and a pattern seen once with one hit would score
  1.0 and be promoted on a single observation. The prior pulls both toward 0.5
  until real evidence accumulates.

  ## Why the rule is deliberately dumb

  A review comment is not a bandit arm: you get one observation per pull
  request, and the same pattern may appear on many PRs. `Yoke.SelfImprove.Telemetry`
  implements a UCB1 bandit for model selection, which is the right tool when you
  can pull an arm repeatedly. Here you cannot, so a transparent frequency
  estimate is both more accurate and explainable to a customer who asks why a
  finding disappeared.

  ## Explainability is a product requirement

  Every decision carries the counts that produced it. The dashboard must be able
  to say "we suppressed 14 findings this week because your team ignored 5 or more
  of them previously", and an operator debugging a missing finding must be able
  to see exactly which observation suppressed it. A learned model that cannot
  answer that question is unsellable.
  """

  alias Yoke.Cloud.Baseline
  alias Yoke.Cloud.Outcome

  @typedoc """
  A pattern's accumulated evidence.

    * `:file` -- the file the findings were anchored to
    * `:title` -- the normalised title used for matching
    * `:acted_on` -- findings the developer acted on
    * `:ignored` -- findings the developer ignored after the PR merged
    * `:pending` -- findings with no verdict yet
  """
  @type tally :: %{
          file: String.t(),
          title: String.t(),
          acted_on: non_neg_integer(),
          ignored: non_neg_integer(),
          pending: non_neg_integer()
        }

  @typedoc "What the service should do with a pattern."
  @type decision :: :promote | :suppress | :observe

  @typedoc """
  A scoring verdict for one pattern.

    * `:decision` -- `:promote`, `:suppress`, or `:observe`
    * `:score` -- Laplace-smoothed precision, or `nil` when nothing is decisive
    * `:tally` -- the counts that produced the decision
    * `:reason` -- a one-line explanation suitable for a dashboard
  """
  @type verdict :: %{
          decision: decision(),
          score: float() | nil,
          tally: tally(),
          reason: String.t()
        }

  # A pattern must be seen at least this often before it can be promoted.
  # Matches the existing `Seen: 3+` convention in `Yoke.PRReview.Patterns`, so
  # the cloud and the repository-local pattern memory agree on what "frequent"
  # means.
  @promote_min_occurrences 3
  @promote_min_score 0.6

  # Suppression needs more evidence than promotion: hiding a real finding is a
  # worse failure than repeating a noisy one, so the bar is higher.
  @suppress_min_occurrences 5
  @suppress_max_score 0.2

  @doc "Returns the occurrence threshold below which a pattern is never promoted."
  @spec promote_min_occurrences() :: pos_integer()
  def promote_min_occurrences, do: @promote_min_occurrences

  @doc "Returns the score at or above which a frequent pattern is promoted."
  @spec promote_min_score() :: float()
  def promote_min_score, do: @promote_min_score

  @doc "Returns the occurrence threshold below which a pattern is never suppressed."
  @spec suppress_min_occurrences() :: pos_integer()
  def suppress_min_occurrences, do: @suppress_min_occurrences

  @doc "Returns the score at or below which a frequent pattern is suppressed."
  @spec suppress_max_score() :: float()
  def suppress_max_score, do: @suppress_max_score

  @doc """
  Groups classified findings into per-pattern tallies.

  `classified` is the `[{finding, verdict}]` list `Yoke.Cloud.Outcome` produces.
  Endorsements are excluded: praise that nobody acted on is not a false
  positive, so counting it would poison every score it touched.
  """
  @spec tally([{map(), Outcome.verdict()}]) :: [tally()]
  def tally(classified) when is_list(classified) do
    classified
    |> Enum.reject(fn {finding, _verdict} -> Yoke.PRReview.endorsement?(finding) end)
    |> Enum.group_by(fn {finding, _verdict} ->
      {finding.file, Baseline.normalize_title(finding.title)}
    end)
    |> Enum.map(fn {{file, title}, entries} ->
      verdicts = Enum.map(entries, &elem(&1, 1))

      %{
        file: file,
        title: title,
        acted_on: Enum.count(verdicts, &Outcome.positive?/1),
        ignored: Enum.count(verdicts, &Outcome.negative?/1),
        pending: Enum.count(verdicts, &(&1 == :pending))
      }
    end)
    |> Enum.sort_by(fn tally -> {tally.file, tally.title} end)
  end

  @doc """
  Scores one pattern's tally and returns the decision.

  Precedence is promote, then suppress, then observe. Promotion wins a tie
  because keeping a finding is the safe direction: a promoted pattern is a
  mandatory check the reviewer will surface, while a suppressed one is invisible.
  """
  @spec score(tally()) :: verdict()
  def score(%{acted_on: acted_on, ignored: ignored} = tally) do
    decisive = acted_on + ignored
    score = if decisive == 0, do: nil, else: smoothed(acted_on, ignored)
    decision = decide(score, decisive)

    %{
      decision: decision,
      score: score,
      tally: tally,
      reason: reason(decision, score, decisive)
    }
  end

  @doc """
  Scores every pattern and returns the verdicts, most actionable first.

  Sorted by decision (promote, suppress, observe) then by occurrence count
  descending, so a dashboard's first rows are the ones worth acting on.
  """
  @spec score_all([tally()]) :: [verdict()]
  def score_all(tallies) when is_list(tallies) do
    tallies
    |> Enum.map(&score/1)
    |> Enum.sort_by(fn verdict ->
      {decision_rank(verdict.decision), -occurrences(verdict.tally)}
    end)
  end

  @doc """
  Converts scored verdicts into the baseline entries `Yoke.Cloud.Baseline`
  consumes.

  Only `:suppress` verdicts become entries. A promoted pattern is not a
  suppression — it is a mandatory check, which the repository-local
  `Yoke.PRReview.Patterns` file already expresses — so it is deliberately not
  returned here.

  The entry's severity is the highest severity observed among the suppressed
  findings, so the baseline can only ever hide findings at or below what was
  actually ignored. `Yoke.Cloud.Baseline.apply_baseline/2` enforces the bound
  again on the runner side; this is defence in depth, not duplication, because
  the two sides can be running different versions.
  """
  @spec to_baseline_entries([verdict()], [{map(), Outcome.verdict()}]) :: [Baseline.entry()]
  def to_baseline_entries(verdicts, classified) when is_list(verdicts) do
    severities = severities_by_pattern(classified)

    verdicts
    |> Enum.filter(&(&1.decision == :suppress))
    |> Enum.map(fn verdict ->
      key = {verdict.tally.file, verdict.tally.title}

      %{
        file: verdict.tally.file,
        title: verdict.tally.title,
        severity: Map.get(severities, key, "low"),
        ignored_count: verdict.tally.ignored
      }
    end)
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp smoothed(acted_on, ignored) do
    Float.round((acted_on + 1) / (acted_on + ignored + 2), 4)
  end

  defp decide(nil, _decisive), do: :observe

  defp decide(score, decisive) do
    cond do
      decisive >= @promote_min_occurrences and score >= @promote_min_score -> :promote
      decisive >= @suppress_min_occurrences and score <= @suppress_max_score -> :suppress
      true -> :observe
    end
  end

  defp reason(:promote, score, decisive) do
    "promoted: #{decisive} decisive observations, precision #{format(score)} " <>
      "(needs >= #{@promote_min_occurrences} and >= #{@promote_min_score})"
  end

  defp reason(:suppress, score, decisive) do
    "suppressed: #{decisive} decisive observations, precision #{format(score)} " <>
      "(needs >= #{@suppress_min_occurrences} and <= #{@suppress_max_score})"
  end

  defp reason(:observe, nil, _decisive) do
    "observed: no decisive observations yet"
  end

  defp reason(:observe, score, decisive) do
    "observed: #{decisive} decisive observations, precision #{format(score)} " <>
      "(below the promotion bar, above the suppression bar)"
  end

  defp format(nil), do: "n/a"
  defp format(score), do: :erlang.float_to_binary(score * 1.0, decimals: 2)

  defp decision_rank(:promote), do: 0
  defp decision_rank(:suppress), do: 1
  defp decision_rank(:observe), do: 2

  defp occurrences(tally), do: tally.acted_on + tally.ignored + tally.pending

  # The highest severity seen for each pattern. Suppressing a pattern must never
  # hide a finding more severe than the ones actually observed, so the entry
  # carries the ceiling rather than a default.
  defp severities_by_pattern(classified) do
    classified
    |> Enum.reject(fn {finding, _verdict} -> Yoke.PRReview.endorsement?(finding) end)
    |> Enum.group_by(fn {finding, _verdict} ->
      {finding.file, Baseline.normalize_title(finding.title)}
    end)
    |> Map.new(fn {key, entries} ->
      severity =
        entries
        |> Enum.map(fn {finding, _verdict} -> finding.severity end)
        |> Enum.max_by(&Baseline.rank/1, fn -> "low" end)

      {key, severity}
    end)
  end
end

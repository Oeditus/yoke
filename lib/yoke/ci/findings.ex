defmodule Yoke.CI.Findings do
  @moduledoc """
  Classifies review findings for CI reporting (`docs/CI_PLAN.md` Phase 1.1).

  The review turn already produces schema-validated findings via
  `Yoke.PRReview.Findings.parse/1`, and `Yoke.PRReview.Context.validate_findings/2`
  rejects any finding not anchored to the reviewed diff. This module adds the
  three things CI reporting needs on top of that:

    1. **Classification** into `:issue` / `:endorsement`, reusing
       `Yoke.PRReview.endorsement?/1` so CI and the REPL never disagree.
    2. **Severity ranking**, so `--fail-on` can compare against a threshold.
    3. **Aggregation** into a report map the sinks render from.

  An endorsement is an observation, never a request for changes: it is
  reported, but it never gates a build and never counts toward
  `findings-count`.
  """

  alias Yoke.PRReview

  # Ordered from most to least severe. `info` sits below `low` so an
  # informational issue is reported but never gates at any threshold except
  # `--fail-on info`.
  @severity_rank %{"high" => 4, "medium" => 3, "low" => 2, "info" => 1}

  # Thresholds accepted by `--fail-on`. `never` disables gating entirely.
  @thresholds ~w(high medium low info never)

  @doc "Returns the accepted `--fail-on` thresholds, most severe first."
  @spec thresholds() :: [String.t()]
  def thresholds, do: @thresholds

  @doc """
  Returns the numeric rank of a severity string.

  Unknown severities rank as `0` (below everything), so a malformed
  severity can never accidentally gate a build.
  """
  @spec rank(String.t()) :: non_neg_integer()
  def rank(severity) when is_binary(severity) do
    Map.get(@severity_rank, String.downcase(String.trim(severity)), 0)
  end

  def rank(_), do: 0

  @doc """
  Returns true when `severity` is at or above `threshold`.

  `"never"` is never exceeded, so it always returns `false`.
  """
  @spec at_or_above?(String.t(), String.t()) :: boolean()
  def at_or_above?(_severity, "never"), do: false

  def at_or_above?(severity, threshold) do
    rank(severity) >= rank(threshold) and rank(severity) > 0
  end

  @doc """
  Splits findings into `{issues, endorsements}`.

  Delegates to `Yoke.PRReview.endorsement?/1` so the CI view and the
  interactive review view classify identically.
  """
  @spec classify([map()]) :: {[map()], [map()]}
  def classify(findings) when is_list(findings) do
    Enum.split_with(findings, fn finding -> not PRReview.endorsement?(finding) end)
  end

  @doc """
  Builds a report map from parsed findings.

  The report is the single input every sink renders from, so the step
  summary, the annotations, the artifact and the exit code can never
  disagree about what was found.

  Keys:

    * `:findings` -- every finding, in the order the model produced them
    * `:issues` / `:endorsements` -- the classification split
    * `:findings_count` -- number of issues (endorsements excluded)
    * `:max_severity` -- highest issue severity, or `"none"` when there are none
    * `:fail_on` -- the threshold in force
    * `:gating` -- the issues at or above the threshold, i.e. what fails the build
    * `:failed?` -- whether the run should exit non-zero
  """
  @spec report([map()], String.t()) :: map()
  def report(findings, fail_on) when is_list(findings) and is_binary(fail_on) do
    {issues, endorsements} = classify(findings)
    gating = Enum.filter(issues, &at_or_above?(&1.severity, fail_on))

    %{
      findings: findings,
      issues: issues,
      endorsements: endorsements,
      findings_count: length(issues),
      max_severity: max_severity(issues),
      fail_on: fail_on,
      gating: gating,
      failed?: gating != []
    }
  end

  @doc """
  Returns the highest severity among `findings`, or `"none"` when empty.

  Ties resolve to the first occurrence, which keeps the output stable across
  runs for identical input.
  """
  @spec max_severity([map()]) :: String.t()
  def max_severity([]), do: "none"

  def max_severity(findings) when is_list(findings) do
    findings
    |> Enum.map(& &1.severity)
    |> Enum.max_by(&rank/1, fn -> "none" end)
  end

  @doc """
  Returns the process exit code implied by a report.

  `0` when nothing gates, `1` when at least one finding is at or above the
  threshold. Kept as a named function so the exit-code policy in §4.6 of the
  plan lives in exactly one place.
  """
  @spec exit_code(map()) :: non_neg_integer()
  def exit_code(%{failed?: true}), do: 1
  def exit_code(_), do: 0
end

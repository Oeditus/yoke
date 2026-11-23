defmodule Yoke.Cloud.Outcome do
  @moduledoc """
  Classifies what became of a posted review finding (`docs/YAAS.md` Phase 0).

  The whole paid thesis rests on one measurable question: **when Yoke posts a
  finding, does the developer act on it?** This module answers that question
  from evidence GitHub already holds, without asking the customer to do
  anything extra.

  ## Signals, ranked by reliability

  | Signal | Evidence required | Verdict |
  | :--- | :--- | :--- |
  | Line changed in a later commit | The finding's `{file, line}` is not present unchanged in the newer head | `:acted_on` |
  | Comment resolved | Review thread `isResolved` is true | `:resolved` |
  | Explicit reaction | A thumbs-up or thumbs-down reaction on the comment | `:reacted_up` / `:reacted_down` |
  | PR merged with the line untouched | The PR merged and the line is unchanged | `:ignored` |
  | Nothing yet | The PR is still open and nothing has happened | `:pending` |

  ## Why line-change is the primary signal

  It needs no human action, so it works on every pull request rather than only
  the ones where somebody remembered to click a button. The other signals are
  refinements layered on top — see `classify/2` for the precedence order.

  ## What this module deliberately does not do

  It does not talk to GitHub. It takes already-fetched facts and returns a
  verdict, so the classification rules are unit-testable without a network
  call, a token, or a repository. Fetching lives in `Yoke.Cloud.GitHub`.
  """

  @typedoc "What became of a single finding."
  @type verdict :: :acted_on | :resolved | :reacted_up | :reacted_down | :ignored | :pending

  @typedoc """
  Facts about a finding's fate, as gathered by `Yoke.Cloud.GitHub`.

    * `:line_present` -- whether the finding's `{file, line}` still exists with
      the same content in the newer head. `nil` when unknown.
    * `:file_present` -- whether the file still exists at all. `nil` when unknown.
    * `:resolved` -- the review thread was resolved by a human.
    * `:reactions` -- reaction counts as `%{"+1" => n, "-1" => n}`.
    * `:pr_merged` -- the pull request has been merged.
    * `:review_fix` -- a commit inside the PR marks itself as a code-review fix
      and touches the finding's file.
  """
  @type evidence :: %{
          optional(:line_present) => boolean() | nil,
          optional(:file_present) => boolean() | nil,
          optional(:resolved) => boolean(),
          optional(:reactions) => %{optional(String.t()) => non_neg_integer()},
          optional(:pr_merged) => boolean(),
          optional(:review_fix) => boolean()
        }

  @doc """
  Classifies a finding's outcome from the evidence gathered about it.

  Precedence, most reliable first:

    1. A changed or deleted line means the code moved, so `:acted_on`.
    2. An accepted suggestion or an explicit thumbs-up means `:reacted_up`.
    3. A resolved thread with the line untouched means the comment was
       acknowledged without a code change, so `:resolved`.
    4. An explicit thumbs-down means `:reacted_down`.
    5. A merged PR with the line untouched means `:ignored`.
    6. Anything else is `:pending`.

  Endorsements are never classified as `:ignored`: praise that nobody acted on
  is not a false positive, so treating it as one would poison the precision
  score. Callers should exclude them before scoring (see `score/1`).
  """
  @spec classify(map(), evidence()) :: verdict()
  def classify(finding, evidence \\ %{}) when is_map(finding) do
    cond do
      # A commit inside the PR that marks itself as a code-review fix and
      # touches the finding's file is the strongest available signal: a human
      # read the comment and changed that file in response. It is checked
      # before line movement because a fix can address a finding without
      # moving the anchored line.
      evidence[:review_fix] == true -> :acted_on
      # The finding's anchor no longer exists in the newer head. Either the
      # line was edited or the file was deleted; both mean the reviewer's
      # point landed somewhere.
      evidence[:line_present] == false -> :acted_on
      evidence[:file_present] == false -> :acted_on
      positive_reaction?(evidence) -> :reacted_up
      evidence[:resolved] == true -> :resolved
      negative_reaction?(evidence) -> :reacted_down
      evidence[:pr_merged] == true and evidence[:line_present] == true -> :ignored
      true -> :pending
    end
  end

  @doc """
  Returns true when a verdict counts as the reviewer having been right.

  `:acted_on`, `:reacted_up` and `:resolved` are all positive: a resolved
  thread is a human acknowledging the comment, which is not the same as
  ignoring it.
  """
  @spec positive?(verdict()) :: boolean()
  def positive?(verdict), do: verdict in [:acted_on, :reacted_up, :resolved]

  @doc """
  Returns true when a verdict counts as the reviewer having been wrong.

  Only `:ignored` and `:reacted_down` are negative. `:pending` is excluded
  because an open PR is not evidence either way, and counting it as a miss
  would make every fresh review look like a false positive.
  """
  @spec negative?(verdict()) :: boolean()
  def negative?(verdict), do: verdict in [:ignored, :reacted_down]

  @doc """
  Computes Laplace-smoothed precision over classified findings
  (`docs/YAAS.md` §4.2).

  ```
  score = (acted_on + 1) / (acted_on + ignored + 2)
  ```

  Endorsements and `:pending` findings are excluded from both numerator and
  denominator: praise is not a claim that can be wrong, and an open PR has not
  answered yet.

  Returns `nil` when there is nothing to score, so a caller can distinguish
  "no data" from "zero precision" — a distinction that matters enormously when
  deciding whether the thesis has been validated.

  ## Options

    * `:kind` -- when `:issue` (the default), endorsements are excluded.
      Pass `:all` to score every finding.
  """
  @spec score([{map(), verdict()}], keyword()) :: float() | nil
  def score(classified, opts \\ []) when is_list(classified) do
    kind = Keyword.get(opts, :kind, :issue)

    verdicts =
      classified
      |> Enum.reject(fn {finding, _verdict} ->
        kind == :issue and Yoke.PRReview.endorsement?(finding)
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&(&1 == :pending))

    positives = Enum.count(verdicts, &positive?/1)
    negatives = Enum.count(verdicts, &negative?/1)

    if positives + negatives == 0 do
      nil
    else
      Float.round((positives + 1) / (positives + negatives + 2), 4)
    end
  end

  @doc """
  Aggregates classified findings into a report map.

  Keys:

    * `:total` -- every finding considered
    * `:scored` -- findings with a decisive verdict (`:pending` excluded)
    * `:pending` -- findings still awaiting an answer
    * `:by_verdict` -- counts per verdict
    * `:precision` -- `score/2`, or `nil` when nothing is decisive
    * `:acted_on_rate` -- positive verdicts over decisive verdicts, or `nil`
  """
  @spec report([{map(), verdict()}], keyword()) :: map()
  def report(classified, opts \\ []) when is_list(classified) do
    verdicts = Enum.map(classified, &elem(&1, 1))
    by_verdict = Enum.frequencies(verdicts)
    scored = Enum.reject(verdicts, &(&1 == :pending))
    positives = Enum.count(scored, &positive?/1)

    %{
      total: length(verdicts),
      scored: length(scored),
      pending: Enum.count(verdicts, &(&1 == :pending)),
      by_verdict: by_verdict,
      precision: score(classified, opts),
      acted_on_rate: if(scored == [], do: nil, else: Float.round(positives / length(scored), 4))
    }
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp positive_reaction?(evidence) do
    count(evidence, "+1") > 0
  end

  defp negative_reaction?(evidence) do
    count(evidence, "-1") > 0
  end

  defp count(evidence, key) do
    case evidence[:reactions] do
      %{} = reactions -> Map.get(reactions, key, 0)
      _ -> 0
    end
  end
end

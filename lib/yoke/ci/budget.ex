defmodule Yoke.CI.Budget do
  @moduledoc """
  Hard, fail-closed run budgets (`docs/CI_PLAN.md` Phase 1.3).

  A review that runs away — a looping model, a pathological diff, a provider
  that keeps returning tool calls — must be stopped rather than allowed to burn
  a CI job's wall clock and the user's API quota. Every budget here is
  **fail-closed**: exceeding it aborts the run with an error, never a warning.

  ## Budgets

  | Key | Meaning |
  | :--- | :--- |
  | `max_tool_calls` | Total tool calls a single run may make |
  | `max_wall_clock_s` | Wall-clock seconds a single run may take |
  | `max_tokens` | Total tokens (prompt + completion) a run may consume |
  | `max_cost_usd` | Estimated USD a run may spend |

  All four are read from the policy document (see
  `Yoke.Interaction.Policy`), so a repository can tighten them per-project
  without code changes.

  ## Why a struct rather than four loose counters

  The caller needs one value to thread through the loop and one predicate to
  ask. Keeping the arithmetic here — rather than inline in
  `Yoke.Brain.Session` — means it can be unit-tested exhaustively without
  starting a session actor or a fake provider.

  ## Cost estimation

  Cost uses the same per-million-token prices the status bar and `/cost` use
  (`price_per_million_prompt_tokens` / `price_per_million_completion_tokens`),
  defaulting to DeepSeek's published V3 rates, so a CI run and an interactive
  session never disagree about what a review cost.
  """

  alias Yoke.Interaction.Policy

  @default_prompt_price 0.14
  @default_completion_price 0.28

  defstruct [
    # Configured ceilings. `nil` means "unlimited" for that dimension.
    :max_tool_calls,
    :max_wall_clock_s,
    :max_tokens,
    :max_cost_usd,
    # Running totals.
    tool_calls: 0,
    prompt_tokens: 0,
    completion_tokens: 0,
    # Monotonic start time, in milliseconds.
    started_at: nil,
    # Per-million-token prices used for the cost estimate.
    prompt_price: @default_prompt_price,
    completion_price: @default_completion_price
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds a budget from the effective policy for `cwd`.

  `opts` may override any ceiling (used by `--max-cost`), and may supply
  `:prompt_price` / `:completion_price` from the repository config.
  """
  @spec from_policy(String.t(), keyword()) :: t()
  def from_policy(cwd \\ ".", opts \\ []) do
    policy = Policy.load(cwd)

    %__MODULE__{
      max_tool_calls: Keyword.get(opts, :max_tool_calls, policy["max_tool_calls"]),
      max_wall_clock_s: Keyword.get(opts, :max_wall_clock_s, policy["max_wall_clock_s"]),
      max_tokens: Keyword.get(opts, :max_tokens, policy["max_tokens"]),
      max_cost_usd: Keyword.get(opts, :max_cost_usd, policy["max_cost_usd"]),
      prompt_price: Keyword.get(opts, :prompt_price, @default_prompt_price),
      completion_price: Keyword.get(opts, :completion_price, @default_completion_price),
      started_at: now_ms()
    }
  end

  @doc "Starts the wall clock on an existing budget."
  @spec start(t()) :: t()
  def start(%__MODULE__{} = budget), do: %{budget | started_at: now_ms()}

  @doc "Records one tool call."
  @spec record_tool_call(t()) :: t()
  def record_tool_call(%__MODULE__{} = budget) do
    %{budget | tool_calls: budget.tool_calls + 1}
  end

  @doc """
  Records token usage from one model response.

  Accepts the `usage` map the provider returns (`:prompt_tokens` /
  `:completion_tokens`, atom or string keys) and tolerates `nil`.
  """
  @spec record_usage(t(), map() | nil) :: t()
  def record_usage(%__MODULE__{} = budget, nil), do: budget

  def record_usage(%__MODULE__{} = budget, usage) when is_map(usage) do
    %{
      budget
      | prompt_tokens: budget.prompt_tokens + fetch_int(usage, :prompt_tokens),
        completion_tokens: budget.completion_tokens + fetch_int(usage, :completion_tokens)
    }
  end

  @doc "Returns the total tokens consumed so far."
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{} = budget), do: budget.prompt_tokens + budget.completion_tokens

  @doc "Returns the estimated cost in USD consumed so far."
  @spec cost_usd(t()) :: float()
  def cost_usd(%__MODULE__{} = budget) do
    budget.prompt_tokens * budget.prompt_price / 1_000_000 +
      budget.completion_tokens * budget.completion_price / 1_000_000
  end

  @doc "Returns elapsed wall-clock seconds since `started_at`."
  @spec elapsed_s(t()) :: non_neg_integer()
  def elapsed_s(%__MODULE__{started_at: nil}), do: 0

  def elapsed_s(%__MODULE__{started_at: started_at}) do
    max(div(now_ms() - started_at, 1000), 0)
  end

  @doc """
  Returns `:ok` when every budget still has headroom, or
  `{:error, reason}` naming the first exhausted budget.

  The reason string is user-facing: it appears in the CI log and in the
  artifact, so it says exactly which ceiling was hit and at what value.
  """
  @spec check(t()) :: :ok | {:error, String.t()}
  def check(%__MODULE__{} = budget) do
    cond do
      exceeded?(budget.max_tool_calls, budget.tool_calls) ->
        {:error,
         "Tool-call budget exhausted (#{budget.tool_calls}/#{budget.max_tool_calls}). " <>
           "Raise max_tool_calls in .yoke/policy.json or narrow the review range."}

      exceeded?(budget.max_tokens, total_tokens(budget)) ->
        {:error,
         "Token budget exhausted (#{total_tokens(budget)}/#{budget.max_tokens}). " <>
           "Raise max_tokens in .yoke/policy.json or narrow the review range."}

      exceeded?(budget.max_cost_usd, cost_usd(budget)) ->
        {:error,
         "Cost budget exhausted ($#{format_usd(cost_usd(budget))}/$#{format_usd(budget.max_cost_usd)}). " <>
           "Raise max_cost_usd in .yoke/policy.json or narrow the review range."}

      exceeded?(budget.max_wall_clock_s, elapsed_s(budget)) ->
        {:error,
         "Wall-clock budget exhausted (#{elapsed_s(budget)}s/#{budget.max_wall_clock_s}s). " <>
           "Raise max_wall_clock_s in .yoke/policy.json or narrow the review range."}

      true ->
        :ok
    end
  end

  @doc "Returns a JSON-encodable snapshot for the artifact and step summary."
  @spec to_report(t()) :: map()
  def to_report(%__MODULE__{} = budget) do
    %{
      "tool_calls" => budget.tool_calls,
      "max_tool_calls" => budget.max_tool_calls,
      "total_tokens" => total_tokens(budget),
      "max_tokens" => budget.max_tokens,
      "cost_usd" => Float.round(cost_usd(budget), 6),
      "max_cost_usd" => budget.max_cost_usd,
      "elapsed_s" => elapsed_s(budget),
      "max_wall_clock_s" => budget.max_wall_clock_s
    }
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  # A `nil` ceiling means unlimited, so it is never exceeded.
  defp exceeded?(nil, _used), do: false

  defp exceeded?(limit, used) when is_number(limit) and is_number(used),
    do: used >= limit

  defp exceeded?(_limit, _used), do: false

  defp fetch_int(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp format_usd(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 4)
  end
end

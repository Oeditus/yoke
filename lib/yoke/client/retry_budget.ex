defmodule Yoke.Client.RetryBudget do
  @moduledoc """
  A single cumulative attempt and wall-clock budget shared by every retry layer
  that participates in one provider request.

  Yoke retried provider failures at two independent levels: the HTTP client
  (`Yoke.Client.DeepSeekAPI`) retried transport errors and transient statuses,
  and the agent harness (`Yoke.Brain.Session`) retried the whole turn. Each
  layer kept its own counter, so a single user turn could issue up to
  `3 * 4 = 12` provider attempts while reporting two unrelated progress
  sequences ("2 attempts left", then "attempt 1/3"). Issue #22 documents the
  result: roughly twelve minutes of silent retrying followed by a prompt that
  recommended yet another retry.

  This struct replaces the per-layer counters with one budget:

    * `:max_attempts` -- total provider attempts allowed for the request,
      counted across every layer.
    * `:deadline_ms` -- a cumulative wall-clock deadline measured from
      `:started_at`, so slow attempts cannot extend the total time by being
      retried.
    * `:max_backoff_ms` -- a ceiling on exponential backoff, so the delay
      between attempts never grows without bound.
    * `:identical_failure_limit` -- a circuit breaker. Consecutive attempts
      that fail with the *same* classification and detail stop early instead
      of consuming the remaining budget, because a deterministic rejection
      will not change.

  The budget is immutable: every transition returns a new struct, so a caller
  can thread it through nested retry loops without shared mutable state.

  A budget is created with `new/1` and can be serialized to a plain map with
  `to_opts/1` so it survives being passed as an option between layers.
  """

  @default_max_attempts 6
  @default_total_timeout_ms 120_000
  @default_max_backoff_ms 8_000
  @default_identical_failure_limit 2

  @type failure :: {:error, term()}

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          total_timeout_ms: pos_integer(),
          max_backoff_ms: non_neg_integer(),
          identical_failure_limit: pos_integer(),
          started_at: integer(),
          attempts: non_neg_integer(),
          last_failure: {term(), term()} | nil,
          identical_failures: non_neg_integer()
        }

  defstruct max_attempts: @default_max_attempts,
            total_timeout_ms: @default_total_timeout_ms,
            max_backoff_ms: @default_max_backoff_ms,
            identical_failure_limit: @default_identical_failure_limit,
            started_at: nil,
            attempts: 0,
            last_failure: nil,
            identical_failures: 0

  @doc """
  Builds a budget from keyword options, falling back to the compiled defaults.

  Recognized keys (all optional):

    * `:max_attempts` -- positive integer, default #{@default_max_attempts}
    * `:total_timeout_ms` -- positive integer, default #{@default_total_timeout_ms}
    * `:max_backoff_ms` -- non-negative integer, default #{@default_max_backoff_ms}
    * `:identical_failure_limit` -- positive integer, default #{@default_identical_failure_limit}

  Invalid values are ignored in favour of the default, so a malformed config
  entry cannot disable the bound entirely.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_attempts: positive_opt(opts, :max_attempts, @default_max_attempts),
      total_timeout_ms: positive_opt(opts, :total_timeout_ms, @default_total_timeout_ms),
      max_backoff_ms: non_negative_opt(opts, :max_backoff_ms, @default_max_backoff_ms),
      identical_failure_limit:
        positive_opt(opts, :identical_failure_limit, @default_identical_failure_limit),
      started_at: now_ms()
    }
  end

  @doc """
  Returns a budget for `opts`, reusing an existing one when present.

  `opts[:retry_budget]` may hold a `t:t/0` (already started) or a keyword list
  of `new/1` options. Anything else yields a fresh budget from `opts`.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :retry_budget) do
      %__MODULE__{} = budget -> budget
      budget_opts when is_list(budget_opts) -> new(budget_opts)
      _ -> new(opts)
    end
  end

  @doc """
  Serializes the budget into keyword options for `from_opts/1`.

  The absolute `:started_at` is preserved so a budget handed to another layer
  keeps counting from the original request rather than restarting its clock.
  """
  @spec to_opts(t()) :: keyword()
  def to_opts(%__MODULE__{} = budget) do
    [
      retry_budget: %{
        budget
        | started_at: budget.started_at || now_ms()
      }
    ]
  end

  @doc """
  Records that one more provider attempt is starting.

  Returns `{:ok, budget}` when the attempt is permitted, or
  `{:error, reason}` when the budget is already exhausted. The reason is a
  human-readable sentence suitable for surfacing to the user.
  """
  @spec begin_attempt(t()) :: {:ok, t()} | {:error, String.t()}
  def begin_attempt(%__MODULE__{} = budget) do
    cond do
      budget.attempts >= budget.max_attempts ->
        {:error, exhausted_message(budget, "attempt limit")}

      expired?(budget) ->
        {:error, exhausted_message(budget, "time limit")}

      true ->
        {:ok, %{budget | attempts: budget.attempts + 1}}
    end
  end

  @doc """
  Records a failed attempt and reports whether another one may be tried.

  `classification` identifies the failure family (for example `:transport` or
  `{:status, 503}`) and `detail` identifies the specific failure (for example
  `:closed` or the response body). Two consecutive failures with the same pair
  trip the circuit breaker, because repeating an identical failure is
  evidence that another attempt will fail the same way.

  Returns `{:retry, budget, delay_ms}` when another attempt is allowed, or
  `{:halt, budget, reason}` when the budget or the breaker stops the loop.
  """
  @spec record_failure(t(), term(), term()) ::
          {:retry, t(), non_neg_integer()} | {:halt, t(), String.t()}
  def record_failure(%__MODULE__{} = budget, classification, detail) do
    # Compare against the previous failure *before* recording this one, or the
    # streak would always match itself and trip the breaker on the first retry.
    identical? = identical_failure?(budget, classification, detail)

    budget = %{budget | last_failure: {classification, detail}}

    budget =
      if identical? do
        %{budget | identical_failures: budget.identical_failures + 1}
      else
        %{budget | identical_failures: 1}
      end

    cond do
      budget.identical_failures >= budget.identical_failure_limit ->
        {:halt, budget,
         "stopped after #{budget.identical_failures} identical failures " <>
           "(#{describe_failure(classification, detail)})"}

      budget.attempts >= budget.max_attempts ->
        {:halt, budget, exhausted_message(budget, "attempt limit")}

      expired?(budget) ->
        {:halt, budget, exhausted_message(budget, "time limit")}

      true ->
        {:retry, budget, backoff_ms(budget)}
    end
  end

  @doc "Returns the exponential backoff for the current attempt count, capped."
  @spec backoff_ms(t()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{attempts: attempts, max_backoff_ms: cap}) do
    # 500ms, 1s, 2s, 4s, ... capped. `attempts` is already >= 1 here.
    exponent = max(attempts - 1, 0)
    min(500 * Integer.pow(2, exponent), cap)
  end

  @doc "Returns the elapsed wall-clock milliseconds since the budget started."
  @spec elapsed_ms(t()) :: non_neg_integer()
  def elapsed_ms(%__MODULE__{started_at: nil}), do: 0

  def elapsed_ms(%__MODULE__{started_at: started_at}) do
    max(now_ms() - started_at, 0)
  end

  @doc "Returns true when the cumulative deadline has passed."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = budget) do
    elapsed_ms(budget) >= budget.total_timeout_ms
  end

  @doc """
  Returns a one-line summary of the budget, e.g.
  `"6 attempts in 121.4s (limit 6 attempts / 120s)"`.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = budget) do
    "#{budget.attempts} #{pluralize(budget.attempts, "attempt")} in " <>
      "#{format_seconds(elapsed_ms(budget))} (limit #{budget.max_attempts} attempts / " <>
      "#{format_seconds(budget.total_timeout_ms)})"
  end

  defp identical_failure?(%__MODULE__{last_failure: previous}, classification, detail) do
    previous == {classification, detail}
  end

  defp describe_failure(classification, detail) do
    "#{inspect(classification)}: #{inspect(detail)}"
  end

  defp exhausted_message(%__MODULE__{} = budget, which) do
    "provider retry budget exhausted (#{which}): #{summary(budget)}"
  end

  defp format_seconds(ms) when is_integer(ms) do
    "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp non_negative_opt(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

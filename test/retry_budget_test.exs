defmodule Yoke.Client.RetryBudgetTest do
  # These tests use wall-clock deadlines, so they must not run concurrently
  # with tests that shrink the same application-level timeouts.
  use ExUnit.Case, async: true

  alias Yoke.Client.RetryBudget

  describe "new/1" do
    test "uses the documented defaults" do
      budget = RetryBudget.new()

      assert budget.max_attempts == 6
      assert budget.total_timeout_ms == 120_000
      assert budget.max_backoff_ms == 8_000
      assert budget.identical_failure_limit == 2
      assert budget.attempts == 0
      assert is_integer(budget.started_at)
    end

    test "honours explicit options" do
      budget = RetryBudget.new(max_attempts: 3, total_timeout_ms: 500, max_backoff_ms: 100)

      assert budget.max_attempts == 3
      assert budget.total_timeout_ms == 500
      assert budget.max_backoff_ms == 100
    end

    test "ignores invalid values so a malformed config cannot disable the bound" do
      budget =
        RetryBudget.new(
          max_attempts: 0,
          total_timeout_ms: "120",
          max_backoff_ms: -1,
          identical_failure_limit: nil
        )

      assert budget.max_attempts == 6
      assert budget.total_timeout_ms == 120_000
      assert budget.max_backoff_ms == 8_000
      assert budget.identical_failure_limit == 2
    end
  end

  describe "from_opts/1 and to_opts/1" do
    test "reuses an existing budget so nested layers share one counter" do
      budget = RetryBudget.new(max_attempts: 4)
      assert RetryBudget.from_opts(retry_budget: budget) == budget
    end

    test "accepts a keyword list of budget options" do
      budget = RetryBudget.from_opts(retry_budget: [max_attempts: 2])
      assert budget.max_attempts == 2
    end

    test "round-trips through keyword options without restarting the clock" do
      budget = RetryBudget.new(max_attempts: 5)
      {:ok, budget} = RetryBudget.begin_attempt(budget)

      restored = budget |> RetryBudget.to_opts() |> RetryBudget.from_opts()

      assert restored.attempts == 1
      assert restored.max_attempts == 5
      assert restored.started_at == budget.started_at
    end
  end

  describe "begin_attempt/1" do
    test "increments the attempt counter" do
      {:ok, budget} = RetryBudget.begin_attempt(RetryBudget.new(max_attempts: 2))
      assert budget.attempts == 1

      {:ok, budget} = RetryBudget.begin_attempt(budget)
      assert budget.attempts == 2
    end

    test "refuses an attempt once the attempt limit is reached" do
      budget = %{RetryBudget.new(max_attempts: 1) | attempts: 1}

      assert {:error, reason} = RetryBudget.begin_attempt(budget)
      assert reason =~ "attempt limit"
      assert reason =~ "1 attempts"
    end

    test "refuses an attempt once the cumulative deadline has passed" do
      budget = %{
        RetryBudget.new(total_timeout_ms: 50)
        | started_at: System.monotonic_time(:millisecond) - 1_000
      }

      assert {:error, reason} = RetryBudget.begin_attempt(budget)
      assert reason =~ "time limit"
    end
  end

  describe "record_failure/3" do
    test "allows a retry and returns exponential backoff" do
      # Backoff is derived from the attempt number, which the client advances
      # with `begin_attempt/1` before each request.
      {:ok, budget} = RetryBudget.begin_attempt(RetryBudget.new(max_attempts: 6))

      assert {:retry, next, 500} = RetryBudget.record_failure(budget, :transport, :closed)
      assert next.attempts == 1

      # A different failure detail keeps the exponential schedule growing
      # instead of tripping the identical-failure breaker.
      {:ok, next} = RetryBudget.begin_attempt(next)
      assert {:retry, next, 1_000} = RetryBudget.record_failure(next, :transport, :econnreset)

      {:ok, next} = RetryBudget.begin_attempt(next)
      assert {:retry, _next, 2_000} = RetryBudget.record_failure(next, :timeout, :timeout)
    end

    test "caps the backoff at max_backoff_ms" do
      budget = %{RetryBudget.new(max_attempts: 10, max_backoff_ms: 1_500) | attempts: 5}

      assert {:retry, _next, 1_500} = RetryBudget.record_failure(budget, :transport, :closed)
    end

    test "trips the circuit breaker after identical consecutive failures" do
      budget = %{RetryBudget.new(max_attempts: 6) | attempts: 1}

      assert {:retry, budget, _} = RetryBudget.record_failure(budget, :transport, :closed)

      assert {:halt, halted, reason} = RetryBudget.record_failure(budget, :transport, :closed)
      assert reason =~ "2 identical failures"
      assert reason =~ ":closed"
      # The breaker stops well before the attempt budget is spent.
      assert halted.attempts < halted.max_attempts
    end

    test "a different failure detail resets the identical-failure streak" do
      budget = %{RetryBudget.new(max_attempts: 6) | attempts: 1}

      assert {:retry, budget, _} = RetryBudget.record_failure(budget, :transport, :closed)
      assert budget.identical_failures == 1

      assert {:retry, budget, _} = RetryBudget.record_failure(budget, :transport, :econnreset)
      assert budget.identical_failures == 1

      assert {:retry, budget, _} = RetryBudget.record_failure(budget, :transport, :closed)
      assert budget.identical_failures == 1
    end

    test "halts when the attempt limit is reached" do
      budget = %{RetryBudget.new(max_attempts: 2) | attempts: 2}

      assert {:halt, _budget, reason} = RetryBudget.record_failure(budget, :transport, :closed)
      assert reason =~ "attempt limit"
    end

    test "halts when the cumulative deadline has passed" do
      budget = %{
        RetryBudget.new(total_timeout_ms: 10, identical_failure_limit: 100)
        | attempts: 1,
          started_at: System.monotonic_time(:millisecond) - 5_000
      }

      assert {:halt, _budget, reason} = RetryBudget.record_failure(budget, :transport, :closed)
      assert reason =~ "time limit"
    end
  end

  describe "summary/1" do
    test "reports attempts and elapsed time against the configured limits" do
      budget = %{RetryBudget.new(max_attempts: 6, total_timeout_ms: 120_000) | attempts: 3}

      summary = RetryBudget.summary(budget)

      assert summary =~ "3 attempts in"
      assert summary =~ "limit 6 attempts / 120.0s"
    end

    test "uses the singular form for a single attempt" do
      budget = %{RetryBudget.new() | attempts: 1}
      assert RetryBudget.summary(budget) =~ "1 attempt in"
    end
  end
end

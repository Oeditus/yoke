defmodule Yoke.CI.BudgetTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Yoke.CI.Budget

  defp budget(attrs) do
    struct(
      %Budget{
        max_tool_calls: 10,
        max_wall_clock_s: 60,
        max_tokens: 1000,
        max_cost_usd: 1.0,
        started_at: System.monotonic_time(:millisecond)
      },
      attrs
    )
  end

  describe "from_policy/2" do
    test "reads every ceiling from the policy file", %{tmp_dir: dir} do
      Yoke.Interaction.Policy.write(dir, %{
        "max_tool_calls" => 5,
        "max_wall_clock_s" => 30,
        "max_tokens" => 500,
        "max_cost_usd" => 0.25
      })

      b = Budget.from_policy(dir)

      assert b.max_tool_calls == 5
      assert b.max_wall_clock_s == 30
      assert b.max_tokens == 500
      assert b.max_cost_usd == 0.25
    end

    test "falls back to defaults with no policy file", %{tmp_dir: dir} do
      b = Budget.from_policy(dir)

      assert b.max_tool_calls == 120
      assert b.max_wall_clock_s == 900
      assert b.max_tokens == 400_000
      assert b.max_cost_usd == 2.0
    end

    test "explicit options override the policy", %{tmp_dir: dir} do
      Yoke.Interaction.Policy.write(dir, %{"max_cost_usd" => 5.0})
      b = Budget.from_policy(dir, max_cost_usd: 0.1)

      assert b.max_cost_usd == 0.1
    end

    test "starts the wall clock" do
      b = Budget.from_policy(".")
      assert is_integer(b.started_at)
    end
  end

  describe "check/1 — tool calls" do
    test "passes below the ceiling" do
      assert :ok = Budget.check(budget(%{tool_calls: 9}))
    end

    test "fails at the ceiling (fail-closed)" do
      assert {:error, reason} = Budget.check(budget(%{tool_calls: 10}))
      assert reason =~ "Tool-call budget exhausted"
      assert reason =~ "10/10"
    end

    test "fails above the ceiling" do
      assert {:error, _} = Budget.check(budget(%{tool_calls: 11}))
    end

    test "a nil ceiling means unlimited" do
      assert :ok = Budget.check(budget(%{max_tool_calls: nil, tool_calls: 1_000_000}))
    end
  end

  describe "check/1 — tokens" do
    test "passes below the ceiling" do
      assert :ok = Budget.check(budget(%{prompt_tokens: 400, completion_tokens: 599}))
    end

    test "fails at the ceiling" do
      assert {:error, reason} =
               Budget.check(budget(%{prompt_tokens: 500, completion_tokens: 500}))

      assert reason =~ "Token budget exhausted"
      assert reason =~ "1000/1000"
    end
  end

  describe "check/1 — cost" do
    test "passes below the ceiling" do
      # 1M prompt tokens at $0.14/M is $0.14, well under $1.00. The token
      # ceiling is lifted so this test observes the cost check specifically.
      assert :ok = Budget.check(budget(%{prompt_tokens: 1_000_000, max_tokens: nil}))
    end

    test "fails at the ceiling" do
      # 1M completion tokens at $0.28/M is $0.28; 4M is $1.12 > $1.00.
      assert {:error, reason} =
               Budget.check(budget(%{completion_tokens: 4_000_000, max_tokens: nil}))

      assert reason =~ "Cost budget exhausted"
    end

    test "uses the configured per-million prices" do
      b = budget(%{prompt_tokens: 1_000_000, prompt_price: 2.0, completion_price: 0.0})
      assert_in_delta Budget.cost_usd(b), 2.0, 0.0001
    end
  end

  describe "check/1 — wall clock" do
    test "passes when the run is young" do
      assert :ok = Budget.check(budget(%{started_at: System.monotonic_time(:millisecond)}))
    end

    test "fails once the ceiling has elapsed" do
      started = System.monotonic_time(:millisecond) - 61_000
      assert {:error, reason} = Budget.check(budget(%{started_at: started}))
      assert reason =~ "Wall-clock budget exhausted"
    end

    test "a budget with no start time reports zero elapsed" do
      assert Budget.elapsed_s(budget(%{started_at: nil})) == 0
    end
  end

  describe "check/1 — precedence" do
    test "names the first exhausted budget in a stable order" do
      b = budget(%{tool_calls: 10, prompt_tokens: 5000})
      assert {:error, reason} = Budget.check(b)
      assert reason =~ "Tool-call budget"
    end
  end

  describe "recording" do
    test "record_tool_call/1 increments" do
      b = budget(%{tool_calls: 0}) |> Budget.record_tool_call() |> Budget.record_tool_call()
      assert b.tool_calls == 2
    end

    test "record_usage/2 accumulates atom-keyed usage" do
      b = Budget.record_usage(budget(%{}), %{prompt_tokens: 10, completion_tokens: 5})
      assert b.prompt_tokens == 10
      assert b.completion_tokens == 5
      assert Budget.total_tokens(b) == 15
    end

    test "record_usage/2 accumulates string-keyed usage" do
      b = Budget.record_usage(budget(%{}), %{"prompt_tokens" => 7, "completion_tokens" => 3})
      assert Budget.total_tokens(b) == 10
    end

    test "record_usage/2 tolerates nil and malformed usage" do
      assert Budget.total_tokens(Budget.record_usage(budget(%{}), nil)) == 0
      assert Budget.total_tokens(Budget.record_usage(budget(%{}), %{})) == 0
      assert Budget.total_tokens(Budget.record_usage(budget(%{}), %{prompt_tokens: "x"})) == 0
      assert Budget.total_tokens(Budget.record_usage(budget(%{}), %{prompt_tokens: -5})) == 0
    end
  end

  describe "to_report/1" do
    test "exposes every dimension for the artifact" do
      report = Budget.to_report(budget(%{tool_calls: 3, prompt_tokens: 100}))

      assert report["tool_calls"] == 3
      assert report["max_tool_calls"] == 10
      assert report["total_tokens"] == 100
      assert report["max_tokens"] == 1000
      assert is_float(report["cost_usd"])
      assert is_integer(report["elapsed_s"])
    end
  end
end

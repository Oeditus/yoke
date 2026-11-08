defmodule Yoke.Workflow.PlanTest do
  use ExUnit.Case, async: true

  alias Yoke.Workflow.Plan

  describe "draft/1,2" do
    test "returns a well-formed {:ok, plan_map} in offline/mock mode" do
      # Force mock mode regardless of the developer's configured provider.
      # The mock's split response is free-form
      # prose (not parseable JSON), so build_plan collapses the split and the
      # plan comes back with an empty steps list -- still a valid, well-formed
      # plan map.
      assert {:ok, plan} = Plan.draft("Add a login feature with tests", mock: true)
      assert is_map(plan)
      assert is_binary(plan["summary"]) and plan["summary"] != ""
      assert is_list(plan["steps"])
    end

    test "accepts an explicit mock: true option" do
      assert {:ok, plan} = Plan.draft("Refactor the ordering module", mock: true)
      assert is_map(plan)
      assert is_binary(plan["summary"])
      assert is_list(plan["steps"])
    end

    test "steps is empty when the task cannot be split (declined/unparseable)" do
      # Force mock mode so the model response is deterministic prose that
      # doesn't decode to a multi-subtask JSON object.
      assert {:ok, %{"summary" => summary, "steps" => steps}} =
               Plan.draft("Fix the typo in the README", mock: true)

      assert is_binary(summary)
      assert steps == []
    end

    test "returns {:ok, plan_map} or {:error, _} without raising for any task text" do
      case Plan.draft("", mock: true) do
        {:ok, %{"summary" => summary, "steps" => steps}} ->
          assert is_binary(summary)
          assert is_list(steps)

        {:error, _reason} ->
          :ok
      end
    end
  end
end

defmodule Yoke.TaskEngineTest do
  use ExUnit.Case, async: true
  # `Orchestrator.execute_batch/3` needs `Yoke.TaskEngine.TaskSupervisor`.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.Hands.Executor, as: HandsExecutor
  alias Yoke.TaskEngine.Orchestrator

  setup do
    session_state = %{
      session_id: "test_task_engine",
      cwd: ".",
      hands: %HandsExecutor{mode: :local}
    }

    {:ok, session_state: session_state}
  end

  test "executes multiple tools concurrently and returns results in order", %{
    session_state: state
  } do
    tool_calls = [
      %{id: "tc_1", name: "list_dir", arguments: %{"path" => "."}},
      %{id: "tc_2", name: "list_dir", arguments: %{"path" => "lib"}},
      %{id: "tc_3", name: "list_dir", arguments: %{"path" => "test"}}
    ]

    results = Orchestrator.execute_batch(tool_calls, state)

    assert length(results) == 3

    [{tc1, res1}, {tc2, res2}, {tc3, res3}] = results

    assert tc1.id == "tc_1"
    assert match?({:ok, _}, res1)

    assert tc2.id == "tc_2"
    assert match?({:ok, _}, res2)

    assert tc3.id == "tc_3"
    assert match?({:ok, _}, res3)
  end

  test "handles tool execution failures gracefully without crashing orchestrator", %{
    session_state: state
  } do
    tool_calls = [
      %{id: "tc_valid", name: "list_dir", arguments: %{"path" => "."}},
      %{id: "tc_invalid", name: "unknown_non_existent_tool", arguments: %{}}
    ]

    results = Orchestrator.execute_batch(tool_calls, state)

    assert length(results) == 2
    [{_tc1, res1}, {_tc2, res2}] = results

    assert match?({:ok, _}, res1)
    assert match?({:error, _}, res2)
  end
end

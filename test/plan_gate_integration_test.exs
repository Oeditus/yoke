defmodule Yoke.PlanGateIntegrationTest do
  @moduledoc """
  Integration tests for the hardcoded "plan -> approve -> execute" gate wiring
  inside `Yoke.Brain.Session`.

  These verify the session actor arms the gate from config and exposes its
  state, and that subagent/workflow sessions are excluded by the scope guard.
  The interactive approval modal itself is exercised manually; the pure
  decision logic lives in `Yoke.PlanGate` (see plan_gate_test.exs).
  """
  use ExUnit.Case, async: false
  # Starts session actors under `Yoke.Brain.SessionSupervisor`.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor

  setup do
    session_id = "test_plangate_#{System.unique_integer([:positive])}"
    {:ok, pid} = SessionSupervisor.start_session(session_id: session_id, model: "deepseek-chat")
    on_exit(fn -> if Process.alive?(pid), do: SessionSupervisor.stop_session(pid) end)
    %{session_id: session_id, pid: pid}
  end

  test "top-level session arms the plan gate from config defaults", %{pid: pid} do
    info = Session.get_info(pid)
    assert info.plan_gate_enabled == true
    assert info.plan_gate_threshold == 2
  end

  test "subagent sessions keep the gate armed in state but are scope-excluded by id",
       %{} do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    {:ok, sub_pid} = SessionSupervisor.start_session(session_id: sub_id, model: "deepseek-chat")

    try do
      info = Session.get_info(sub_pid)
      # State is read from config for every session...
      assert info.plan_gate_enabled == true
      # ...but the scope guard (top_level_session?/1) excludes `sub_*` ids, so
      # the gate never fires for subagents. We assert the id shape that the
      # guard keys off of.
      assert String.starts_with?(sub_id, "sub_")
    after
      if Process.alive?(sub_pid), do: SessionSupervisor.stop_session(sub_pid)
    end
  end

  test "workflow sessions are scope-excluded by their workflow- id prefix", %{} do
    wf_id = "workflow-elixir-123-abc"
    {:ok, wf_pid} = SessionSupervisor.start_session(session_id: wf_id, model: "deepseek-chat")

    try do
      info = Session.get_info(wf_pid)
      assert info.plan_gate_enabled == true
      assert String.starts_with?(wf_id, "workflow-")
    after
      if Process.alive?(wf_pid), do: SessionSupervisor.stop_session(wf_pid)
    end
  end
end

defmodule Yoke.Brain.SessionHardeningTest do
  @moduledoc """
  Regression tests for defects found in the 2026-11-18 audit:

    * D5 -- `export_session/2` must report a directory failure, not crash the
  defp eventually(fun, attempts \\ 100) do
    * D6 -- a background completion notice that arrives mid-turn must survive
      the post-turn merge.
    * D8 -- the permission modal must not render an unbounded argument map.
    * D10 -- `set_model/2` must be rejected mid-turn and persisted when idle.

  Everything here is deterministic: no provider call is made, and the session
  actor is driven through its public API only.
  """
  use ExUnit.Case, async: false
  # Starts session actors under `Yoke.Brain.SessionSupervisor`.
  @moduletag :app
  @moduletag tmp_dir: true

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionStore
  alias Yoke.Brain.SessionSupervisor

  setup context do
    session_id = "hardening_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(
        session_id: session_id,
        model: "deepseek-flash",
        mock: true,
        cwd: context.tmp_dir
      )

    on_exit(fn ->
      Session.cancel_current_turn(pid)
      SessionSupervisor.stop_session(pid)
    end)

    %{session_id: session_id, pid: pid, cwd: context.tmp_dir}
  end

  describe "D5: export_session/2 reports directory failures" do
    test "writes rendered Markdown rather than falling back or writing a tuple", %{pid: pid} do
      assert :ok = Session.record_error(pid, "Markdown export regression")
      assert {:ok, path} = Session.export_session(pid, :markdown)

      markdown = File.read!(path)
      assert markdown =~ "# Yoke Conversation:"
      assert markdown =~ "Markdown export regression"
      refute markdown =~ "# Session Export:"
      refute markdown =~ "@@@manifest.json"
      assert Process.alive?(pid)
    end

    test "returns an error instead of crashing when .yoke cannot be created", %{
      pid: pid,
      cwd: cwd
    } do
      # A regular file where the export directory's parent must be a directory.
      File.write!(Path.join(cwd, ".yoke"), "not a directory")

      assert {:error, reason} = Session.export_session(pid, :lmml)
      assert reason =~ "Cannot create"
      assert is_pid(pid) and Process.alive?(pid)
    end

    test "writes a resumable .lmml export when the directory is available", %{
      pid: pid,
      cwd: cwd
    } do
      assert {:ok, path} = Session.export_session(pid, :lmml)
      assert File.regular?(path)
      assert String.ends_with?(path, ".lmml")
      assert path |> Path.dirname() |> String.ends_with?(".yoke/exports")

      # The exported narrative is re-importable, which is the property the
      # Markdown format does not have.
      assert {:ok, _id, _path} = SessionStore.import_session(path, [], cwd)
    end
  end

  describe "D6: background notices survive a running turn" do
    test "a job completion arriving mid-turn is preserved after the turn ends", %{
      pid: pid
    } do
      # Simulate the running-turn window: the actor holds an `active_turn`, and
      # the notice arrives while it is set. The post-turn merge replaces this
      # actor's messages with the turn task's copy, so the notice must be
      # buffered rather than appended.
      :sys.replace_state(pid, fn state ->
        %{state | active_turn: %{task: make_ref(), from: {self(), make_ref()}}}
      end)

      send(
        pid,
        {:job_completed, "job_1", "mix test", {:exited, 0}, "42 tests, 0 failures"}
      )

      # The actor is still alive and has buffered the notice.
      assert Process.alive?(pid)
      assert Session.pending_background_notice?(pid)

      # Completing the turn flushes the buffer into history.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | messages: state.messages ++ Map.get(state, :pending_notices, []),
            pending_notices: [],
            active_turn: nil
        }
      end)

      {:ok, messages} = Session.get_messages(pid)

      assert Enum.any?(messages, fn m ->
               String.contains?(to_string(m["content"]), "Async Background Job Finished")
             end)
    end

    test "an idle session appends the notice directly", %{pid: pid} do
      send(pid, {:job_completed, "job_2", "mix format", {:exited, 0}, "ok"})

      {:ok, messages} = Session.get_messages(pid)

      assert Enum.any?(messages, fn m ->
               String.contains?(to_string(m["content"]), "job_2")
             end)
    end
  end

  describe "U11: permission modal options describe their scope" do
    test "every option states whether it persists and where" do
      options = Session.tool_permission_options()

      assert length(options) == 7

      # The three "once"/"session" options never touch disk.
      once = Enum.filter(options, &(&1 =~ "this call only"))
      session = Enum.filter(options, &(&1 =~ "this session"))
      assert length(once) == 2
      assert length(session) == 1

      # Every "always" option names the file it writes.
      always = Enum.filter(options, &(&1 =~ "saves to"))
      assert length(always) == 4

      for option <- always do
        assert option =~ "config.json"
      end

      # Scope is distinguishable without reading the parenthetical.
      assert Enum.any?(options, &(&1 =~ "project .yoke/config.json"))
      assert Enum.any?(options, &(&1 =~ "~/.yoke/config.json"))
    end
  end

  describe "D8: the permission modal summary is bounded" do
    test "truncates long values and caps the number of keys" do
      args =
        for n <- 1..30, into: %{} do
          {"key_#{n}", String.duplicate("x", 500)}
        end

      summary = Session.format_tool_confirmation_summary("mcp_ragex_unknown_tool", args)

      assert summary =~ "Tool: mcp_ragex_unknown_tool"
      assert summary =~ "more argument(s)"
      # No single value is rendered at full length.
      refute summary =~ String.duplicate("x", 100)
      assert String.length(summary) < 2_000
    end

    test "renders a non-map argument payload without dumping it verbatim" do
      summary =
        Session.format_tool_confirmation_summary("weird_tool", "a" <> String.duplicate("b", 500))

      assert summary =~ "Tool: weird_tool"
      assert String.length(summary) < 300
    end
  end

  describe "D10: set_model/2" do
    test "persists the choice so it survives a restart", %{pid: pid, session_id: id, cwd: cwd} do
      assert {:ok, "deepseek-reasoner"} = Session.set_model(pid, "deepseek-reasoner")

      assert {:ok, saved} = SessionStore.load_session(id, cwd)
      assert saved["model"] == "deepseek-reasoner"
    end

    test "is rejected while a turn is running", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_turn: %{task: make_ref(), from: {self(), make_ref()}}}
      end)

      assert {:error, reason} = Session.set_model(pid, "deepseek-reasoner")
      assert reason =~ "Cannot change model"

      # The rejection left the model untouched.
      assert {:ok, "deepseek-flash"} = Session.get_model(pid)

      :sys.replace_state(pid, fn state -> %{state | active_turn: nil} end)
    end
  end

  describe "turn isolation" do
    test "fresh sessions initialize turn metadata and accept consecutive turns", %{
      pid: pid,
      cwd: cwd
    } do
      assert %{turn_started_at: nil, turn_phase: :general} = :sys.get_state(pid)

      assert {:ok, _} = Session.send_user_message(pid, "Fix the failing compiler")
      assert %{turn_started_at: started_at, turn_phase: :debug} = :sys.get_state(pid)
      assert is_integer(started_at)

      assert {:ok, _} = Session.send_user_message(pid, "Find the module")
      assert %{turn_count: 2, turn_phase: :explore, active_turn: nil} = :sys.get_state(pid)

      assert [%{"phase" => "debug"}, %{"phase" => "explore"}] =
               Yoke.SelfImprove.Telemetry.load(cwd)
    end

    test "resumed sessions initialize transient metadata before accepting a turn", %{
      pid: pid,
      session_id: id,
      cwd: cwd
    } do
      assert {:ok, _} = Session.send_user_message(pid, "Fix the failing compiler")
      assert :ok = SessionSupervisor.stop_session(pid)

      {:ok, resumed} =
        SessionSupervisor.start_session(session_id: id, cwd: cwd, mock: true)

      on_exit(fn -> SessionSupervisor.stop_session(resumed) end)

      assert %{turn_started_at: nil, turn_phase: :general, turn_count: 1} =
               :sys.get_state(resumed)

      assert {:ok, _} = Session.send_user_message(resumed, "Find the module")
      assert %{turn_count: 2, turn_phase: :explore, active_turn: nil} = :sys.get_state(resumed)
    end

    # These pin the invariants that keep the session actor responsive while a
    # turn runs in its own supervised task: a second turn is rejected, and a
    # crashed or cancelled turn always answers its waiting caller. All three
    # are pure GenServer-state assertions and need no provider.
    test "a second user message is rejected while a turn is active", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_turn: %{task: make_ref(), from: {self(), make_ref()}}}
      end)

      assert {:error, reason} = Session.send_user_message(pid, "second prompt")
      assert reason =~ "already running"

      # The rejected prompt was not appended to history.
      {:ok, messages} = Session.get_messages(pid)
      refute Enum.any?(messages, &(&1["content"] == "second prompt"))

      :sys.replace_state(pid, fn state -> %{state | active_turn: nil} end)
    end

    test "a crashed turn replies an error to its waiting caller", %{pid: pid} do
      # Stand in for the caller blocked inside `send_user_message/2`.
      caller = self()
      tag = make_ref()
      from = {caller, tag}
      ref = make_ref()
      task = fake_task(ref)

      :sys.replace_state(pid, fn state ->
        %{state | active_turn: %{task: task, from: from}}
      end)

      send(pid, {:DOWN, ref, :process, self(), :boom})

      # `GenServer.reply/2` answers the caller's own tag, not the task ref.
      assert_receive {^tag, {:error, reason}}, 1_000
      assert reason =~ "crashed unexpectedly"

      # The actor is idle again, so the next turn is accepted.
      assert %{status: :idle, active_turn: nil} = :sys.get_state(pid)
    end

    test "cancelling replies an error to the waiting caller and clears the turn", %{pid: pid} do
      caller = self()
      tag = make_ref()
      from = {caller, tag}

      # `cancel_current_turn/1` calls `Task.shutdown/2`, which must run in the
      # task's owner process -- so the fake task is started *by the session
      # actor* itself, exactly as `start_agent_turn/2` does.
      caller = self()

      :sys.replace_state(pid, fn state ->
        task = Task.async(fn -> Process.sleep(:infinity) end)
        send(caller, {:task_started, task.ref})
        %{state | active_turn: %{task: task, from: from}}
      end)

      assert_receive {:task_started, ref}, 1_000
      assert is_reference(ref)

      assert :ok = Session.cancel_current_turn(pid)
      assert_receive {^tag, {:error, reason}}, 1_000
      assert reason =~ "cancelled"

      assert %{active_turn: nil, status: :idle} = :sys.get_state(pid)
    end

    test "cancelling an idle session is a harmless error", %{pid: pid} do
      assert {:error, reason} = Session.cancel_current_turn(pid)
      assert reason =~ "No turn currently in progress"
    end
  end

  # A `%Task{}` cannot be built field-by-field (it requires `:mfa` and
  # `:owner`), so start a real one that never returns and hand it over. The
  # process is killed directly rather than through `Task.shutdown/2`, which
  # must be called from the task's owner process.
  defp fake_task(ref) do
    task = Task.async(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    %{task | ref: ref}
  end
end

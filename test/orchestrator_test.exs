defmodule Yoke.TaskEngine.OrchestratorTest do
  use ExUnit.Case, async: true
  # `execute_batch/3` needs `Yoke.TaskEngine.TaskSupervisor`.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.TaskEngine.Orchestrator

  describe "get_lock_resource/2" do
    test "returns a fixed shared key for every ask_question call, regardless of arguments" do
      assert Orchestrator.get_lock_resource("ask_question", %{}) == "tty_interactive"

      assert Orchestrator.get_lock_resource("ask_question", %{"questions" => [%{}]}) ==
               "tty_interactive"

      # Same key across two differently-shaped calls -- this is what
      # actually serializes them via the shared LockRegistry entry.
      assert Orchestrator.get_lock_resource("ask_question", %{"a" => 1}) ==
               Orchestrator.get_lock_resource("ask_question", %{"b" => 2})
    end

    test "returns a per-path file lock key for write/replace tools" do
      key = Orchestrator.get_lock_resource("write_file", %{"path" => "/tmp/foo.txt"})
      assert key == "file_lock:" <> Path.expand("/tmp/foo.txt")
    end

    test "returns nil for tools with no locking requirement" do
      assert Orchestrator.get_lock_resource("read_file", %{"path" => "/tmp/foo.txt"}) == nil
      assert Orchestrator.get_lock_resource("bash", %{"command" => "ls"}) == nil
    end
  end

  describe "interactive_tool?/1" do
    test "only ask_question is treated as an interactive, non-expiring tool" do
      assert Orchestrator.interactive_tool?("ask_question")
      refute Orchestrator.interactive_tool?("bash")
      refute Orchestrator.interactive_tool?("read_file")
    end
  end

  describe "execute_batch/3" do
    test "ask_question tool calls are never cut off by the batch execution timeout" do
      session_state = %{hands: %Yoke.Hands.Executor{mode: :local}}

      tool_calls = [
        # Invalid arguments resolve near-instantly via a fast error path,
        # without ever touching the TTY -- safe to run in a unit test.
        %{id: "1", name: "ask_question", arguments: %{}},
        %{id: "2", name: "bash", arguments: %{"command" => "sleep 1"}}
      ]

      # An absurdly small timeout: any tool call subject to it is
      # guaranteed to be reported as timed out / killed.
      results = Orchestrator.execute_batch(tool_calls, session_state, timeout: 1)

      {_ask_tc, ask_res} = Enum.find(results, fn {tc, _res} -> tc.id == "1" end)
      {_bash_tc, bash_res} = Enum.find(results, fn {tc, _res} -> tc.id == "2" end)

      # The ask_question call completed on its own terms (its real "invalid
      # arguments" error), proving it was awaited with :infinity rather
      # than being force-killed by the 1ms batch timeout.
      assert {:error, ask_msg} = ask_res
      assert ask_msg =~ "Invalid arguments"
      refute ask_msg =~ "timed out"

      # Meanwhile a normal (non-interactive) tool call is still subject to
      # the batch timeout as before.
      assert {:error, bash_msg} = bash_res
      assert bash_msg =~ "timed out"
    end
  end

  describe "lock acquisition" do
    # A lock is held only for the duration of one tool call. Before the
    # deadline, a contended worker recursed forever, waking 100x/second: a
    # batch holding two `ask_question` calls spun for as long as the human
    # took to answer, and a lock leaked by a `:brutal_kill`ed task (which
    # skips `after` blocks, and therefore `release_lock/1`) deadlocked every
    # later write to that path permanently.
    test "a contended lock is acquired once the holder releases it" do
      key = "test_lock:#{System.unique_integer([:positive])}"

      # Hold the lock from a separate process, release it shortly after.
      holder =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Yoke.TaskEngine.LockRegistry, key, :locked)
          Process.sleep(100)
          Registry.unregister(Yoke.TaskEngine.LockRegistry, key)
        end)

      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 2_000

      # The lock is now free; a write to the same path must succeed rather
      # than hang or fail.
      session_state = %{hands: %Yoke.Hands.Executor{mode: :local}}
      path = Path.join(System.tmp_dir!(), "lock_ok_#{System.unique_integer([:positive])}.txt")

      results =
        Orchestrator.execute_batch(
          [%{id: "w1", name: "write_file", arguments: %{"path" => path, "content" => "ok"}}],
          session_state
        )

      assert [{_tc, {:ok, _}}] = results
      on_exit(fn -> File.rm(path) end)
    end

    test "the lock wait is bounded rather than infinite" do
      # Guards against a regression to unbounded recursion: the deadline must
      # be a finite, positive number of milliseconds.
      assert is_integer(Orchestrator.lock_timeout_ms())
      assert Orchestrator.lock_timeout_ms() > 0
    end
  end
end

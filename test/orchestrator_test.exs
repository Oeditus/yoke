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

  describe "long_running_command?/1" do
    test "recognises server, watcher, and REPL commands" do
      assert Orchestrator.long_running_command?("./mvnw quarkus:dev")
      assert Orchestrator.long_running_command?("mvn quarkus:dev")
      assert Orchestrator.long_running_command?("./mvnw spring-boot:run")
      assert Orchestrator.long_running_command?("npm run dev")
      assert Orchestrator.long_running_command?("docker compose up -d")
      assert Orchestrator.long_running_command?("mix phx.server")
      assert Orchestrator.long_running_command?("tail -f logs/app.log")
    end

    test "does not treat one-shot build and test commands as long running" do
      refute Orchestrator.long_running_command?("./mvnw clean install")
      refute Orchestrator.long_running_command?("./mvnw test")
      refute Orchestrator.long_running_command?("mix test")
      refute Orchestrator.long_running_command?("cargo build")
      refute Orchestrator.long_running_command?("ls -la")
    end
  end

  describe "long_running_tool?/1" do
    test "classifies shell-executing tool calls by their command" do
      assert Orchestrator.long_running_tool?(%{
               name: "bash",
               arguments: %{"command" => "./mvnw quarkus:dev"}
             })

      refute Orchestrator.long_running_tool?(%{
               name: "bash",
               arguments: %{"command" => "./mvnw clean install"}
             })
    end

    test "ignores non-shell tools even when their arguments mention a server" do
      refute Orchestrator.long_running_tool?(%{
               name: "write_file",
               arguments: %{"path" => "dev.sh", "content" => "./mvnw quarkus:dev"}
             })
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

    test "a long-running server command is not reported as a timeout when allowed" do
      session_state = %{hands: %Yoke.Hands.Executor{mode: :local}}

      tool_calls = [
        %{
          id: "dev",
          name: "bash",
          arguments: %{"command" => "echo 'Quarkus dev mode started' # ./mvnw quarkus:dev"}
        }
      ]

      # `allow_long_running: true` is what the session passes for real turns;
      # the command itself is a fast stand-in for a server that never returns.
      results =
        Orchestrator.execute_batch(tool_calls, session_state,
          timeout: 1,
          allow_long_running: true
        )

      assert [{_tc, res}] = results
      assert {:ok, out} = res
      assert out =~ "Quarkus dev mode started"
    end

    test "a timed-out long-running command explains how to recover" do
      session_state = %{hands: %Yoke.Hands.Executor{mode: :local}}

      tool_calls = [
        %{
          id: "dev",
          name: "bash",
          arguments: %{"command" => "sleep 5 # ./mvnw quarkus:dev"}
        }
      ]

      # Without `allow_long_running`, the hard timeout still applies -- but the
      # error must point the model at the background-job escape hatch instead
      # of leaving it to retry the same blocking command.
      results = Orchestrator.execute_batch(tool_calls, session_state, timeout: 1)

      assert [{_tc, res}] = results
      assert {:error, msg} = res
      assert msg =~ "timed out"
      assert msg =~ "async: true"
      assert msg =~ "long-lived process"
    end
  end

  describe "lock acquisition" do
    # Exercise actual contention on the tool's file_lock key, rather than
    # waiting for an unrelated lock holder to exit before starting a tool.
    test "a contended lock is acquired once the holder releases it" do
      path = Path.join(System.tmp_dir!(), "lock_ok_#{System.unique_integer([:positive])}.txt")
      key = Orchestrator.get_lock_resource("write_file", %{"path" => path})
      caller = self()
      on_exit(fn -> File.rm(path) end)

      holder =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Yoke.TaskEngine.LockRegistry, key, :locked)
          send(caller, :lock_held)
          receive do: (:release -> Registry.unregister(Yoke.TaskEngine.LockRegistry, key))
        end)

      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
      assert_receive :lock_held

      session_state = %{hands: %Yoke.Hands.Executor{mode: :local}}

      worker =
        Task.async(fn ->
          Orchestrator.execute_batch(
            [%{id: "w1", name: "write_file", arguments: %{"path" => path, "content" => "ok"}}],
            session_state
          )
        end)

      assert Task.yield(worker, 50) == nil
      refute File.exists?(path)
      send(holder, :release)
      assert [{_tc, {:ok, _}}] = Task.await(worker)
      assert File.read!(path) == "ok"
    end

    test "the configured lock wait is finite and positive" do
      assert is_integer(Orchestrator.lock_timeout_ms())
      assert Orchestrator.lock_timeout_ms() > 0
    end
  end
end

defmodule Yoke.Brain.AgentLoopSessionTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Brain.Session
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    for {name, keys} <- [
          {Yoke.Registry, :unique},
          {Yoke.PubSubRegistry, :duplicate},
          {Yoke.TaskEngine.TaskRegistry, :duplicate},
          {Yoke.TaskEngine.LockRegistry, :unique},
          {Yoke.PackageRegistry, :duplicate}
        ] do
      unless Process.whereis(name),
        do: start_supervised!({Registry, keys: keys, name: name}, id: name)
    end

    unless Process.whereis(Yoke.TaskEngine.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: Yoke.TaskEngine.TaskSupervisor})

    unless Process.whereis(Yoke.Plugin.Loader), do: start_supervised!(Yoke.Plugin.Loader)
    :ok
  end

  test "progress after a warning gives a later loop its own first warning", %{tmp_dir: dir} do
    pid =
      session(dir, [
        call("first"),
        call("first"),
        call("different"),
        call("different"),
        Fixture.choice("Finished")
      ])

    assert {:ok, %{content: "Finished"}} = Session.send_user_message(pid, "Perform the task")
    assert {:ok, messages} = Session.get_messages(pid)

    warnings =
      Enum.filter(messages, fn msg ->
        msg["role"] == "user" and is_binary(msg["content"]) and
          String.starts_with?(msg["content"], "SYSTEM NOTICE: Repetitive tool loop detected")
      end)

    assert [_, _] = warnings
  end

  test "immediate repetition after a warning still stops an unyielding subagent", %{tmp_dir: dir} do
    pid = session(dir, [call("same"), call("same"), call("same")])

    assert {:error, "Turn stopped: agent stuck in infinite tool loop (period 1)."} =
             Session.send_user_message(pid, "Perform the task")
  end

  defp call(value), do: Fixture.tool_choice("loop_test_tool", %{"value" => value})

  defp session(dir, responses) do
    {listen, server, endpoint} = Fixture.provider(self(), responses)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    start_supervised!(
      {Session,
       session_id: "sub_loop_test_#{System.unique_integer([:positive])}",
       cwd: dir,
       api_key: "",
       model: "loop-test",
       endpoint: endpoint,
       permission_mode: :auto_approve,
       max_tool_depth: 8}
    )
  end
end

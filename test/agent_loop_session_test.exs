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

  test "a narrated plan without tool calls continues the turn instead of ending it",
       %{tmp_dir: dir} do
    pid =
      session(dir, [
        Fixture.choice("Now I have all the information I need. Let me implement the method."),
        Fixture.choice("Implemented the method.")
      ])

    assert {:ok, %{content: "Implemented the method."}} =
             Session.send_user_message(pid, "Implement addArticle/1")

    assert_receive {:review_request, first}
    assert_receive {:review_request, second}

    [_, first_turn] = first["messages"]
    assert first_turn["role"] == "user"

    # The second request must carry the narrated text and the continuation notice.
    assert Enum.any?(second["messages"], fn msg ->
             msg["role"] == "assistant" and
               String.contains?(msg["content"] || "", "Let me implement the method")
           end)

    assert Enum.any?(second["messages"], fn msg ->
             msg["role"] == "user" and
               String.starts_with?(msg["content"] || "", "SYSTEM NOTICE: You described")
           end)

    assert {:ok, messages} = Session.get_messages(pid)
    assert List.last(messages)["content"] == "Implemented the method."
  end

  test "narrated plans stop being re-prompted after the bounded number of notices",
       %{tmp_dir: dir} do
    narrated = Fixture.choice("Let me implement the method now.")
    pid = session(dir, [narrated, narrated, narrated, narrated])

    assert {:ok, %{content: "Let me implement the method now."}} =
             Session.send_user_message(pid, "Implement addArticle/1")

    assert {:ok, messages} = Session.get_messages(pid)

    notices =
      Enum.filter(messages, fn msg ->
        msg["role"] == "user" and
          String.starts_with?(msg["content"] || "", "SYSTEM NOTICE: You described")
      end)

    assert [_, _] = notices
  end

  test "a completed answer ends the turn without a continuation notice", %{tmp_dir: dir} do
    pid = session(dir, [Fixture.choice("The method is implemented and tests pass.")])

    assert {:ok, %{content: "The method is implemented and tests pass."}} =
             Session.send_user_message(pid, "Implement addArticle/1")

    assert_receive {:review_request, _request}
    refute_receive {:review_request, _request}, 200

    assert {:ok, messages} = Session.get_messages(pid)

    refute Enum.any?(messages, fn msg ->
             String.starts_with?(msg["content"] || "", "SYSTEM NOTICE: You described")
           end)
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
       plan_gate_enabled: false,
       max_tool_depth: 8}
    )
  end
end

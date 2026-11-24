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

  describe "explicit questions" do
    test "default_system_prompt includes explicit question guidance unless opted out", %{
      tmp_dir: dir
    } do
      assert Session.default_system_prompt(dir) =~ "Explicit Questions (`ask_question`)"

      refute Session.default_system_prompt(dir, explicit_questions_enabled: false) =~
               "Explicit Questions (`ask_question`)"
    end

    test "nudges tool-free response with an unresolved tension to call ask_question", %{
      tmp_dir: dir
    } do
      ask_call =
        Fixture.tool_choice("ask_question", %{
          "questions" => [
            %{
              "question" => "Should the feature be opt-out?",
              "options" => ["Yes (opt-out)", "No (opt-in)"]
            }
          ]
        })

      pid =
        session(
          dir,
          [
            Fixture.choice(
              "There's one tension I need to settle before writing code: whether this should be opt-in or opt-out."
            ),
            ask_call,
            Fixture.choice("Understood, implementing as opt-out.")
          ],
          session_id: "explicit_q_test_#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{content: "Understood, implementing as opt-out."}} =
               Session.send_user_message(pid, "Add the feature")

      assert_receive {:review_request, _first}
      assert_receive {:review_request, second}

      assert Enum.any?(second["messages"], fn msg ->
               msg["role"] == "user" and
                 String.starts_with?(
                   msg["content"] || "",
                   "SYSTEM NOTICE: Your response contained an implicit question"
                 )
             end)
    end

    test "bounds explicit question nudges to one per turn", %{tmp_dir: dir} do
      implicit =
        Fixture.choice(
          "Tension I need to settle before writing code: should this default to true?"
        )

      pid =
        session(
          dir,
          [implicit, implicit, implicit],
          session_id: "explicit_q_bound_#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{content: content}} = Session.send_user_message(pid, "Implement feature")
      assert content =~ "Tension I need to settle"

      assert {:ok, messages} = Session.get_messages(pid)

      notices =
        Enum.filter(messages, fn msg ->
          msg["role"] == "user" and
            String.starts_with?(
              msg["content"] || "",
              "SYSTEM NOTICE: Your response contained an implicit question"
            )
        end)

      assert [_single_notice] = notices
    end

    test "opting out disables explicit question nudging", %{tmp_dir: dir} do
      implicit =
        Fixture.choice(
          "There's one tension I need to settle before writing code: should this be opt-out?"
        )

      pid =
        session(
          dir,
          [implicit],
          session_id: "explicit_q_optout_#{System.unique_integer([:positive])}",
          explicit_questions_enabled: false
        )

      assert Session.get_info(pid).explicit_questions_enabled == false

      assert {:ok, %{content: content}} = Session.send_user_message(pid, "Implement feature")
      assert content =~ "tension I need to settle"

      assert_receive {:review_request, first}
      refute_receive {:review_request, _second}, 200

      [system_msg | _] = first["messages"]
      refute system_msg["content"] =~ "Explicit Questions (`ask_question`)"
    end

    test "set_explicit_questions/2 toggles nudging on a running session", %{tmp_dir: dir} do
      implicit =
        Fixture.choice("Before writing code, I need to decide whether to use ETS or GenServer.")

      pid =
        session(
          dir,
          [implicit],
          session_id: "explicit_q_toggle_#{System.unique_integer([:positive])}"
        )

      assert Session.get_info(pid).explicit_questions_enabled == true
      assert {:ok, false} = Session.set_explicit_questions(pid, false)
      assert Session.get_info(pid).explicit_questions_enabled == false

      assert {:ok, %{content: content}} = Session.send_user_message(pid, "Implement storage")
      assert content =~ "Before writing code"
      assert_receive {:review_request, _first}
      refute_receive {:review_request, _second}, 200
    end

    test "subagent sessions do not trigger explicit question nudging", %{tmp_dir: dir} do
      implicit =
        Fixture.choice(
          "There's a tension I need to settle before writing code: should this be opt-out?"
        )

      pid = session(dir, [implicit])

      assert {:ok, %{content: content}} = Session.send_user_message(pid, "Implement feature")
      assert content =~ "tension I need to settle"
      assert_receive {:review_request, _first}
      refute_receive {:review_request, _second}, 200
    end
  end

  describe "invalid/truncated tool argument recovery" do
    test "steers model to use smaller targeted edits on truncated write_file and succeeds", %{
      tmp_dir: dir
    } do
      pid =
        session(dir, [
          truncated_tool_choice("write_file", "{\"path\": \"big.ex\", \"content\": \"defmodule"),
          Fixture.choice("Applied the change using smaller incremental edits.")
        ])

      assert {:ok, %{content: "Applied the change using smaller incremental edits."}} =
               Session.send_user_message(pid, "Update big.ex")

      assert_receive {:review_request, _first}
      assert_receive {:review_request, second}

      assert Enum.any?(second["messages"], fn msg ->
               msg["role"] == "user" and
                 String.contains?(
                   msg["content"] || "",
                   "SYSTEM NOTICE: Your previous `write_file`"
                 ) and
                 String.contains?(msg["content"] || "", "replace_file")
             end)
    end

    test "temporarily disables write_file on second failure, uses alternative tools, and restores write_file",
         %{tmp_dir: dir} do
      target = Path.join(dir, "sample.ex")
      File.write!(target, "old_value\n")

      truncated =
        truncated_tool_choice("write_file", "{\"path\": \"sample.ex\", \"content\": \"new")

      pid =
        session(dir, [
          truncated,
          truncated,
          Fixture.tool_choice("replace_file", %{
            "path" => target,
            "target" => "old_value",
            "replacement" => "new_value"
          }),
          Fixture.choice("Replaced the target using replace_file.")
        ])

      assert {:ok, %{content: "Replaced the target using replace_file."}} =
               Session.send_user_message(pid, "Update sample.ex")

      assert_receive {:review_request, first}
      assert_receive {:review_request, second}
      assert_receive {:review_request, third}
      assert_receive {:review_request, fourth}

      tool_names = fn req ->
        Enum.map(req["tools"] || [], &get_in(&1, ["function", "name"]))
      end

      assert "write_file" in tool_names.(first)
      assert "write_file" in tool_names.(second)
      refute "write_file" in tool_names.(third)
      assert "replace_file" in tool_names.(third)
      # Restored automatically after a successful response
      assert "write_file" in tool_names.(fourth)

      assert File.read!(target) == "new_value\n"
    end

    test "returns a meaningful actionable error after bounded recovery retries are exhausted", %{
      tmp_dir: dir
    } do
      truncated =
        truncated_tool_choice("write_file", "{\"path\": \"big.ex\", \"content\": \"defmodule")

      pid = session(dir, [truncated, truncated, truncated])

      assert {:error, reason} = Session.send_user_message(pid, "Write big.ex")
      assert reason =~ "repeatedly produced truncated JSON arguments for `write_file`"
      assert reason =~ "replace_file"
      assert reason =~ "max_tokens"
      assert reason =~ "/model"

      assert_receive {:review_request, _attempt_1}
      assert_receive {:review_request, _attempt_2}
      assert_receive {:review_request, _attempt_3}
      refute_receive {:review_request, _extra}, 200
    end
  end

  defp truncated_tool_choice(name, raw_args) do
    %{
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "tool-trunc-1",
                "type" => "function",
                "function" => %{
                  "name" => name,
                  "arguments" => raw_args
                }
              }
            ]
          },
          "finish_reason" => "length"
        }
      ],
      "usage" => %{"prompt_tokens" => 50, "completion_tokens" => 4096}
    }
  end

  defp call(value), do: Fixture.tool_choice("loop_test_tool", %{"value" => value})

  defp session(dir, responses, extra_opts \\ []) do
    {listen, server, endpoint} = Fixture.provider(self(), responses)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    opts =
      Keyword.merge(
        [
          session_id: "sub_loop_test_#{System.unique_integer([:positive])}",
          cwd: dir,
          api_key: "",
          model: "loop-test",
          endpoint: endpoint,
          permission_mode: :auto_approve,
          plan_gate_enabled: false,
          max_tool_depth: 8
        ],
        extra_opts
      )

    start_supervised!({Session, opts})
  end
end

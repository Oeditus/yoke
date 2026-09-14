defmodule Yoke.BrainSessionTest do
  use ExUnit.Case, async: false

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Plugin.Loader, as: PluginLoader

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, pid} = SessionSupervisor.start_session(session_id: session_id, model: "deepseek-chat")
    %{session_id: session_id, pid: pid}
  end

  test "session actor initializes with default state", %{pid: pid, session_id: session_id} do
    info = Session.get_info(pid)
    assert info.session_id == session_id
    assert info.model == "deepseek-chat"
    assert info.hands_mode == :local
    assert info.tools_count > 0
  end

  test "model selection switching", %{pid: pid} do
    assert {:ok, "deepseek-reasoner"} = Session.set_model(pid, "deepseek-reasoner")
    info = Session.get_info(pid)
    assert info.model == "deepseek-reasoner"
  end

  test "temporal state checkpoints and undo", %{pid: pid} do
    # Create manual checkpoint
    {:ok, cp1} = Session.checkpoint(pid, "Checkpoint 1")
    assert cp1.label == "Checkpoint 1"

    # Send a message to mutate history
    {:ok, _response} = Session.send_user_message(pid, "Hello world")
    info_after = Session.get_info(pid)
    assert info_after.message_count > 1

    # Rollback via undo
    assert {:ok, msg} = Session.undo(pid)
    assert msg =~ "Pre-turn #1"
  end

  test "hot code reloading updates tools live without dropping state", %{pid: pid} do
    initial_info = Session.get_info(pid)

    # Trigger hot-code reload broadcast
    {:ok, _tools} = PluginLoader.reload_all()

    # Verify session received broadcast and preserved its state/pid
    info_after = Session.get_info(pid)
    assert info_after.pid == initial_info.pid
    assert info_after.session_id == initial_info.session_id
  end

  test "configures hands execution mode", %{pid: pid} do
    assert {:ok, %{mode: :remote}} = Session.set_hands_mode(pid, :remote, "hands@127.0.0.1")
    info = Session.get_info(pid)
    assert info.hands_mode == :remote
    assert info.hands_target == "hands@127.0.0.1"
  end

  test "spawns subagent actor and calculates token stats", %{pid: pid} do
    stats = Session.get_token_stats(pid)
    assert is_integer(stats.total_tokens)

    assert {:ok, result} = Session.spawn_subagent(pid, "Research quantum computing")
    assert is_binary(result)
  end

  test "compresses context via session actor", %{pid: pid} do
    assert {:ok, summary} = Session.compact_context(pid)
    assert is_binary(summary)
  end

  test "resets session state clearing messages, tokens, and checkpoints", %{pid: pid} do
    {:ok, _} = Session.checkpoint(pid, "Checkpoint to clear")
    {:ok, _} = Session.send_user_message(pid, "Test prompt")
    info_before = Session.get_info(pid)
    assert info_before.message_count > 1

    assert :ok = Session.reset(pid)
    info_after = Session.get_info(pid)
    assert info_after.message_count == 1
    assert info_after.snapshot_count == 0
  end

  test "retrieves latest assistant response", %{pid: pid} do
    assert match?({:ok, _}, Session.send_user_message(pid, "Hello agent"))
    assert {:ok, response} = Session.get_latest_response(pid)
    assert is_binary(response)
  end

  test "image attachment builds structured content array for vision model" do
    # Minimal valid 1x1 transparent PNG (base64-encoded)
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      )

    img_path = Path.join(System.tmp_dir!(), "sess_img_#{System.unique_integer([:positive])}.png")
    File.write!(img_path, png)

    # Run the vision model in offline/mock mode (no API key) so the test is
    # deterministic and never hits the network. The multimodal `content` array
    # flows through ContextExpander -> Session -> DeepSeekAPI, which extracts
    # the text part for the mock reply.
    sess_id = "vision_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(
        session_id: sess_id,
        model: "deepseek-v4-flash-vision-exp",
        api_key: ""
      )

    assert {:ok, %{content: resp}} = Session.send_user_message(pid, "Describe @#{img_path}")
    assert is_binary(resp)

    File.rm(img_path)
  end

  test "toggles sandbox bounds, retrieves stats dashboard, turn tokens, and exports session", %{
    pid: pid
  } do
    assert {:ok, true} = Session.set_sandbox_mode(pid, true)
    stats = Session.get_stats(pid)
    assert stats.sandbox_workspace == true
    assert is_map(stats)

    turns = Session.get_turn_tokens(pid)
    assert is_list(turns)

    assert {:ok, md_path} = Session.export_session(pid, :markdown)
    assert File.exists?(md_path)
    assert String.ends_with?(md_path, ".md")

    assert {:ok, json_path} = Session.export_session(pid, :json)
    assert File.exists?(json_path)
    assert String.ends_with?(json_path, ".json")

    File.rm(md_path)
    File.rm(json_path)
  end

  test "sanitizes message sequence to enforce tool_calls followed by tool responses" do
    invalid_messages = [
      %{"role" => "user", "content" => "Run tools"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [%{"id" => "call_123", "function" => %{"name" => "bash"}}]
      },
      %{"role" => "user", "content" => "SYSTEM NOTICE: Duplicate tool call"}
    ]

    sanitized = Session.sanitize_messages(invalid_messages)
    assert length(sanitized) == 4

    [user1, assistant, tool, user2] = sanitized
    assert user1["role"] == "user"
    assert assistant["role"] == "assistant"
    assert tool["role"] == "tool"
    assert tool["tool_call_id"] == "call_123"
    assert user2["role"] == "user"
  end

  test "defaults max_tool_depth to 100 and honors an explicit override", %{pid: pid} do
    stats = Session.get_stats(pid)
    assert stats.max_tool_depth == 100

    sess_id = "depth_override_test_#{System.unique_integer([:positive])}"

    {:ok, override_pid} =
      SessionSupervisor.start_session(
        session_id: sess_id,
        model: "deepseek-chat",
        max_tool_depth: 7
      )

    assert Session.get_stats(override_pid).max_tool_depth == 7
  end

  test "estimated cost honors configurable per-million-token prices" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "session_price_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Override pricing in the session's workspace config: prompt $1.00/1M,
    # completion $2.00/1M (well above the 0.14/0.28 defaults, so the test
    # clearly distinguishes the configured values from the fallbacks).
    Yoke.Config.save_config(
      %{
        "price_per_million_prompt_tokens" => 1.0,
        "price_per_million_completion_tokens" => 2.0
      },
      tmp_dir
    )

    sess_id = "price_override_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(session_id: sess_id, model: "deepseek-chat", cwd: tmp_dir)

    # 1,000,000 prompt tokens + 1,000,000 completion tokens => $1.00 + $2.00 = $3.00
    :sys.replace_state(pid, fn state ->
      %{state | total_prompt_tokens: 1_000_000, total_completion_tokens: 1_000_000}
    end)

    token_stats = Session.get_token_stats(pid)
    assert Float.round(token_stats.estimated_cost_usd, 4) == 3.0

    stats = Session.get_stats(pid)
    assert Float.round(stats.estimated_cost_usd, 4) == 3.0

    File.rm_rf!(tmp_dir)
  end

  test "estimated cost falls back to DeepSeek V3 rates when pricing is unset" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "session_price_default_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    sess_id = "price_default_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(session_id: sess_id, model: "deepseek-chat", cwd: tmp_dir)

    # 1,000,000 prompt + 1,000,000 completion => $0.14 + $0.28 = $0.42
    :sys.replace_state(pid, fn state ->
      %{state | total_prompt_tokens: 1_000_000, total_completion_tokens: 1_000_000}
    end)

    token_stats = Session.get_token_stats(pid)
    assert Float.round(token_stats.estimated_cost_usd, 4) == 0.42

    File.rm_rf!(tmp_dir)
  end

  test "cancel_current_turn/1 aborts an in-flight turn and replies to its original caller", %{
    pid: pid
  } do
    test_pid = self()

    # Fabricate an in-flight turn deterministically instead of racing a real
    # (near-instant, mocked) `send_user_message/2` call: a long-sleeping Task
    # standing in for a slow LLM round-trip / tool execution, plus a `from`
    # tag built exactly like `GenServer.call/3` builds one internally
    # (`GenServer.reply/2`'s only real contract is `send(pid, {tag, reply})`),
    # so `assert_receive` below can observe the same reply a real blocked
    # caller would receive.
    #
    # The Task must be created *from inside the session process* (hence
    # doing it inside this `:sys.replace_state/2` callback, which OTP runs
    # in the target process's own context) -- `Task.shutdown/2` requires the
    # calling process to be the task's original owner, exactly like
    # `start_agent_turn/2` and `cancel_current_turn/1`'s own handler always
    # run on the very same session process in production.
    :sys.replace_state(pid, fn state ->
      fake_task =
        Task.Supervisor.async_nolink(Yoke.TaskEngine.TaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      tag = make_ref()
      send(test_pid, {:fake_turn, fake_task, tag})
      %{state | active_turn: %{task: fake_task, from: {test_pid, tag}}}
    end)

    assert_receive {:fake_turn, fake_task, tag}, 1_000

    assert :ok = Session.cancel_current_turn(pid)
    assert_receive {^tag, {:error, "Turn cancelled by user (Ctrl+Q)."}}, 1_000

    refute Process.alive?(fake_task.pid)

    # The session actor itself survives the cancellation and is immediately
    # usable again, back in its idle state.
    info = Session.get_info(pid)
    assert info.status == :idle
    assert info.pid == pid
  end

  test "cancel_current_turn/1 returns an error when no turn is in flight", %{pid: pid} do
    assert {:error, _reason} = Session.cancel_current_turn(pid)
  end

  test "whitelists all ragex tools automatically without asking for user confirmation" do
    # Verify that ragex tool names starting with mcp_ragex_, ragex_, or ragex are permitted
    state = %{
      cwd: File.cwd!(),
      sandbox_workspace: false,
      permission_mode: :ask_confirm,
      session_tool_permissions: %{}
    }

    assert {:allow, _} = Session.tool_permitted?("mcp_ragex_search_code", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("mcp_ragex_ast_search", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("ragex_symbol_location", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("ragex", %{}, state)
  end

  test "permits read-only tools by default in ask_confirm mode" do
    state = %{
      cwd: File.cwd!(),
      sandbox_workspace: false,
      permission_mode: :ask_confirm,
      session_tool_permissions: %{}
    }

    assert Session.read_only_tool?("read_file")
    assert Session.read_only_tool?("read_files")
    assert Session.read_only_tool?("glob_search")
    assert Session.read_only_tool?("grep_search")
    assert Session.read_only_tool?("list_dir")
    assert Session.read_only_tool?("job_status")
    refute Session.read_only_tool?("write_file")
    refute Session.read_only_tool?("replace_file")
    refute Session.read_only_tool?("bash")

    assert {:allow, _} = Session.tool_permitted?("read_file", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("read_files", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("glob_search", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("grep_search", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("list_dir", %{}, state)
    assert {:allow, _} = Session.tool_permitted?("job_status", %{}, state)
  end

  test "repairs malformed tool sequences and converts orphaned tool messages to user role" do
    orphaned_msg = %{"role" => "tool", "tool_call_id" => "call_99", "content" => "output"}

    repaired =
      Session.repair_tool_messages([%{"role" => "user", "content" => "hi"}, orphaned_msg])

    assert length(repaired) == 2
    [user1, converted] = repaired
    assert user1["role"] == "user"
    assert converted["role"] == "user"
    assert converted["content"] =~ "[Tool Output call_99]: output"

    # Aggressive recovery conversion
    ast_with_tools = %{
      "role" => "assistant",
      "content" => "thinking",
      "tool_calls" => [%{"id" => "c1"}]
    }

    tool_resp = %{"role" => "tool", "tool_call_id" => "c1", "content" => "res"}

    converted_all = Session.convert_all_tool_roles_to_user_messages([ast_with_tools, tool_resp])
    assert Enum.all?(converted_all, fn m -> m["role"] in ["user", "assistant"] end)
    refute Map.has_key?(Enum.at(converted_all, 0), "tool_calls")
  end
end

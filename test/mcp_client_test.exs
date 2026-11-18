defmodule Yoke.MCPClientTest do
  use ExUnit.Case, async: true

  alias Yoke.Json
  alias Yoke.MCP.Client

  @mock_server ~S"""
  while IFS= read -r request; do
    id=${request#*'"id":'}
    id=${id%%,*}
    id=${id%%\}*}
    case "$request" in
      *'"name":"fail"'*)
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Invalid arguments"}}\n' "$id" 2>/dev/null || exit 0
        ;;
      *)
        printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$request" 2>/dev/null || exit 0
        ;;
    esac
  done
  """

  test "starts MCP client port and reserves the initialize request ID" do
    pid = start_mock_client()
    assert Process.alive?(pid)
    assert %{req_id: 2} = :sys.get_state(pid)
  end

  test "handles unhandled port messages gracefully" do
    pid = start_mock_client()

    send(pid, {:random_msg, "test"})
    assert %Client{} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "lists tools through a real line-mode port without reusing the initialize ID" do
    pid = start_mock_client()

    task = Task.async(fn -> Client.list_mcp_tools(pid) end)

    assert {:ok, %{"id" => 2, "method" => "tools/list", "params" => %{}}} =
             Task.await(task, 5_000)

    assert %{pending_requests: pending, line_buffer: []} = :sys.get_state(pid)
    assert pending == %{}
  end

  test "calls tools and returns JSON-RPC errors without losing subsequent responses" do
    pid = start_mock_client()
    task = Task.async(fn -> Client.call_mcp_tool(pid, "fail", %{}) end)

    assert {:error, %{"code" => -32_602, "message" => "Invalid arguments"}} =
             Task.await(task, 5_000)

    task = Task.async(fn -> Client.call_mcp_tool(pid, "echo", %{"text" => "hello"}) end)

    assert {:ok,
            %{
              "id" => 3,
              "method" => "tools/call",
              "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
            }} = Task.await(task, 5_000)
  end

  test "reassembles responses larger than multiple port fragments" do
    pid = start_mock_client()
    text = String.duplicate("català 日本語\n", 12_000)
    task = Task.async(fn -> Client.call_mcp_tool(pid, "echo", %{"text" => text}) end)

    assert {:ok, %{"params" => %{"arguments" => %{"text" => ^text}}}} =
             Task.await(task, 5_000)

    assert %{line_buffer: []} = :sys.get_state(pid)
  end

  test "buffers incomplete JSON and split UTF-8 bytes until the end of the line" do
    ref = make_ref()
    port = make_ref()
    state = %Client{port: port, pending_requests: %{7 => {self(), ref}}}
    prefix = ~s({"id":7,"result":{"text":")

    assert {:noreply, state} =
             Client.handle_info({port, {:data, {:noeol, prefix <> <<0xC3>>}}}, state)

    assert {:noreply, state} =
             Client.handle_info({port, {:data, {:noeol, <<0xA0>>}}}, state)

    refute_receive {^ref, _}

    assert {:noreply, state} =
             Client.handle_info({port, {:data, {:eol, ~s("}})}}}, state)

    assert_receive {^ref, {:ok, %{"text" => "à"}}}
    assert state.line_buffer == []
    assert state.pending_requests == %{}
  end

  test "clears malformed frames and ignores notifications, unknown IDs and other ports" do
    ref = make_ref()
    port = make_ref()
    state = %Client{name: "framing-test", port: port, pending_requests: %{7 => {self(), ref}}}

    assert {:noreply, state} =
             Client.handle_info({port, {:data, {:noeol, "invalid "}}}, state)

    assert {:noreply, state} =
             Client.handle_info({port, {:data, {:eol, "JSON"}}}, state)

    assert state.line_buffer == []

    ignored = [
      {port, {:data, {:eol, ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})}}},
      {port, {:data, {:eol, ~s({"id":999,"result":{}})}}},
      {port, {:data, {:eol, ~s({"id":999,"error":{"code":-32602}})}}},
      {make_ref(), {:data, {:noeol, "unrelated"}}},
      {make_ref(), {:data, {:eol, ~s({"id":7,"result":"wrong port"})}}}
    ]

    for message <- ignored do
      assert {:noreply, ^state} = Client.handle_info(message, state)
    end

    refute_receive {^ref, _}
    response = Json.encode!(%{"id" => 7, "result" => "recovered"})
    assert {:noreply, state} = Client.handle_info({port, {:data, {:eol, response}}}, state)
    assert_receive {^ref, {:ok, "recovered"}}
    assert state.pending_requests == %{}
  end

  test "routes out-of-order responses to their matching callers" do
    first = make_ref()
    second = make_ref()
    port = make_ref()
    pending = %{2 => {self(), first}, 3 => {self(), second}}
    state = %Client{port: port, pending_requests: pending}

    state =
      for {id, result} <- [{3, "second"}, {2, "first"}], reduce: state do
        state ->
          response = Json.encode!(%{"id" => id, "result" => result})
          assert {:noreply, next} = Client.handle_info({port, {:data, {:eol, response}}}, state)
          next
      end

    assert_receive {^first, {:ok, "first"}}
    assert_receive {^second, {:ok, "second"}}
    assert state.pending_requests == %{}
  end

  defp start_mock_client do
    start_supervised!({Client, command: "/bin/sh", args: ["-c", @mock_server], name: "mock_mcp"})
  end
end

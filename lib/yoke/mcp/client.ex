defmodule Yoke.MCP.Client do
  @moduledoc """
  Model Context Protocol (MCP) client implementation over stdio / Port JSON-RPC.
  Allows Yoke to dynamically load external MCP servers, inspect tools,
  and convert them into Yoke plugin tools.
  """
  use GenServer
  require Logger

  # Port line size bounds individual fragments, not complete JSON-RPC messages.
  @port_line_size 65_536

  defstruct [:name, :port, :cmd, :args, :env, :req_id, :pending_requests, :tools, line_buffer: []]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Lists tools available from connected MCP server."
  def list_mcp_tools(pid) do
    GenServer.call(pid, :list_mcp_tools, :infinity)
  end

  @doc "Calls a tool on the MCP server."
  def call_mcp_tool(pid, tool_name, arguments) do
    GenServer.call(pid, {:call_mcp_tool, tool_name, arguments}, :infinity)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    cmd = opts[:command] || "npx"
    args = opts[:args] || []
    name = opts[:name] || "mcp_server"

    exec_path = System.find_executable(cmd) || cmd

    port_opts = [
      :binary,
      :stream,
      :use_stdio,
      line: @port_line_size,
      args: args
    ]

    port_opts = if opts[:cwd], do: Keyword.put(port_opts, :cd, opts[:cwd]), else: port_opts

    port_opts =
      if opts[:env] do
        env_list = Enum.map(opts[:env], fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
        Keyword.put(port_opts, :env, env_list)
      else
        port_opts
      end

    port = Port.open({:spawn_executable, exec_path}, port_opts)

    state = %__MODULE__{
      name: name,
      port: port,
      cmd: cmd,
      args: args,
      req_id: 1,
      pending_requests: %{},
      tools: []
    }

    # Send MCP initialize request
    state =
      send_json_rpc(state, "initialize", %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "Yoke-Elixir", "version" => "0.1.0"}
      })

    {:ok, state}
  end

  @impl true
  def handle_call(:list_mcp_tools, from, state) do
    {req_id, state} = get_next_req_id(state)
    state = put_in(state.pending_requests[req_id], from)
    state = send_json_rpc(state, "tools/list", %{}, req_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:call_mcp_tool, tool_name, arguments}, from, state) do
    {req_id, state} = get_next_req_id(state)
    state = put_in(state.pending_requests[req_id], from)

    params = %{
      "name" => tool_name,
      "arguments" => arguments
    }

    state = send_json_rpc(state, "tools/call", params, req_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, fragment}}}, %{port: port} = state) do
    {:noreply, %{state | line_buffer: [fragment | state.line_buffer]}}
  end

  def handle_info({port, {:data, {:eol, fragment}}}, %{port: port} = state) do
    line = [fragment | state.line_buffer] |> Enum.reverse() |> IO.iodata_to_binary()
    handle_json_rpc(line, %{state | line_buffer: []})
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[MCP.Client] MCP server process #{state.name} exited with status #{status}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[MCP.Client] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Helper Functions

  defp handle_json_rpc(line, state) do
    case Yoke.Json.decode(String.trim(line)) do
      {:ok, %{"id" => id, "result" => result}} when not is_nil(id) ->
        case Map.pop(state.pending_requests, id) do
          {from, new_pending} when not is_nil(from) ->
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | pending_requests: new_pending}}

          _ ->
            {:noreply, state}
        end

      {:ok, %{"id" => id, "error" => error}} when not is_nil(id) ->
        case Map.pop(state.pending_requests, id) do
          {from, new_pending} when not is_nil(from) ->
            GenServer.reply(from, {:error, error})
            {:noreply, %{state | pending_requests: new_pending}}

          _ ->
            {:noreply, state}
        end

      {:ok, notification} ->
        Logger.debug(
          "[MCP.Client] Received notification from #{state.name}: #{inspect(notification)}"
        )

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp get_next_req_id(state) do
    id = state.req_id
    {id, %{state | req_id: id + 1}}
  end

  defp send_json_rpc(state, method, params, id \\ nil)

  defp send_json_rpc(state, method, params, nil) do
    {id, state} = get_next_req_id(state)
    send_json_rpc(state, method, params, id)
  end

  defp send_json_rpc(state, method, params, id) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    encoded = Yoke.Json.encode!(payload) <> "\n"
    Port.command(state.port, encoded)
    state
  end
end

defmodule Yoke.Plugin.Loader do
  @moduledoc """
  Manages dynamic plugin loading, hot-code compilation, and live updates.
  Implements José Valim's key insight:
  "Hot-code swapping allows you to build an extensible plugin system... which reloads live without dropping state."
  """
  use GenServer
  require Logger

  @name __MODULE__

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Registers a built-in or loaded plugin module."
  def register_plugin(plugin_module) do
    GenServer.call(@name, {:register_plugin, plugin_module})
  end

  @doc """
  Registers multiple plugin modules in a single pass.

  Unlike calling `register_plugin/1` in a loop, this only rebuilds the tools
  map and notifies live sessions once, regardless of how many modules are
  passed in. Prefer this whenever registering a batch of dynamically
  generated tools (e.g. all tools from an MCP server) to avoid flooding
  sessions with one reload notification per tool.
  """
  def register_plugins([]), do: {:ok, []}

  def register_plugins(plugin_modules) when is_list(plugin_modules) do
    GenServer.call(@name, {:register_plugins, plugin_modules})
  end

  @doc "Unregisters multiple plugin modules or tool names and updates active sessions."
  def unregister_plugins(names_or_mods) when is_list(names_or_mods) do
    GenServer.call(@name, {:unregister_plugins, names_or_mods})
  end

  @doc "Loads and compiles an Elixir plugin source file (.ex or .exs)."
  def load_file(path) do
    GenServer.call(@name, {:load_file, path})
  end

  @doc "Reloads all registered plugin modules from source or re-evaluates them."
  def reload_all do
    GenServer.call(@name, :reload_all)
  end

  @doc "Returns all currently registered tools across all loaded plugins."
  def list_tools do
    GenServer.call(@name, :list_tools)
  end

  @doc "Executes a named tool with arguments."
  def execute_tool(tool_name, args, timeout \\ :infinity) do
    case GenServer.call(@name, {:get_tool, tool_name}, timeout) do
      {:ok, tool_info} ->
        try do
          case tool_info.execute.(args) do
            {:ok, res} -> {:ok, res}
            {:error, err} -> {:error, err}
            other -> {:ok, other}
          end
        rescue
          e ->
            err_msg = "Error executing tool #{tool_name}: #{Exception.message(e)}"
            {:error, err_msg}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      plugins: [Yoke.Plugin.DefaultTools],
      tools_map: %{},
      file_paths: MapSet.new()
    }

    state = build_tools_map(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:register_plugin, plugin_module}, _from, state) do
    new_plugins = Enum.uniq([plugin_module | state.plugins])
    new_state = %{state | plugins: new_plugins} |> build_tools_map()
    notify_sessions_of_reload(new_state.tools_map)
    {:reply, {:ok, plugin_module.name()}, new_state}
  end

  @impl true
  def handle_call({:register_plugins, plugin_modules}, _from, state) do
    new_plugins = Enum.uniq(Enum.reverse(plugin_modules) ++ state.plugins)
    new_state = %{state | plugins: new_plugins} |> build_tools_map()
    notify_sessions_of_reload(new_state.tools_map)
    names = Enum.map(plugin_modules, &apply_name/1)
    {:reply, {:ok, names}, new_state}
  end

  @impl true
  def handle_call({:unregister_plugins, names_or_mods}, _from, state) do
    name_set = MapSet.new(Enum.map(names_or_mods, &to_string/1))

    new_plugins =
      Enum.reject(state.plugins, fn mod ->
        to_string(mod) in name_set or
          (function_exported?(mod, :name, 0) and mod.name() in name_set)
      end)

    new_tools_map =
      Enum.reject(state.tools_map, fn {t_name, _info} ->
        t_name in name_set
      end)
      |> Enum.into(%{})

    new_state = %{state | plugins: new_plugins, tools_map: new_tools_map}
    notify_sessions_of_reload(new_state.tools_map)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:load_file, path}, _from, state) do
    case compile_and_extract_modules(path) do
      {:ok, modules} ->
        valid_plugins =
          Enum.filter(modules, fn mod ->
            Code.ensure_loaded?(mod) and function_exported?(mod, :tools, 0)
          end)

        new_plugins = Enum.uniq(valid_plugins ++ state.plugins)
        new_paths = MapSet.put(state.file_paths, path)

        new_state = %{state | plugins: new_plugins, file_paths: new_paths} |> build_tools_map()
        notify_sessions_of_reload(new_state.tools_map)

        plugin_names = Enum.map(valid_plugins, &apply_name/1)
        Logger.info("[Plugin.Loader] Loaded plugin file: #{path} -> #{inspect(plugin_names)}")
        {:reply, {:ok, plugin_names}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:reload_all, _from, state) do
    Logger.info("[Plugin.Loader] Re-compiling and hot-swapping all plugin files…")

    # Recompile external files
    Enum.each(state.file_paths, fn path ->
      compile_and_extract_modules(path)
    end)

    # Re-purge and reload modules if needed
    Enum.each(state.plugins, fn mod ->
      :code.purge(mod)
      :code.delete(mod)
      Code.ensure_loaded(mod)
    end)

    new_state = build_tools_map(state)
    notify_sessions_of_reload(new_state.tools_map)
    {:reply, {:ok, Map.keys(new_state.tools_map)}, new_state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools_list =
      Enum.map(state.tools_map, fn {name, tool_info} ->
        %{
          name: name,
          description: tool_info.description,
          parameters: tool_info.parameters
        }
      end)

    {:reply, tools_list, state}
  end

  @impl true
  def handle_call({:get_tool, tool_name}, _from, state) do
    case Map.fetch(state.tools_map, tool_name) do
      {:ok, tool_info} ->
        {:reply, {:ok, tool_info}, state}

      :error ->
        case resolve_tool_alias(tool_name) do
          {:ok, resolved} ->
            case Map.fetch(state.tools_map, resolved) do
              {:ok, tool_info} -> {:reply, {:ok, tool_info}, state}
              :error -> {:reply, {:error, "Unknown tool: #{tool_name}"}, state}
            end

          :error ->
            {:reply, {:error, "Unknown tool: #{tool_name}"}, state}
        end
    end
  end

  defp resolve_tool_alias(tool_name) when is_binary(tool_name) do
    lower = String.downcase(tool_name)

    cond do
      lower in [
        "mcp_ragex_grep",
        "ragex_grep",
        "mcp_ragex_search_code",
        "ragex_search_code",
        "mcp_ragex_find_symbol",
        "ragex_find_symbol",
        "mcp_ragex_symbol_definition",
        "ragex_symbol_definition",
        "mcp_ragex_symbol_references",
        "ragex_symbol_references",
        "mcp_ragex_references",
        "ragex_references",
        "mcp_ragex_outline",
        "ragex_outline"
      ] ->
        {:ok, "grep_search"}

      lower in ["mcp_ragex_view", "ragex_view"] ->
        {:ok, "read_file"}

      lower in ["mcp_ragex_structure", "ragex_structure"] ->
        {:ok, "list_dir"}

      true ->
        :error
    end
  end

  defp resolve_tool_alias(_), do: :error

  # Helper Functions

  defp compile_and_extract_modules(path) do
    if File.exists?(path) do
      try do
        compiled = Code.compile_file(path)
        modules = Enum.map(compiled, fn {mod, _bin} -> mod end)
        {:ok, modules}
      rescue
        e -> {:error, "Compilation error in #{path}: #{Exception.message(e)}"}
      end
    else
      {:error, "Plugin file not found: #{path}"}
    end
  end

  defp apply_name(mod) do
    if function_exported?(mod, :name, 0), do: mod.name(), else: inspect(mod)
  end

  defp build_tools_map(state) do
    tools_map =
      Enum.reduce(state.plugins, %{}, fn plugin_mod, acc ->
        if Code.ensure_loaded?(plugin_mod) and function_exported?(plugin_mod, :tools, 0) do
          plugin_tools = plugin_mod.tools()

          Enum.reduce(plugin_tools, acc, fn tool, t_acc ->
            Map.put(t_acc, tool.name, tool)
          end)
        else
          acc
        end
      end)

    %{state | tools_map: tools_map}
  end

  defp notify_sessions_of_reload(tools_map) do
    # Broadcast to all registered Session processes
    Registry.dispatch(Yoke.PubSubRegistry, "sessions", fn entries ->
      tools_list =
        Enum.map(tools_map, fn {name, tool_info} ->
          %{
            name: name,
            description: tool_info.description,
            parameters: tool_info.parameters
          }
        end)

      for {pid, _} <- entries do
        send(pid, {:tools_reloaded, tools_list})
      end
    end)
  rescue
    _ -> :ok
  end
end

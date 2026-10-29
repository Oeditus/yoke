defmodule Yoke.MCP.ServerManager do
  @moduledoc """
  Manages connections to external Model Context Protocol (MCP) servers, with first-class
  support for the `ragex` code intelligence & analysis MCP server.

  Launches MCP server processes over stdio (JSON-RPC), fetches declared tools,
  and registers them with Yoke.Plugin.Loader for live hot-code tool access.
  """
  use GenServer
  require Logger

  alias Ragex.Dllb.ProjectManager, as: DllbPM
  alias Ragex.MCP.Handlers.Tools, as: MCPTools
  alias Ragex.Store.Backend.Dllb, as: DllbStore
  alias Yoke.Config, as: Config
  alias Yoke.MCP.Client, as: MCPClient
  alias Yoke.Plugin.Loader, as: PluginLoader

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Connects and registers an MCP server given name, command, args, and optional cwd/env."
  def add_server(name, command, args \\ [], opts \\ []) do
    GenServer.call(@name, {:add_server, name, command, args, opts}, :infinity)
  end

  @doc "Starts and registers Ragex (@../ragex) as a first-class MCP server targeting specified working directory."
  def start_ragex(opts \\ [])

  def start_ragex(target_dir) when is_binary(target_dir) do
    start_ragex(target_dir: target_dir)
  end

  def start_ragex(opts) when is_list(opts) do
    target_dir = opts[:target_dir] || opts[:cwd] || File.cwd!()
    GenServer.call(@name, {:start_ragex, target_dir, opts}, :infinity)
  end

  @doc "Waits for background auto-start Ragex indexing to complete."
  def await_ragex(timeout \\ :infinity) do
    GenServer.call(@name, :await_ragex, timeout)
  catch
    :exit, _ -> :ok
  end

  @doc "Lists active connected MCP servers."
  def list_servers do
    GenServer.call(@name, :list_servers, :infinity)
  end

  @doc "Loads all configured MCP servers from ~/.yoke/config.json or .yoke/config.json."
  def load_from_config(cwd \\ ".") do
    GenServer.call(@name, {:load_from_config, cwd}, :infinity)
  end

  @doc "Removes a connected MCP server and unregisters its tools."
  def remove_server(name) do
    GenServer.call(@name, {:remove_server, name}, :infinity)
  end

  @doc """
  Gracefully shuts down the Ragex MCP server, including stopping any
  per-project `dllb-server` OS process it spawned.

  MUST be called before the VM halts (see `Yoke.CLI.Repl` exit
  handling and `Yoke.CLI.Main` one-shot mode). `System.halt/1`
  terminates the emulator immediately without running port cleanup, so any
  external `dllb-server` process left running becomes an orphan holding the
  project's `.ragex/dllb.redb` file and TCP port. On the next launch a fresh
  `dllb-server` cannot reliably take over that state, so the knowledge graph
  looks empty and gets fully re-indexed even though nothing changed. Calling
  this first lets the per-project instance flush and exit cleanly so the
  cache is actually reusable on the next launch.
  """
  def stop_ragex do
    GenServer.call(@name, :stop_ragex, :infinity)
  catch
    :exit, _ -> :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    if Application.get_env(:yoke, :auto_start_ragex, true) do
      send(self(), :auto_start_ragex)
      {:ok, %{servers: %{}, ragex_status: :starting, waiting_callers: []}}
    else
      {:ok, %{servers: %{}, ragex_status: :ready, waiting_callers: []}}
    end
  end

  @impl true
  def handle_info(:auto_start_ragex, state) do
    cwd = project_dir()

    Task.start(fn ->
      case do_start_ragex(cwd, []) do
        {:ok, dir, tools_registered} ->
          GenServer.cast(@name, {:ragex_started, dir, tools_registered})

        {:error, reason} ->
          GenServer.cast(@name, {:ragex_failed, reason})
      end
    end)

    {:noreply, %{state | ragex_status: :starting}}
  end

  def handle_info(msg, state) do
    Logger.debug("[ServerManager] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ragex_started, dir, tools_registered}, state) do
    new_servers =
      Map.put(state.servers, "ragex", %{
        command: "in_process",
        args: [],
        cwd: dir,
        tools: tools_registered
      })

    Enum.each(state.waiting_callers, fn
      {:start, caller} -> GenServer.reply(caller, {:ok, dir, tools_registered})
      {:await, caller} -> GenServer.reply(caller, :ok)
      caller -> GenServer.reply(caller, :ok)
    end)

    {:noreply, %{state | servers: new_servers, ragex_status: :ready, waiting_callers: []}}
  end

  @impl true
  def handle_cast({:ragex_failed, reason}, state) do
    Logger.warning("󱐋🔌 Ragex auto-start notice: #{inspect(reason)}")

    Enum.each(state.waiting_callers, fn
      {_tag, caller} -> GenServer.reply(caller, {:error, reason})
      caller -> GenServer.reply(caller, {:error, reason})
    end)

    {:noreply, %{state | ragex_status: :ready, waiting_callers: []}}
  end

  @impl true
  def handle_call(:await_ragex, from, state) do
    case state.ragex_status do
      :starting ->
        {:noreply, %{state | waiting_callers: [{:await, from} | state.waiting_callers]}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:add_server, name, command, args, opts}, _from, state) do
    case start_and_register_mcp_server(name, command, args, opts) do
      {:ok, tools_registered, pid} ->
        new_servers =
          Map.put(state.servers, name, %{
            command: command,
            args: args,
            cwd: opts[:cwd],
            pid: pid,
            tools: tools_registered
          })

        {:reply, {:ok, tools_registered}, %{state | servers: new_servers}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_server, name}, _from, state) do
    case Map.fetch(state.servers, name) do
      {:ok, server_info} ->
        tools = server_info[:tools] || []
        PluginLoader.unregister_plugins(tools)

        if pid = server_info[:pid] do
          Process.exit(pid, :shutdown)
        end

        new_servers = Map.delete(state.servers, name)

        {:reply, {:ok, "MCP server '#{name}' removed successfully."},
         %{state | servers: new_servers}}

      :error ->
        {:reply, {:error, "MCP server '#{name}' is not connected."}, state}
    end
  end

  @impl true
  def handle_call({:start_ragex, target_dir, opts}, from, state) do
    case state.ragex_status do
      :starting ->
        {:noreply, %{state | waiting_callers: [{:start, from} | state.waiting_callers]}}

      _ ->
        Task.start(fn ->
          case do_start_ragex(target_dir, opts) do
            {:ok, dir, tools_registered} ->
              GenServer.cast(@name, {:ragex_started, dir, tools_registered})

            {:error, reason} ->
              GenServer.cast(@name, {:ragex_failed, reason})
          end
        end)

        {:noreply, %{state | ragex_status: :starting, waiting_callers: [{:start, from}]}}
    end
  end

  @impl true
  def handle_call(:stop_ragex, _from, state) do
    if Code.ensure_loaded?(DllbPM) do
      try do
        DllbPM.stop_all_instances()
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    {:reply, :ok, %{state | servers: Map.delete(state.servers, "ragex")}}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    info =
      Enum.map(state.servers, fn {name, srv} ->
        %{
          name: name,
          command: srv.command,
          args: srv.args,
          cwd: srv[:cwd],
          tools_count: length(srv.tools),
          tools: srv.tools
        }
      end)

    {:reply, info, state}
  end

  @impl true
  def handle_call({:load_from_config, cwd}, _from, state) do
    cfg = Config.load_config(cwd)
    mcp_servers = Map.get(cfg, "mcp_servers", %{})

    results =
      Enum.map(mcp_servers, fn {name, srv_cfg} ->
        cmd = Map.get(srv_cfg, "command", "npx")
        args = Map.get(srv_cfg, "args", [])
        srv_cwd = Map.get(srv_cfg, "cwd")
        srv_env = Map.get(srv_cfg, "env", %{})

        opts = []
        opts = if srv_cwd, do: Keyword.put(opts, :cwd, srv_cwd), else: opts
        opts = if srv_env != %{}, do: Keyword.put(opts, :env, srv_env), else: opts

        {name, add_server(name, cmd, args, opts)}
      end)

    {:reply, {:ok, results}, state}
  end

  defp do_start_ragex(target_dir, opts) do
    if Code.ensure_loaded?(MCPTools) do
      with :ok <- load_ragex_store(target_dir) do
        initialize_ragex_tools(target_dir, opts)
      end
    else
      start_ragex_external(target_dir, opts)
    end
  end

  defp load_ragex_store(target_dir) do
    orig_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      configure_ragex_store(target_dir)

      if Code.ensure_loaded?(Ragex.Graph.Store) do
        Ragex.Graph.Store.load_project(target_dir)
      else
        :ok
      end
    after
      Logger.configure(level: orig_level)
    end
  end

  defp initialize_ragex_tools(target_dir, opts) do
    existing_nodes = count_existing_nodes(target_dir)

    if existing_nodes > 0 do
      Logger.info("󱐋🔌 Ragex Knowledge Graph loaded from store (#{existing_nodes} nodes ready).")
    end

    # Always re-analyze the target directory on every run (even when cached
    # nodes already exist in the store) because Yoke may be restarted on a
    # different git branch in the same directory. Ragex's directory analyzer
    # uses FileTracker content hashes for incremental updates while we also
    # prune any stale entities from files deleted or modified across branches.
    Yoke.CLI.Spinner.run(
      fn ->
        orig_level = Logger.level()
        Logger.configure(level: :warning)

        try do
          stale_snapshot = snapshot_stale_tracking()

          case analyze_ragex_directory(target_dir, opts) do
            {:ok, stats} ->
              prune_stale_tracked_entities(target_dir, stale_snapshot)
              Logger.configure(level: orig_level)

              Logger.info(
                "Ragex indexing complete: #{stats.success} indexed, " <>
                  "#{stats.skipped} unchanged, #{stats.errors} failed."
              )

            {:error, reason} ->
              Logger.configure(level: orig_level)
              Logger.warning("󱐋🔌 Ragex indexing notice: #{inspect(reason)}")
          end
        after
          Logger.configure(level: orig_level)
        end
      end,
      title: "Indexing Ragex Knowledge Graph…",
      tip: false
    )

    raw_tools = MCPTools.list_tools()
    tools_list = Map.get(raw_tools, :tools, [])

    built =
      Enum.map(tools_list, fn t ->
        t_name = Map.get(t, "name") || Map.get(t, :name)
        t_desc = Map.get(t, "description") || Map.get(t, :description) || "Ragex tool #{t_name}"

        input_schema =
          Map.get(t, "inputSchema") || Map.get(t, :inputSchema) ||
            %{"type" => "object", "properties" => %{}}

        {t_desc, input_schema} = reinforce_old_content(t_name, t_desc, input_schema)

        tool_name = "mcp_ragex_#{t_name}"

        dynamic_mod_name = build_mcp_ragex_tool_module(tool_name, t_name, t_desc, input_schema)
        {tool_name, dynamic_mod_name}
      end)

    # Register every dynamically generated module in a single batch call so
    # sessions receive one "tools reloaded" notification instead of one per tool.
    PluginLoader.register_plugins(Enum.map(built, fn {_tool_name, mod} -> mod end))
    registered_names = Enum.map(built, fn {tool_name, _mod} -> tool_name end)

    Logger.info("● Yoke initialization complete! System is ready.")
    {:ok, target_dir, registered_names}
  end

  defp analyze_ragex_directory(target_dir, opts) when is_list(opts) do
    analyze_opts =
      Keyword.take(opts, [
        :max_depth,
        :exclude_patterns,
        :incremental,
        :force_refresh,
        :notify,
        :timeout,
        :max_concurrency,
        :generate_embeddings,
        :watch
      ])

    # The store is already loaded before taking the stale-entity snapshot.
    Ragex.Analyzers.Directory.analyze_directory(
      target_dir,
      Keyword.put(analyze_opts, :load_project, false)
    )
  end

  defp analyze_ragex_directory(target_dir, _opts) do
    Ragex.Analyzers.Directory.analyze_directory(target_dir, load_project: false)
  end

  defp snapshot_stale_tracking do
    if Code.ensure_loaded?(Ragex.Embeddings.FileTracker) do
      try do
        Enum.reduce(
          Ragex.Embeddings.FileTracker.list_tracked_files(),
          %{deleted_files: [], candidate_entities: []},
          fn {file_id, metadata}, acc ->
            entities = Map.get(metadata, :entities, [])

            case Ragex.Embeddings.FileTracker.has_changed?(file_id) do
              {:deleted, _} ->
                %{
                  acc
                  | deleted_files: [file_id | acc.deleted_files],
                    candidate_entities: entities ++ acc.candidate_entities
                }

              {:changed, _} ->
                %{acc | candidate_entities: entities ++ acc.candidate_entities}

              _ ->
                acc
            end
          end
        )
      rescue
        _ -> %{deleted_files: [], candidate_entities: []}
      catch
        _, _ -> %{deleted_files: [], candidate_entities: []}
      end
    else
      %{deleted_files: [], candidate_entities: []}
    end
  end

  defp prune_stale_tracked_entities(
         target_dir,
         %{deleted_files: deleted_files, candidate_entities: candidate_entities}
       ) do
    if (deleted_files != [] or candidate_entities != []) and
         Code.ensure_loaded?(Ragex.Embeddings.FileTracker) and
         Code.ensure_loaded?(Ragex.Graph.Store) do
      try do
        Enum.each(deleted_files, fn file_id ->
          Ragex.Embeddings.FileTracker.untrack_file(file_id)
        end)

        active_entities =
          Ragex.Embeddings.FileTracker.list_tracked_files()
          |> Enum.flat_map(fn {_path, metadata} -> Map.get(metadata, :entities, []) end)
          |> MapSet.new()

        removed_entities =
          candidate_entities
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(active_entities, &1))

        Enum.each(removed_entities, fn
          {entity_type, entity_id} ->
            Ragex.Graph.Store.remove_node(entity_type, entity_id)

          _ ->
            :ok
        end)

        if deleted_files != [] or removed_entities != [] do
          Ragex.Graph.Store.save_cache(target_dir)
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------
  # `old_content` reinforcement for Ragex's `edit_file` / `edit_files`
  #
  # Ragex's editor relocates a change's line_start/line_end by fuzzy-matching
  # against `old_content` *before* applying it, which is far more robust
  # than the blind +/-3 line shift it falls back to after a validation
  # failure -- but that relocation only happens when `old_content` is
  # actually supplied, and both tools declare it as an optional schema
  # field. Rather than relying on the system prompt alone, this promotes
  # `old_content` to a `required` property on every change item so it's
  # structurally part of the tool's contract the model is calling against,
  # and reinforces the description every time the tool is offered.
  # ---------------------------------------------------------------------

  @old_content_reinforcement " IMPORTANT: always include `old_content` on every change -- " <>
                               "the exact original text at line_start..line_end as you last " <>
                               "observed it (e.g. from a prior read_file call). Ragex uses this " <>
                               "to verify and auto-correct drifted line numbers before applying " <>
                               "the edit, preventing syntax-breaking off-by-a-few-lines mistakes."

  # Path (in `Access.key/2` form, defaulting missing levels to `%{}` so
  # `get_in`/`put_in` never raise) from a schema root down to the per-change
  # item schema for the single-file `edit_file` tool. `Access.key/2` returns
  # a closure, so these must be built at runtime rather than stored as
  # module attributes (which require literal, escapable terms).
  defp edit_file_items_path do
    [Access.key(:properties, %{}), Access.key(:changes, %{}), Access.key(:items, %{})]
  end

  # Same, but one level deeper through `files` for the multi-file `edit_files` tool.
  defp edit_files_items_path do
    [
      Access.key(:properties, %{}),
      Access.key(:files, %{}),
      Access.key(:items, %{}),
      Access.key(:properties, %{}),
      Access.key(:changes, %{}),
      Access.key(:items, %{})
    ]
  end

  defp reinforce_old_content("edit_file", t_desc, input_schema) do
    {t_desc <> @old_content_reinforcement,
     augment_change_items_schema(input_schema, edit_file_items_path())}
  end

  defp reinforce_old_content("edit_files", t_desc, input_schema) do
    {t_desc <> @old_content_reinforcement,
     augment_change_items_schema(input_schema, edit_files_items_path())}
  end

  defp reinforce_old_content(_t_name, t_desc, input_schema), do: {t_desc, input_schema}

  defp augment_change_items_schema(schema, path) do
    case get_in(schema, path) do
      items when is_map(items) -> put_in(schema, path, require_old_content(items))
      _ -> schema
    end
  rescue
    _ -> schema
  end

  defp require_old_content(items_schema) do
    properties = Map.get(items_schema, :properties, %{})

    old_content_prop =
      Map.get(properties, :old_content, %{
        type: "string",
        description:
          "Exact original text at line_start..line_end, as last observed. Required so " <>
            "Ragex can verify/auto-correct drifted line numbers."
      })

    required =
      items_schema
      |> Map.get(:required, [])
      |> Kernel.++(["old_content"])
      |> Enum.uniq()

    items_schema
    |> Map.put(:properties, Map.put(properties, :old_content, old_content_prop))
    |> Map.put(:required, required)
  end

  defp start_ragex_external(target_dir, opts) do
    ragex_dir = discover_ragex_dir(opts[:ragex_dir] || ".")

    case ragex_dir do
      {:ok, dir} ->
        script_path = Path.join(dir, "bin/ragex-mcp")

        {cmd, args, run_opts} =
          if File.exists?(script_path) do
            {script_path, ["--project", target_dir],
             [
               cwd: dir,
               env: %{"MIX_ENV" => "prod", "RAGEX_STDIO" => "1", "RAGEX_PROJECT" => target_dir}
             ]}
          else
            {"mix", ["run", "--no-halt", "--", "--project", target_dir],
             [
               cwd: dir,
               env: %{"MIX_ENV" => "prod", "RAGEX_STDIO" => "1", "RAGEX_PROJECT" => target_dir}
             ]}
          end

        case start_and_register_mcp_server("ragex", cmd, args, run_opts) do
          {:ok, tools_registered, _pid} ->
            {:ok, target_dir, tools_registered}

          {:error, reason} ->
            {:error, "Failed to start ragex MCP server: #{reason}"}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp configure_ragex_store(target_dir) do
    use_dllb? = Code.ensure_loaded?(Dllb) and Application.get_env(:dllb, :enabled, true)
    backend = if use_dllb?, do: :dllb, else: :ets

    if use_dllb?, do: ensure_dllb_server_binary()

    host = System.get_env("DLLB_HOST", Application.get_env(:dllb, :host, "127.0.0.1"))

    port =
      case System.get_env("DLLB_PORT") do
        nil -> Application.get_env(:dllb, :port, 3009)
        p -> String.to_integer(p)
      end

    pool_size =
      case System.get_env("DLLB_POOL_SIZE") do
        nil -> Application.get_env(:dllb, :pool_size, 30)
        p -> String.to_integer(p)
      end

    dllb_mode =
      case System.get_env("DLLB_MODE") do
        "per_project" -> :per_project
        "global" -> :global
        _ -> Application.get_env(:ragex, :dllb_mode, :per_project)
      end

    Application.put_env(:ragex, :store_backend, backend)
    Application.put_env(:ragex, :dllb_mode, dllb_mode)

    if use_dllb? do
      Application.put_env(:dllb, :enabled, true)
      Application.put_env(:dllb, :host, host)
      Application.put_env(:dllb, :port, port)
      Application.put_env(:dllb, :pool_size, pool_size)

      if dllb_mode == :per_project and Code.ensure_loaded?(DllbPM) do
        case DllbPM.set_active_project(target_dir) do
          :ok ->
            db_path = Path.join(target_dir, ".ragex/dllb.redb")

            Logger.info(
              "󱐋🔌 Per-project Dllb daemon active for '#{target_dir}' (database: #{db_path})"
            )

          {:error, reason} ->
            Logger.warning("󱐋🔌 Per-project Dllb startup notice: #{inspect(reason)}")
            Application.put_env(:ragex, :store_backend, :ets)
            Application.put_env(:dllb, :enabled, false)
        end
      else
        Logger.info("󱐋🔌 Connecting to global Dllb server on #{host}:#{port}…")

        if Process.whereis(Dllb.Pool) == nil and Process.whereis(Dllb.Supervisor) != nil do
          pool_opts = [
            host: host,
            port: port,
            pool_size: pool_size,
            outcome: Application.get_env(:dllb, :outcome, :json),
            timeout: Application.get_env(:dllb, :timeout, 30_000)
          ]

          case Supervisor.start_child(Dllb.Supervisor, Dllb.Pool.child_spec(pool_opts)) do
            {:ok, _pid} ->
              Logger.info("󱐋🔌 Dllb.Pool connected on #{host}:#{port} (pool size: #{pool_size})")

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning("󱐋🔌 Failed to start Dllb.Pool: #{inspect(reason)}")
          end
        end
      end

      # Fast check: skip schema bootstrapping if ast_node table already exists
      if dllb_mode != :per_project and Process.whereis(Dllb.Pool) != nil do
        already_bootstrapped? =
          try do
            case DllbStore.query("SELECT * FROM ast_node LIMIT 1;") do
              {:ok, _} -> true
              _ -> false
            end
          rescue
            _ -> false
          catch
            _, _ -> false
          end

        if already_bootstrapped? do
          Logger.info("󱐋🔌 Dllb schema ready for Ragex Knowledge Graph")
        else
          Logger.info("⌛ Bootstrapping Dllb database schema…")

          case DllbStore.bootstrap() do
            :ok ->
              Logger.info("󱐋🔌 Dllb schema bootstrapped for Ragex Knowledge Graph")

            {:error, reason} ->
              Logger.warning("󱐋🔌 Dllb schema bootstrap notice: #{inspect(reason)}")
          end
        end
      end
    end

    Logger.info(
      "󱐋🔌 Ragex Knowledge Graph backend configured: #{backend} (mode: #{dllb_mode}, dllb active: #{use_dllb?})"
    )
  end

  # Helper Functions

  @doc "Returns the active user project directory (preserving YOKE_PROJECT_DIR from launcher)."
  def project_dir(override \\ nil) do
    cond do
      is_binary(override) and override != "" and override != "." -> override
      env = System.get_env("YOKE_PROJECT_DIR") -> env
      pwd = System.get_env("PWD") -> pwd
      true -> File.cwd!()
    end
  end

  def discover_ragex_dir(start_dir \\ nil) do
    target_start = project_dir(start_dir)

    env_path =
      System.get_env("RAGEX_PATH") || Application.get_env(:yoke, :ragex_path)

    candidates =
      [
        env_path,
        Path.expand("../ragex", target_start),
        Path.expand("./ragex", target_start),
        Path.expand("~/Proyectos/Oeditus/ragex", target_start),
        target_start
      ]
      |> Enum.reject(&is_nil/1)

    found =
      Enum.find(candidates, fn path ->
        File.exists?(Path.join(path, "mix.exs")) and
          (File.exists?(Path.join(path, "bin/ragex-mcp")) or
             File.exists?(Path.join(path, "lib/ragex")))
      end)

    if found do
      {:ok, found}
    else
      {:error, "Ragex directory not found in candidate paths: #{inspect(candidates)}"}
    end
  end

  # A newly launched per-project dllb-server OS process requires a short window
  # to load its .ragex/dllb.redb database file into memory and establish pool sockets.
  # If a .ragex database exists on disk, retry querying the node count up to 15 times
  # (3.0s total window) to prevent false zero counts that force unwanted re-indexing.
  defp count_existing_nodes(target_dir, attempts \\ 15) do
    has_ragex_db? =
      File.exists?(Path.join(target_dir, ".ragex")) or
        File.exists?(Path.join(target_dir, ".ragex/dllb.redb"))

    nodes = query_node_count()

    cond do
      nodes > 0 ->
        nodes

      has_ragex_db? and attempts > 1 ->
        Process.sleep(200)
        count_existing_nodes(target_dir, attempts - 1)

      attempts > 1 and not has_ragex_db? and attempts > 12 ->
        Process.sleep(100)
        count_existing_nodes(target_dir, attempts - 1)

      true ->
        nodes
    end
  end

  defp query_node_count do
    if Code.ensure_loaded?(Ragex.Graph.Store) do
      try do
        stats = Ragex.Graph.Store.stats()

        nodes =
          Map.get(stats, :nodes) || Map.get(stats, "nodes") || Map.get(stats, :total_nodes) ||
            Map.get(stats, :total) || 0

        if is_integer(nodes) and nodes > 0 do
          nodes
        else
          0
        end
      rescue
        _ -> 0
      catch
        _, _ -> 0
      end
    else
      0
    end
  end

  defp start_and_register_mcp_server(name, command, args, opts) do
    client_opts = [name: name, command: command, args: args, cwd: opts[:cwd], env: opts[:env]]

    case MCPClient.start_link(client_opts) do
      {:ok, client_pid} ->
        case MCPClient.list_mcp_tools(client_pid) do
          {:ok, %{"tools" => mcp_tools}} when is_list(mcp_tools) ->
            built =
              Enum.map(mcp_tools, fn t ->
                tool_name = "mcp_#{name}_#{t["name"]}"
                desc = Map.get(t, "description", "MCP Tool from #{name}")

                input_schema =
                  Map.get(t, "inputSchema", %{"type" => "object", "properties" => %{}})

                spec = %{
                  server_name: name,
                  tool_name: tool_name,
                  mcp_tool_name: t["name"],
                  desc: desc,
                  input_schema: input_schema,
                  client_pid: client_pid
                }

                dynamic_mod_name = build_mcp_client_tool_module(spec)
                {tool_name, dynamic_mod_name}
              end)

            # Single batch registration -- avoids one "tools reloaded" notification per tool.
            PluginLoader.register_plugins(Enum.map(built, fn {_tool_name, mod} -> mod end))
            registered_names = Enum.map(built, fn {tool_name, _mod} -> tool_name end)

            {:ok, registered_names, client_pid}

          {:ok, other} ->
            {:error, "Unexpected tools/list output from MCP server: #{inspect(other)}"}

          {:error, err} ->
            {:error, "Failed to fetch tools/list from MCP server #{name}: #{inspect(err)}"}
        end

      {:error, reason} ->
        {:error,
         "Failed to start MCP server process (#{command} #{Enum.join(args, " ")}): #{inspect(reason)}"}
    end
  end

  @doc "Executes a Ragex MCP tool by target name with args."
  def execute_ragex_tool(t_name, args) do
    case MCPTools.call_tool(t_name, args) do
      {:ok, result} -> {:ok, format_mcp_content(result)}
      {:error, %{type: :validation_error} = err} -> {:error, format_mcp_content(err)}
      {:error, %{"type" => "validation_error"} = err} -> {:error, format_mcp_content(err)}
      {:error, err} -> {:error, "Ragex tool error: #{inspect(err)}"}
      other -> {:ok, format_mcp_content(other)}
    end
  end

  @doc "Executes an external stdio MCP tool by target name with args."
  def execute_mcp_client_tool(client_pid, mcp_tool_name, arguments) do
    if Process.alive?(client_pid) do
      try do
        case MCPClient.call_mcp_tool(client_pid, mcp_tool_name, arguments) do
          {:ok, %{"content" => content}} -> {:ok, format_mcp_content(content)}
          {:ok, res} -> {:ok, inspect(res, pretty: true)}
          {:error, err} -> {:error, "MCP tool error: #{inspect(err)}"}
        end
      catch
        kind, reason ->
          {:error, "MCP client process failure (#{kind}): #{inspect(reason)}"}
      end
    else
      {:error, "MCP client process for '#{mcp_tool_name}' is no longer running."}
    end
  end

  defp build_mcp_ragex_tool_module(tool_name, t_name, t_desc, input_schema) do
    exec_ast =
      quote do
        Yoke.MCP.ServerManager.execute_ragex_tool(unquote(t_name), args)
      end

    build_dynamic_tool_module(tool_name, "ragex", t_desc, input_schema, exec_ast)
  end

  defp build_mcp_client_tool_module(%{
         server_name: server_name,
         tool_name: tool_name,
         mcp_tool_name: mcp_tool_name,
         desc: desc,
         input_schema: input_schema,
         client_pid: client_pid
       }) do
    exec_ast =
      quote do
        Yoke.MCP.ServerManager.execute_mcp_client_tool(
          unquote(client_pid),
          unquote(mcp_tool_name),
          args
        )
      end

    build_dynamic_tool_module(tool_name, server_name, desc, input_schema, exec_ast)
  end

  defp build_dynamic_tool_module(tool_name, server_tag, desc, input_schema, exec_ast) do
    dynamic_mod_name = String.to_atom("Elixir.Yoke.Plugin.MCP_#{tool_name}")

    :code.purge(dynamic_mod_name)
    :code.delete(dynamic_mod_name)

    Module.create(
      dynamic_mod_name,
      quote do
        @behaviour Yoke.Plugin.Behaviour

        def name, do: unquote(tool_name)
        def description, do: unquote("[MCP:#{server_tag}] #{desc}")

        def execute(args) do
          unquote(exec_ast)
        end

        def tools do
          [
            %{
              name: unquote(tool_name),
              description: unquote("[MCP:#{server_tag}] #{desc}"),
              parameters: unquote(Macro.escape(input_schema)),
              execute: &execute/1
            }
          ]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    dynamic_mod_name
  end

  @doc "Formats raw MCP tool result content (validation errors, text blocks, etc.) into a display string."
  def format_mcp_content(%{"type" => "validation_error", "errors" => errors} = err) do
    format_mcp_content(%{
      type: :validation_error,
      errors: errors,
      hint: err["hint"],
      language: err["language"]
    })
  end

  def format_mcp_content(%{type: :validation_error, errors: errors} = err) do
    hint =
      Map.get(
        err,
        :hint,
        "Line range line_start/line_end was off by a few lines. Ensure replacement lines align exactly with code boundaries."
      )

    error_lines =
      Enum.map_join(errors, "\n", fn e ->
        line = e[:line] || e["line"]
        msg = e[:message] || e["message"]
        line_info = if is_list(line), do: inspect(line), else: "#{line || "?"}"
        "  ● Line #{line_info}: #{msg}"
      end)

    lang = Map.get(err, :language) || Map.get(err, "language")
    lang_str = if lang, do: " #{lang}", else: ""

    "Validation Error: Code changes produced invalid#{lang_str} syntax:\n#{error_lines}\n\nHINT: #{hint}"
  end

  def format_mcp_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      item -> inspect(item)
    end)
  end

  def format_mcp_content(content), do: inspect(content, pretty: true)

  defp ensure_dllb_server_binary do
    existing_bin =
      Application.get_env(:ragex, :dllb_server_bin) || System.get_env("DLLB_SERVER_BIN")

    if is_binary(existing_bin) and existing_bin != "" and File.exists?(existing_bin) do
      :ok
    else
      repo_dir =
        System.get_env("YOKE_REPO_DIR") ||
          Application.get_env(:yoke, :repo_dir)

      user_home = System.user_home() || System.get_env("HOME") || "/home/am"

      candidates =
        [
          repo_dir && Path.expand("../dllb/target/release/dllb-server", repo_dir),
          repo_dir && Path.expand("../dllb/target/debug/dllb-server", repo_dir),
          Path.join(user_home, ".local/bin/dllb-server"),
          Path.join(user_home, ".cargo/bin/dllb-server"),
          "/opt/Proyectos/Oeditus/dllb/target/release/dllb-server",
          "/opt/Proyectos/Oeditus/dllb/target/debug/dllb-server",
          System.find_executable("dllb-server")
        ]
        |> Enum.reject(&is_nil/1)

      case Enum.find(candidates, &File.exists?/1) do
        nil ->
          Logger.warning(
            "󱐋🔌 dllb-server binary not found in PATH or standard candidate locations. Per-project Ragex Knowledge Graph daemon may fail to start."
          )

          :ok

        found_bin ->
          Application.put_env(:ragex, :dllb_server_bin, found_bin)
          System.put_env("DLLB_SERVER_BIN", found_bin)
      end
    end
  end
end

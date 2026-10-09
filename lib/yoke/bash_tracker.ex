defmodule Yoke.BashTracker do
  @moduledoc """
  Tracks and analyzes model-invoked bash commands, calculating invocation counts,
  frequencies, and proportions. Identifies ineffective shell patterns and pairs
  them with superior analogs from Ragex MCP tools and dedicated Yoke tools.

  Persists analytics in `.yoke/bash_analytics.json` and supports structured
  export to `.yoke/exports/bash_calls_<timestamp>.json`.
  """
  use GenServer
  require Logger

  @name __MODULE__
  @store_file ".yoke/bash_analytics.json"
  @export_dir ".yoke/exports"

  # Mappings from ineffective shell commands/patterns to better Ragex / Yoke tool analogs
  @analogs %{
    "grep" => %{
      analog: "mcp_ragex_grep / mcp_ragex_search_code",
      category: :code_search,
      reason:
        "Use Ragex code intelligence or grep_search for indexed, AST-aware, and semantic search"
    },
    "rg" => %{
      analog: "mcp_ragex_grep / mcp_ragex_search_code",
      category: :code_search,
      reason: "Use Ragex code intelligence or grep_search for indexed code search"
    },
    "ag" => %{
      analog: "mcp_ragex_grep / mcp_ragex_search_code",
      category: :code_search,
      reason: "Use Ragex code intelligence or grep_search for indexed code search"
    },
    "cat" => %{
      analog: "read_file / mcp_ragex_view",
      category: :file_read,
      reason:
        "Use read_file (with start_line/end_line) or mcp_ragex_view for structured file reading"
    },
    "head" => %{
      analog: "read_file (with start_line/end_line) / mcp_ragex_view",
      category: :file_read,
      reason: "Use read_file with line limits to read top lines"
    },
    "tail" => %{
      analog: "read_file (with start_line/end_line) / mcp_ragex_view",
      category: :file_read,
      reason: "Use read_file with line limits to read tail lines"
    },
    "more" => %{
      analog: "read_file / mcp_ragex_view",
      category: :file_read,
      reason: "Use read_file or mcp_ragex_view instead of paging"
    },
    "less" => %{
      analog: "read_file / mcp_ragex_view",
      category: :file_read,
      reason: "Use read_file or mcp_ragex_view instead of paging"
    },
    "find" => %{
      analog: "list_dir / mcp_ragex_structure",
      category: :file_discovery,
      reason: "Use list_dir or mcp_ragex_structure to inspect file trees and directories"
    },
    "locate" => %{
      analog: "list_dir / mcp_ragex_structure",
      category: :file_discovery,
      reason: "Use list_dir or mcp_ragex_structure for file discovery"
    },
    "ls" => %{
      analog: "list_dir / mcp_ragex_structure",
      category: :directory_listing,
      reason: "Use list_dir or mcp_ragex_structure for directory contents"
    },
    "tree" => %{
      analog: "list_dir / mcp_ragex_structure",
      category: :directory_listing,
      reason: "Use list_dir or mcp_ragex_structure for project hierarchy"
    },
    "sed" => %{
      analog: "replace_file / mcp_ragex_edit_file",
      category: :file_edit,
      reason: "Use replace_file or mcp_ragex_edit_file for deterministic file editing"
    },
    "awk" => %{
      analog: "replace_file / mcp_ragex_edit_file / read_file",
      category: :file_edit,
      reason: "Use dedicated file tools instead of shell text-processing streams"
    },
    "git status" => %{
      analog: "git_status",
      category: :git,
      reason: "Use dedicated git_status tool"
    },
    "git diff" => %{
      analog: "git_diff",
      category: :git,
      reason: "Use dedicated git_diff tool"
    },
    "git commit" => %{
      analog: "git_commit",
      category: :git,
      reason: "Use dedicated git_commit tool"
    },
    "git rev-parse" => %{
      analog: "git_root",
      category: :git,
      reason: "Use dedicated git_root tool"
    },
    "git branch" => %{
      analog: "git_status",
      category: :git,
      reason: "Use dedicated git tools"
    },
    "git log" => %{
      analog: "git_diff / git_status",
      category: :git,
      reason: "Use dedicated git tools where applicable"
    },
    "wc" => %{
      analog: "mcp_ragex_analyze_file / read_file",
      category: :analysis,
      reason: "Use mcp_ragex_analyze_file or read_file for file metrics"
    },
    "ctags" => %{
      analog: "mcp_ragex_symbol_definition / mcp_ragex_symbol_references",
      category: :symbol_lookup,
      reason: "Use Ragex Knowledge Graph for symbols and definitions"
    },
    "cscope" => %{
      analog: "mcp_ragex_symbol_definition / mcp_ragex_symbol_references",
      category: :symbol_lookup,
      reason: "Use Ragex Knowledge Graph for symbols and definitions"
    },
    "convert" => %{
      analog: "mcp_ragex_image_convert / mcp_ragex_image_resize",
      category: :image,
      reason: "Use Ragex MCP image manipulation tools"
    },
    "magick" => %{
      analog: "mcp_ragex_image_* tools",
      category: :image,
      reason: "Use Ragex MCP image manipulation tools"
    },
    "sips" => %{
      analog: "mcp_ragex_image_* tools",
      category: :image,
      reason: "Use Ragex MCP image manipulation tools"
    }
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Records an execution of a bash command."
  def record(command, opts \\ []) when is_binary(command) do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:record, command, opts})
        catch
          :exit, _ -> record_direct(command, opts)
        end

      nil ->
        record_direct(command, opts)
    end
  end

  def record_call(command, opts \\ []), do: record(command, opts)

  @doc "Returns structured analytics and statistics for tracked bash commands."
  def stats(opts \\ []) do
    cwd = get_cwd(opts)

    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:stats, cwd})
        catch
          :exit, _ -> compute_stats(load(cwd))
        end

      nil ->
        compute_stats(load(cwd))
    end
  end

  @doc "Formats a human-readable text summary of bash calls, frequencies, and Ragex analogs."
  def format_summary(opts \\ []) do
    s = stats(opts)
    format_stats_report(s)
  end

  @doc "Exports the collected bash analytics to a JSON file in .yoke/exports/."
  def export_analytics(opts \\ []) do
    cwd = get_cwd(opts)

    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:export, cwd})
        catch
          :exit, _ -> do_export(cwd)
        end

      nil ->
        do_export(cwd)
    end
  end

  @doc "Clears tracked bash analytics in memory and on disk."
  def clear(opts \\ []) do
    cwd = get_cwd(opts)

    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:clear, cwd})
        catch
          :exit, _ -> do_clear(cwd)
        end

      nil ->
        do_clear(cwd)
    end
  end

  @doc "Returns path to workspace bash analytics JSON store."
  def store_file_path(cwd \\ ".") do
    Path.join([cwd, @store_file])
  end

  @doc "Loads analytics data from disk, initializing if not present."
  def load(cwd \\ ".") do
    file_path = store_file_path(cwd)

    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, data} when is_map(data) -> data
            _ -> initial_data()
          end

        _ ->
          initial_data()
      end
    else
      initial_data()
    end
  end

  @doc "Saves analytics data to disk."
  def save(data, cwd \\ ".") when is_map(data) do
    file_path = store_file_path(cwd)
    file_path |> Path.dirname() |> File.mkdir_p!()

    case Yoke.Json.encode(data, pretty: true) do
      {:ok, json} ->
        File.write(file_path, json)
        {:ok, file_path}

      {:error, err} ->
        Logger.warning("[BashTracker] Failed to encode analytics: #{inspect(err)}")
        {:error, err}
    end
  end

  @doc "Normalizes a raw command string to identify the root executable or compound command."
  def normalize_command(cmd) when is_binary(cmd) do
    trimmed = String.trim(cmd)

    stripped =
      trimmed
      |> strip_leading_env_vars()
      |> strip_wrappers()

    tokens =
      stripped
      |> String.split(~r/\s+/, trim: true)

    case tokens do
      [] ->
        {"", ""}

      [bin | rest] ->
        base_bin = Path.basename(bin)

        case {base_bin, rest} do
          {tool, [sub | _]}
          when tool in ["git", "mix", "cargo", "npm", "yarn", "pnpm", "docker"] and
                 not is_nil(sub) ->
            if String.starts_with?(sub, "-") do
              {base_bin, base_bin}
            else
              compound = "#{tool} #{sub}"
              {base_bin, compound}
            end

          _ ->
            {base_bin, base_bin}
        end
    end
  end

  @doc "Returns suggested analog information for a command if it is ineffective."
  def suggest_analog(cmd) when is_binary(cmd) do
    {base_bin, compound} = normalize_command(cmd)

    cond do
      Map.has_key?(@analogs, compound) ->
        {:ok, Map.get(@analogs, compound)}

      Map.has_key?(@analogs, base_bin) ->
        {:ok, Map.get(@analogs, base_bin)}

      true ->
        find_analog_in_pipeline(cmd)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    analytics = load(cwd)
    {:ok, %{analytics: analytics, cwd: cwd}}
  end

  @impl true
  def handle_call({:record, command, opts}, _from, state) do
    cwd = Keyword.get(opts, :cwd, state.cwd)
    current_data = if cwd == state.cwd, do: state.analytics, else: load(cwd)
    updated_data = do_record_data(current_data, command, opts)
    save(updated_data, cwd)

    new_state =
      if cwd == state.cwd do
        %{state | analytics: updated_data}
      else
        state
      end

    {:reply, {:ok, updated_data}, new_state}
  end

  @impl true
  def handle_call({:stats, cwd}, _from, state) do
    data = if cwd == state.cwd, do: state.analytics, else: load(cwd)
    {:reply, compute_stats(data), state}
  end

  @impl true
  def handle_call({:export, cwd}, _from, state) do
    data = if cwd == state.cwd, do: state.analytics, else: load(cwd)
    res = do_export_data(data, cwd)
    {:reply, res, state}
  end

  @impl true
  def handle_call({:clear, cwd}, _from, state) do
    res = do_clear(cwd)
    new_state = if cwd == state.cwd, do: %{state | analytics: initial_data()}, else: state
    {:reply, res, new_state}
  end

  # --- Private Helpers ---

  defp record_direct(command, opts) do
    cwd = get_cwd(opts)
    current_data = load(cwd)
    updated_data = do_record_data(current_data, command, opts)
    save(updated_data, cwd)
    {:ok, updated_data}
  end

  defp initial_data do
    %{
      "version" => 1,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "total_calls" => 0,
      "ineffective_calls" => 0,
      "root_commands" => %{},
      "command_details" => %{},
      "recent_calls" => []
    }
  end

  defp do_record_data(data, command, opts) do
    raw_cmd = String.trim(command)
    {base_bin, compound} = normalize_command(raw_cmd)
    analog_info = suggest_analog(raw_cmd)
    ineffective? = match?({:ok, _}, analog_info)

    {suggested_analog, reason, category} =
      case analog_info do
        {:ok, %{analog: a, reason: r, category: c}} -> {a, r, to_string(c)}
        _ -> {nil, nil, nil}
      end

    timestamp = Keyword.get(opts, :timestamp) || DateTime.utc_now() |> DateTime.to_iso8601()
    session_id = Keyword.get(opts, :session_id, "default")
    is_async = Keyword.get(opts, :async, false)
    source = to_string(Keyword.get(opts, :source, :tool_call))

    total = Map.get(data, "total_calls", 0) + 1
    ineffective_count = Map.get(data, "ineffective_calls", 0) + if(ineffective?, do: 1, else: 0)

    # Update root_commands
    root_key = compound
    root_map = Map.get(data, "root_commands", %{})
    existing_root = Map.get(root_map, root_key, %{})
    root_count = Map.get(existing_root, "count", 0) + 1
    samples = Map.get(existing_root, "samples", [])
    updated_samples = if raw_cmd in samples, do: samples, else: Enum.take([raw_cmd | samples], 5)

    updated_root = %{
      "name" => root_key,
      "base_bin" => base_bin,
      "count" => root_count,
      "ineffective" => ineffective?,
      "suggested_analog" => suggested_analog,
      "reason" => reason,
      "category" => category,
      "last_seen" => timestamp,
      "samples" => updated_samples
    }

    updated_root_map = Map.put(root_map, root_key, updated_root)

    # Update command_details
    details_map = Map.get(data, "command_details", %{})
    existing_detail = Map.get(details_map, raw_cmd, %{})
    detail_count = Map.get(existing_detail, "count", 0) + 1
    first_seen = Map.get(existing_detail, "first_seen", timestamp)

    updated_detail = %{
      "command" => raw_cmd,
      "root" => root_key,
      "base_bin" => base_bin,
      "count" => detail_count,
      "ineffective" => ineffective?,
      "suggested_analog" => suggested_analog,
      "reason" => reason,
      "category" => category,
      "first_seen" => first_seen,
      "last_seen" => timestamp
    }

    updated_details_map = Map.put(details_map, raw_cmd, updated_detail)

    # Update recent_calls
    call_entry = %{
      "command" => raw_cmd,
      "root" => root_key,
      "timestamp" => timestamp,
      "session_id" => session_id,
      "async" => is_async,
      "source" => source,
      "ineffective" => ineffective?,
      "suggested_analog" => suggested_analog
    }

    recent = [call_entry | Map.get(data, "recent_calls", [])] |> Enum.take(100)

    %{
      "version" => 1,
      "updated_at" => timestamp,
      "total_calls" => total,
      "ineffective_calls" => ineffective_count,
      "root_commands" => updated_root_map,
      "command_details" => updated_details_map,
      "recent_calls" => recent
    }
  end

  defp compute_stats(data) do
    total_calls = Map.get(data, "total_calls", 0)
    ineffective_calls = Map.get(data, "ineffective_calls", 0)

    ineffective_percentage =
      if total_calls > 0 do
        Float.round(ineffective_calls / total_calls * 100.0, 2)
      else
        0.0
      end

    root_commands =
      data
      |> Map.get("root_commands", %{})
      |> Map.values()
      |> Enum.map(fn entry ->
        cnt = Map.get(entry, "count", 0)
        freq = if total_calls > 0, do: Float.round(cnt / total_calls, 4), else: 0.0
        pct = if total_calls > 0, do: Float.round(cnt / total_calls * 100.0, 2), else: 0.0

        Map.merge(entry, %{
          "frequency" => freq,
          "percentage" => pct
        })
      end)
      |> Enum.sort_by(& &1["count"], :desc)

    top_ineffective =
      root_commands
      |> Enum.filter(& &1["ineffective"])
      |> Enum.sort_by(& &1["count"], :desc)

    commands =
      data
      |> Map.get("command_details", %{})
      |> Map.values()
      |> Enum.map(fn entry ->
        cnt = Map.get(entry, "count", 0)
        freq = if total_calls > 0, do: Float.round(cnt / total_calls, 4), else: 0.0
        pct = if total_calls > 0, do: Float.round(cnt / total_calls * 100.0, 2), else: 0.0

        Map.merge(entry, %{
          "frequency" => freq,
          "percentage" => pct
        })
      end)
      |> Enum.sort_by(& &1["count"], :desc)

    %{
      total_calls: total_calls,
      unique_commands: length(commands),
      ineffective_calls: ineffective_calls,
      ineffective_percentage: ineffective_percentage,
      root_commands: root_commands,
      top_ineffective: top_ineffective,
      commands: commands,
      recent_calls: Map.get(data, "recent_calls", [])
    }
  end

  defp do_export(cwd) do
    data = load(cwd)
    do_export_data(data, cwd)
  end

  defp do_export_data(data, cwd) do
    stats = compute_stats(data)
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    export_dir = Path.join(cwd, @export_dir)
    File.mkdir_p!(export_dir)

    export_path = Path.join(export_dir, "bash_calls_#{timestamp}.json")

    payload = %{
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "total_calls" => stats.total_calls,
      "unique_commands" => stats.unique_commands,
      "ineffective_calls" => stats.ineffective_calls,
      "ineffective_percentage" => stats.ineffective_percentage,
      "most_used_ineffective_calls" => stats.top_ineffective,
      "root_commands_by_frequency" => stats.root_commands,
      "commands_by_frequency" => stats.commands,
      "recent_calls" => stats.recent_calls
    }

    with {:ok, json} <- Yoke.Json.encode(payload, pretty: true),
         :ok <- File.write(export_path, json) do
      save(data, cwd)
      {:ok, export_path}
    else
      err ->
        Logger.error("[BashTracker] Failed to export bash analytics: #{inspect(err)}")
        {:error, err}
    end
  end

  defp do_clear(cwd) do
    init = initial_data()
    save(init, cwd)
    :ok
  end

  defp format_stats_report(stats) do
    cyan = Yoke.CLI.Formatter.cyan()
    yellow = Yoke.CLI.Formatter.yellow()
    bold = Yoke.CLI.Formatter.bold()
    reset = Yoke.CLI.Formatter.reset()
    dim = Yoke.CLI.Formatter.dim()

    if stats.total_calls == 0 do
      """
      #{bold}#{cyan}BASH COMMAND CALLS ANALYTICS#{reset}
      #{dim}─────────────────────────────────────────────────────────────────────────────#{reset}
      No bash commands recorded yet. All operations are using structured tools!
      """
    else
      ineffective_lines =
        if Enum.empty?(stats.top_ineffective) do
          "  #{cyan}None! All executed bash commands are legitimate fallback operations.#{reset}\n"
        else
          Enum.map_join(stats.top_ineffective, "\n", fn item ->
            samples_str =
              case item["samples"] do
                [s | _] -> " (e.g. `#{s}`)"
                _ -> ""
              end

            """
              #{yellow}▸ #{item["name"]}#{reset} (#{item["count"]} calls, #{item["percentage"]}%)#{samples_str}
                ↳ #{cyan}Better Ragex / Yoke Analog:#{reset} #{bold}#{item["suggested_analog"]}#{reset}
                ↳ #{dim}Reason: #{item["reason"]}#{reset}
            """
          end)
        end

      top_roots_lines =
        stats.root_commands
        |> Enum.take(10)
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {item, idx} ->
          status_tag =
            if item["ineffective"] do
              " #{yellow}[Ineffective: #{item["suggested_analog"]}]#{reset}"
            else
              ""
            end

          name_padded = String.pad_trailing(item["name"], 22)
          "  #{idx}. #{name_padded} #{item["count"]} calls (#{item["percentage"]}%)#{status_tag}"
        end)

      """

      #{bold}#{cyan}╭─ 󱐋 Bash Commands Analytics & Tool Analogs ───────────────────────────────╮#{reset}
      │ Total Bash Calls: #{String.pad_trailing(to_string(stats.total_calls), 8)} Unique: #{String.pad_trailing(to_string(stats.unique_commands), 6)} Ineffective: #{String.pad_trailing("#{stats.ineffective_calls} (#{stats.ineffective_percentage}%)", 18)} │
      #{bold}#{cyan}╰─────────────────────────────────────────────────────────────────────────────╯#{reset}

      #{bold}▲ Most Used Ineffective Calls (Export Better Analogs From Ragex):#{reset}
      #{ineffective_lines}
      #{bold}▲ Root Commands by Frequency:#{reset}
      #{top_roots_lines}

      #{dim}Use `/bash export` to dump full analytics JSON to .yoke/exports/.#{reset}
      """
    end
  end

  defp strip_leading_env_vars(cmd) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*=\S+\s+)+(.*)$/, cmd) do
      [_, _, rest] -> String.trim(rest)
      _ -> cmd
    end
  end

  defp strip_wrappers(cmd) do
    case Regex.run(~r/^(sudo|time|nohup)\s+(.*)$/, cmd) do
      [_, _, rest] -> String.trim(rest)
      _ -> cmd
    end
  end

  defp find_analog_in_pipeline(cmd) do
    segments = String.split(cmd, ~r/\||&&|;/)

    Enum.find_value(segments, fn seg ->
      seg = String.trim(seg)
      tokens = String.split(seg, ~r/\s+/, trim: true)

      case tokens do
        [bin | _] ->
          base = Path.basename(bin)
          if Map.has_key?(@analogs, base), do: {:ok, Map.get(@analogs, base)}

        _ ->
          nil
      end
    end)
  end

  defp get_cwd(opts) when is_list(opts), do: Keyword.get(opts, :cwd, File.cwd!())
  defp get_cwd(cwd) when is_binary(cwd), do: cwd
  defp get_cwd(_), do: File.cwd!()
end

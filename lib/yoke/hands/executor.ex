defmodule Yoke.Hands.Executor do
  @moduledoc """
  The "Hands" component of Yoke.
  Executes tools and sandbox operations across local system, isolated Erlang nodes, or Docker containers.
  Provides temporal side-effect tracking for undo and crash recovery.
  """
  require Logger
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.LineEditor

  defstruct [
    # :local | :remote | :docker
    mode: :local,
    # e.g., :"hands@127.0.0.1"
    remote_node: nil,
    # e.g., "yoke_sandbox_1"
    docker_container: nil
  ]

  @type execution_mode :: :local | :remote | :docker

  @doc "Executes a tool call under the configured sandbox target."
  def execute(%__MODULE__{mode: :local} = _executor, tool_name, args) do
    verdict = Yoke.AIGuard.guard_tool(tool_name, args)

    if verdict.action == :blocked do
      {:error, "[AI Guard Enforce] Tool execution blocked: #{verdict.reason}"}
    else
      Logger.info(format_execution_log(tool_name, args))

      case Yoke.Plugin.Loader.execute_tool(tool_name, args, :infinity) do
        {:ok, result} -> {:ok, format_output(result)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def execute(%__MODULE__{mode: :remote, remote_node: node}, tool_name, args)
      when not is_nil(node) do
    Logger.info(format_execution_log(tool_name, args, "[remote:#{node}]"))

    case :rpc.call(
           node,
           Yoke.Plugin.Loader,
           :execute_tool,
           [tool_name, args, :infinity],
           :infinity
         ) do
      {:ok, result} ->
        {:ok, format_output(result)}

      {:error, reason} ->
        {:error, "Remote node execution error: #{inspect(reason)}"}

      {:badrpc, nodedown_reason} ->
        {:error, "Remote node unreachable (#{node}): #{inspect(nodedown_reason)}"}
    end
  end

  def execute(%__MODULE__{mode: :docker, docker_container: container}, tool_name, args)
      when not is_nil(container) do
    Logger.info(format_execution_log(tool_name, args, "[docker:#{container}]"))

    case tool_name do
      "bash" ->
        cmd = Map.get(args, "command", "")
        cwd = Map.get(args, "_session_cwd", File.cwd!())
        session_id = Map.get(args, "_session_id")
        Yoke.BashTracker.record(cmd, cwd: cwd, session_id: session_id, mode: :docker)
        docker_cmd = "docker exec #{container} sh -c #{shell_quote(cmd)}"

        case System.cmd("sh", ["-c", docker_cmd], stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "Docker exec exited with status #{code}:\n#{out}"}
        end

      _ ->
        # Fallback to local RPC execution inside docker if node is shared or standard local
        execute(%__MODULE__{mode: :local}, tool_name, args)
    end
  end

  def execute(config, tool_name, args) do
    {:error,
     "Invalid Hands configuration: #{inspect(config)} for tool #{tool_name} (#{inspect(args)})"}
  end

  @icon_map %{
    "read_file" => "󰈔",
    "read_files" => "󰈔",
    "view_file" => "󰈔",
    "file_read" => "󰈔",
    "read_contents" => "󰈔",
    "get_file" => "󰈔",
    "write_file" => "󰏫",
    "write_to_file" => "󰏫",
    "replace_file_content" => "󰏫",
    "replace_file" => "󰏫",
    "edit_file" => "󰏫",
    "create_file" => "󰏫",
    "save_file" => "󰏫",
    "bash" => "⚙",
    "cmd" => "⚙",
    "run_command" => "⚙",
    "shell" => "⚙",
    "exec" => "⚙",
    "execute_command" => "⚙",
    "grep_search" => "󰍉",
    "grep" => "󰍉",
    "search_files" => "󰍉",
    "file_search" => "󰍉",
    "ripgrep" => "󰍉",
    "search" => "󰍉",
    "list_dir" => "󰉋",
    "ls" => "󰉋",
    "dir_list" => "󰉋",
    "list_directory" => "󰉋",
    "find_by_name" => "󰉋",
    "git" => "󰘬",
    "git_status" => "󰘬",
    "git_diff" => "󰘬",
    "git_commit" => "󰘬",
    "git_root" => "󰘬",
    "git_toplevel" => "󰘬",
    "git_log" => "󰘬",
    "http" => "󰖟",
    "req" => "󰖟",
    "fetch_url" => "󰖟",
    "web_search" => "󰖟",
    "read_url" => "󰖟",
    "subagent" => "〰",
    "spawn_subagent" => "〰",
    "agent" => "〰",
    "run_workflow" => "〰",
    "ask_question" => "󰋗",
    "ask" => "󰋗",
    "question" => "󰋗",
    "user_input" => "󰋗"
  }

  @doc "Returns a Nerd Font icon symbol for a known tool."
  def tool_icon(name) when is_binary(name) do
    cond do
      icon = Map.get(@icon_map, String.downcase(name)) -> icon
      String.starts_with?(name, "mcp_") or name == "ragex" -> "🔌"
      true -> "󰒓"
    end
  end

  def tool_icon(_), do: "🛠️"

  @doc "Formats a tool call into a user-friendly string: tool_name(key: val, ...)"
  def format_tool_call(tool_name, args, opts \\ [])

  def format_tool_call(tool_name, %{} = args, _opts) when map_size(args) == 0,
    do: "#{tool_name}()"

  def format_tool_call(tool_name, args, opts) when is_map(args) do
    # Underscore-prefixed keys (e.g. `_session_id`, injected server-side by
    # `Yoke.TaskEngine.Orchestrator` for tools like
    # `spawn_subagent` that need session context the model never supplies
    # or even sees in the tool's own parameter schema) are a "private
    # argument" convention -- always hidden from this user-facing summary.
    visible_args =
      Map.reject(args, fn {k, _v} -> is_binary(k) and String.starts_with?(k, "_") end)

    if map_size(visible_args) == 0 do
      "#{tool_name}()"
    else
      max_width = Keyword.get(opts, :max_width) || default_max_width()

      if Yoke.CLI.LineEditor.expand_tool_calls?() do
        formatted_args =
          Enum.map_join(visible_args, ", ", fn
            {k, v} when is_binary(k) -> "#{k}: #{inspect_val(v)}"
            {k, v} -> "#{inspect(k)}: #{inspect_val(v)}"
          end)

        "#{tool_name}(#{formatted_args})"
      else
        format_smart_tool_call(tool_name, visible_args, max_width)
      end
    end
  end

  def format_tool_call(tool_name, args, _opts) do
    "#{tool_name}(#{inspect(args)})"
  end

  defp default_max_width do
    case :io.columns() do
      {:ok, c} when is_integer(c) and c > 15 -> max(c - 8, 20)
      _ -> 112
    end
  end

  defp inspect_val(val) when is_binary(val), do: inspect(val)
  defp inspect_val(val), do: inspect(val)

  defp format_smart_tool_call(tool_name, visible_args, max_width) do
    arg_items =
      Enum.map(visible_args, fn {k, v} ->
        k_str = if is_binary(k), do: k, else: inspect(k)
        full_val_str = inspect_val(v)
        full_kv_str = "#{k_str}: #{full_val_str}"
        full_kv_width = Yoke.CLI.Formatter.display_width(full_kv_str)

        trimmed_val_str = make_payload_link(k_str, v)
        trimmed_kv_str = "#{k_str}: #{trimmed_val_str}"
        trimmed_kv_width = Yoke.CLI.Formatter.display_width(trimmed_kv_str)

        %{
          key: k_str,
          val: v,
          full_kv: full_kv_str,
          full_kv_width: full_kv_width,
          trimmed_kv: trimmed_kv_str,
          trimmed_kv_width: trimmed_kv_width,
          is_trimmed: false
        }
      end)

    full_line_str = build_call_string(tool_name, arg_items)
    full_line_width = Yoke.CLI.Formatter.display_width(full_line_str)

    if full_line_width <= max_width do
      full_line_str
    else
      trim_longest_args_until_fits(tool_name, arg_items, max_width)
    end
  end

  defp build_call_string(tool_name, arg_items) do
    formatted_args =
      Enum.map_join(arg_items, ", ", fn item ->
        if item.is_trimmed do
          item.trimmed_kv
        else
          item.full_kv
        end
      end)

    "#{tool_name}(#{formatted_args})"
  end

  defp trim_longest_args_until_fits(tool_name, arg_items, max_width) do
    current_line_str = build_call_string(tool_name, arg_items)
    current_width = Yoke.CLI.Formatter.display_width(current_line_str)

    if current_width <= max_width do
      current_line_str
    else
      untrimmed_candidates =
        arg_items
        |> Enum.with_index()
        |> Enum.reject(fn {item, _idx} -> item.is_trimmed end)

      case untrimmed_candidates do
        [] ->
          current_line_str

        candidates ->
          {best_item, max_idx} =
            Enum.max_by(candidates, fn {item, _idx} -> item.full_kv_width end)

          other_items = List.delete_at(arg_items, max_idx)

          other_widths =
            Enum.map(other_items, fn item ->
              if item.is_trimmed, do: item.trimmed_kv_width, else: item.full_kv_width
            end)

          commas_count = max(length(arg_items) - 1, 0)

          overhead =
            Yoke.CLI.Formatter.display_width(tool_name) + 2 + commas_count * 2 +
              Enum.sum(other_widths)

          avail_kv_budget = max_width - overhead
          key_prefix_width = Yoke.CLI.Formatter.display_width("#{best_item.key}: ")
          avail_val_budget = avail_kv_budget - key_prefix_width

          trimmed_val_str = format_trimmed_val(best_item.key, best_item.val, avail_val_budget)
          trimmed_kv_str = "#{best_item.key}: #{trimmed_val_str}"
          trimmed_kv_width = Yoke.CLI.Formatter.display_width(trimmed_kv_str)

          updated_item = %{
            best_item
            | trimmed_kv: trimmed_kv_str,
              trimmed_kv_width: trimmed_kv_width,
              is_trimmed: true
          }

          updated_items = List.replace_at(arg_items, max_idx, updated_item)
          trim_longest_args_until_fits(tool_name, updated_items, max_width)
      end
    end
  end

  defp format_trimmed_val(key, val, avail_val_budget) do
    if avail_val_budget > 3 do
      raw_str =
        case val do
          s when is_binary(s) ->
            s |> String.replace("\r\n", " ") |> String.replace("\n", " ")

          other ->
            ins = inspect(other)

            if String.starts_with?(ins, "\"") and String.ends_with?(ins, "\"") and
                 String.length(ins) >= 2 do
              String.slice(ins, 1..(String.length(ins) - 2))
            else
              ins
            end
        end

      content_budget = avail_val_budget - 3
      sliced = slice_to_display_width(raw_str, content_budget)

      if Yoke.CLI.Formatter.display_width(raw_str) > Yoke.CLI.Formatter.display_width(sliced) do
        display_text = "\"#{sliced}…\""
        make_payload_link(key, val, display_text)
      else
        display_text = inspect_val(val)
        make_payload_link(key, val, display_text)
      end
    else
      make_payload_link(key, val, "…")
    end
  end

  defp slice_to_display_width(_str, target_width) when target_width <= 0, do: ""

  defp slice_to_display_width(str, target_width) do
    str
    |> Yoke.CLI.Formatter.sanitize_utf8()
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, w} ->
      gw = Yoke.CLI.Formatter.display_width(grapheme)

      if w + gw > target_width do
        {:halt, {acc, w}}
      else
        {:cont, {acc <> grapheme, w + gw}}
      end
    end)
    |> elem(0)
  end

  defp make_payload_link(key, val, display_text \\ "…") do
    dir = Path.expand(".yoke/payloads")
    File.mkdir_p!(dir)
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S_%f")
    filename = "payload_#{key}_#{timestamp}.txt"
    abs_path = Path.join(dir, filename)

    content =
      case val do
        s when is_binary(s) -> s
        other -> inspect(other, pretty: true)
      end

    File.write!(abs_path, content)

    # OSC 8 Terminal Hyperlink format: \e]8;;file:///path\e\…\e]8;;\e\
    "\e]8;;file://#{abs_path}\e\\#{display_text}\e]8;;\e\\"
  rescue
    _ -> display_text
  end

  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: inspect(output, pretty: true)

  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  @doc "Categorizes a tool call into :shell_out, :other, or :tool_call."
  def tool_category(tool_name) when is_binary(tool_name) do
    case String.downcase(tool_name) do
      name when name in ["bash", "cmd", "run_command", "shell", "exec", "execute_command"] ->
        :shell_out

      name
      when name in [
             "subagent",
             "spawn_subagent",
             "agent",
             "run_workflow",
             "ask_question",
             "ask",
             "question",
             "user_input",
             "job_status",
             "job_list",
             "job_kill"
           ] ->
        :other

      _ ->
        :tool_call
    end
  end

  def tool_category(_), do: :other

  @doc "Returns color code for tool category."
  def category_color(:tool_call), do: Yoke.CLI.Formatter.cyan()
  def category_color(:shell_out), do: Yoke.CLI.Formatter.yellow()
  def category_color(:other), do: Yoke.CLI.Formatter.magenta()

  @doc "Returns Unicode symbol for tool category."
  def category_symbol(:tool_call), do: "◈"
  def category_symbol(:shell_out), do: "❯"
  def category_symbol(:other), do: "⟡"

  @doc "Returns colored Unicode bullet for tool category: ToolCall (◈), ShellOut (❯), Other (⟡)."
  def category_badge(cat) do
    category_color(cat) <> category_symbol(cat) <> Formatter.reset()
  end

  @doc "Formats full tool execution line with colored bullet and verb, target prefix, and semantic summary."
  def format_execution_log(tool_name, args, prefix \\ nil) do
    cat = tool_category(tool_name)
    color = category_color(cat)
    symbol = category_symbol(cat)
    reset = Formatter.reset()
    prefix_str = if prefix, do: " #{prefix}", else: ""

    if Yoke.CLI.LineEditor.expand_tool_calls?() do
      badge = category_badge(cat)
      "#{badge}#{prefix_str} #{format_tool_call(tool_name, args)}"
    else
      action_text = humanize_action(tool_name, args)
      {verb_padded, details} = split_verb_and_details(action_text)
      details_str = if details != "", do: " #{details}", else: ""
      line = "#{color}#{symbol} #{verb_padded}#{reset}#{prefix_str}#{details_str}"
      LineEditor.truncate_to_width(line, terminal_cols())
    end
  end

  defp split_verb_and_details(action_text) do
    case Regex.run(~r/^(\S+)\s*(.*)$/, action_text) do
      [_, verb, details] ->
        verb_padded = String.pad_trailing(verb, 6)
        {verb_padded, details}

      _ ->
        {String.pad_trailing(action_text, 6), ""}
    end
  end

  @doc "Formats tool call into succinct, human-readable action text."
  # credo:disable-for-lines:250
  def humanize_action(tool_name, args) when is_map(args) do
    name_lower = String.downcase(to_string(tool_name))

    cond do
      name_lower in ["bash", "cmd", "run_command", "shell", "exec", "execute_command"] ->
        cmd =
          Map.get(args, "command") || Map.get(args, "cmd") || Map.get(args, "CommandLine") ||
            Map.get(args, "command_line") || ""

        clean_cmd = clean_single_line(cmd)
        cwd = get_arg(args, ["cwd", "Cwd", "dir", "directory"])
        desc = get_description(args) |> clean_single_line()
        budget = details_budget()

        cmd_part =
          if cwd != "" and cwd != "." do
            "$ #{clean_cmd} (in #{cwd})"
          else
            "$ #{clean_cmd}"
          end

        details =
          if desc != "" and desc != clean_cmd do
            truncate_str("#{cmd_part} — #{desc}", budget)
          else
            truncate_str(cmd_part, budget)
          end

        "Bash   #{details}"

      name_lower in ["read_file", "file_read", "read_contents", "get_file", "view_file"] or
          String.ends_with?(name_lower, "view") ->
        path =
          get_arg(args, ["path", "target_file", "TargetFile", "AbsolutePath", "file", "filepath"])

        start_line = get_arg(args, ["start_line", "StartLine"])
        end_line = get_arg(args, ["end_line", "EndLine"])
        desc = get_description(args) |> clean_single_line()

        range =
          cond do
            start_line != "" and end_line != "" ->
              {parse_int(start_line), parse_int(end_line)}

            start_line != "" ->
              {parse_int(start_line), nil}

            true ->
              case count_file_lines(path) do
                total when is_integer(total) and total > 0 -> {1, total}
                _ -> nil
              end
          end

        line_suffix = format_line_range(range)
        base = "#{path}#{line_suffix}"
        budget = details_budget()

        details =
          if desc != "" do
            truncate_str("#{base} — #{desc}", budget)
          else
            base
          end

        "Read   #{details}"

      name_lower == "read_files" ->
        paths = Map.get(args, "paths") || []
        budget = details_budget()

        case paths do
          [] ->
            "Read   files"

          [p] ->
            "Read   #{p}"

          [p1, p2] ->
            "Read   #{p1}, #{p2}"

          list ->
            joined = Enum.join(list, ", ")

            if String.length(joined) <= max(budget - 7, 20) do
              "Read   #{joined}"
            else
              [p1, p2 | rest] = list
              "Read   #{p1}, #{p2} (+#{length(rest)})"
            end
        end

      name_lower in ["grep_search", "grep", "search_files", "file_search", "ripgrep", "search"] ->
        path = get_arg(args, ["path", "target", "path_to_search"])
        query = get_arg(args, ["query", "pattern"])
        glob = get_arg(args, ["glob", "include", "file_types", "type"])
        desc = get_description(args) |> clean_single_line()
        budget = details_budget()

        clean_query =
          query
          |> safe_to_string()
          |> clean_single_line()
          |> String.replace("\\(", "(")
          |> String.replace("\\)", ")")

        path_part =
          cond do
            path != "" and glob != "" -> "#{path} (#{glob})"
            path != "" -> path
            glob != "" -> glob
            true -> ""
          end

        base =
          cond do
            clean_query != "" and path_part != "" ->
              "Grep   /#{clean_query}/ in #{path_part}"

            clean_query != "" ->
              "Grep   /#{clean_query}/"

            path_part != "" ->
              "Grep   in #{path_part}"

            true ->
              "Grep"
          end

        if desc != "" and desc != clean_query do
          truncate_str("#{base} — #{desc}", budget)
        else
          truncate_str(base, budget)
        end

      name_lower in ["write_file", "write_to_file", "create_file", "save_file"] ->
        path =
          get_arg(args, ["path", "target_file", "TargetFile", "AbsolutePath", "file", "filepath"])

        content = get_arg(args, ["content", "CodeContent", "code_content", "text"])
        desc = get_description(args) |> clean_single_line()
        budget = details_budget()

        line_info =
          if content != "" do
            lines = count_lines(content)
            if lines == 1, do: ":1 (1 line)", else: ":1-#{lines} (#{lines} lines)"
          else
            ""
          end

        base = if line_info != "", do: "#{path}#{line_info}", else: path

        details =
          if desc != "" do
            truncate_str("#{base} — #{desc}", budget)
          else
            base
          end

        "Write  #{details}"

      name_lower in ["edit_files", "mcp_ragex_edit_files", "ragex_edit_files"] ->
        files = Map.get(args, "files") || []
        budget = details_budget()

        case files do
          [] ->
            "Edit   files"

          [%{"path" => p}] ->
            "Edit   #{p}"

          [%{"path" => p1}, %{"path" => p2}] ->
            "Edit   #{p1}, #{p2}"

          [%{"path" => p1}, %{"path" => p2} | rest] ->
            joined = Enum.map_join(files, ", ", fn f -> Map.get(f, "path") || "file" end)

            if String.length(joined) <= max(budget - 7, 20) do
              "Edit   #{joined}"
            else
              "Edit   #{p1}, #{p2} (+#{length(rest)})"
            end

          [p | _] when is_binary(p) ->
            truncate_str("Edit   #{Enum.join(files, ", ")}", budget)

          _ ->
            "Edit   #{length(files)} files"
        end

      name_lower in [
        "replace_file_content",
        "replace_file",
        "edit_file",
        "patch_file",
        "apply_diff"
      ] or
        String.ends_with?(name_lower, "edit_file") or
          String.ends_with?(name_lower, "refactor_code") ->
        path =
          get_arg(args, ["path", "target_file", "TargetFile", "AbsolutePath", "file", "filepath"])

        range = get_line_range(path, args)
        line_suffix = format_line_range(range)
        count_str = format_line_count(range, args)
        desc = get_description(args) |> clean_single_line()
        budget = details_budget()
        base = "#{path}#{line_suffix}"

        details =
          cond do
            count_str != "" and desc != "" ->
              truncate_str("#{base} #{count_str} — #{desc}", budget)

            desc != "" ->
              truncate_str("#{base} — #{desc}", budget)

            count_str != "" ->
              "#{base} #{count_str}"

            true ->
              base
          end

        "Edit   #{details}"

      name_lower in ["list_dir", "ls", "dir_list", "list_directory"] ->
        path = get_arg(args, ["path", "target", "dir", "directory"])
        path = if path == "", do: ".", else: path
        recursive = Map.get(args, "recursive") == true or Map.get(args, "recursive") == "true"
        pattern = get_arg(args, ["pattern", "filter"])
        budget = details_budget()

        suffix =
          cond do
            recursive and pattern != "" -> " (#{pattern}, recursive)"
            recursive -> " (recursive)"
            pattern != "" -> " (#{pattern})"
            true -> ""
          end

        truncate_str("List   #{path}#{suffix}", budget)

      name_lower in ["glob_search", "glob", "file_glob"] or
          String.starts_with?(name_lower, "glob_") ->
        pattern = get_arg(args, ["pattern", "glob"])
        path = get_arg(args, ["path", "cwd"])
        exclude = get_arg(args, ["exclude", "ignore"])
        budget = details_budget()

        path_part =
          cond do
            path != "" and path != "." and exclude != "" -> " in #{path} (excl. #{exclude})"
            path != "" and path != "." -> " in #{path}"
            exclude != "" -> " (excl. #{exclude})"
            true -> ""
          end

        base =
          cond do
            pattern != "" -> "Glob   #{pattern}#{path_part}"
            path_part != "" -> "Glob  #{path_part}"
            true -> "Glob"
          end

        truncate_str(base, budget)

      name_lower == "find_by_name" ->
        name = get_arg(args, ["name", "pattern"])
        path = get_arg(args, ["path"])
        path = if path == "", do: ".", else: path
        type = get_arg(args, ["type"])
        type_str = if type != "", do: " (#{type})", else: ""
        budget = details_budget()
        truncate_str("Find   \"#{name}\"#{type_str} in #{path}", budget)

      name_lower == "git_status" ->
        path = get_arg(args, ["path", "file"])
        if path != "", do: "Git    status #{path}", else: "Git    status"

      name_lower == "git_diff" ->
        path = get_arg(args, ["path", "file"])
        staged = Map.get(args, "staged") == true or Map.get(args, "cached") == true
        flag = if staged, do: " --staged", else: ""
        if path != "", do: "Git    diff#{flag} #{path}", else: "Git    diff#{flag}"

      name_lower == "git_commit" ->
        msg = clean_single_line(get_arg(args, ["message", "msg"]))
        budget = details_budget()
        truncate_str("Git    commit \"#{msg}\"", budget)

      name_lower == "git_log" ->
        n = get_arg(args, ["n", "count", "max_count"])
        path = get_arg(args, ["path", "file"])
        n_str = if n != "", do: " -n #{n}", else: ""
        path_str = if path != "", do: " #{path}", else: ""
        "Git    log#{n_str}#{path_str}"

      name_lower in ["job_status", "job_info"] ->
        job_id = get_arg(args, ["job_id", "id", "TaskId", "task_id"])
        tail = get_arg(args, ["tail"])
        tail_str = if tail != "", do: " (tail #{tail})", else: ""
        "Job    ##{job_id}#{tail_str}"

      name_lower in ["job_kill", "job_cancel"] ->
        job_id = get_arg(args, ["job_id", "id", "TaskId", "task_id"])
        "Job    kill ##{job_id}"

      name_lower == "job_list" ->
        "Job    list"

      name_lower in ["spawn_subagent", "invoke_subagent", "subagent", "agent"] ->
        budget = details_budget()
        subagents = Map.get(args, "Subagents") || Map.get(args, "subagents") || []

        case subagents do
          [%{} = first | rest] ->
            role = Map.get(first, "Role") || Map.get(first, "role") || ""
            prompt = Map.get(first, "Prompt") || Map.get(first, "prompt") || ""
            clean_prompt = prompt |> clean_single_line()
            rest_str = if rest != [], do: " (+#{length(rest)})", else: ""

            if role != "" do
              truncate_str("Agent  #{role}: \"#{clean_prompt}\"#{rest_str}", budget)
            else
              truncate_str("Agent  \"#{clean_prompt}\"#{rest_str}", budget)
            end

          _ ->
            role = get_arg(args, ["Role", "role", "TypeName", "type_name"])
            prompt = get_arg(args, ["prompt", "Prompt", "task", "instruction"])
            clean_prompt = prompt |> clean_single_line()

            if role != "" and clean_prompt != "" do
              truncate_str("Agent  #{role}: \"#{clean_prompt}\"", budget)
            else
              truncate_str("Agent  \"#{clean_prompt}\"", budget)
            end
        end

      name_lower in ["ask_question", "ask", "question", "user_input"] ->
        budget = details_budget()
        questions = Map.get(args, "questions")

        q =
          case questions do
            [%{"question" => text} | _] -> text
            [%{question: text} | _] -> text
            _ -> get_arg(args, ["question", "prompt"])
          end

        clean_q = q |> clean_single_line()
        truncate_str("Ask    \"#{clean_q}\"", budget)

      name_lower == "run_workflow" ->
        wf = get_arg(args, ["workflow", "name"])
        "Flow   #{wf}"

      name_lower in [
        "http",
        "req",
        "fetch_url",
        "web_search",
        "read_url",
        "read_url_content",
        "search_web"
      ] ->
        url = get_arg(args, ["url", "Url"])
        query = get_arg(args, ["query", "q"])
        budget = details_budget()

        target =
          cond do
            query != "" -> "search \"#{query}\""
            url != "" -> url
            true -> get_arg(args, ["target"])
          end

        truncate_str("Web    #{clean_single_line(target)}", budget)

      name_lower in [
        "mcp_ragex_find_symbol",
        "mcp_ragex_symbol_definition",
        "mcp_ragex_references",
        "ragex_find_symbol",
        "ragex_symbol_definition",
        "ragex_references"
      ] ->
        symbol = get_arg(args, ["symbol", "name"])
        path = get_arg(args, ["path", "file"])
        budget = details_budget()
        details = if path != "", do: "#{symbol} in #{path}", else: symbol
        truncate_str("Symbol #{details}", budget)

      name_lower in ["mcp_ragex_search_code", "ragex_search_code"] ->
        query = get_arg(args, ["query", "pattern"])
        path = get_arg(args, ["path", "file"])
        budget = details_budget()
        details = if path != "", do: "/#{query}/ in #{path}", else: "/#{query}/"
        truncate_str("Search #{details}", budget)

      name_lower in ["mcp_ragex_outline", "ragex_outline"] ->
        path = get_arg(args, ["path", "file"])
        budget = details_budget()
        truncate_str("Outlin #{path}", budget)

      true ->
        label = format_tool_label(tool_name)
        budget = details_budget()
        summary = format_detailed_args(args, budget - 7)
        "#{label} #{summary}"
    end
  end

  def humanize_action(tool_name, args), do: format_tool_call(tool_name, args)

  @doc "Returns current terminal columns or fallback 120."
  def terminal_cols do
    case :io.columns() do
      {:ok, c} when is_integer(c) and c > 10 -> c
      _ -> 120
    end
  end

  defp details_budget do
    max(terminal_cols() - 8, 72)
  end

  defp get_arg(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, "", fn k ->
      case Map.get(map, k) do
        nil -> nil
        "" -> nil
        val -> safe_to_string(val)
      end
    end)
  end

  defp clean_single_line(nil), do: ""

  defp clean_single_line(str) do
    str
    |> safe_to_string()
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
  end

  defp truncate_str(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 1) <> "…"
    else
      str
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp count_lines(""), do: 1

  defp count_lines(str) when is_binary(str) do
    length(String.split(str, "\n"))
  end

  defp count_file_lines(path) when is_binary(path) do
    if path != "" and File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> count_lines(content)
        _ -> nil
      end
    else
      nil
    end
  end

  defp get_description(args) when is_map(args) do
    get_arg(args, [
      "Description",
      "description",
      "Instruction",
      "instruction",
      "toolAction",
      "summary",
      "toolSummary",
      "message",
      "title",
      "comment"
    ])
  end

  defp get_line_range(path, args) do
    start_arg = get_arg(args, ["start_line", "StartLine", "line_start", "line", "start"])
    end_arg = get_arg(args, ["end_line", "EndLine", "line_end", "end"])

    start_num = parse_int(start_arg)
    end_num = parse_int(end_arg)

    cond do
      is_integer(start_num) and is_integer(end_num) and start_num > 0 and end_num > 0 ->
        {start_num, end_num}

      is_integer(start_num) and start_num > 0 ->
        target =
          get_arg(args, ["target_content", "TargetContent", "target", "old_content", "old_str"])

        if target != "" do
          lines = count_lines(target)
          {start_num, start_num + max(lines - 1, 0)}
        else
          {start_num, nil}
        end

      is_list(Map.get(args, "changes")) ->
        extract_range_from_changes(Map.get(args, "changes"))

      true ->
        case extract_range_arg(args) do
          {s, e} ->
            {s, e}

          nil ->
            target =
              get_arg(args, [
                "target_content",
                "TargetContent",
                "target",
                "old_content",
                "old_str"
              ])

            if target != "" and path != "" and File.exists?(path) do
              find_target_in_file(path, target)
            else
              nil
            end
        end
    end
  end

  defp extract_range_from_changes(changes) when is_list(changes) do
    ranges =
      Enum.flat_map(changes, fn
        %{} = change ->
          s = parse_int(Map.get(change, "line_start") || Map.get(change, "start_line"))
          e = parse_int(Map.get(change, "line_end") || Map.get(change, "end_line"))

          cond do
            is_integer(s) and is_integer(e) -> [{s, e}]
            is_integer(s) -> [{s, s}]
            true -> []
          end

        _ ->
          []
      end)

    case ranges do
      [] ->
        nil

      _ ->
        min_s = Enum.map(ranges, &elem(&1, 0)) |> Enum.min()
        max_e = Enum.map(ranges, &elem(&1, 1)) |> Enum.max()
        {min_s, max_e}
    end
  end

  defp extract_range_from_changes(_), do: nil

  defp extract_range_arg(args) do
    val = Map.get(args, "range") || Map.get(args, "lines")

    case val do
      [s, e] when is_integer(s) and is_integer(e) ->
        {s, e}

      [s, e] ->
        with s_int when is_integer(s_int) <- parse_int(s),
             e_int when is_integer(e_int) <- parse_int(e) do
          {s_int, e_int}
        else
          _ -> nil
        end

      str when is_binary(str) ->
        case Regex.run(~r/^(\d+)\s*[-:]\s*(\d+)$/, String.trim(str)) do
          [_, s_str, e_str] -> {String.to_integer(s_str), String.to_integer(e_str)}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp find_target_in_file(path, target) when is_binary(path) and is_binary(target) do
    case File.read(path) do
      {:ok, content} ->
        find_target_lines(content, target)

      _ ->
        nil
    end
  end

  defp find_target_lines(file_content, target_content)
       when is_binary(file_content) and is_binary(target_content) do
    trimmed_target = String.trim_trailing(target_content, "\n")

    if trimmed_target == "" do
      nil
    else
      match_res =
        case :binary.match(file_content, trimmed_target) do
          {offset, _} ->
            {:ok, file_content, offset, trimmed_target}

          :nomatch ->
            norm_file = String.replace(file_content, "\r\n", "\n")
            norm_target = String.replace(trimmed_target, "\r\n", "\n")

            case :binary.match(norm_file, norm_target) do
              {offset, _} -> {:ok, norm_file, offset, norm_target}
              :nomatch -> :nomatch
            end
        end

      case match_res do
        {:ok, content, offset, target} ->
          before = :binary.part(content, 0, offset)
          start_line = count_lines(before)
          target_lines = count_lines(target)
          {start_line, start_line + max(target_lines - 1, 0)}

        :nomatch ->
          nil
      end
    end
  end

  defp format_line_range({start_l, end_l}) when is_integer(start_l) and is_integer(end_l) do
    if start_l == end_l do
      ":#{start_l}"
    else
      ":#{start_l}-#{end_l}"
    end
  end

  defp format_line_range({start_l, nil}) when is_integer(start_l), do: ":#{start_l}+"
  defp format_line_range(_), do: ""

  defp format_line_count({start_l, end_l}, args)
       when is_integer(start_l) and is_integer(end_l) do
    count = max(end_l - start_l + 1, 1)
    base = if count == 1, do: "(1 line)", else: "(#{count} lines)"

    case Map.get(args, "changes") do
      changes when is_list(changes) and length(changes) > 1 ->
        "#{base} (#{length(changes)} changes)"

      _ ->
        base
    end
  end

  defp format_line_count(_, %{} = args) do
    case Map.get(args, "changes") do
      [_] ->
        "(1 change)"

      changes when is_list(changes) and changes != [] ->
        "(#{length(changes)} changes)"

      _ ->
        ""
    end
  end

  defp format_tool_label(tool_name) do
    cleaned =
      tool_name
      |> to_string()
      |> String.replace_prefix("mcp_", "")
      |> String.replace_prefix("ragex_", "")

    first_word =
      cleaned
      |> String.split("_")
      |> List.first()
      |> to_string()
      |> String.capitalize()

    first_word
    |> String.slice(0, 6)
    |> String.pad_trailing(6)
  end

  defp format_detailed_args(args, budget) when is_map(args) do
    visible = Map.reject(args, fn {k, _} -> is_binary(k) and String.starts_with?(k, "_") end)

    if map_size(visible) == 0 do
      "()"
    else
      path = get_arg(visible, ["path", "target_file", "TargetFile", "file", "filepath"])
      symbol = get_arg(visible, ["symbol", "name"])
      query = get_arg(visible, ["query", "pattern"])
      action = get_arg(visible, ["action", "Action"])
      desc = get_description(visible) |> clean_single_line()

      semantic_text =
        cond do
          action != "" and (symbol != "" or path != "") ->
            "#{action} #{if symbol != "", do: symbol, else: path}"

          symbol != "" and path != "" ->
            "#{symbol} in #{path}"

          query != "" and path != "" ->
            "/#{query}/ in #{path}"

          symbol != "" ->
            symbol

          query != "" ->
            "/#{query}/"

          path != "" and desc != "" ->
            "#{path} — #{desc}"

          path != "" ->
            path

          true ->
            pairs =
              visible
              |> Enum.reject(fn {k, _} -> k in ["toolSummary", "toolAction"] end)
              |> Enum.map(fn {k, v} ->
                val_str = format_arg_value_summary(v) |> clean_single_line()
                "#{k}: #{val_str}"
              end)

            case pairs do
              [] ->
                visible
                |> Map.values()
                |> List.first()
                |> format_arg_value_summary()
                |> clean_single_line()

              list ->
                Enum.join(list, ", ")
            end
        end

      truncate_str(semantic_text, budget)
    end
  end

  defp format_arg_value_summary(nil), do: ""
  defp format_arg_value_summary(val) when is_binary(val), do: val
  defp format_arg_value_summary(val) when is_atom(val), do: Atom.to_string(val)
  defp format_arg_value_summary(val) when is_number(val), do: to_string(val)

  defp format_arg_value_summary(val) when is_list(val) do
    if List.ascii_printable?(val) do
      to_string(val)
    else
      case val do
        [] ->
          "[]"

        [%{"path" => p} | rest] ->
          if rest == [], do: "[#{p}]", else: "[#{p}, ... (+#{length(rest)})]"

        _ ->
          "[#{length(val)} items]"
      end
    end
  end

  defp format_arg_value_summary(val) when is_map(val) do
    cond do
      Map.has_key?(val, "path") ->
        "%{path: #{inspect(val["path"])}}"

      Map.has_key?(val, :path) ->
        "%{path: #{inspect(val[:path])}}"

      true ->
        "%{#{map_size(val)} keys}"
    end
  end

  defp format_arg_value_summary(val), do: inspect(val)

  defp safe_to_string(nil), do: ""
  defp safe_to_string(val) when is_binary(val), do: val
  defp safe_to_string(val) when is_atom(val), do: Atom.to_string(val)
  defp safe_to_string(val) when is_number(val), do: to_string(val)

  defp safe_to_string(val) when is_list(val) do
    if List.ascii_printable?(val), do: to_string(val), else: inspect(val)
  end

  defp safe_to_string(val), do: inspect(val)
end

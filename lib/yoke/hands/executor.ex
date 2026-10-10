defmodule Yoke.Hands.Executor do
  @moduledoc """
  The "Hands" component of Yoke.
  Executes tools and sandbox operations across local system, isolated Erlang nodes, or Docker containers.
  Provides temporal side-effect tracking for undo and crash recovery.
  """
  require Logger

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

  @doc "Returns colored Unicode bullet for tool category: ToolCall (◈), ShellOut (❯), Other (⟡)."
  def category_badge(:tool_call),
    do: Yoke.CLI.Formatter.cyan() <> "◈" <> Yoke.CLI.Formatter.reset()

  def category_badge(:shell_out),
    do: Yoke.CLI.Formatter.yellow() <> "❯" <> Yoke.CLI.Formatter.reset()

  def category_badge(:other),
    do: Yoke.CLI.Formatter.magenta() <> "⟡" <> Yoke.CLI.Formatter.reset()

  @doc "Formats full tool execution line with bullet, target prefix, and semantic summary."
  def format_execution_log(tool_name, args, prefix \\ nil) do
    cat = tool_category(tool_name)
    badge = category_badge(cat)
    prefix_str = if prefix, do: " #{prefix}", else: ""

    action_text =
      if Yoke.CLI.LineEditor.expand_tool_calls?() do
        format_tool_call(tool_name, args)
      else
        humanize_action(tool_name, args)
      end

    "#{badge}#{prefix_str} #{action_text}"
  end

  @doc "Formats tool call into succinct, human-readable action text."
  def humanize_action(tool_name, args) when is_map(args) do
    name_lower = String.downcase(to_string(tool_name))

    cond do
      name_lower in ["bash", "cmd", "run_command", "shell", "exec", "execute_command"] ->
        cmd = Map.get(args, "command") || Map.get(args, "cmd") || ""
        clean_cmd = clean_single_line(cmd)
        "Bash   $ #{truncate_str(clean_cmd, 90)}"

      name_lower in ["read_file", "file_read", "read_contents", "get_file", "view_file"] ->
        path = get_arg(args, ["path", "target_file", "TargetFile"])
        start_line = get_arg(args, ["start_line", "StartLine"])
        end_line = get_arg(args, ["end_line", "EndLine"])

        line_suffix =
          cond do
            start_line != "" and end_line != "" -> ":#{start_line}-#{end_line}"
            start_line != "" -> ":#{start_line}+"
            true -> ""
          end

        "Read   #{path}#{line_suffix}"

      name_lower == "read_files" ->
        paths = Map.get(args, "paths") || []

        case paths do
          [] -> "Read   files"
          [p] -> "Read   #{p}"
          [p1, p2] -> "Read   #{p1}, #{p2}"
          [p1, p2 | rest] -> "Read   #{p1}, #{p2} (+#{length(rest)})"
        end

      name_lower in ["grep_search", "grep", "search_files", "file_search", "ripgrep", "search"] ->
        path = get_arg(args, ["path", "target"])
        query = get_arg(args, ["query", "pattern"])

        clean_query =
          query
          |> to_string()
          |> clean_single_line()
          |> String.replace("\\(", "(")
          |> String.replace("\\)", ")")
          |> truncate_str(40)

        cond do
          clean_query != "" and path != "" ->
            "Grep   /#{clean_query}/ in #{path}"

          clean_query != "" ->
            "Grep   /#{clean_query}/"

          path != "" ->
            "Grep   in #{path}"

          true ->
            "Grep"
        end

      name_lower in ["write_file", "write_to_file", "create_file", "save_file"] ->
        path = get_arg(args, ["path", "target_file", "TargetFile"])
        "Write  #{path}"

      name_lower in ["replace_file_content", "replace_file", "edit_file"] ->
        path = get_arg(args, ["path", "target_file", "TargetFile"])
        "Edit   #{path}"

      name_lower in ["list_dir", "ls", "dir_list", "list_directory"] ->
        path = get_arg(args, ["path", "target"])
        path = if path == "", do: ".", else: path
        "List   #{path}"

      name_lower == "find_by_name" ->
        name = get_arg(args, ["name", "pattern"])
        path = get_arg(args, ["path"])
        path = if path == "", do: ".", else: path
        "Find   \"#{name}\" in #{path}"

      name_lower == "git_status" ->
        "Git    status"

      name_lower == "git_diff" ->
        path = get_arg(args, ["path", "file"])
        if path != "", do: "Git    diff #{path}", else: "Git    diff"

      name_lower == "git_commit" ->
        msg = clean_single_line(get_arg(args, ["message", "msg"]))
        "Git    commit \"#{truncate_str(msg, 40)}\""

      name_lower == "git_log" ->
        "Git    log"

      name_lower in ["job_status", "job_info"] ->
        job_id = get_arg(args, ["job_id", "id"])
        tail = get_arg(args, ["tail"])
        tail_str = if tail != "", do: " (tail #{tail})", else: ""
        "Job    ##{job_id}#{tail_str}"

      name_lower == "job_list" ->
        "Job    list"

      name_lower in ["spawn_subagent", "subagent", "agent"] ->
        prompt = get_arg(args, ["prompt", "task", "instruction"])
        clean_prompt = prompt |> clean_single_line() |> truncate_str(50)
        "Agent  \"#{clean_prompt}\""

      name_lower in ["ask_question", "ask", "question", "user_input"] ->
        q = get_arg(args, ["question", "prompt"])
        clean_q = q |> clean_single_line() |> truncate_str(50)
        "Ask    \"#{clean_q}\""

      name_lower == "run_workflow" ->
        wf = get_arg(args, ["workflow", "name"])
        "Flow   #{wf}"

      name_lower in ["http", "req", "fetch_url", "web_search", "read_url"] ->
        target = get_arg(args, ["url", "query"])
        "Web    #{truncate_str(clean_single_line(target), 60)}"

      true ->
        label =
          tool_name
          |> String.replace("mcp_", "")
          |> String.capitalize()
          |> String.slice(0, 6)
          |> String.pad_trailing(6)

        summary = format_short_args(args)
        "#{label} #{summary}"
    end
  end

  def humanize_action(tool_name, args), do: format_tool_call(tool_name, args)

  defp get_arg(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, "", fn k ->
      case Map.get(map, k) do
        nil -> nil
        "" -> nil
        val -> to_string(val)
      end
    end)
  end

  defp clean_single_line(nil), do: ""

  defp clean_single_line(str) do
    str
    |> to_string()
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

  defp truncate_str(other, max_len), do: truncate_str(to_string(other), max_len)

  defp format_short_args(args) when is_map(args) do
    visible = Map.reject(args, fn {k, _} -> is_binary(k) and String.starts_with?(k, "_") end)

    case map_size(visible) do
      0 ->
        "()"

      _ ->
        first_val =
          visible
          |> Map.values()
          |> List.first()
          |> to_string()
          |> clean_single_line()
          |> truncate_str(40)

        first_val
    end
  end
end

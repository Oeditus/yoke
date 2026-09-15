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
      badge =
        Yoke.CLI.Formatter.cyan() <> "⚡" <> Yoke.CLI.Formatter.reset()

      Logger.info("#{badge} #{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}")

      case Yoke.Plugin.Loader.execute_tool(tool_name, args, :infinity) do
        {:ok, result} -> {:ok, format_output(result)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def execute(%__MODULE__{mode: :remote, remote_node: node}, tool_name, args)
      when not is_nil(node) do
    badge =
      Yoke.CLI.Formatter.cyan() <> "⚡" <> Yoke.CLI.Formatter.reset()

    Logger.info(
      "#{badge} [remote:#{node}] #{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}"
    )

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
    badge =
      Yoke.CLI.Formatter.cyan() <> "⚡" <> Yoke.CLI.Formatter.reset()

    Logger.info(
      "#{badge} [docker:#{container}] #{tool_icon(tool_name)} #{format_tool_call(tool_name, args)}"
    )

    case tool_name do
      "bash" ->
        cmd = Map.get(args, "command", "")
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
end

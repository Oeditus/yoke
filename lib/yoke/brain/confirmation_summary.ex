defmodule Yoke.Brain.ConfirmationSummary do
  @moduledoc """
  Renders a tool call into the short, human-readable block shown by the
  permission modal before a tool is allowed to run.

  Extracted from `Yoke.Brain.Session` because it is a pure function of
  `(tool_name, args)` with no dependency on session state, and because the
  permission prompt is the one place a user must actually *read* what they are
  approving -- it deserves its own tests rather than being reachable only
  through a live session actor.

  ## Bounded output

  Every clause truncates. An MCP tool with a large argument payload used to be
  rendered with `inspect(args)` verbatim, producing a wall of text the user
  could not read before answering. The generic renderer here caps both the
  number of keys and the length of each value.
  """

  @max_keys 12
  @max_value_length 60

  # Tool names whose arguments have a well-known shape worth rendering
  # specifically. Anything else falls through to the generic renderer.
  @replace_tools ~w(replace_file_content replace_file edit_file)
  @write_tools ~w(write_file write_to_file create_file)
  @shell_tools ~w(bash cmd run_command shell exec)
  @read_file_tools ~w(read_file view_file file_read)
  @read_files_tools ~w(read_files read_multiple_files)

  @doc """
  Returns a bounded, multi-line summary of a tool call for the permission modal.

  Accepts a map of arguments (string- or atom-keyed) or any other term.
  """
  @spec render(String.t(), term()) :: String.t()
  def render(tool_name, args) when is_map(args) and not is_struct(args) do
    case tool_name do
      name when name in @replace_tools -> replace_summary(tool_name, args)
      name when name in @write_tools -> write_summary(tool_name, args)
      name when name in @shell_tools -> shell_summary(tool_name, args)
      name when name in @read_file_tools -> read_file_summary(tool_name, args)
      name when name in @read_files_tools -> read_files_summary(tool_name, args)
      _ -> generic(tool_name, args)
    end
  end

  def render(tool_name, args), do: generic(tool_name, args)

  # ---------------------------------------------------------------------
  # Per-shape renderers
  # ---------------------------------------------------------------------

  defp replace_summary(tool_name, args) do
    file = first(args, ~w(TargetFile path AbsolutePath file)) || "file"
    target = first(args, ~w(TargetContent target)) || ""
    replacement = first(args, ~w(ReplacementContent replacement)) || ""
    start_line = first(args, ~w(StartLine line_start))
    end_line = first(args, ~w(EndLine line_end))

    lines_info = if start_line, do: " (lines #{start_line}-#{end_line})", else: ""

    diff_summary =
      cond do
        target != "" and replacement != "" ->
          """
          Target:
          - #{truncate_lines(target, 2)}
          Replacement:
          + #{truncate_lines(replacement, 2)}
          """

        replacement != "" ->
          """
          Replacement:
          + #{truncate_lines(replacement, 3)}
          """

        true ->
          ""
      end

    """
    Tool: #{tool_name}
    File: #{file}#{lines_info}
    #{diff_summary}
    """
    |> String.trim()
  end

  defp write_summary(tool_name, args) do
    file = first(args, ~w(TargetFile path AbsolutePath)) || "file"
    content = first(args, ~w(CodeContent content)) || ""
    line_count = length(String.split(content, "\n"))

    """
    Tool: #{tool_name}
    File: #{file} (#{line_count} lines)
    Preview:
    #{truncate_lines(content, 3)}
    """
    |> String.trim()
  end

  defp shell_summary(tool_name, args) do
    cmd = first(args, ~w(CommandLine command cmd)) || ""

    """
    Tool: #{tool_name}
    Command: $ #{cmd}
    """
    |> String.trim()
  end

  defp read_file_summary(tool_name, args) do
    file = first(args, ~w(AbsolutePath path file)) || "file"
    start_line = first(args, ~w(StartLine))
    end_line = first(args, ~w(EndLine))
    range = if start_line, do: " (lines #{start_line}-#{end_line})", else: ""

    """
    Tool: #{tool_name}
    File: #{file}#{range}
    """
    |> String.trim()
  end

  defp read_files_summary(tool_name, args) do
    files = first(args, ~w(paths)) || []

    file_list =
      if is_list(files) and files != [] do
        Enum.map_join(files, "\n", fn f -> "  - #{f}" end)
      else
        "  (none specified)"
      end

    count = if is_list(files), do: length(files), else: 0

    """
    Tool: #{tool_name}
    Files (#{count}):
    #{file_list}
    """
    |> String.trim()
  end

  # ---------------------------------------------------------------------
  # Generic renderer
  # ---------------------------------------------------------------------

  defp generic(tool_name, args) when is_map(args) and not is_struct(args) do
    keys = args |> Map.keys() |> Enum.sort_by(&to_string/1)

    shown =
      keys
      |> Enum.take(@max_keys)
      |> Enum.map_join("\n", fn key ->
        "  #{key}: #{truncate_str(stringify(Map.get(args, key)), @max_value_length)}"
      end)

    hidden = length(keys) - min(length(keys), @max_keys)
    more = if hidden > 0, do: "\n  ... (#{hidden} more argument(s))", else: ""

    "Tool: #{tool_name}\n#{shown}#{more}"
  end

  defp generic(tool_name, args) do
    "Tool: #{tool_name}\n  args: #{truncate_str(inspect(args), @max_value_length)}"
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Returns the first present, non-nil value among `keys`, so a call site does
  # not have to spell out every accepted spelling of the same argument.
  defp first(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp truncate_lines(text, max_lines) when is_binary(text) do
    lines = String.split(text, "\n")

    if length(lines) <= max_lines do
      text
    else
      preview = lines |> Enum.take(max_lines) |> Enum.join("\n")
      "#{preview}\n  ... [#{length(lines)} lines total]"
    end
  end

  defp truncate_str(str, max_len) when is_binary(str) do
    clean = String.replace(str, "\n", "\\n")

    if String.length(clean) <= max_len do
      clean
    else
      String.slice(clean, 0, max_len) <> "..."
    end
  end
end

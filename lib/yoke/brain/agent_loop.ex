defmodule Yoke.Brain.AgentLoop do
  @moduledoc """
  Encapsulates agent loop evaluation rules, duplicate tool call detection,
  and circuit breaker logic for non-standard tools.
  """
  require Logger

  @standard_tools ~w(
    read_file
    read_files
    write_file
    replace_file
    list_dir
    bash
    elixir_eval
    ask_question
    grep_search
    glob_search
    job_status
    job_kill
    run_linter
    git_status
    git_diff
    git_commit
    git_root
    mcp_ragex_grep
    mcp_ragex_search_code
    mcp_ragex_view
    mcp_ragex_structure
  )

  @repeatable_tools ~w(bash cmd run_command shell exec job_status ask_question user_input)

  @doc "Detects whether the exact same tool calls with identical arguments were executed in the previous turn."
  def duplicate_tool_calls?(messages, new_tool_calls)
      when is_list(messages) and is_list(new_tool_calls) do
    # Repeatable tools (such as bash probes, process checks, interactive questions)
    # observe external, mutable system state and must never be deduplicated.
    if Enum.any?(new_tool_calls, fn tc -> tc.name in @repeatable_tools end) do
      false
    else
      last_assistant_msg =
        messages
        |> Enum.reverse()
        |> Enum.find(fn m -> m["role"] == "assistant" and is_list(m["tool_calls"]) end)

      case last_assistant_msg do
        %{"tool_calls" => prev_calls} when is_list(prev_calls) ->
          prev_names_and_args =
            Enum.map(prev_calls, fn tc ->
              fn_data = Map.get(tc, "function", %{})
              {Map.get(fn_data, "name"), Map.get(fn_data, "arguments")}
            end)

          new_names_and_args =
            Enum.map(new_tool_calls, fn tc ->
              {tc.name, Yoke.Json.encode!(tc.arguments)}
            end)

          prev_names_and_args == new_names_and_args and prev_names_and_args != []

        _ ->
          false
      end
    end
  end

  def duplicate_tool_calls?(_, _), do: false

  @doc "Evaluates tool execution result and applies circuit breaker if non-standard tool repeatedly fails."
  def handle_tool_failure(tool_name, exec_result, state) do
    if non_standard_tool?(tool_name) and blank_result?(exec_result) do
      current_counts = Map.get(state, :tool_failure_counts, %{})
      new_fail_count = Map.get(current_counts, tool_name, 0) + 1
      updated_counts = Map.put(current_counts, tool_name, new_fail_count)

      if new_fail_count >= 3 do
        Logger.warning(
          "[AgentLoop] Non-standard tool '#{tool_name}' failed #{new_fail_count} times without results. Disabling tool."
        )

        remaining_tools =
          Enum.reject(state.tools, fn t ->
            Map.get(t, :name) == tool_name or Map.get(t, "name") == tool_name
          end)

        fallback_notice = %{
          "role" => "user",
          "content" =>
            "SYSTEM NOTICE: Non-standard tool '#{tool_name}' failed to provide results after #{new_fail_count} attempts. Fallback mode activated: tool '#{tool_name}' has been disabled. Please use standard tools: bash, read_file, replace_file, or list_dir instead."
        }

        updated_state = %{
          state
          | tool_failure_counts: updated_counts,
            tools: remaining_tools
        }

        {updated_state, fallback_notice}
      else
        {%{state | tool_failure_counts: updated_counts}, nil}
      end
    else
      {state, nil}
    end
  end

  def non_standard_tool?(name) when is_binary(name) do
    name not in @standard_tools
  end

  def non_standard_tool?(_), do: false

  def blank_result?({:error, _}), do: true

  def blank_result?({:ok, res}) when is_binary(res) do
    trimmed = String.trim(res)

    trimmed == "" or String.starts_with?(trimmed, "Tool execution failed") or
      String.starts_with?(trimmed, "Ragex tool error") or
      String.contains?(trimmed, "dllb_disabled") or
      String.contains?(trimmed, "manager_not_started")
  end

  def blank_result?({:ok, nil}), do: true
  def blank_result?({:ok, []}), do: true
  def blank_result?({:ok, %{}}), do: true
  def blank_result?(_), do: false
end

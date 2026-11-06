defmodule Yoke.Brain.AgentLoop do
  @moduledoc """
  Encapsulates agent loop evaluation rules, duplicate tool call detection,
  periodic cycle detection, and circuit breaker logic for non-standard tools.
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

  @repeatable_tools ~w(bash cmd run_command shell exec job_status ask_question user_input read_file read_files list_dir grep_search glob_search git_status git_diff git_root mcp_ragex_grep mcp_ragex_search_code mcp_ragex_view mcp_ragex_structure)

  @doc """
  Detects whether the sequence of tool calls in the current turn exhibits a repeating cycle.

  Tests for periodic cycles of period length `1..max_period` (default up to 4).
  - Period 1 non-repeatable tools: triggers after 2 consecutive identical calls.
  - Period 1 repeatable tools (e.g. bash probes): allows up to 2 calls, triggers on 3.
  - Period >= 2 (e.g. A -> B -> A -> B): triggers after 2 complete repetitions (>= 4 calls).

  Returns `{:loop, %{period: p, count: c, cycle: pattern}}` or `:ok`.
  """
  def detect_tool_loop(messages, new_tool_calls, opts \\ [])

  def detect_tool_loop(messages, new_tool_calls, opts)
      when is_list(messages) and is_list(new_tool_calls) and new_tool_calls != [] do
    max_period = Keyword.get(opts, :max_period, 4)
    repeatable_tools = Keyword.get(opts, :repeatable_tools, @repeatable_tools)

    history_steps = extract_turn_tool_steps(messages)
    current_step = normalize_tool_calls(new_tool_calls)

    if current_step == [] do
      :ok
    else
      full_sequence = history_steps ++ [current_step]
      check_cycles(full_sequence, max_period, repeatable_tools)
    end
  end

  def detect_tool_loop(_messages, _new_tool_calls, _opts), do: :ok

  @doc "Detects whether the exact same tool calls with identical arguments were executed in the previous turn or form a repeating cycle."
  def duplicate_tool_calls?(messages, new_tool_calls, opts \\ []) do
    case detect_tool_loop(messages, new_tool_calls, opts) do
      {:loop, _} -> true
      :ok -> false
    end
  end

  @doc "Extracts the sequence of assistant tool call signatures within the current turn."
  def extract_turn_tool_steps(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(fn m ->
      role = Map.get(m, "role") || Map.get(m, :role)
      content = Map.get(m, "content") || Map.get(m, :content) || ""

      not (role == "user" and not system_notice?(content))
    end)
    |> Enum.filter(fn m ->
      role = Map.get(m, "role") || Map.get(m, :role)
      calls = Map.get(m, "tool_calls") || Map.get(m, :tool_calls)
      role == "assistant" and is_list(calls) and calls != []
    end)
    |> Enum.reverse()
    |> Enum.map(&extract_step_signature/1)
  end

  def extract_turn_tool_steps(_), do: []

  @doc "Extracts the normalized step signature from an assistant message map."
  def extract_step_signature(msg) when is_map(msg) do
    calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls) || []
    normalize_tool_calls(calls)
  end

  def extract_step_signature(_), do: []

  @doc "Normalizes a list of tool call structs/maps into sorted `{name, normalized_args}` tuples."
  def normalize_tool_calls(calls) when is_list(calls) do
    calls
    |> Enum.map(fn tc ->
      fn_data = Map.get(tc, "function") || Map.get(tc, :function) || %{}

      name =
        Map.get(tc, :name) || Map.get(tc, "name") ||
          Map.get(fn_data, :name) || Map.get(fn_data, "name") || ""

      args =
        Map.get(tc, :arguments) || Map.get(tc, "arguments") ||
          Map.get(fn_data, :arguments) || Map.get(fn_data, "arguments") || %{}

      canonical_call(to_string(name), args)
    end)
    |> Enum.sort()
  end

  def normalize_tool_calls(_), do: []

  @doc "Creates a canonical `{name, args}` representation."
  def canonical_call(name, args) when is_binary(name) do
    {name, normalize_arguments(args)}
  end

  @doc "Recursively normalizes argument maps/strings for deterministic comparison."
  def normalize_arguments(args) when is_binary(args) do
    case Yoke.Json.decode(args) do
      {:ok, decoded} -> normalize_arguments(decoded)
      _ -> String.trim(args)
    end
  end

  def normalize_arguments(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_arguments(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  def normalize_arguments(args) when is_list(args) do
    Enum.map(args, &normalize_arguments/1)
  end

  def normalize_arguments(args), do: args

  @doc "Formats a detected cycle pattern for display in user notices and logs."
  def format_cycle_description(cycle) when is_list(cycle) do
    cycle
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {step, idx} ->
      step_str =
        Enum.map_join(step, ", ", fn {name, args} ->
          "#{name}(#{format_args_for_display(args)})"
        end)

      "  #{idx}. #{step_str}"
    end)
  end

  def format_cycle_description(_), do: ""

  defp format_args_for_display(args) when is_list(args) do
    Enum.map_join(args, ", ", fn
      {k, v} when is_binary(v) ->
        short_v = if String.length(v) > 80, do: String.slice(v, 0, 77) <> "...", else: v
        "#{k}: #{inspect(short_v)}"

      {k, v} ->
        "#{k}: #{inspect(v)}"
    end)
  end

  defp format_args_for_display(args), do: inspect(args)

  defp check_cycles(sequence, max_period, repeatable_tools) do
    seq_len = length(sequence)

    Enum.find_value(1..max_period, :ok, fn period ->
      if seq_len >= period do
        candidate_cycle = Enum.slice(sequence, (seq_len - period)..(seq_len - 1))
        repeats = count_cycle_repeats(sequence, candidate_cycle, period)
        threshold = repetition_threshold(candidate_cycle, period, repeatable_tools)

        if repeats >= threshold do
          {:loop, %{period: period, count: repeats, cycle: candidate_cycle}}
        else
          nil
        end
      else
        nil
      end
    end)
  end

  defp repetition_threshold(cycle, 1, repeatable_tools) do
    [single_step] = cycle

    all_repeatable? =
      single_step != [] and
        Enum.all?(single_step, fn {name, _args} -> name in repeatable_tools end)

    if all_repeatable?, do: 3, else: 2
  end

  defp repetition_threshold(_cycle, _period, _repeatable_tools) do
    2
  end

  defp count_cycle_repeats(sequence, cycle, period) do
    seq_len = length(sequence)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(0, fn k, acc ->
      start_idx = seq_len - k * period

      if start_idx >= 0 do
        chunk = Enum.slice(sequence, start_idx, period)

        if chunk == cycle do
          {:cont, k}
        else
          {:halt, acc}
        end
      else
        {:halt, acc}
      end
    end)
  end

  defp system_notice?(content) when is_binary(content) do
    String.starts_with?(content, "SYSTEM NOTICE:") or
      String.starts_with?(content, "SYSTEM INTERRUPT:")
  end

  defp system_notice?(_), do: false

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

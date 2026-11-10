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

  # Tools whose repeated invocation with identical arguments is *legitimate*
  # because the point of the repeat is to observe changing external state
  # (a running process, a mutated workspace, a fresh listing). For a period-1
  # cycle of only these tools the threshold is 3 identical calls instead of 2.
  #
  # `job_status` is deliberately absent: it is a *terminal* status probe, not a
  # live one. The documented contract (see the `bash`/`job_status` tool
  # descriptions) is that background jobs notify the session automatically on
  # completion, so a model that calls `job_status` with the same `job_id` and
  # `tail` over and over is polling a value that will not change until the job
  # ends -- the textbook infinite tool loop. Treating it as repeatable gave
  # such a loop one extra free iteration and, worse, made the loop notice read
  # as a false positive to reviewers. It is now a plain (non-repeatable) tool.
  @repeatable_tools ~w(bash cmd run_command shell exec ask_question user_input read_file read_files list_dir grep_search glob_search git_status git_diff git_root mcp_ragex_grep mcp_ragex_search_code mcp_ragex_view mcp_ragex_structure)

  # Tools that are never part of a *productive* cycle, regardless of period.
  # A period-N cycle containing one of these is always a stall: e.g.
  # `bash(compile) -> job_status(job_1) -> bash(compile) -> job_status(job_1)`
  # would otherwise slip past the period-2 threshold (which is 2) even though
  # the `job_status` half of the cycle is pure waiting.
  @non_cycling_tools ~w(job_status job_info)

  # A model that narrates its intent and then stops ("Now I have all the
  # information I need. Let me implement the addArticle() method...") ends the
  # turn with no tool calls and no work done. Small local models do this
  # often, so the harness treats such a response as an unfinished turn and
  # asks the model to continue instead of returning it to the user.
  #
  # The patterns are deliberately narrow: a first-person planning phrase that
  # is followed by a colon or by an action verb. Explanations that merely
  # contain "I'll" ("I'll explain how the loop works") or a colon after a
  # non-planning lead-in must not match, otherwise a legitimate answer would
  # be re-prompted.
  @intent_patterns [
    ~r/\b(?:let me|i(?:'ll| will| am going to| am about to|'m going to))\s+(?:now\s+)?(?:just\s+)?(?:go\s+ahead\s+and\s+)?(?:implement|add|create|write|apply|make|perform|update|modify|edit|fix|refactor|change|insert|remove|delete|replace|run|execute|call|use|read|open|inspect|check|search|find|look|grep|list|start|begin|proceed|continue|handle|build|generate|produce|draft|prepare|set\s+up|wire|rename|move|extract|introduce|define|declare|document|test|verify|validate|compile|install|configure|commit|stage|push|patch|rewrite|restructure|migrate|port|convert)\b/i,
    ~r/\b(?:now|next|then|first|finally|so)[^.!?\n]{0,80}\b(?:i(?:'ll| will| need to| should| must| have to| am going to)|let me|we(?:'ll| will| need to| should))\b/i,
    ~r/\b(?:here(?:'s| is) (?:my|the) plan|my plan is|the plan is|plan of action|steps? (?:are|is) as follows|next steps? (?:are|is))\b\s*:/i,
    ~r/^\s*(?:step\s*\d+|\d+[.)])\s*[^\n]{0,120}:\s*$/im,
    ~r/\b(?:i(?:'ll| will| need to| should| must| have to)|let me|we(?:'ll| will))\b[^.!?\n]{0,120}:\s*$/im
  ]

  # Phrases that mark a complete answer even when they appear next to a
  # planning phrase, e.g. "Let me know if you want me to implement it."
  @completion_patterns [
    ~r/\blet me know\b/i,
    ~r/\b(?:summary|in summary|to summarize|overall|conclusion|in conclusion)\b/i,
    ~r/\b(?:done|complete|completed|finished|implemented|applied|added|created|updated|fixed)\b\s*(?:[.!]|successfully)/i,
    ~r/\b(?:all|the) (?:tests?|checks?|changes?) (?:pass|passed|are in place|were applied)/i,
    ~r/\b(?:what would you like|would you like me to|shall i|should i|do you want me to|any questions|anything else)\b/i
  ]

  @max_intent_chars 4_000

  @doc """
  Detects whether the sequence of tool calls in the current turn exhibits a repeating cycle.

  Tests for periodic cycles of period length `1..max_period` (default up to 4).
  - Period 1 non-repeatable tools: triggers after 2 consecutive identical calls.
  - Period 1 repeatable tools (e.g. bash probes): allows up to 2 calls, triggers on 3.
  - Period >= 2 (e.g. A -> B -> A -> B): triggers after 2 complete repetitions (>= 4 calls).

  `job_status` is intentionally NOT repeatable: waiting on a background job with
  the same `job_id` yields no new information (the job notifies the session on
  completion), so two identical `job_status` calls in a row are already a loop.

  Returns `{:loop, %{period: p, count: c, cycle: pattern, waiting?: boolean}}`
  or `:ok`. `waiting?` is true when the cycle contains a pure-waiting probe
  (`job_status`), which callers use to pick a more specific loop notice.
  """
  def detect_tool_loop(messages, new_tool_calls, opts \\ [])

  def detect_tool_loop(messages, new_tool_calls, opts)
      when is_list(messages) and is_list(new_tool_calls) and new_tool_calls != [] do
    max_period = Keyword.get(opts, :max_period, 4)
    repeatable_tools = Keyword.get(opts, :repeatable_tools, @repeatable_tools)
    non_cycling_tools = Keyword.get(opts, :non_cycling_tools, @non_cycling_tools)

    history_steps = extract_turn_tool_steps(messages)
    current_step = normalize_tool_calls(new_tool_calls)

    if current_step == [] do
      :ok
    else
      full_sequence = history_steps ++ [current_step]
      check_cycles(full_sequence, max_period, repeatable_tools, non_cycling_tools)
    end
  end

  def detect_tool_loop(_messages, _new_tool_calls, _opts), do: :ok

  @doc """
  Returns the default list of tools whose identical repetition is tolerated
  (they observe changing external state), i.e. the tools that get a period-1
  threshold of 3 instead of 2.
  """
  @spec repeatable_tools() :: [String.t()]
  def repeatable_tools, do: @repeatable_tools

  @doc """
  Returns the default list of tools that must never appear in a detected
  cycle (pure-waiting probes such as `job_status`).
  """
  @spec non_cycling_tools() :: [String.t()]
  def non_cycling_tools, do: @non_cycling_tools

  @doc "Detects whether the exact same tool calls with identical arguments were executed in the previous turn or form a repeating cycle."
  def duplicate_tool_calls?(messages, new_tool_calls, opts \\ []) do
    case detect_tool_loop(messages, new_tool_calls, opts) do
      {:loop, _} -> true
      :ok -> false
    end
  end

  @doc """
  Detects a response that announces the next action instead of performing it.

  A turn that ends with a tool-free assistant message is only complete if the
  message is an answer. Models -- small local ones in particular -- instead
  emit a plan ("Let me implement the `addArticle()` method now") and stop,
  leaving the requested work undone. `narrates_intent?/1` recognizes that
  shape so the caller can ask the model to continue rather than handing an
  unfinished turn back to the user.

  Returns `true` when the content contains a first-person planning phrase and
  no completion marker, and is short enough to be an announcement rather than
  a report. Pure reasoning preambles, empty content, and long explanations
  return `false`.
  """
  @spec narrates_intent?(term()) :: boolean()
  def narrates_intent?(content) when is_binary(content) do
    text = String.trim(content)

    text != "" and String.length(text) <= @max_intent_chars and
      not Enum.any?(@completion_patterns, &Regex.match?(&1, text)) and
      Enum.any?(@intent_patterns, &Regex.match?(&1, text))
  end

  def narrates_intent?(_), do: false

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

  @doc "Decodes the outer argument JSON while preserving exact nested values."
  def normalize_arguments(args) when is_binary(args) do
    case Yoke.Json.decode(args) do
      {:ok, decoded} -> normalize_argument_value(decoded)
      _ -> String.trim(args)
    end
  end

  def normalize_arguments(args), do: normalize_argument_value(args)

  # Strings inside an already decoded argument object are tool input, not
  # another JSON envelope. Whitespace, JSON-looking source and scalar types
  # matter to edits; maps must also stay distinct from arrays.
  defp normalize_argument_value(args) when is_map(args) do
    Map.new(args, fn {k, v} -> {to_string(k), normalize_argument_value(v)} end)
  end

  defp normalize_argument_value(args) when is_list(args) do
    Enum.map(args, &normalize_argument_value/1)
  end

  defp normalize_argument_value(args), do: args

  @doc "Whether the model's next response is answering an outstanding loop warning."
  def loop_warning_pending?(messages) when is_list(messages) do
    case List.last(messages) do
      msg when is_map(msg) ->
        role = Map.get(msg, "role") || Map.get(msg, :role)
        content = Map.get(msg, "content") || Map.get(msg, :content)

        role == "user" and is_binary(content) and
          String.starts_with?(content, "SYSTEM NOTICE: Repetitive tool loop detected")

      _ ->
        false
    end
  end

  def loop_warning_pending?(_), do: false

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

  defp format_args_for_display(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {k, v} when is_binary(v) ->
        short_v = if String.length(v) > 80, do: String.slice(v, 0, 77) <> "...", else: v
        "#{k}: #{inspect(short_v)}"

      {k, v} ->
        "#{k}: #{inspect(v)}"
    end)
  end

  defp format_args_for_display(args), do: inspect(args)

  defp check_cycles(sequence, max_period, repeatable_tools, non_cycling_tools) do
    seq_len = length(sequence)

    Enum.find_value(1..max_period, :ok, fn period ->
      if seq_len >= period do
        candidate_cycle = Enum.slice(sequence, (seq_len - period)..(seq_len - 1))
        repeats = count_cycle_repeats(sequence, candidate_cycle, period)
        threshold = repetition_threshold(candidate_cycle, period, repeatable_tools)

        if repeats >= threshold do
          {:loop,
           %{
             period: period,
             count: repeats,
             cycle: candidate_cycle,
             waiting?: cycle_contains?(candidate_cycle, non_cycling_tools)
           }}
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

  defp cycle_contains?(cycle, tool_names) do
    Enum.any?(cycle, fn step ->
      Enum.any?(step, fn {name, _args} -> name in tool_names end)
    end)
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

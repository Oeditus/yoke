defmodule Yoke.Brain.ContextCompressor do
  @moduledoc """
  Handles context compression (/compact) for agent sessions to free up context window space.
  Sends conversation history to DeepSeek to generate a condensed summary preserving key facts,
  and provides deterministic local compaction when the context already exceeds the remote
  model's limit.
  """

  alias Yoke.Brain.MessageRepair
  alias Yoke.Client.DeepSeekAPI

  @context_error_markers [
    "maximum context length",
    "context_length_exceeded",
    "context length exceeded",
    "exceeds the available context size",
    "exceeds the context",
    "prompt is too long",
    "input is too long",
    "too many tokens",
    "reduce the length of the messages"
  ]

  @doc "Returns true when an API error message indicates the request exceeded the model's context window."
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?(reason) when is_binary(reason) do
    downcased = String.downcase(reason)
    Enum.any?(@context_error_markers, &String.contains?(downcased, &1))
  end

  def context_length_error?(_), do: false

  @doc """
  Computes a conservative local token target from a provider context-limit error message.

  When the error reports both the model's maximum context length and the requested
  token count, scales the current local token estimate proportionally with headroom;
  otherwise targets a fraction of the current local estimate.
  """
  @spec target_tokens_from_error(term(), [map()], keyword()) :: pos_integer()
  def target_tokens_from_error(reason, messages, opts \\ []) do
    local_tokens = estimate_tokens(messages)
    attempt = Keyword.get(opts, :attempt, 0)
    # Shrink more aggressively on subsequent attempts in case the remote tokenizer
    # is denser than our chars/4 estimate or tools consume significant overhead.
    fallback_factor = if attempt > 0, do: 0.35, else: 0.60
    fallback_target = max(trunc(local_tokens * fallback_factor), 512)

    case parse_token_limits(reason) do
      {max_ctx, requested} when max_ctx > 0 and requested > 0 ->
        ratio = min(max_ctx / requested, 1.0)
        headroom = if attempt > 0, do: 0.45, else: 0.70
        scaled = trunc(local_tokens * ratio * headroom)
        max(min(scaled, fallback_target), 512)

      _ ->
        fallback_target
    end
  end

  @doc "Compresses session message history into a summary block."
  def compress_messages(messages, opts \\ []) do
    non_system = Enum.filter(messages, fn m -> role_of(m) != "system" end)

    if Enum.empty?(non_system) do
      {:ok, messages, "No history to compress."}
    else
      summary_prompt = [
        %{
          "role" => "system",
          "content" =>
            "You are an expert technical summarizer. Compress the provided conversation history into a structured summary preserving: 1. Core user goal & requirements. 2. Code files modified/inspected. 3. Decisions made. 4. Current state and next steps. Keep it highly concise."
        },
        %{
          "role" => "user",
          "content" => "Conversation History to Compress:\n" <> format_history(non_system)
        }
      ]

      case DeepSeekAPI.chat_completion(summary_prompt, [], opts) do
        {:ok, %{content: summary}} when is_binary(summary) ->
          system_msgs = Enum.filter(messages, fn m -> role_of(m) == "system" end)

          compressed_block = %{
            "role" => "system",
            "content" =>
              "=== Compressed Conversation Context ===\n#{summary}\n======================================"
          }

          new_messages = system_msgs ++ [compressed_block]
          {:ok, new_messages, summary}

        {:error, reason} ->
          if context_length_error?(reason) do
            target = target_tokens_from_error(reason, messages)
            compress_locally(messages, target_tokens: target)
          else
            {:error, "Compression failed: #{reason}"}
          end
      end
    end
  end

  @doc """
  Deterministically compacts `messages` locally without calling a remote model.

  Deduplicates superseded file reads, preserves system messages and the most recent
  user turn with intact tool-call/result pairs, summarizes older turns, and uses
  AST/code-aware skeletonization before falling back to line/head-tail truncation.
  """
  @spec compress_locally([map()], keyword()) :: {:ok, [map()], String.t()}
  def compress_locally(messages, opts \\ []) when is_list(messages) do
    {system_msgs, non_system} = Enum.split_with(messages, &(role_of(&1) == "system"))

    if Enum.empty?(non_system) do
      {:ok, messages, "No history to compress."}
    else
      before_tokens = estimate_tokens(messages)
      default_target = max(div(before_tokens, 2), 512)
      target_tokens = Keyword.get(opts, :target_tokens, default_target)

      deduped_non_system = deduplicate_tool_reads(non_system)
      units = group_into_turns(deduped_non_system)
      system_tokens = estimate_tokens(system_msgs)
      tail_budget = max(trunc((target_tokens - system_tokens) * 0.65), 256)

      {dropped_units, kept_units} = split_tail_units(units, tail_budget)
      dropped_msgs = List.flatten(dropped_units)
      kept_msgs = List.flatten(kept_units)

      summary_msgs =
        if dropped_msgs == [] do
          []
        else
          [build_local_summary_block(dropped_msgs)]
        end

      {final_non_system, truncated_count} =
        fit_within_budget(
          summary_msgs ++ kept_msgs,
          max(target_tokens - system_tokens, 256)
        )

      final_messages =
        (system_msgs ++ final_non_system)
        |> MessageRepair.repair()

      after_tokens = estimate_tokens(final_messages)

      summary =
        "Locally compacted context (#{length(dropped_msgs)} older message(s) summarized, " <>
          "#{truncated_count} oversized message(s) compacted; est. #{before_tokens} -> #{after_tokens} tokens)."

      {:ok, final_messages, summary}
    end
  end

  @doc """
  Builds a rolling compacted snapshot map suitable for persisting alongside the
  full conversation in `.lmml` (e.g. `@@@compacted_context.json@@@`).
  """
  @spec build_compacted_snapshot([map()], keyword()) :: map() | nil
  def build_compacted_snapshot(messages, opts \\ []) when is_list(messages) do
    non_system = Enum.reject(messages, &(role_of(&1) == "system"))

    if length(non_system) < 2 do
      nil
    else
      before_tokens = estimate_tokens(messages)
      target = Keyword.get(opts, :target_tokens, max(div(before_tokens, 2), 1024))
      {:ok, compacted_messages, summary} = compress_locally(messages, target_tokens: target)

      %{
        "messages" => compacted_messages,
        "summary" => summary,
        "estimated_tokens" => estimate_tokens(compacted_messages),
        "source_message_count" => length(messages),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end
  end

  @doc "Estimates token count for a message list (~4 chars per JSON token)."
  @spec estimate_tokens([map()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    payload = Yoke.Json.encode!(messages)
    div(String.length(payload) + 3, 4)
  end

  defp parse_token_limits(reason) when is_binary(reason) do
    max_match = Regex.run(~r/maximum context length is (\d+)\s+tokens/i, reason)
    req_match = Regex.run(~r/requested (\d+)\s+tokens/i, reason)

    case {max_match, req_match} do
      {[_, max_str], [_, req_str]} ->
        {String.to_integer(max_str), String.to_integer(req_str)}

      {[_, max_str], nil} ->
        {String.to_integer(max_str), String.to_integer(max_str)}

      _ ->
        nil
    end
  end

  defp parse_token_limits(_), do: nil

  # Groups non-system messages into user turns (a user message plus all
  # following assistant/tool messages until the next user message) so the
  # latest user prompt is always preserved alongside its active tool calls.
  defp group_into_turns(messages) do
    {turns, current} =
      Enum.reduce(messages, {[], []}, fn msg, {acc, cur} ->
        if role_of(msg) == "user" and cur != [] do
          {acc ++ [cur], [msg]}
        else
          {acc, cur ++ [msg]}
        end
      end)

    if current == [], do: turns, else: turns ++ [current]
  end

  # Groups non-system messages into atomic tool-call units so an assistant message
  # with tool_calls is never separated from its matching tool responses.
  defp group_into_units(messages) do
    {units, current} =
      Enum.reduce(messages, {[], []}, fn msg, {acc, cur} ->
        role = role_of(msg)

        cond do
          role == "tool" and cur != [] ->
            {acc, cur ++ [msg]}

          role == "assistant" and has_tool_calls?(msg) ->
            acc = if cur == [], do: acc, else: acc ++ [cur]
            {acc, [msg]}

          true ->
            acc = if cur == [], do: acc, else: acc ++ [cur]
            {acc ++ [[msg]], []}
        end
      end)

    if current == [], do: units, else: units ++ [current]
  end

  # Keeps at least the most recent turn, plus as many preceding turns as fit
  # within `tail_budget` tokens. Both returned lists are in chronological order.
  defp split_tail_units(units, tail_budget) do
    case Enum.reverse(units) do
      [] ->
        {[], []}

      [latest | rest] ->
        latest_tokens = estimate_tokens(latest)

        {kept_rev, dropped_chrono, _used} =
          Enum.reduce(rest, {[latest], [], latest_tokens}, fn unit, {kept, dropped, used} ->
            if dropped != [] do
              {kept, [unit | dropped], used}
            else
              unit_tokens = estimate_tokens(unit)

              if used + unit_tokens <= tail_budget do
                {[unit | kept], dropped, used + unit_tokens}
              else
                {kept, [unit | dropped], used}
              end
            end
          end)

        {dropped_chrono, kept_rev}
    end
  end

  defp build_local_summary_block(dropped_msgs) do
    bullets =
      dropped_msgs
      |> Enum.map(&summarize_single_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(-25)
      |> Enum.join("\n")
      |> truncate_text(3500)

    content =
      "=== Locally Compressed Conversation Context ===\n" <>
        "#{length(dropped_msgs)} older message(s) were compacted locally to fit the model's context limit.\n" <>
        bullets <>
        "\n=============================================="

    %{"role" => "system", "content" => content}
  end

  defp summarize_single_message(msg) do
    role = role_of(msg)
    text = msg |> Map.get("content", "") |> message_content_text() |> String.trim()

    cond do
      role == "user" and text != "" ->
        "- [USER] #{truncate_single_line(text, 200)}"

      role == "assistant" and has_tool_calls?(msg) ->
        names =
          msg
          |> Map.get("tool_calls", [])
          |> Enum.map_join(", ", fn tc ->
            get_in(tc, ["function", "name"]) || Map.get(tc, "name") || "tool"
          end)

        "- [ASSISTANT tools: #{names}] #{truncate_single_line(text, 120)}"

      role == "assistant" and text != "" ->
        "- [ASSISTANT] #{truncate_single_line(text, 200)}"

      role == "tool" ->
        name = Map.get(msg, "name") || "tool"
        "- [TOOL #{name}] #{truncate_single_line(text, 100)}"

      true ->
        nil
    end
  end

  defp fit_within_budget(msgs, budget_tokens) do
    if estimate_tokens(msgs) <= budget_tokens do
      {msgs, 0}
    else
      # Pass 1: truncate oversized tool outputs and long older messages.
      {trimmed, count1} = truncate_oversized_messages(msgs, budget_tokens)

      if estimate_tokens(trimmed) <= budget_tokens do
        {trimmed, count1}
      else
        # Pass 2: drop older non-last units, then aggressively truncate remaining content.
        units = group_into_units(trimmed)

        reduced =
          case units do
            [] -> []
            _ -> List.last(units)
          end

        if estimate_tokens(reduced) <= budget_tokens do
          {reduced, count1}
        else
          truncate_to_budget(reduced, budget_tokens, count1)
        end
      end
    end
  end

  defp truncate_oversized_messages(msgs, budget_tokens) do
    max_chars_per_msg = max(div(budget_tokens * 4, max(length(msgs), 1)), 400)

    Enum.map_reduce(msgs, 0, fn msg, count ->
      content = Map.get(msg, "content")

      if is_binary(content) and String.length(content) > max_chars_per_msg do
        {Map.put(msg, "content", truncate_smart(content, max_chars_per_msg)), count + 1}
      else
        {msg, count}
      end
    end)
  end

  defp truncate_to_budget(msgs, budget_tokens, base_count) do
    # Iteratively halve per-message char limit until under budget or at minimum floor.
    Enum.reduce_while([2000, 1000, 400, 150], {msgs, base_count}, fn cap, {cur, cnt} ->
      if estimate_tokens(cur) <= budget_tokens do
        {:halt, {cur, cnt}}
      else
        {next, added} =
          Enum.map_reduce(cur, 0, fn msg, acc ->
            content = Map.get(msg, "content")

            if is_binary(content) and String.length(content) > cap do
              {Map.put(msg, "content", truncate_smart(content, cap)), acc + 1}
            else
              {msg, acc}
            end
          end)

        {:cont, {next, cnt + added}}
      end
    end)
  end

  # Deduplicates superseded file-read tool results so earlier reads of a path
  # that was later re-read or modified don't bloat the compacted context.
  @read_tools ~w(read_file mcp_ragex_view)
  @write_tools ~w(edit_file write_file replace_file mcp_ragex_edit_file mcp_ragex_edit_files)

  defp deduplicate_tool_reads(messages) do
    # Map tool_call_id -> {:read | :write, path}
    call_meta =
      Enum.reduce(messages, %{}, fn msg, acc ->
        if role_of(msg) == "assistant" and has_tool_calls?(msg) do
          Enum.reduce(Map.get(msg, "tool_calls", []), acc, fn tc, inner ->
            id = Map.get(tc, "id") || Map.get(tc, :id)
            name = get_in(tc, ["function", "name"]) || Map.get(tc, "name")

            args =
              parse_tool_args(get_in(tc, ["function", "arguments"]) || Map.get(tc, "arguments"))

            path = Map.get(args, "path") || Map.get(args, "file") || Map.get(args, "Path")

            cond do
              is_binary(id) and is_binary(path) and name in @read_tools ->
                Map.put(inner, id, {:read, path})

              is_binary(id) and is_binary(path) and name in @write_tools ->
                Map.put(inner, id, {:write, path})

              true ->
                inner
            end
          end)
        else
          acc
        end
      end)

    # Find the latest message index where each path is touched.
    latest_by_path =
      messages
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {msg, idx}, acc ->
        if role_of(msg) == "tool" do
          call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id)

          case Map.get(call_meta, call_id) do
            {_, path} -> Map.put(acc, path, idx)
            nil -> acc
          end
        else
          acc
        end
      end)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, idx} ->
      if role_of(msg) == "tool" do
        call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id)

        case Map.get(call_meta, call_id) do
          {:read, path} ->
            if Map.get(latest_by_path, path) > idx do
              Map.put(
                msg,
                "content",
                "[Superseded: #{path} was read or modified again later in the conversation]"
              )
            else
              msg
            end

          _ ->
            msg
        end
      else
        msg
      end
    end)
  end

  defp parse_tool_args(args) when is_map(args), do: args

  defp parse_tool_args(args) when is_binary(args) do
    case Yoke.Json.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_tool_args(_), do: %{}

  @doc """
  Compacts `text` to at most `max_chars` using Elixir AST skeletonization or
  structural code outlining when applicable, falling back to line-aware head/tail
  truncation.
  """
  @spec truncate_smart(String.t(), pos_integer()) :: String.t()
  def truncate_smart(text, max_chars) when is_binary(text) do
    if String.length(text) <= max_chars do
      text
    else
      case skeletonize_elixir_ast(text) do
        {:ok, skeleton} when byte_size(skeleton) > 0 ->
          if String.length(skeleton) <= max_chars do
            skeleton
          else
            truncate_head_tail(skeleton, max_chars)
          end

        :error ->
          if looks_like_code?(text) do
            outline = extract_code_outline(text)

            if String.length(outline) > 0 and String.length(outline) < String.length(text) do
              if String.length(outline) <= max_chars do
                outline
              else
                truncate_head_tail(outline, max_chars)
              end
            else
              truncate_head_tail(text, max_chars)
            end
          else
            truncate_head_tail(text, max_chars)
          end
      end
    end
  end

  @doc """
  Parses Elixir source with `Code.string_to_quoted/2` and collapses function/macro
  bodies into signature skeletons while preserving modules, attributes, specs,
  structs, and aliases.
  """
  @spec skeletonize_elixir_ast(String.t()) :: {:ok, String.t()} | :error
  def skeletonize_elixir_ast(text) when is_binary(text) do
    case Code.string_to_quoted(text, columns: true, token_metadata: true) do
      {:ok, ast} ->
        lines = collect_elixir_skeleton(ast, 0) |> List.flatten()

        if lines == [] do
          :error
        else
          {:ok, Enum.join(lines, "\n")}
        end

      {:error, _} ->
        :error
    end
  end

  defp collect_elixir_skeleton({:__block__, _, nodes}, indent) do
    Enum.map(nodes, &collect_elixir_skeleton(&1, indent))
  end

  defp collect_elixir_skeleton({:defmodule, meta, [alias_ast, [do: body]]}, indent) do
    pad = String.duplicate("  ", indent)
    mod_name = Macro.to_string(alias_ast)
    line_info = format_line_comment(meta)
    inner = collect_elixir_skeleton(body, indent + 1)

    [
      "#{pad}defmodule #{mod_name} do#{line_info}",
      inner,
      "#{pad}end"
    ]
  end

  defp collect_elixir_skeleton({kind, meta, [head, body]}, indent)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    pad = String.duplicate("  ", indent)
    sig = Macro.to_string(head)
    span = body_line_span(meta, body)
    ["#{pad}#{kind} #{sig} # [body omitted#{span}]"]
  end

  defp collect_elixir_skeleton({kind, meta, [head]}, indent)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    pad = String.duplicate("  ", indent)
    ["#{pad}#{kind} #{Macro.to_string(head)}#{format_line_comment(meta)}"]
  end

  defp collect_elixir_skeleton({kind, _meta, _args} = node, indent)
       when kind in [:alias, :use, :import, :require, :defstruct] do
    pad = String.duplicate("  ", indent)
    ["#{pad}#{Macro.to_string(node)}"]
  end

  defp collect_elixir_skeleton({:@, _meta, [{attr, _, [val]}]}, indent)
       when attr in [:spec, :type, :typep, :callback] do
    pad = String.duplicate("  ", indent)
    ["#{pad}@#{attr} #{Macro.to_string(val)}"]
  end

  defp collect_elixir_skeleton({:@, _meta, [{attr, _, [doc]}]}, indent)
       when attr in [:moduledoc, :doc] and is_binary(doc) do
    pad = String.duplicate("  ", indent)
    ["#{pad}@#{attr} #{inspect(truncate_single_line(doc, 100))}"]
  end

  defp collect_elixir_skeleton(_, _indent), do: []

  defp format_line_comment(meta) do
    case Keyword.get(meta, :line) do
      line when is_integer(line) -> " # line #{line}"
      _ -> ""
    end
  end

  defp body_line_span(meta, body) do
    start_line = Keyword.get(meta, :line)

    end_line =
      case body do
        [do: {:__block__, bmeta, _}] -> Keyword.get(bmeta, :closing) |> then(&(&1 && &1[:line]))
        _ -> Keyword.get(meta, :end_of_expression, [])[:line]
      end

    cond do
      is_integer(start_line) and is_integer(end_line) and end_line >= start_line ->
        ", lines #{start_line}..#{end_line}"

      is_integer(start_line) ->
        ", line #{start_line}"

      true ->
        ""
    end
  end

  defp looks_like_code?(text) do
    Regex.match?(
      ~r/^\s*(def |defp |defmodule |class |struct |interface |function |func |fn |pub fn |export |import )/m,
      text
    )
  end

  defp extract_code_outline(text) do
    decl_regex =
      ~r/^\s*(defmodule|defmacro|defp|def|class|struct|interface|enum|type|impl|pub\s+fn|fn|func|function|export\s+(?:default\s+)?(?:function|class|const|interface)|import|from\s+\S+\s+import)\b/

    lines = String.split(text, "\n")

    {kept_rev, omitted?} =
      Enum.reduce(lines, {[], false}, fn line, {acc, was_omitted} ->
        if Regex.match?(decl_regex, line) do
          acc = if was_omitted, do: ["  # ... [body omitted] ..." | acc], else: acc
          {[line | acc], false}
        else
          {acc, true}
        end
      end)

    kept =
      if omitted? do
        Enum.reverse(["  # ... [omitted] ..." | kept_rev])
      else
        Enum.reverse(kept_rev)
      end

    Enum.join(kept, "\n")
  end

  defp truncate_head_tail(text, max_chars) when max_chars >= 80 do
    marker = "\n... [truncated locally to fit context limit] ...\n"
    keep = max_chars - String.length(marker)
    head_len = div(keep * 2, 3)
    tail_len = max(keep - head_len, 0)
    head = String.slice(text, 0, head_len)
    tail = if tail_len > 0, do: String.slice(text, -tail_len, tail_len), else: ""
    head <> marker <> tail
  end

  defp truncate_head_tail(text, max_chars), do: String.slice(text, 0, max_chars)

  defp truncate_single_line(text, max_chars) do
    text
    |> String.replace(~r/\s+/, " ")
    |> truncate_text(max_chars)
  end

  defp truncate_text(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      String.slice(text, 0, max_chars) <> "..."
    end
  end

  defp role_of(msg), do: Map.get(msg, "role") || Map.get(msg, :role)

  defp has_tool_calls?(msg) do
    calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)
    is_list(calls) and calls != []
  end

  defp format_history(messages) do
    Enum.map_join(messages, "\n\n", fn m ->
      role = String.upcase(m["role"] || "UNKNOWN")
      content = message_content_text(m["content"])
      "[#{role}]: #{content}"
    end)
  end

  defp message_content_text(content) when is_binary(content), do: content

  defp message_content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp message_content_text(_), do: ""
end

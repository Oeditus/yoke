defmodule Yoke.ExternalCall do
  @moduledoc """
  Standardized wrapper for external third-party service calls (LLMs, MCP servers, HTTP fetches).
  Measures duration, logs telemetry, and classifies errors into `:timeout`, `:transport`, or `:error`.
  """
  require Logger

  @type error_classification :: :timeout | :transport | :error

  @doc """
  Executes an external call `fun`, recording telemetry and error classification.

  ## Parameters
    - `service`: atom or string identifying the external service (e.g. `:deepseek_api`, `:mcp_server`, `:http_fetch`)
    - `meta`: key-value metadata map or keyword list (e.g. `[endpoint: ..., model: ...]`)
    - `fun`: 0-arity function performing the actual call
  """
  def run(service, meta, fun, _opts \\ []) when is_function(fun, 0) do
    meta_map = Map.new(meta)
    start_time = System.monotonic_time(:millisecond)

    try do
      case fun.() do
        {:ok, result} = ok_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          log_success(service, meta_map, duration_ms, result)
          emit_telemetry(service, :ok, duration_ms, meta_map)
          ok_res

        {:error, reason} = err_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          classification = classify_error(reason)
          log_failure(service, meta_map, classification, reason, duration_ms)
          emit_telemetry(service, classification, duration_ms, meta_map)
          err_res

        other_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          log_success(service, meta_map, duration_ms, other_res)
          emit_telemetry(service, :ok, duration_ms, meta_map)
          other_res
      end
    catch
      kind, reason ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        classification = classify_error(reason)
        log_failure(service, meta_map, classification, {kind, reason}, duration_ms)
        emit_telemetry(service, classification, duration_ms, meta_map)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Classifies an error payload into `:timeout`, `:transport`, or `:error`."
  def classify_error(reason) do
    case reason do
      :timeout ->
        :timeout

      %{reason: :timeout} ->
        :timeout

      {:timeout, _} ->
        :timeout

      reason_str when is_binary(reason_str) ->
        cond do
          String.contains?(
            reason_str,
            ["timeout", "timed out", "econnrefused", "connect_timeout"]
          ) ->
            :timeout

          String.contains?(
            reason_str,
            ["nxdomain", "nodedown", "unreachable", "econnreset", "closed"]
          ) ->
            :transport

          true ->
            :error
        end

      {:badrpc, :nodedown} ->
        :transport

      :econnrefused ->
        :transport

      :nxdomain ->
        :transport

      _ ->
        :error
    end
  end

  @doc """
  Summarizes an LLM/external service response payload into a concise, single-line text summary.
  Handles tool call lists, text/markdown responses, reasoning content, and raw strings.
  """
  def summarize_response(nil), do: ""
  def summarize_response(""), do: ""

  def summarize_response({:ok, inner}), do: summarize_response(inner)

  def summarize_response(%{choices: [first | _]}) do
    msg = Map.get(first, :message) || Map.get(first, "message") || first
    summarize_response(msg)
  end

  def summarize_response(%{"choices" => [first | _]}) do
    msg = Map.get(first, "message") || Map.get(first, :message) || first
    summarize_response(msg)
  end

  def summarize_response(%{} = map) do
    tool_calls = Map.get(map, :tool_calls) || Map.get(map, "tool_calls")

    tool_summary =
      if is_list(tool_calls) and tool_calls != [] do
        summarize_tool_calls(tool_calls)
      else
        ""
      end

    if tool_summary != "" do
      tool_summary
    else
      content =
        Enum.find_value(
          [
            Map.get(map, :content),
            Map.get(map, "content"),
            Map.get(map, :text),
            Map.get(map, "text"),
            Map.get(map, :reasoning_content),
            Map.get(map, "reasoning_content")
          ],
          "",
          fn
            nil -> false
            "" -> false
            val when is_binary(val) -> val
            _ -> false
          end
        )

      if is_binary(content) and content != "" do
        summarize_text(content)
      else
        ""
      end
    end
  end

  def summarize_response(text) when is_binary(text) do
    summarize_text(text)
  end

  def summarize_response(_), do: ""

  @doc """
  Summarizes free-form text or markdown into a single trimmed line with markdown artifacts removed.
  """
  def summarize_text(text, max_len \\ 60)

  def summarize_text(text, max_len) when is_binary(text) do
    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> Enum.map(fn line ->
        line
        |> String.replace(~r/^#+\s*/, "")
        |> String.replace(~r/^>\s*/, "")
        |> String.replace(~r/^[-*+]\s+/, "")
        |> String.replace(~r/^\d+\.\s+/, "")
        |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    joined =
      case lines do
        [] ->
          text
          |> String.replace(~r/[\r\n\t]+/, " ")
          |> String.trim()

        _ ->
          Enum.join(lines, " ")
      end

    cleaned =
      joined
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(cleaned) > max_len do
      String.slice(cleaned, 0, max_len - 1) <> "…"
    else
      cleaned
    end
  end

  def summarize_text(_, _), do: ""

  defp summarize_tool_calls(tool_calls) when is_list(tool_calls) do
    calls =
      tool_calls
      |> Enum.map(&extract_tool_call/1)
      |> Enum.reject(&is_nil/1)

    formatted =
      case calls do
        [] ->
          ""

        [single] ->
          format_tool_call_summary(single)

        [first, second] ->
          "#{format_tool_call_summary(first)}, #{format_tool_call_summary(second)}"

        [first, second | rest] ->
          "#{format_tool_call_summary(first)}, #{format_tool_call_summary(second)} (+#{length(rest)})"
      end

    if String.length(formatted) > 70 do
      String.slice(formatted, 0, 69) <> "…"
    else
      formatted
    end
  end

  defp extract_tool_call(%{name: name} = tc) when not is_nil(name) do
    {to_string(name), normalize_args(Map.get(tc, :arguments) || Map.get(tc, "arguments"))}
  end

  defp extract_tool_call(%{"name" => name} = tc) when not is_nil(name) do
    {to_string(name), normalize_args(Map.get(tc, "arguments") || Map.get(tc, :arguments))}
  end

  defp extract_tool_call(%{function: %{name: name} = f}) when not is_nil(name) do
    {to_string(name), normalize_args(Map.get(f, :arguments) || Map.get(f, "arguments"))}
  end

  defp extract_tool_call(%{"function" => %{"name" => name} = f}) when not is_nil(name) do
    {to_string(name), normalize_args(Map.get(f, "arguments") || Map.get(f, :arguments))}
  end

  defp extract_tool_call(tc) when is_binary(tc), do: {tc, %{}}
  defp extract_tool_call(_), do: nil

  defp normalize_args(args) when is_map(args), do: args

  defp normalize_args(args) when is_binary(args) do
    case Yoke.Json.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_args(_), do: %{}

  defp format_tool_call_summary({name, args}) when is_map(args) do
    target =
      get_arg_value(args, [
        "target_file",
        :target_file,
        "path",
        :path,
        "TargetFile",
        "file",
        :file,
        "filepath",
        :filepath,
        "AbsolutePath",
        "command",
        :command,
        "cmd",
        :cmd,
        "CommandLine",
        "query",
        :query,
        "pattern",
        :pattern,
        "code",
        :code,
        "url",
        :url,
        "question",
        :question,
        "prompt",
        :prompt
      ])

    target =
      cond do
        target != "" ->
          target

        is_list(args["paths"]) or is_list(args[:paths]) ->
          paths = args["paths"] || args[:paths]

          case paths do
            [] -> ""
            [single] -> to_string(single)
            [first | rest] -> "#{first} (+#{length(rest)})"
          end

        is_list(args["files"]) or is_list(args[:files]) ->
          files = args["files"] || args[:files]

          case files do
            [] -> ""
            [%{"path" => p}] -> to_string(p)
            [%{path: p}] -> to_string(p)
            [%{"path" => p} | rest] -> "#{p} (+#{length(rest)})"
            [%{path: p} | rest] -> "#{p} (+#{length(rest)})"
            _ -> "#{length(files)} files"
          end

        true ->
          ""
      end

    cleaned =
      target
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.trim()

    truncated =
      if String.length(cleaned) > 25 do
        String.slice(cleaned, 0, 22) <> "..."
      else
        cleaned
      end

    if truncated != "" do
      "#{name}(\"#{truncated}\")"
    else
      "#{name}()"
    end
  end

  defp format_tool_call_summary({name, _}), do: "#{name}()"
  defp format_tool_call_summary(name) when is_binary(name), do: "#{name}()"

  defp get_arg_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, "", fn k ->
      case Map.get(map, k) do
        nil -> nil
        "" -> nil
        val when is_binary(val) -> val
        val when is_number(val) or is_atom(val) -> to_string(val)
        _ -> nil
      end
    end)
  end

  defp log_success(service, meta, duration_ms, result) do
    model = get_meta_field(meta, :model)
    target = if model, do: "#{model}", else: "#{service}"
    badge = Yoke.CLI.Formatter.magenta() <> "⟡ API   " <> Yoke.CLI.Formatter.reset()
    summary = summarize_response(result)

    msg =
      if summary != "" do
        "#{badge} #{target} (#{duration_ms}ms) #{summary}"
      else
        "#{badge} #{target} (#{duration_ms}ms)"
      end

    Logger.debug(msg)
  end

  defp log_failure(service, meta, classification, reason, duration_ms) do
    model = get_meta_field(meta, :model)
    target = if model, do: "#{model}", else: "#{service}"
    badge = Yoke.CLI.Formatter.magenta() <> "⟡ API   " <> Yoke.CLI.Formatter.reset()
    clean_reason = if is_binary(reason), do: reason, else: inspect(reason)

    msg =
      "#{badge} #{target} failed (#{classification}, #{duration_ms}ms): #{clean_reason}"

    case classification do
      :timeout -> Logger.warning(msg)
      :transport -> Logger.warning(msg)
      :error -> Logger.error(msg)
    end
  end

  defp get_meta_field(%{} = meta, key) do
    Map.get(meta, key) || Map.get(meta, to_string(key))
  end

  defp emit_telemetry(service, status, duration_ms, meta) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(
        [:yoke, :external_call, service],
        %{duration_ms: duration_ms},
        Map.merge(meta, %{status: status})
      )
    end
  rescue
    _ -> :ok
  end
end

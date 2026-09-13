defmodule Yoke.Client.DeepSeekAPI do
  @moduledoc """
  Client interface for DeepSeek API (deepseek-chat V3 and deepseek-reasoner R1).
  Handles message serialization, tool declarations, reasoning extraction (R1),
  real token usage tracking, SSE response streaming, and mock execution mode.
  """
  require Logger

  @default_endpoint "https://api.deepseek.com/chat/completions"
  @default_model "deepseek-chat"

  defmodule ClientConfig do
    @moduledoc "Configuration parameters for DeepSeek API requests."
    defstruct model: "deepseek-chat",
              api_key: nil,
              endpoint: "https://api.deepseek.com/chat/completions",
              temperature: 0.7,
              # Optional per-request cap on generated completion tokens
              # (sent as `max_tokens`). `nil` omits the field so the
              # provider's own default applies.
              max_tokens: nil,
              stream: false,
              stream_fun: nil,
              mock: false
  end

  @doc """
  Sends a chat completion request to DeepSeek API or mock handler.
  """
  def chat_completion(messages, tools, opts \\ []) do
    config = build_config(opts)
    _input_verdict = Yoke.AIGuard.guard_llm(messages, :input, target: config.model)

    res =
      Yoke.ExternalCall.run(:deepseek_api, [endpoint: config.endpoint, model: config.model], fn ->
        if ((is_nil(config.api_key) or config.api_key == "") and
              not local_endpoint?(config.endpoint)) or
             config.mock == true do
          mock_response(messages, tools, config.model)
        else
          real_chat_completion(messages, tools, config)
        end
      end)

    case res do
      {:ok, choice} = ok_res ->
        _output_verdict = Yoke.AIGuard.guard_llm(inspect(choice), :output, target: config.model)
        ok_res

      other ->
        other
    end
  end

  @doc """
  Fetches the full list of available model IDs dynamically from the DeepSeek API
  (or configured OpenRouter/Ollama/custom endpoint).
  Returns `{:ok, [model_id_string, ...]}` or `{:error, reason}`.
  """
  def list_models(opts \\ []) do
    config = build_config(opts)

    if ((is_nil(config.api_key) or config.api_key == "") and not local_endpoint?(config.endpoint)) or
         config.mock == true do
      {:ok,
       ["deepseek-chat", "deepseek-reasoner", "deepseek-coder", "deepseek-v4-flash-vision-exp"]}
    else
      fetch_real_models(config)
    end
  end

  @doc "Derives the `/models` endpoint URL from a chat completions endpoint."
  def models_endpoint(endpoint) when is_binary(endpoint) do
    cond do
      String.ends_with?(endpoint, "/chat/completions") ->
        String.replace(endpoint, ~r|/chat/completions$|, "/models")

      String.ends_with?(endpoint, "/completions") ->
        String.replace(endpoint, ~r|/completions$|, "/models")

      String.ends_with?(endpoint, "/v1") ->
        endpoint <> "/models"

      true ->
        URI.merge(endpoint, "/models") |> to_string()
    end
  end

  defp fetch_real_models(%ClientConfig{} = config) do
    target_url = models_endpoint(config.endpoint)

    headers =
      if is_binary(config.api_key) and config.api_key != "" and config.api_key != "not-needed" do
        [{"Authorization", "Bearer #{config.api_key}"}, {"Accept", "application/json"}]
      else
        [{"Accept", "application/json"}]
      end

    headers =
      if String.contains?(config.endpoint, "openrouter.ai") do
        headers ++
          [
            {"HTTP-Referer", "https://github.com/yoke"},
            {"X-Title", "yoke"}
          ]
      else
        headers
      end

    req_opts = [
      headers: headers,
      receive_timeout: 10_000
    ]

    case Req.get(target_url, req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"data" => models}}} when is_list(models) ->
        model_ids =
          models
          |> Enum.map(fn
            %{"id" => id} when is_binary(id) -> id
            id when is_binary(id) -> id
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        if Enum.empty?(model_ids) do
          {:ok, ["deepseek-chat", "deepseek-reasoner"]}
        else
          {:ok, model_ids}
        end

      {:ok, %Req.Response{status: 200, body: models}} when is_list(models) ->
        model_ids =
          models
          |> Enum.map(fn
            %{"id" => id} when is_binary(id) -> id
            id when is_binary(id) -> id
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        {:ok, model_ids}

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "DeepSeek API /models returned HTTP status #{status}: #{inspect(err_body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc "Builds a structured ClientConfig struct from keyword options."
  def build_config(opts) when is_list(opts) do
    mock_default =
      cond do
        Keyword.has_key?(opts, :mock) ->
          opts[:mock]

        function_exported?(Mix, :env, 0) and Mix.env() == :test and
            System.get_env("ENABLE_REAL_API_TESTS") != "true" ->
          true

        true ->
          false
      end

    raw_endpoint =
      opts[:endpoint] ||
        System.get_env("DEEPSEEK_ENDPOINT") ||
        System.get_env("OPENROUTER_BASE_URL") ||
        System.get_env("OLLAMA_HOST") ||
        @default_endpoint

    normalized_endpoint = normalize_endpoint(raw_endpoint)

    api_key =
      cond do
        opts[:api_key] ->
          opts[:api_key]

        local_endpoint?(normalized_endpoint) ->
          "not-needed"

        true ->
          System.get_env("DEEPSEEK_API_KEY") ||
            System.get_env("OPENROUTER_API_KEY") ||
            System.get_env("LLM_API_KEY")
      end

    %ClientConfig{
      model: opts[:model] || System.get_env("DEEPSEEK_MODEL") || @default_model,
      api_key: api_key,
      endpoint: normalized_endpoint,
      temperature: opts[:temperature] || 0.7,
      max_tokens: opts[:max_tokens],
      stream: opts[:stream] || false,
      stream_fun: opts[:stream_fun],
      mock: mock_default
    }
  end

  defp real_chat_completion(messages, tools, %ClientConfig{} = config) do
    formatted_tools = format_tools(tools)

    body = %{
      "model" => config.model,
      "messages" => messages,
      "temperature" => config.temperature
    }

    # Only send `max_tokens` when explicitly configured (a positive integer),
    # so callers that don't set it keep the provider's own default behavior.
    body =
      if is_integer(config.max_tokens) and config.max_tokens > 0 do
        Map.put(body, "max_tokens", config.max_tokens)
      else
        body
      end

    body =
      if Enum.empty?(formatted_tools) do
        body
      else
        Map.put(body, "tools", formatted_tools)
      end

    headers =
      if is_binary(config.api_key) and config.api_key != "" and config.api_key != "not-needed" do
        [{"Authorization", "Bearer #{config.api_key}"}, {"Content-Type", "application/json"}]
      else
        [{"Content-Type", "application/json"}]
      end

    headers =
      if String.contains?(config.endpoint, "openrouter.ai") do
        headers ++
          [
            {"HTTP-Referer", "https://github.com/yoke"},
            {"X-Title", "yoke"}
          ]
      else
        headers
      end

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: :infinity
    ]

    post_with_retry(config.endpoint, req_opts)
  end

  defp post_with_retry(endpoint, req_opts, attempts_left \\ 3, backoff_ms \\ 500) do
    case Req.post(endpoint, req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp_body}} ->
        usage = Map.get(resp_body, "usage", %{})
        parse_choice(choice, usage)

      {:ok, %Req.Response{status: status, body: _err_body}}
      when status in [429, 500, 502, 503, 504] and attempts_left > 1 ->
        Logger.warning(
          "[DeepSeekAPI] Transient HTTP #{status} error. Retrying in #{backoff_ms}ms... (#{attempts_left - 1} attempts left)"
        )

        Process.sleep(backoff_ms)
        post_with_retry(endpoint, req_opts, attempts_left - 1, backoff_ms * 2)

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "DeepSeek API returned HTTP status #{status}: #{inspect(err_body)}"}

      {:error, reason} when attempts_left > 1 ->
        Logger.warning(
          "[DeepSeekAPI] Transport error #{inspect(reason)}. Retrying in #{backoff_ms}ms... (#{attempts_left - 1} attempts left)"
        )

        Process.sleep(backoff_ms)
        post_with_retry(endpoint, req_opts, attempts_left - 1, backoff_ms * 2)

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn t ->
      name = Map.get(t, :name) || Map.get(t, "name")
      desc = Map.get(t, :description) || Map.get(t, "description")
      params = Map.get(t, :parameters) || Map.get(t, "parameters")

      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => desc,
          "parameters" => params
        }
      }
    end)
  end

  defp parse_choice(%{"message" => msg}, usage) do
    raw_content = Map.get(msg, "content")
    tool_calls = Map.get(msg, "tool_calls") || []

    {content, thinking_from_tags} = extract_thinking_tags(raw_content)

    reasoning_content =
      Map.get(msg, "reasoning_content") ||
        Map.get(msg, "reasoning") ||
        thinking_from_tags

    parsed_tool_calls =
      Enum.map(tool_calls, fn tc ->
        fn_data = Map.get(tc, "function", %{})
        args_raw = Map.get(fn_data, "arguments", "{}")

        args =
          case Yoke.Json.decode(args_raw) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        %{
          id: Map.get(tc, "id"),
          name: Map.get(fn_data, "name"),
          arguments: args
        }
      end)

    usage_map = %{
      prompt_tokens: Map.get(usage, "prompt_tokens", 0),
      completion_tokens: Map.get(usage, "completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0)
    }

    {:ok,
     %{
       role: "assistant",
       content: content,
       reasoning_content: reasoning_content,
       tool_calls: parsed_tool_calls,
       usage: usage_map
     }}
  end

  @doc "Normalizes an LLM API endpoint URL to ensure valid full chat completions path."
  def normalize_endpoint(endpoint) when is_binary(endpoint) do
    trimmed = String.trim(endpoint)

    cond do
      String.ends_with?(trimmed, "/chat/completions") ->
        trimmed

      String.ends_with?(trimmed, "/v1") or String.ends_with?(trimmed, "/v1/") ->
        trimmed |> String.trim_trailing("/") |> Kernel.<>("/chat/completions")

      String.contains?(trimmed, "api.deepseek.com") ->
        trimmed |> String.trim_trailing("/") |> Kernel.<>("/chat/completions")

      true ->
        trimmed |> String.trim_trailing("/") |> Kernel.<>("/v1/chat/completions")
    end
  end

  def normalize_endpoint(endpoint), do: endpoint

  @doc "Returns true if an endpoint target URL is a local or loopback address."
  def local_endpoint?(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)
    host = uri.host || ""

    host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"] or
      String.starts_with?(host, "192.168.") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "172.") or
      String.ends_with?(host, ".local")
  end

  def local_endpoint?(_), do: false

  defp extract_thinking_tags(content) when is_binary(content) do
    case Regex.run(~r/<think>(.*?)<\/think>/s, content) do
      [full_match, think_body] ->
        clean_content = String.replace(content, full_match, "") |> String.trim()
        clean_think = String.trim(think_body)
        {clean_content, if(clean_think == "", do: nil, else: clean_think)}

      _ ->
        {content, nil}
    end
  end

  defp extract_thinking_tags(content), do: {content, nil}

  # Mock lookup patterns table (eliminates deep cond nesting)
  @mock_handlers [
    {~r/(list|ls|directory|examine|project)/i, "list_dir", %{"path" => "."},
     "I will list the files in the directory to inspect project layout.",
     "Thought: User requested directory listing. Calling list_dir tool."},
    {~r/(eval|calculate|elixir)/i, "elixir_eval", %{"code" => "1 + 1 + 42"},
     "Executing Elixir code snippet.", "Thought: Need to evaluate mathematical expression."}
  ]

  defp mock_response(messages, _tools, model) do
    last_user_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "user" end) || %{"content" => ""}

    has_tool_result? = Enum.any?(messages, fn m -> m["role"] == "tool" end)

    if has_tool_result? do
      tool_results =
        messages
        |> Enum.filter(fn m -> m["role"] == "tool" end)
        |> Enum.map_join("\n", fn m -> message_content_text(m["content"]) end)

      prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""

      {:ok,
       %{
         role: "assistant",
         content:
           "#{prefix}Examined workspace directory:\n\n#{tool_results}\n\n(Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
         reasoning_content: "Processed tool results and formulated response.",
         tool_calls: [],
         usage: %{prompt_tokens: 60, completion_tokens: 30, total_tokens: 90}
       }}
    else
      content_str = message_content_text(last_user_msg["content"])

      case match_mock_handler(content_str) do
        {:ok, tool_name, args, text, reasoning} ->
          {:ok,
           %{
             role: "assistant",
             content: text,
             reasoning_content: reasoning,
             tool_calls: [
               %{
                 id: "call_mock_#{System.unique_integer([:positive])}",
                 name: tool_name,
                 arguments: args
               }
             ],
             usage: %{prompt_tokens: 40, completion_tokens: 25, total_tokens: 65}
           }}

        :no_match ->
          prefix = if model == "deepseek-reasoner", do: "[DeepSeek-R1 Reasoning Mode] ", else: ""
          vision_note = if vision_model?(model), do: "[Vision] ", else: ""

          {:ok,
           %{
             role: "assistant",
             content:
               "#{prefix}#{vision_note}Received prompt: \"#{content_str}\". (Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
             reasoning_content: "Analyzed request using spatiotemporal actor context.",
             tool_calls: [],
             usage: %{prompt_tokens: 30, completion_tokens: 20, total_tokens: 50}
           }}
      end
    end
  end

  defp message_content_text(content) when is_binary(content), do: content

  defp message_content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"image_url" => %{"url" => url}} when is_binary(url) -> "[Image attached: #{url}]"
      _ -> ""
    end)
  end

  defp message_content_text(_), do: ""

  defp vision_model?(model) when is_binary(model) do
    String.contains?(String.downcase(model), "vision") or
      String.contains?(String.downcase(model), "vl")
  end

  defp vision_model?(_), do: false

  defp match_mock_handler(input) do
    Enum.find_value(@mock_handlers, :no_match, fn {regex, name, args, text, reasoning} ->
      if Regex.match?(regex, input) do
        {:ok, name, args, text, reasoning}
      else
        false
      end
    end)
  end
end

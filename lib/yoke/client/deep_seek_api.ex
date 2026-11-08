defmodule Yoke.Client.DeepSeekAPI do
  @moduledoc """
  Client interface for DeepSeek API (deepseek-flash, deepseek-v4-pro, and deepseek-reasoner R1).
  Handles message serialization, tool declarations, reasoning extraction (R1),
  real token usage tracking, SSE response streaming, and mock execution mode.
  """
  require Logger

  # Finite receive timeout for one chat-completion HTTP attempt.
  #
  # This used to be `:infinity`, which meant a provider that accepted the TCP
  # connection and then never responded wedged the session forever: the call
  # chain is `Session.send_user_message/2` (`:infinity`) -> `run_agent_loop` ->
  # `chat_completion/3`, so nothing above this point imposed a bound either.
  # `Yoke.CLI.Fix` documents the hazard and works around it with its own
  # 600s `Task.yield`. Retries can span multiple receive windows, so the
  # separate whole-turn timeout remains useful.
  #
  # 300s is deliberately generous: a long reasoning-model completion can
  # legitimately take minutes. It is a liveness backstop, not a latency target.
  @receive_timeout_ms 300_000

  @doc """
  Returns the per-request HTTP receive timeout, in milliseconds.

  Overridable via `:yoke, :chat_receive_timeout_ms` so a test can exercise
  the timeout path without waiting five minutes.
  """
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms do
    case Application.get_env(:yoke, :chat_receive_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @receive_timeout_ms
    end
  end

  defmodule ClientConfig do
    @moduledoc "Configuration parameters for DeepSeek API requests."
    defstruct model: "deepseek-flash",
              api_key: nil,
              endpoint: "https://api.deepseek.com/chat/completions",
              temperature: 0.7,
              # Optional per-request cap on generated completion tokens
              # (sent as `max_tokens`). `nil` omits the field so the
              # provider's own default applies.
              max_tokens: nil,
              stream: false,
              stream_fun: nil,
              mock: false,
              # Stable session identifier attached as `x-opencode-session` header
              # for OpenCode Go and other session-routed providers.
              session_id: nil,
              # Reasoning / thinking control for hybrid models
              thinking: nil,
              reasoning_effort: nil
  end

  @doc "Rejects review requests that would silently use offline canned responses."
  def validate_live_config(opts) do
    config = build_config(opts)

    if config.mock or
         ((is_nil(config.api_key) or config.api_key == "") and
            not local_endpoint?(config.endpoint)),
       do:
         {:error,
          "Code review requires a configured model provider. No API credentials are configured; canned offline responses cannot be used for reviews."},
       else: :ok
  end

  @doc """
  Sends a chat completion request to DeepSeek API or mock handler.
  """
  def chat_completion(messages, tools, opts \\ []) do
    opts = Yoke.Provider.resolve(opts)
    config = build_config(opts)
    _input_verdict = Yoke.AIGuard.guard_llm(messages, :input, target: config.model)

    res =
      Yoke.ExternalCall.run(:deepseek_api, [endpoint: config.endpoint, model: config.model], fn ->
        if opts[:provider] && not config.mock && config.api_key in [nil, ""] do
          {:error, "Selected provider has no API credentials configured."}
        else
          if ((is_nil(config.api_key) or config.api_key == "") and
                not local_endpoint?(config.endpoint)) or
               config.mock == true do
            mock_response(messages, tools, config.model)
          else
            real_chat_completion(messages, tools, config)
          end
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
       [
         "deepseek-flash",
         "deepseek-v4-pro",
         "deepseek-reasoner",
         "deepseek-coder",
         "deepseek-v4-flash-vision-exp",
         "deepseek-chat"
       ]}
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
    headers = build_headers(config, false)

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

        if Enum.empty?(model_ids) and not local_endpoint?(config.endpoint) do
          {:ok, ["deepseek-flash", "deepseek-v4-pro", "deepseek-reasoner", "deepseek-chat"]}
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

  if Mix.env() == :test do
    defp enable_real_api_tests?,
      do: System.get_env("ENABLE_REAL_API_TESTS") in ["true", "1", "yes"]
  else
    defp enable_real_api_tests?, do: false
  end

  @doc "Builds a structured ClientConfig struct from keyword options."
  # credo:disable-for-lines:109
  def build_config(opts) when is_list(opts) do
    opts = Yoke.Provider.resolve(opts)

    mock_default =
      if Keyword.has_key?(opts, :mock),
        do: Keyword.get(opts, :mock),
        else: enable_real_api_tests?()

    normalized_endpoint = normalize_endpoint(opts[:endpoint])
    api_key = opts[:api_key]

    session_id =
      cond do
        opts[:session_id] ->
          opts[:session_id]

        System.get_env("OPENCODE_SESSION_ID") ->
          System.get_env("OPENCODE_SESSION_ID")

        System.get_env("YOKE_SESSION_ID") ->
          System.get_env("YOKE_SESSION_ID")

        opencode_endpoint?(normalized_endpoint) ->
          generate_session_id()

        true ->
          nil
      end

    cfg = Yoke.Config.load_config(opts[:cwd] || ".")

    configured_model = opts[:model]

    is_reasoning = reasoning_model?(configured_model)

    config_reasoning =
      case Map.get(cfg, "reasoning") do
        nil -> Map.get(cfg, "enable_reasoning")
        val -> val
      end

    thinking =
      cond do
        opts[:thinking] ->
          opts[:thinking]

        opts[:reasoning] == false or config_reasoning == false ->
          %{"type" => "disabled"}

        opts[:reasoning] == true or config_reasoning == true ->
          %{"type" => "enabled"}

        is_reasoning ->
          nil

        true ->
          %{"type" => "disabled"}
      end

    reasoning_effort =
      cond do
        opts[:reasoning_effort] ->
          opts[:reasoning_effort]

        Map.get(cfg, "reasoning_effort") ->
          Map.get(cfg, "reasoning_effort")

        opts[:reasoning] == false or config_reasoning == false ->
          "none"

        opts[:reasoning] == true or config_reasoning == true ->
          nil

        is_reasoning ->
          nil

        true ->
          "none"
      end

    %ClientConfig{
      model: configured_model,
      api_key: api_key,
      endpoint: normalized_endpoint,
      temperature: opts[:temperature] || 0.7,
      max_tokens: opts[:max_tokens],
      stream: opts[:stream] || false,
      stream_fun: opts[:stream_fun],
      mock: mock_default,
      session_id: session_id,
      thinking: if(local_endpoint?(normalized_endpoint), do: nil, else: thinking),
      reasoning_effort: if(local_endpoint?(normalized_endpoint), do: nil, else: reasoning_effort)
    }
  end

  @doc "Builds HTTP headers for API requests based on configuration."
  def build_headers(%ClientConfig{} = config, content_type? \\ true) do
    type_header =
      if content_type?,
        do: {"Content-Type", "application/json"},
        else: {"Accept", "application/json"}

    headers =
      if is_binary(config.api_key) and config.api_key != "" and config.api_key != "not-needed" do
        [{"Authorization", "Bearer #{config.api_key}"}, type_header]
      else
        [type_header]
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

    session_id =
      config.session_id ||
        if(opencode_endpoint?(config.endpoint), do: generate_session_id(), else: nil)

    if is_binary(session_id) and session_id != "" do
      [{"x-opencode-session", session_id} | headers]
    else
      headers
    end
  end

  defp real_chat_completion(messages, tools, %ClientConfig{} = config) do
    sanitized_messages = sanitize_utf8(messages)
    formatted_tools = format_tools(tools)

    body = %{
      "model" => config.model,
      "messages" => sanitized_messages,
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

    body =
      if config.thinking != nil do
        Map.put(body, "thinking", config.thinking)
      else
        body
      end

    body =
      if config.reasoning_effort != nil do
        Map.put(body, "reasoning_effort", config.reasoning_effort)
      else
        body
      end

    headers = build_headers(config, true)

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: receive_timeout_ms()
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
        retry(endpoint, req_opts, attempts_left, backoff_ms, "Transient HTTP #{status} error")

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "DeepSeek API returned HTTP status #{status}: #{inspect(err_body)}"}

      # A provider that accepts the connection and then never responds is the
      # failure mode `receive_timeout` exists to catch. Treat it as transient
      # so it goes through the same bounded retry path as a 503, rather than
      # surfacing as an opaque `%Req.TransportError{}`.
      {:error, %Req.TransportError{reason: :timeout} = reason} when attempts_left > 1 ->
        retry(
          endpoint,
          req_opts,
          attempts_left,
          backoff_ms,
          "Request timed out (#{inspect(reason)})"
        )

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error,
         "HTTP request timed out after #{receive_timeout_ms()}ms. The provider accepted the " <>
           "connection but never responded; retry, or use a different endpoint."}

      {:error, reason} when attempts_left > 1 ->
        retry(endpoint, req_opts, attempts_left, backoff_ms, "Transport error #{inspect(reason)}")

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      if attempts_left > 1 do
        retry(
          endpoint,
          req_opts,
          attempts_left,
          backoff_ms,
          "Exception (#{Exception.message(e)})"
        )
      else
        {:error, "API request failed with exception: #{Exception.message(e)}"}
      end
  end

  defp retry(endpoint, req_opts, attempts_left, backoff_ms, description) do
    Logger.warning(
      "[DeepSeekAPI] #{description}. Retrying in #{backoff_ms}ms... (#{attempts_left - 1} attempts left)"
    )

    Process.sleep(backoff_ms)
    post_with_retry(endpoint, req_opts, attempts_left - 1, backoff_ms * 2)
  end

  @doc "Recursively sanitizes binary strings within data structures to ensure valid UTF-8 encoding."
  defdelegate sanitize_utf8(term), to: Yoke.Json

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

  defp parse_choice(%{"message" => msg} = choice, usage) do
    raw_content = Map.get(msg, "content")
    tool_calls = Map.get(msg, "tool_calls") || []

    {content, thinking_from_tags} = extract_thinking_tags(raw_content)

    reasoning_content =
      Map.get(msg, "reasoning_content") ||
        Map.get(msg, "reasoning") ||
        thinking_from_tags

    with {:ok, parsed_tool_calls} <- parse_tool_calls(tool_calls) do
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
         finish_reason: Map.get(choice, "finish_reason"),
         tool_calls: parsed_tool_calls,
         usage: usage_map
       }}
    end
  end

  defp parse_tool_calls(tool_calls) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tc, {:ok, calls} ->
      fn_data = Map.get(tc, "function", %{})
      raw = Map.get(fn_data, "arguments", "{}")
      decoded = if is_binary(raw), do: Yoke.Json.decode(raw), else: {:ok, raw}

      case decoded do
        {:ok, args} when is_map(args) ->
          call = %{id: Map.get(tc, "id"), name: Map.get(fn_data, "name"), arguments: args}
          {:cont, {:ok, [call | calls]}}

        _ ->
          # Never erase malformed edit requests into identical empty calls.
          # Do not echo argument content: it may contain private file data.
          {:halt,
           {:error,
            "Invalid tool arguments for #{Map.get(fn_data, "name")}: expected a JSON object."}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  @doc "Normalizes an LLM API endpoint URL to ensure valid full chat completions path."
  def normalize_endpoint(endpoint) when is_binary(endpoint) do
    trimmed = String.trim(endpoint)

    cond do
      trimmed in ["openrouter", "https://openrouter.ai"] ->
        "https://openrouter.ai/api/v1/chat/completions"

      trimmed in ["opencode", "https://opencode.ai"] ->
        "https://opencode.ai/zen/go/v1/chat/completions"

      trimmed in ["ollama", "http://localhost:11434"] ->
        "http://localhost:11434/v1/chat/completions"

      trimmed in ["lmstudio", "http://localhost:1234"] ->
        "http://localhost:1234/v1/chat/completions"

      trimmed in ["vllm", "http://localhost:8000"] ->
        "http://localhost:8000/v1/chat/completions"

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

  @doc "Returns true if an endpoint target URL is an OpenCode service."
  def opencode_endpoint?(endpoint) when is_binary(endpoint) do
    String.contains?(String.downcase(endpoint), "opencode")
  end

  def opencode_endpoint?(_), do: false

  @doc "Generates a unique UUID v4 string for session tracking."
  def generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

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

  @doc "Returns true if the model identifier indicates a reasoning/thinking model (such as deepseek-reasoner or R1)."
  def reasoning_model?(model) when is_binary(model) do
    down = String.downcase(model)

    String.contains?(down, "reasoner") or
      String.contains?(down, "r1") or
      String.contains?(down, "o1") or
      String.contains?(down, "o3")
  end

  def reasoning_model?(_), do: false

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
    is_reasoning = reasoning_model?(model)

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

      prefix = if is_reasoning, do: "[DeepSeek-R1 Reasoning Mode] ", else: ""

      reasoning =
        if is_reasoning, do: "Processed tool results and formulated response.", else: nil

      {:ok,
       %{
         role: "assistant",
         content:
           "#{prefix}Examined workspace directory:\n\n#{tool_results}\n\n(Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
         reasoning_content: reasoning,
         tool_calls: [],
         usage: %{prompt_tokens: 60, completion_tokens: 30, total_tokens: 90}
       }}
    else
      content_str = message_content_text(last_user_msg["content"])

      case match_mock_handler(content_str) do
        {:ok, tool_name, args, text, reasoning} ->
          reasoning_content = if is_reasoning, do: reasoning, else: nil

          {:ok,
           %{
             role: "assistant",
             content: text,
             reasoning_content: reasoning_content,
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
          prefix = if is_reasoning, do: "[DeepSeek-R1 Reasoning Mode] ", else: ""
          vision_note = if vision_model?(model), do: "[Vision] ", else: ""

          reasoning_content =
            if is_reasoning, do: "Analyzed request using spatiotemporal actor context.", else: nil

          {:ok,
           %{
             role: "assistant",
             content:
               "#{prefix}#{vision_note}Received prompt: \"#{content_str}\". (Running in offline/mock mode. Set DEEPSEEK_API_KEY to connect live to DeepSeek API).",
             reasoning_content: reasoning_content,
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

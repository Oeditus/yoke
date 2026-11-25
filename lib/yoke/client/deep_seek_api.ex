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
              reasoning_effort: nil,
              # Cumulative attempt/time budget shared with the harness retry
              # layer. `nil` means "build the default budget".
              retry_budget: nil
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
    # Capture the retry budget before `Provider.resolve/1` normalizes the
    # options: the budget is a client concern, not a provider setting, so it
    # would otherwise be dropped.
    retry_budget_opt = Keyword.get(opts, :retry_budget)
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
      reasoning_effort: if(local_endpoint?(normalized_endpoint), do: nil, else: reasoning_effort),
      retry_budget: retry_budget(retry_budget_opt, cfg)
    }
  end

  # The retry budget is cumulative across the HTTP client and the harness turn
  # retry, so it is resolved from (in order) an explicit session option, the
  # workspace/global config file, and finally the compiled defaults. A budget
  # object handed down from the harness is reused as-is so the two layers
  # share one attempt counter and one clock.
  defp retry_budget(%Yoke.Client.RetryBudget{} = budget, _cfg), do: budget

  defp retry_budget(budget_opts, cfg) do
    opts = if is_list(budget_opts), do: budget_opts, else: []

    Yoke.Client.RetryBudget.new(
      max_attempts: config_positive_int(opts, cfg, :max_attempts, "api_retry_max_attempts"),
      total_timeout_ms:
        config_positive_int(opts, cfg, :total_timeout_ms, "api_retry_total_timeout_ms"),
      max_backoff_ms:
        config_non_negative_int(opts, cfg, :max_backoff_ms, "api_retry_max_backoff_ms"),
      identical_failure_limit:
        config_positive_int(
          opts,
          cfg,
          :identical_failure_limit,
          "api_retry_identical_failure_limit"
        )
    )
  end

  defp config_positive_int(opts, cfg, opt_key, config_key) do
    case Keyword.get(opts, opt_key) do
      value when is_integer(value) and value > 0 -> value
      _ -> Map.get(cfg, config_key)
    end
  end

  defp config_non_negative_int(opts, cfg, opt_key, config_key) do
    case Keyword.get(opts, opt_key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Map.get(cfg, config_key)
    end
  end

  @doc """
  Returns true when `key` is a real credential rather than the absence of one.

  `nil`, `""`, and the `"not-needed"` sentinel that loopback endpoints use are
  all treated as "no credential".
  """
  @spec credential?(term()) :: boolean()
  def credential?("not-needed"), do: false
  def credential?(<<_::utf8, _::binary>>), do: true
  def credential?(_), do: false

  @doc """
  Describes the credential state of a resolved provider configuration without
  revealing the secret.

  Returns `{:configured, source}` when a credential is present, otherwise
  `:missing`. `source` names the variable or setting the credential came from
  so `/env` and error messages can tell the user what to change; it never
  contains the secret itself.

  The resolution order mirrors `Yoke.Provider.resolve/1` so the reported source
  is the one actually in effect for the session.
  """
  @spec credential_state(keyword()) :: {:configured, String.t()} | :missing
  def credential_state(opts) when is_list(opts) do
    case opts[:api_key] do
      "not-needed" -> {:configured, "not required for loopback endpoint"}
      <<_::utf8, _::binary>> -> {:configured, credential_source(opts)}
      _ -> :missing
    end
  end

  @credential_env_vars ~w(YOKE_API_KEY OPENAI_API_KEY LLM_API_KEY DEEPSEEK_API_KEY
                           OPENROUTER_API_KEY OPENCODE_API_KEY OPENCODE_ZEN_API_KEY)

  defp credential_source(opts) do
    cond do
      opts[:provider] -> "provider profile #{opts[:provider]}"
      env_source = Enum.find(@credential_env_vars, &credential?(System.get_env(&1))) -> env_source
      true -> "config api_key"
    end
  end

  @doc "Builds HTTP headers for API requests based on configuration."
  def build_headers(%ClientConfig{} = config, content_type? \\ true) do
    type_header =
      if content_type?,
        do: {"Content-Type", "application/json"},
        else: {"Accept", "application/json"}

    headers =
      if credential?(config.api_key) do
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

    diagnostics = Yoke.Client.RequestDiagnostics.build(body, formatted_tools)

    post_with_retry(config.endpoint, req_opts, diagnostics, config.retry_budget)
  end

  # HTTP statuses worth another attempt: rate limiting and server-side
  # unavailability. Everything else in the 4xx range is deterministic -- the
  # same request will be rejected the same way -- so retrying only delays the
  # error the user needs to act on.
  @transient_statuses [429, 500, 502, 503, 504]

  # One provider request. The attempt budget is shared with the harness-level
  # retry in `Yoke.Brain.Session`, so the two layers cannot multiply into a
  # dozen silent attempts (issue #22). `budget` is threaded through the loop
  # and returned to the caller on every terminal path so the harness can keep
  # counting against the same budget.
  defp post_with_retry(endpoint, req_opts, diagnostics, budget) do
    case Yoke.Client.RetryBudget.begin_attempt(budget) do
      {:error, reason} ->
        {:error, with_diagnostics(reason, diagnostics)}

      {:ok, budget} ->
        attempt(endpoint, req_opts, diagnostics, budget)
    end
  end

  defp attempt(endpoint, req_opts, diagnostics, budget) do
    case Req.post(endpoint, req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp_body}} ->
        usage = Map.get(resp_body, "usage", %{})
        parse_choice(choice, usage)

      {:ok, %Req.Response{status: status}} when status in @transient_statuses ->
        retry_or_halt(
          endpoint,
          req_opts,
          diagnostics,
          budget,
          {:status, status},
          "HTTP #{status}",
          "Transient HTTP #{status} error"
        )

      {:ok, %Req.Response{status: 401, body: err_body}} ->
        {:error, authentication_error(endpoint, err_body)}

      {:ok, %Req.Response{status: 403, body: err_body}} ->
        {:error,
         "Access forbidden (HTTP 403): Request rejected by #{endpoint}. " <>
           "Verify your API key and permissions: #{inspect(err_body)}"}

      {:ok, %Req.Response{status: status, body: err_body}} when status in 400..499 ->
        {:error,
         "Request rejected (HTTP #{status}): #{endpoint} refused the request. " <>
           "This is a client-side error, so retrying will not help; check the model name, " <>
           "max_tokens, and request options: #{inspect(err_body)}"}

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, "API returned HTTP status #{status}: #{inspect(err_body)}"}

      # A provider that accepts the connection and then never responds is the
      # failure mode `receive_timeout` exists to catch. Treat it as transient
      # so it goes through the same bounded retry path as a 503, rather than
      # surfacing as an opaque `%Req.TransportError{}`.
      {:error, %Req.TransportError{reason: :timeout} = reason} ->
        retry_or_halt(
          endpoint,
          req_opts,
          diagnostics,
          budget,
          :timeout,
          :timeout,
          "Request timed out (#{inspect(reason)})"
        )

      # A connection closed mid-request is the failure issue #22 documents.
      # Its detail is the transport reason, so repeated identical closures trip
      # the circuit breaker instead of burning the whole budget.
      {:error, %Req.TransportError{reason: reason} = error} ->
        retry_or_halt(
          endpoint,
          req_opts,
          diagnostics,
          budget,
          :transport,
          reason,
          "Transport error #{inspect(error)}"
        )

      {:error, reason} ->
        retry_or_halt(
          endpoint,
          req_opts,
          diagnostics,
          budget,
          :transport,
          reason,
          "Transport error #{inspect(reason)}"
        )
    end
  rescue
    e ->
      retry_or_halt(
        endpoint,
        req_opts,
        diagnostics,
        budget,
        :exception,
        Exception.message(e),
        "Exception (#{Exception.message(e)})"
      )
  end

  defp retry_or_halt(
         endpoint,
         req_opts,
         diagnostics,
         budget,
         classification,
         detail,
         description
       ) do
    case Yoke.Client.RetryBudget.record_failure(budget, classification, detail) do
      {:halt, final_budget, halt_reason} ->
        {:error,
         with_diagnostics(
           terminal_message(classification, description),
           diagnostics,
           final_budget,
           halt_reason
         )}

      {:retry, next_budget, delay_ms} ->
        Logger.warning(
          "[DeepSeekAPI] #{description}. Retrying in #{delay_ms}ms " <>
            "(attempt #{next_budget.attempts + 1}/#{next_budget.max_attempts}, " <>
            "#{Yoke.Client.RetryBudget.elapsed_ms(next_budget)}ms elapsed). " <>
            "Request size: #{Yoke.Client.RequestDiagnostics.describe(diagnostics)}"
        )

        Process.sleep(delay_ms)
        post_with_retry(endpoint, req_opts, diagnostics, next_budget)
    end
  end

  # A timeout is worth naming precisely: the provider accepted the connection
  # and never responded, which is a different user action from a refused
  # connection. Every other transient failure keeps the transport wording.
  defp terminal_message(:timeout, _description) do
    "HTTP request timed out after #{receive_timeout_ms()}ms. The provider accepted the " <>
      "connection but never responded; retry, or use a different endpoint."
  end

  defp terminal_message(_classification, description), do: "HTTP request failed: #{description}"

  # The byte counts belong in the error the user actually sees: the whole point
  # of the diagnostics is to correlate a transport failure with payload size.
  defp with_diagnostics(message, diagnostics, budget \\ nil, halt_reason \\ nil) do
    suffix =
      case budget do
        nil -> ""
        %{attempts: attempts} -> " after #{attempts} #{pluralize(attempts, "attempt")}"
      end

    halt = if halt_reason, do: " (#{halt_reason})", else: ""

    "#{message}#{halt}#{suffix}. Request size: " <>
      Yoke.Client.RequestDiagnostics.describe(diagnostics)
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
  # A 401 is deterministic: the same credentials will be rejected the same way,
  # so the message has to say what to change. Loopback servers that demand a
  # bearer token get a different hint than a remote provider, because their
  # usual failure is "none was configured", not "the key is wrong".
  defp authentication_error(endpoint, err_body) do
    hint =
      if local_endpoint?(endpoint) do
        "This loopback server requires a bearer token. Export OPENAI_API_KEY (or YOKE_API_KEY) " <>
          "before starting Yoke, or start a new session after exporting it."
      else
        "Provide a valid key via OPENAI_API_KEY, YOKE_API_KEY, or provider configuration."
      end

    "Authentication failed (HTTP 401): API key is invalid or required by #{endpoint}. " <>
      hint <> " Server response: #{inspect(err_body)}"
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
    finish_reason = Map.get(choice, "finish_reason")

    {content, thinking_from_tags} = extract_thinking_tags(raw_content)

    reasoning_content =
      Map.get(msg, "reasoning_content") ||
        Map.get(msg, "reasoning") ||
        thinking_from_tags

    with {:ok, parsed_tool_calls} <- parse_tool_calls(tool_calls, finish_reason, usage) do
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
         finish_reason: finish_reason,
         tool_calls: parsed_tool_calls,
         usage: usage_map
       }}
    end
  end

  defp parse_tool_calls(tool_calls, finish_reason, usage) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tc, {:ok, calls} ->
      fn_data = Map.get(tc, "function", %{})
      tool_name = Map.get(fn_data, "name")
      raw = Map.get(fn_data, "arguments", "{}")

      case decode_tool_arguments(raw) do
        {:ok, args} ->
          call = %{id: Map.get(tc, "id"), name: tool_name, arguments: args}
          {:cont, {:ok, [call | calls]}}

        {:error, reason} ->
          # Never erase malformed edit requests into identical empty calls.
          # Do not echo argument content: it may contain private file data.
          {:halt,
           {:error, format_invalid_tool_args_error(tool_name, reason, finish_reason, usage)}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp decode_tool_arguments(raw) when is_map(raw), do: {:ok, raw}

  defp decode_tool_arguments(raw) when is_binary(raw) do
    case Yoke.Json.decode(raw) do
      {:ok, args} when is_map(args) ->
        {:ok, args}

      {:ok, inner} when is_binary(inner) ->
        # Some OpenAI-compatible providers double-encode the arguments JSON string.
        case Yoke.Json.decode(inner) do
          {:ok, args} when is_map(args) -> {:ok, args}
          _ -> {:error, {:non_object, "string"}}
        end

      {:ok, other} ->
        {:error, {:non_object, json_value_type(other)}}

      {:error, decode_err} ->
        {:error, {:json_decode, decode_err, byte_size(raw)}}
    end
  end

  defp decode_tool_arguments(other), do: {:error, {:non_object, json_value_type(other)}}

  defp format_invalid_tool_args_error(tool_name, {:json_decode, _err, bytes}, "length", usage) do
    tokens = Map.get(usage || %{}, "completion_tokens")

    token_detail =
      if is_integer(tokens) and tokens > 0, do: ", #{tokens} completion tokens", else: ""

    "Invalid tool arguments for #{tool_name}: response was truncated at the model's max output token limit " <>
      "(finish_reason=length#{token_detail}, #{bytes} bytes received). " <>
      "Break the edit into smaller steps, use replace_file for targeted changes, or increase max_tokens."
  end

  defp format_invalid_tool_args_error(
         tool_name,
         {:json_decode, {:unexpected_end, _offset}, bytes},
         _finish_reason,
         _usage
       ) do
    "Invalid tool arguments for #{tool_name}: JSON arguments were truncated before completion " <>
      "(#{bytes} bytes received). Break the edit into smaller steps or use replace_file for targeted changes."
  end

  defp format_invalid_tool_args_error(
         tool_name,
         {:json_decode, decode_err, bytes},
         _finish_reason,
         _usage
       ) do
    "Invalid tool arguments for #{tool_name}: malformed JSON " <>
      "(#{format_json_decode_error(decode_err)}, #{bytes} bytes received)."
  end

  defp format_invalid_tool_args_error(
         tool_name,
         {:non_object, type_name},
         _finish_reason,
         _usage
       ) do
    "Invalid tool arguments for #{tool_name}: expected a JSON object, got #{type_name}."
  end

  defp format_json_decode_error({:invalid_byte, offset, _byte}),
    do: "invalid syntax at byte #{offset}"

  defp format_json_decode_error({:unexpected_sequence, offset, _bytes}),
    do: "invalid syntax at byte #{offset}"

  defp json_value_type(nil), do: "null"
  defp json_value_type(v) when is_list(v), do: "array"
  defp json_value_type(v) when is_boolean(v), do: "boolean"
  defp json_value_type(v) when is_number(v), do: "number"
  defp json_value_type(_), do: "non-object"

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
  defdelegate generate_session_id, to: Yoke.UUID, as: :v4

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

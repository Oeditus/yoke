defmodule Yoke.DeepSeekAPITest do
  # This module changes process-wide model/timeout configuration.
  use ExUnit.Case, async: false

  alias Yoke.Client.DeepSeekAPI

  describe "tool argument parsing" do
    test "preserves encoded, double-encoded, and already decoded argument objects" do
      args = %{"files" => [%{"path" => "sample.ex", "content" => "  value\n"}]}
      encoded = Yoke.Json.encode!(args)
      double_encoded = Yoke.Json.encode!(encoded)

      for raw <- [encoded, double_encoded, args] do
        assert {:ok, %{tool_calls: [%{arguments: ^args}]}} = tool_response(raw)
      end
    end

    test "rejects non-object arguments with their JSON type rather than fabricating empty edits" do
      for {raw, expected_type} <- [
            {"[]", "array"},
            {"null", "null"},
            {"true", "boolean"},
            {"1", "number"},
            {"\"plain string\"", "string"},
            {nil, "null"},
            {[], "array"}
          ] do
        assert {:error, message} = tool_response(raw)

        assert message ==
                 "Invalid tool arguments for mcp_ragex_edit_files: expected a JSON object, got #{expected_type}."
      end
    end

    test "reports output token truncation when finish_reason is length" do
      truncated = "{\"path\": \"secret.ex\", \"content\": \"TOP_SECRET_VALUE"

      assert {:error, message} =
               tool_response(truncated,
                 tool_name: "write_file",
                 finish_reason: "length",
                 usage: %{"prompt_tokens" => 100, "completion_tokens" => 4096}
               )

      assert message =~ "Invalid tool arguments for write_file:"
      assert message =~ "finish_reason=length"
      assert message =~ "4096 completion tokens"
      assert message =~ "replace_file"
      refute message =~ "TOP_SECRET_VALUE"
    end

    test "reports truncated JSON even when finish_reason is not length" do
      assert {:error, message} = tool_response("{\"secret_key\":")

      assert message =~ "Invalid tool arguments for mcp_ragex_edit_files:"
      assert message =~ "truncated before completion"
      refute message =~ "secret_key"
    end

    test "preserves valid escaped newlines, tabs, quotes, and backslashes in tool content" do
      raw = ~S({"content": "line one\nline two\t\"quoted\"\\path"})
      expected = %{"content" => "line one\nline two\t\"quoted\"\\path"}

      assert {:ok, %{tool_calls: [%{arguments: ^expected}]}} =
               tool_response(raw, tool_name: "write_file")
    end

    test "reports malformed JSON syntax without echoing private argument content" do
      for raw <- [
            "{\"content\": \"SECRET\nUNESCAPED\"}",
            ~S({"content": "SECRET\qINVALID"}),
            ~S({"content": "SECRET",})
          ] do
        assert {:error, message} = tool_response(raw, tool_name: "write_file")

        assert message =~ "Invalid tool arguments for write_file: malformed JSON"
        assert message =~ "invalid syntax at byte"
        refute message =~ "SECRET"
      end
    end
  end

  defp tool_response(raw, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)
    tool_name = Keyword.get(opts, :tool_name, "mcp_ragex_edit_files")
    finish_reason = Keyword.get(opts, :finish_reason, "tool_calls")
    usage = Keyword.get(opts, :usage)

    response = Yoke.Test.ReviewFixture.tool_choice(tool_name, %{})

    response =
      update_in(response["choices"], fn [choice] ->
        [
          choice
          |> put_in(["message", "tool_calls", Access.at(0), "function", "arguments"], raw)
          |> Map.put("finish_reason", finish_reason)
        ]
      end)

    response = if usage, do: Map.put(response, "usage", usage), else: response

    {listen, server, endpoint} = Yoke.Test.ReviewFixture.provider(self(), [response])

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    DeepSeekAPI.chat_completion(
      [%{"role" => "user", "content" => "Edit"}],
      [],
      endpoint: endpoint,
      api_key: "not-needed",
      model: "loop-test"
    )
  end

  test "returns mock chat completion in offline mode" do
    messages = [%{"role" => "user", "content" => "Hello DeepSeek"}]

    assert {:ok, %{content: content}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-chat", mock: true)

    assert is_binary(content)
  end

  test "extracts reasoning content for deepseek-reasoner R1 model" do
    messages = [%{"role" => "user", "content" => "Explain quantum physics"}]

    assert {:ok, %{content: content, reasoning_content: reasoning}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-reasoner", mock: true)

    assert is_binary(content)
    assert is_binary(reasoning)
  end

  test "does not extract reasoning content for default deepseek-flash model in offline mode" do
    messages = [%{"role" => "user", "content" => "Explain quantum physics"}]

    assert {:ok, %{content: content, reasoning_content: nil}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-flash", mock: true)

    assert is_binary(content)
  end

  describe "reasoning_model?/1" do
    test "identifies reasoning models" do
      assert DeepSeekAPI.reasoning_model?("deepseek-reasoner")
      assert DeepSeekAPI.reasoning_model?("deepseek-r1")
      assert DeepSeekAPI.reasoning_model?("o1-mini")
      assert DeepSeekAPI.reasoning_model?("o3-mini")

      refute DeepSeekAPI.reasoning_model?("deepseek-flash")
      refute DeepSeekAPI.reasoning_model?("deepseek-chat")
      refute DeepSeekAPI.reasoning_model?("deepseek-coder")
      refute DeepSeekAPI.reasoning_model?("deepseek-v4-pro")
    end
  end

  describe "build_config/1 reasoning and thinking configuration" do
    test "disables thinking and sets reasoning_effort to none for non-reasoning models by default" do
      cfg = DeepSeekAPI.build_config(model: "deepseek-flash")
      assert cfg.thinking == %{"type" => "disabled"}
      assert cfg.reasoning_effort == "none"
    end

    test "keeps thinking and reasoning_effort nil for reasoning models" do
      cfg = DeepSeekAPI.build_config(model: "deepseek-reasoner")
      assert cfg.thinking == nil
      assert cfg.reasoning_effort == nil
    end

    test "respects explicit reasoning: true or thinking opts" do
      cfg = DeepSeekAPI.build_config(model: "deepseek-flash", reasoning: true)
      assert cfg.thinking == %{"type" => "enabled"}
      assert cfg.reasoning_effort == nil

      cfg2 = DeepSeekAPI.build_config(model: "deepseek-flash", reasoning_effort: "low")
      assert cfg2.reasoning_effort == "low"
    end
  end

  describe "build_config/1 max_tokens handling" do
    test "defaults max_tokens to nil when not provided" do
      cfg = DeepSeekAPI.build_config([])
      assert cfg.max_tokens == nil
    end

    test "captures an explicit max_tokens opt" do
      cfg = DeepSeekAPI.build_config(max_tokens: 64_000)
      assert cfg.max_tokens == 64_000
    end

    test "respects DEEPSEEK_MODEL when model opt not provided" do
      orig = System.get_env("DEEPSEEK_MODEL")
      System.put_env("DEEPSEEK_MODEL", "deepseek-v4-flash")

      try do
        cfg = DeepSeekAPI.build_config([])
        assert cfg.model == "deepseek-v4-flash"
      after
        if orig,
          do: System.put_env("DEEPSEEK_MODEL", orig),
          else: System.delete_env("DEEPSEEK_MODEL")
      end
    end

    test "preserves explicit api_key on local endpoint when provided" do
      cfg =
        DeepSeekAPI.build_config(
          api_key: "local-secret-key",
          endpoint: "http://localhost:30000/v1"
        )

      assert cfg.api_key == "local-secret-key"
    end

    test "preserves max_tokens through chat_completion opts" do
      messages = [%{"role" => "user", "content" => "Hello"}]

      assert {:ok, %{content: content}} =
               DeepSeekAPI.chat_completion(messages, [], max_tokens: 64_000, mock: true)

      assert is_binary(content)
    end
  end

  describe "OpenRouter and local model helpers" do
    test "normalize_endpoint/1 appends /chat/completions or /v1/chat/completions correctly" do
      assert DeepSeekAPI.normalize_endpoint("https://api.deepseek.com/chat/completions") ==
               "https://api.deepseek.com/chat/completions"

      assert DeepSeekAPI.normalize_endpoint("https://openrouter.ai/api/v1") ==
               "https://openrouter.ai/api/v1/chat/completions"

      assert DeepSeekAPI.normalize_endpoint("http://localhost:11434") ==
               "http://localhost:11434/v1/chat/completions"
    end

    test "local_endpoint?/1 identifies localhost and local IP addresses" do
      assert DeepSeekAPI.local_endpoint?("http://localhost:11434/v1/chat/completions") == true
      assert DeepSeekAPI.local_endpoint?("http://127.0.0.1:1234/v1/chat/completions") == true
      assert DeepSeekAPI.local_endpoint?("https://openrouter.ai/api/v1/chat/completions") == false
      assert DeepSeekAPI.local_endpoint?("https://api.deepseek.com/chat/completions") == false
    end

    test "build_config/1 automatically sets dummy api_key for local endpoints" do
      cfg = DeepSeekAPI.build_config(endpoint: "http://localhost:11434")
      assert cfg.endpoint == "http://localhost:11434/v1/chat/completions"
      assert cfg.api_key == "not-needed"
    end

    test "models_endpoint/1 derives /models path correctly" do
      assert DeepSeekAPI.models_endpoint("https://api.deepseek.com/chat/completions") ==
               "https://api.deepseek.com/models"

      assert DeepSeekAPI.models_endpoint("https://openrouter.ai/api/v1/chat/completions") ==
               "https://openrouter.ai/api/v1/models"
    end

    test "list_models/1 returns available models list in mock mode" do
      assert {:ok, models} = DeepSeekAPI.list_models(mock: true)
      assert is_list(models)
      assert "deepseek-chat" in models
      assert "deepseek-reasoner" in models
    end
  end

  describe "OpenCode and session routing helpers" do
    test "normalize_endpoint/1 handles opencode alias" do
      assert DeepSeekAPI.normalize_endpoint("opencode") ==
               "https://opencode.ai/zen/go/v1/chat/completions"

      assert DeepSeekAPI.normalize_endpoint("https://opencode.ai/zen/go/v1") ==
               "https://opencode.ai/zen/go/v1/chat/completions"
    end

    test "opencode_endpoint?/1 identifies OpenCode URLs" do
      assert DeepSeekAPI.opencode_endpoint?("https://opencode.ai/zen/go/v1/chat/completions") ==
               true

      assert DeepSeekAPI.opencode_endpoint?("https://api.opencode.ai/v1") == true
      assert DeepSeekAPI.opencode_endpoint?("https://api.deepseek.com/chat/completions") == false
    end

    test "build_config/1 captures explicit session_id" do
      cfg = DeepSeekAPI.build_config(session_id: "test-sess-1234")
      assert cfg.session_id == "test-sess-1234"
    end

    test "build_config/1 auto-generates session_id for opencode endpoints when none is provided" do
      cfg = DeepSeekAPI.build_config(endpoint: "opencode")
      assert is_binary(cfg.session_id)
      assert String.length(cfg.session_id) == 36
    end

    test "build_headers/2 attaches x-opencode-session header when session_id is present" do
      cfg = DeepSeekAPI.build_config(session_id: "sess-abc-789", api_key: "test-key")
      headers = DeepSeekAPI.build_headers(cfg)

      assert {"x-opencode-session", "sess-abc-789"} in headers
      assert {"Authorization", "Bearer test-key"} in headers
      assert {"Content-Type", "application/json"} in headers
    end

    test "build_headers/2 attaches x-opencode-session header automatically for opencode endpoints" do
      cfg = DeepSeekAPI.build_config(endpoint: "https://opencode.ai/zen/go/v1/chat/completions")
      headers = DeepSeekAPI.build_headers(cfg)

      opencode_header = Enum.find(headers, fn {k, _v} -> k == "x-opencode-session" end)
      assert opencode_header != nil
      {_k, sess_id} = opencode_header
      assert is_binary(sess_id)
      assert String.length(sess_id) == 36
    end

    test "generate_session_id/0 generates valid UUID v4 string" do
      id = DeepSeekAPI.generate_session_id()
      assert is_binary(id)
      assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, id)
    end
  end

  describe "HTTP receive timeout" do
    # The response timeout used to be `:infinity`. Because the call chain is
    # `Session.send_user_message/2` (`:infinity`) -> `run_agent_loop` ->
    # `chat_completion/3`, a provider that accepted the TCP connection and
    # then never responded wedged the session permanently. `yoke fix`
    # documented the hazard and worked around it with its own 600s
    # `Task.yield`; the per-attempt timeout bounds stalled receives, but
    # retries mean the separate whole-turn timeout is still useful.
    test "the receive timeout is finite and generous enough for slow models" do
      timeout = DeepSeekAPI.receive_timeout_ms()

      assert is_integer(timeout)
      assert timeout > 0
      # A long reasoning completion can legitimately take minutes.
      assert timeout >= 60_000
    end

    test "a silently-stalled provider fails instead of hanging forever" do
      # `Req` needs its own supervision tree (`Req.Finch`) to issue a request.
      {:ok, _} = Application.ensure_all_started(:req)

      # Shrink the production timeout so the real timeout path is exercised
      # without waiting five minutes.
      prior = Application.get_env(:yoke, :chat_receive_timeout_ms)
      Application.put_env(:yoke, :chat_receive_timeout_ms, 150)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:yoke, :chat_receive_timeout_ms, prior),
          else: Application.delete_env(:yoke, :chat_receive_timeout_ms)
      end)

      # A listener that accepts the connection and then never writes a byte.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Accept in the background so the client's connect succeeds.
      acceptor =
        spawn_link(fn ->
          {:ok, _socket} = :gen_tcp.accept(listen)
          Process.sleep(:infinity)
        end)

      on_exit(fn ->
        Process.exit(acceptor, :kill)
        :gen_tcp.close(listen)
      end)

      result =
        DeepSeekAPI.chat_completion(
          [%{"role" => "user", "content" => "hi"}],
          [],
          endpoint: "http://127.0.0.1:#{port}/v1/chat/completions",
          api_key: "not-needed",
          model: "deepseek-flash"
        )

      # Every attempt times out, so the retry loop exhausts and reports the
      # timeout -- it does not surface as an opaque transport error, and it
      # does not hang.
      assert {:error, message} = result
      assert message =~ "HTTP request timed out after 150ms"
    end
  end

  describe "sanitize_utf8/1" do
    test "preserves valid UTF-8 strings" do
      assert DeepSeekAPI.sanitize_utf8("Hello World 🚀") == "Hello World 🚀"
    end

    test "scrubs invalid bytes like 0x80 from binary strings" do
      invalid_binary =
        <<70, 111, 117, 110, 100, 32, 49, 51, 32, 0x80, 109, 97, 116, 99, 104, 101, 115>>

      sanitized = DeepSeekAPI.sanitize_utf8(invalid_binary)
      assert String.valid?(sanitized)
      assert String.contains?(sanitized, "Found 13")
      assert String.contains?(sanitized, "matches")
    end

    test "recursively sanitizes nested maps and lists" do
      invalid_binary = <<70, 0x80, 111, 117, 110, 100>>

      input = %{
        "role" => "tool",
        "content" => invalid_binary,
        "nested" => [invalid_binary]
      }

      sanitized = DeepSeekAPI.sanitize_utf8(input)
      assert String.valid?(sanitized["content"])
      assert String.valid?(hd(sanitized["nested"]))
    end
  end
end

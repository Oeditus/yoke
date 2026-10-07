defmodule Yoke.DeepSeekAPITest do
  use ExUnit.Case, async: true

  alias Yoke.Client.DeepSeekAPI

  test "returns mock chat completion in offline mode" do
    messages = [%{"role" => "user", "content" => "Hello DeepSeek"}]

    assert {:ok, %{content: content}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-chat")

    assert is_binary(content)
  end

  test "extracts reasoning content for deepseek-reasoner R1 model" do
    messages = [%{"role" => "user", "content" => "Explain quantum physics"}]

    assert {:ok, %{content: content, reasoning_content: reasoning}} =
             DeepSeekAPI.chat_completion(messages, [], model: "deepseek-reasoner")

    assert is_binary(content)
    assert is_binary(reasoning)
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

    test "preserves max_tokens through chat_completion opts" do
      messages = [%{"role" => "user", "content" => "Hello"}]

      assert {:ok, %{content: content}} =
               DeepSeekAPI.chat_completion(messages, [], max_tokens: 64_000)

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

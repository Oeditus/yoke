defmodule Yoke.CLIMainTest do
  use ExUnit.Case, async: false

  alias Yoke.CLI.Main

  test "parses --help flag without error" do
    assert :ok = Main.main(["--help"])
  end

  test "parses --help flag even when passed with leading -- from eval launcher" do
    assert :ok = Main.main(["--", "--help"])
  end

  test "configure_ragex_ai sets empty providers when no API key is present" do
    orig_key = System.get_env("DEEPSEEK_API_KEY")
    orig_r1 = System.get_env("DEEPSEEK_R1_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_R1_API_KEY")

    try do
      Main.configure_ragex_ai()
      ai_cfg = Application.get_env(:ragex, :ai, [])
      assert Keyword.get(ai_cfg, :providers) == []
    after
      if orig_key, do: System.put_env("DEEPSEEK_API_KEY", orig_key)
      if orig_r1, do: System.put_env("DEEPSEEK_R1_API_KEY", orig_r1)
    end
  end

  test "configure_ragex_ai enables Ragex Ollama with the session model" do
    prior_ai = Application.get_env(:ragex, :ai)
    prior_providers = Application.get_env(:ragex, :ai_providers)

    try do
      Main.configure_ragex_ai("qwen3-coder:30b", "http://localhost:11434/v1/chat/completions")

      assert Application.get_env(:ragex, :ai)[:providers] == [:ollama]
      assert Application.get_env(:ragex, :ai)[:default_provider] == :ollama

      assert Application.get_env(:ragex, :ai_providers)[:ollama][:endpoint] ==
               "http://localhost:11434"

      assert Application.get_env(:ragex, :ai_providers)[:ollama][:model] == "qwen3-coder:30b"
    after
      Application.put_env(:ragex, :ai, prior_ai)

      if is_nil(prior_providers) do
        Application.delete_env(:ragex, :ai_providers)
      else
        Application.put_env(:ragex, :ai_providers, prior_providers)
      end
    end
  end

  test "configure_ragex_ai keeps Ragex AI disabled for non-Ollama endpoints" do
    prior_ai = Application.get_env(:ragex, :ai)

    try do
      Main.configure_ragex_ai("deepseek-flash", "https://api.deepseek.com/chat/completions")
      assert Application.get_env(:ragex, :ai)[:providers] == []
    after
      Application.put_env(:ragex, :ai, prior_ai)
    end
  end

  test "generates valid UUIDs for session tracking" do
    uuid = Main.generate_uuid()
    assert is_binary(uuid)
    assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  end
end

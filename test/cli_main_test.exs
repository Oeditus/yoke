defmodule Yoke.CLIMainTest do
  use ExUnit.Case, async: true

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

  test "generates valid UUIDs for session tracking" do
    uuid = Main.generate_uuid()
    assert is_binary(uuid)
    assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  end
end

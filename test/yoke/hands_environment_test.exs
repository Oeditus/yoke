defmodule Yoke.Hands.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Yoke.Hands.Environment

  test "build/2 scrubs inherited environment and sets controlled defaults" do
    env = Environment.build("/tmp/my_workspace", %{"CUSTOM_VAR" => "123"})
    env_map = Map.new(env)

    assert env_map["HOME"] == "/tmp/my_workspace"
    assert env_map["GIT_CONFIG_GLOBAL"] == "/dev/null"
    assert env_map["GIT_CONFIG_NOSYSTEM"] == "1"
    assert env_map["GIT_TERMINAL_PROMPT"] == "0"
    assert env_map["NO_COLOR"] == "1"
    assert env_map["LANG"] == "C.UTF-8"
    assert env_map["CUSTOM_VAR"] == "123"

    all_keys = Map.keys(System.get_env())

    sample_key =
      Enum.find(all_keys, fn k ->
        k not in [
          "HOME",
          "PATH",
          "TMPDIR",
          "LANG",
          "LC_ALL",
          "NO_COLOR",
          "GIT_CONFIG_GLOBAL",
          "GIT_CONFIG_NOSYSTEM",
          "GIT_TERMINAL_PROMPT",
          "CUSTOM_VAR"
        ]
      end)

    if sample_key do
      assert env_map[sample_key] == nil
    end
  end
end

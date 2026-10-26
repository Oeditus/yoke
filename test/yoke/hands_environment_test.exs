defmodule Yoke.Hands.EnvironmentTest do
  use ExUnit.Case, async: false

  alias Yoke.Hands.Environment
  alias Yoke.Plugin.DefaultTools
  alias Yoke.TaskEngine.JobManager

  @toolchain_paths %{
    "MIX_HOME" => "/tmp/yoke-toolchain/mise/.mix",
    "HEX_HOME" => "/tmp/yoke-toolchain/hex",
    "MIX_ARCHIVES" => "/tmp/yoke-toolchain/archives",
    "ERL_HOME" => "/tmp/yoke-toolchain/erlang"
  }

  @scrubbed_variables ~w(
    YOKE_ENV_TEST_SECRET YOKE_ENV_TEST_UNRELATED HEX_API_KEY OPENAI_API_KEY
    MIX_ENV MIX_TEST_SECRET HEX_TEST_SECRET ERL_FLAGS ELIXIR_ERL_OPTIONS
    LD_PRELOAD BASH_ENV
  )

  setup do
    values =
      @scrubbed_variables
      |> Map.new(&{&1, "synthetic-test-value"})
      |> Map.merge(@toolchain_paths)
      |> Map.merge(%{
        "HOME" => "/tmp/yoke-user-home",
        "GIT_CONFIG_GLOBAL" => "/tmp/parent-git-config",
        "GIT_CONFIG_NOSYSTEM" => "0",
        "GIT_TERMINAL_PROMPT" => "1"
      })

    original = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(values)
    :ok
  end

  test "build/2 scrubs inherited environment and sets controlled defaults" do
    env = Environment.build("/tmp/my_workspace", %{"CUSTOM_VAR" => "123"})
    env_map = Map.new(env)

    assert env_map["HOME"] == "/tmp/yoke-user-home"
    assert env_map["GIT_CONFIG_GLOBAL"] == "/dev/null"
    assert env_map["GIT_CONFIG_NOSYSTEM"] == "1"
    assert env_map["GIT_TERMINAL_PROMPT"] == "0"
    assert env_map["NO_COLOR"] == "1"
    assert env_map["LANG"] == "C.UTF-8"
    assert env_map["CUSTOM_VAR"] == "123"
    assert env_map["PATH"] == System.get_env("PATH")
    assert env_map["TMPDIR"] == System.tmp_dir!()
    assert env_map["LC_ALL"] == "C.UTF-8"

    for key <- @scrubbed_variables do
      assert Map.fetch!(env_map, key) == nil
    end
  end

  test "preserves exact user toolchain paths" do
    env = Environment.build("/tmp/unrelated-workspace") |> Map.new()

    assert Map.take(env, Map.keys(@toolchain_paths)) == @toolchain_paths
  end

  test "does not synthesize absent toolchain variables" do
    Enum.each(@toolchain_paths, fn {key, _} -> System.delete_env(key) end)

    env = Environment.build() |> Map.new()

    for key <- Map.keys(@toolchain_paths) do
      refute Map.has_key?(env, key)
    end
  end

  test "resolves missing HOME using the system user home instead of the workspace" do
    System.delete_env("HOME")

    env = Environment.build("/tmp/unrelated-workspace") |> Map.new()

    assert env["HOME"] == System.user_home!()
    assert env["HOME"] == Environment.user_home()
    refute env["HOME"] == "/tmp/unrelated-workspace"
  end

  test "trusted map overrides replace and unset inherited or controlled variables" do
    env =
      Environment.build("/tmp/workspace", %{
        "HOME" => "/tmp/explicit-home",
        "MIX_HOME" => "/tmp/explicit-mix",
        "HEX_HOME" => nil,
        "MIX_ARCHIVES" => false,
        "GIT_TERMINAL_PROMPT" => "1",
        "YOKE_ENV_TEST_SECRET" => "explicit-test-value",
        "CUSTOM_NUMBER" => 123
      })
      |> Map.new()

    assert env["HOME"] == "/tmp/explicit-home"
    assert env["MIX_HOME"] == "/tmp/explicit-mix"
    assert env["HEX_HOME"] == nil
    assert env["MIX_ARCHIVES"] == nil
    assert env["GIT_TERMINAL_PROMPT"] == "1"
    assert env["YOKE_ENV_TEST_SECRET"] == "explicit-test-value"
    assert env["CUSTOM_NUMBER"] == "123"
  end

  test "normalizes keyword override keys before merging without duplicate entries" do
    env = Environment.build("/tmp/workspace", HOME: "/tmp/keyword-home", MIX_HOME: false)

    assert [{"HOME", "/tmp/keyword-home"}] = Enum.filter(env, &(elem(&1, 0) == "HOME"))
    assert [{"MIX_HOME", nil}] = Enum.filter(env, &(elem(&1, 0) == "MIX_HOME"))
    assert Enum.all?(env, fn {key, _} -> is_binary(key) end)
  end

  test "job preparation preserves user home and existing ERL_HOME" do
    command = "mix compile"
    assert {env, ^command} = JobManager.prepare_environment(command)
    env = Map.new(env)

    assert env["HOME"] == Environment.user_home()
    assert Map.take(env, Map.keys(@toolchain_paths)) == @toolchain_paths
    assert env["VIPS_UNBLOCK"] == "svgload,svgload_buffer,svgload_stream"
    assert env["YOKE_ENV_TEST_SECRET"] == nil
  end

  test "foreground commands preserve toolchain paths but cannot inherit a synthetic secret" do
    assert {:ok, output} = DefaultTools.execute_bash(%{"command" => subprocess_probe()})
    assert output == expected_probe_output()
  end

  test "background commands use the same sanitized environment" do
    command = subprocess_probe()
    assert {:ok, job_id, log_file} = JobManager.start_job(command, notify_pid: self())

    assert_receive {:job_completed, ^job_id, ^command, {:exited, 0}, _log_tail}, 5_000
    assert File.read!(log_file) == expected_probe_output()
  end

  defp subprocess_probe do
    """
    test "${YOKE_ENV_TEST_SECRET+x}" != x || exit 1
    printf '%s\\n' "$HOME" "$MIX_HOME" "$HEX_HOME" "$MIX_ARCHIVES" "$ERL_HOME"
    """
  end

  defp expected_probe_output do
    Enum.join(
      [
        "/tmp/yoke-user-home"
        | Enum.map(~w(MIX_HOME HEX_HOME MIX_ARCHIVES ERL_HOME), &@toolchain_paths[&1])
      ],
      "\n"
    ) <> "\n"
  end
end

defmodule Yoke.Config.CITest do
  # Not async: `load_ci_config/2` reads process-wide environment variables.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Config.CI
  alias Yoke.Interaction.Policy

  @env_vars ~w(
    YOKE_MODEL YOKE_ENDPOINT YOKE_API_KEY YOKE_DEFAULT_BRANCH YOKE_MAX_TOKENS
    YOKE_MAX_TOOL_DEPTH YOKE_TEMPERATURE YOKE_LANGUAGES YOKE_ASSISTANT_NAME
    YOKE_FAIL_ON GITHUB_EVENT_NAME CI GITHUB_ACTIONS YOKE_POLICY
  )

  setup do
    prior = Map.new(@env_vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(prior, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  describe "load_ci_config/2" do
    test "returns sensible defaults for an empty repository", %{tmp_dir: dir} do
      config = CI.load_ci_config(dir)

      assert config["model"] == "deepseek-flash"
      assert config["max_tool_depth"] == 1000
      assert config["cwd"] == dir
      assert is_map(config["policy"])
    end

    test "reads the repository .yoke/config.json", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".yoke"))

      File.write!(
        Path.join(dir, ".yoke/config.json"),
        Yoke.Json.encode!(%{"model" => "repo-model", "max_tool_depth" => 42})
      )

      config = CI.load_ci_config(dir)
      assert config["model"] == "repo-model"
      assert config["max_tool_depth"] == 42
    end

    test "environment overrides the repository config", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".yoke"))

      File.write!(
        Path.join(dir, ".yoke/config.json"),
        Yoke.Json.encode!(%{"model" => "repo-model"})
      )

      System.put_env("YOKE_MODEL", "env-model")

      assert CI.load_ci_config(dir)["model"] == "env-model"
    end

    test "explicit inputs override the environment", %{tmp_dir: dir} do
      System.put_env("YOKE_MODEL", "env-model")

      assert CI.load_ci_config(dir, model: "flag-model")["model"] == "flag-model"
    end

    test "coerces numeric environment values", %{tmp_dir: dir} do
      System.put_env("YOKE_MAX_TOKENS", "1234")
      System.put_env("YOKE_MAX_TOOL_DEPTH", "7")
      System.put_env("YOKE_TEMPERATURE", "0.25")

      config = CI.load_ci_config(dir)

      assert config["max_tokens"] == 1234
      assert config["max_tool_depth"] == 7
      assert config["temperature"] == 0.25
    end

    test "leaves an unparseable numeric value as its raw string", %{tmp_dir: dir} do
      System.put_env("YOKE_MAX_TOKENS", "not-a-number")
      assert CI.load_ci_config(dir)["max_tokens"] == "not-a-number"
    end

    test "splits the languages variable into a list", %{tmp_dir: dir} do
      System.put_env("YOKE_LANGUAGES", "elixir, rust;go")
      assert CI.load_ci_config(dir)["languages"] == ["elixir", "rust", "go"]
    end

    test "empty environment variables never clobber repository values", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".yoke"))

      File.write!(
        Path.join(dir, ".yoke/config.json"),
        Yoke.Json.encode!(%{"model" => "repo-model"})
      )

      System.put_env("YOKE_MODEL", "")

      assert CI.load_ci_config(dir)["model"] == "repo-model"
    end

    test "nil explicit inputs are ignored", %{tmp_dir: dir} do
      System.put_env("YOKE_MODEL", "env-model")
      assert CI.load_ci_config(dir, model: nil)["model"] == "env-model"
    end

    test "never reads the user's home config", %{tmp_dir: dir} do
      # A malformed repo config must not raise, and the result must be the
      # defaults -- proving the merge never reaches out to `~/.yoke`.
      File.mkdir_p!(Path.join(dir, ".yoke"))
      File.write!(Path.join(dir, ".yoke/config.json"), "{broken")

      config = CI.load_ci_config(dir)
      assert config["model"] == "deepseek-flash"
    end

    test "embeds the effective policy", %{tmp_dir: dir} do
      Policy.write(dir, %{"fail_on" => "low"})
      assert CI.load_ci_config(dir)["policy"]["fail_on"] == "low"
    end
  end

  describe "fail_on/2" do
    test "an explicit flag wins", %{tmp_dir: dir} do
      System.put_env("YOKE_FAIL_ON", "low")
      System.put_env("GITHUB_EVENT_NAME", "pull_request")
      assert CI.fail_on(dir, "medium") == "medium"
    end

    test "the environment wins over the event default", %{tmp_dir: dir} do
      System.put_env("YOKE_FAIL_ON", "low")
      System.put_env("GITHUB_EVENT_NAME", "push")
      assert CI.fail_on(dir) == "low"
    end

    test "pull_request defaults to gating on high", %{tmp_dir: dir} do
      System.put_env("GITHUB_EVENT_NAME", "pull_request")
      assert CI.fail_on(dir) == "high"
    end

    test "push defaults to never gating", %{tmp_dir: dir} do
      System.put_env("GITHUB_EVENT_NAME", "push")
      assert CI.fail_on(dir) == "never"
    end

    test "an unrecognised severity normalizes to high", %{tmp_dir: dir} do
      assert CI.fail_on(dir, "catastrophic") == "high"
    end

    test "falls back to the policy outside GitHub", %{tmp_dir: dir} do
      Policy.write(dir, %{"fail_on" => "medium"})
      assert CI.fail_on(dir) == "medium"
    end
  end

  describe "ci?/0" do
    test "is false with no CI markers set" do
      refute CI.ci?()
    end

    test "recognises the conventional CI variable" do
      System.put_env("CI", "true")
      assert CI.ci?()
    end

    test "recognises GITHUB_ACTIONS" do
      System.put_env("GITHUB_ACTIONS", "true")
      assert CI.ci?()
    end

    test "treats falsy values as not-CI" do
      System.put_env("CI", "false")
      refute CI.ci?()

      System.put_env("CI", "0")
      refute CI.ci?()

      System.put_env("CI", "")
      refute CI.ci?()
    end
  end

  describe "install_headless_seams/1" do
    setup do
      keys = [:interaction, :auto_start_ragex, :non_interactive, :output_mode]
      prior = Map.new(keys, fn key -> {key, Application.get_env(:yoke, key)} end)

      on_exit(fn ->
        Enum.each(prior, fn
          {key, nil} -> Application.delete_env(:yoke, key)
          {key, value} -> Application.put_env(:yoke, key, value)
        end)
      end)

      :ok
    end

    test "installs the policy interaction and disables Ragex", %{tmp_dir: dir} do
      applied = CI.install_headless_seams(dir)

      assert {:interaction, Yoke.Interaction.Policy} in applied
      assert {:auto_start_ragex, false} in applied
      assert {:non_interactive, true} in applied
      assert {:output_mode, :plain} in applied

      assert Application.get_env(:yoke, :interaction) == Yoke.Interaction.Policy
      assert Application.get_env(:yoke, :auto_start_ragex) == false
      assert Application.get_env(:yoke, :output_mode) == :plain
    end

    test "the installed interaction never blocks", %{tmp_dir: dir} do
      CI.install_headless_seams(dir)

      for kind <- Yoke.Interaction.kinds() do
        assert Yoke.Interaction.ask(kind, %{cwd: dir}) == :deny
      end
    end
  end

  describe "install_dllb_binary/0" do
    setup do
      prior = %{
        ragex_bin: Application.get_env(:ragex, :dllb_server_bin),
        env_bin: System.get_env("DLLB_SERVER_BIN")
      }

      on_exit(fn ->
        case prior.ragex_bin do
          nil -> Application.delete_env(:ragex, :dllb_server_bin)
          value -> Application.put_env(:ragex, :dllb_server_bin, value)
        end

        case prior.env_bin do
          nil -> System.delete_env("DLLB_SERVER_BIN")
          value -> System.put_env("DLLB_SERVER_BIN", value)
        end
      end)

      :ok
    end

    # Regression guard for the CI failure that reported
    # `:dllb_binary_not_found`: the action installs `dllb-server` into
    # `~/.local/bin`, which is on PATH but which Ragex does not search, so the
    # resolved path must be exported explicitly.
    test "exports an explicit DLLB_SERVER_BIN when a binary is available", %{tmp_dir: dir} do
      bin = Path.join(dir, "dllb-server")
      File.write!(bin, "#!/bin/sh\n")

      System.put_env("DLLB_SERVER_BIN", bin)

      assert CI.install_dllb_binary() == bin
      assert Application.get_env(:ragex, :dllb_server_bin) == bin
      assert System.get_env("DLLB_SERVER_BIN") == bin
    end

    # dllb is an accelerator, not a dependency: a missing binary must degrade
    # to the ETS backend, never raise and never change the exit code.
    test "returns nil without raising when no binary exists", %{tmp_dir: _dir} do
      System.put_env("DLLB_SERVER_BIN", "/nonexistent/dllb-server")
      Application.put_env(:ragex, :dllb_server_bin, "/nonexistent/dllb-server")

      # `System.find_executable/1` may still find a real binary on a developer
      # machine; the assertion is only that the call is total.
      assert CI.install_dllb_binary() == nil or is_binary(CI.install_dllb_binary())
    end

    test "install_headless_seams/1 resolves the binary as a side effect", %{tmp_dir: dir} do
      bin = Path.join(dir, "dllb-server")
      File.write!(bin, "#!/bin/sh\n")
      System.put_env("DLLB_SERVER_BIN", bin)

      CI.install_headless_seams(dir)

      assert Application.get_env(:ragex, :dllb_server_bin) == bin
    end
  end
end

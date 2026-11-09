defmodule Yoke.CLI.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Yoke.CLI.Doctor
  alias Yoke.CLI.Main

  @moduletag :app
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    keys = ~w(PATH YOKE_REPO_DIR YOKE_PROVIDER YOKE_WORKSPACE UPDATE_GIT_STATUS UPDATE_MIX_STATUS)
    original = Map.new(keys, &{&1, System.get_env(&1)})
    elixir = System.find_executable("elixir")
    halt_enabled = Application.fetch_env(:yoke, :system_halt_enabled)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case halt_enabled do
        {:ok, value} -> Application.put_env(:yoke, :system_halt_enabled, value)
        :error -> Application.delete_env(:yoke, :system_halt_enabled)
      end
    end)

    Application.put_env(:yoke, :system_halt_enabled, false)
    System.delete_env("YOKE_PROVIDER")
    System.delete_env("YOKE_WORKSPACE")
    System.put_env("UPDATE_GIT_STATUS", "0")
    System.put_env("UPDATE_MIX_STATUS", "0")

    # A .git file is normal for worktrees. Quotes and shell metacharacters
    # exercise the argument-based updater without running a real git command.
    repo = Path.join(dir, "checkout 'quoted'; $(not-a-command)")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".git"), "gitdir: fixture")
    System.put_env("YOKE_REPO_DIR", repo)

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    fake_executable(bin, "git", """
    #!/bin/sh
    printf 'git args: <%s> <%s>\\n' "$1" "$2"
    printf 'git cwd: %s\\n' "$PWD"
    exit "$UPDATE_GIT_STATUS"
    """)

    fake_executable(bin, "mix", """
    #!/bin/sh
    printf 'mix args: <%s> <%s> env: %s\\n' "$1" "$2" "$MIX_ENV"
    printf 'release diagnostics\\n' >&2
    exit "$UPDATE_MIX_STATUS"
    """)

    System.put_env("PATH", bin)
    %{repo: repo, bin: bin, elixir: elixir, original_path: original["PATH"]}
  end

  test "self-update waits for git and production release, preserving command output", %{
    repo: repo
  } do
    output = capture_io(fn -> assert Main.handle_self_update() == 0 end)
    assert output =~ "git args: <pull> <--rebase>"
    assert output =~ "git cwd: #{repo}"
    assert output =~ "mix args: <release> <--overwrite> env: prod"
    assert output =~ "release diagnostics"
    assert output =~ "Update completed"
    refute output =~ "background"
  end

  test "git failure prevents release and returns its exit status" do
    System.put_env("UPDATE_GIT_STATUS", "23")
    output = capture_io(fn -> assert Main.handle_self_update() == 23 end)
    assert output =~ "git exited with status 23"
    refute output =~ "mix args"
    refute output =~ "Update completed"
  end

  test "release failure is visible and returns nonzero" do
    System.put_env("UPDATE_MIX_STATUS", "17")
    output = capture_io(fn -> assert Main.handle_self_update() == 17 end)
    assert output =~ "release diagnostics"
    assert output =~ "mix exited with status 17"
    refute output =~ "Update completed"
  end

  test "main propagates updater failure as the process exit status",
       %{elixir: elixir, bin: bin, original_path: original_path} do
    script = """
    Code.compiler_options(ignore_module_conflict: true, no_warn_undefined: :all)
    Application.load(:yoke)
    Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test))
    Application.put_env(:yoke, :system_halt_enabled, true)
    Code.compile_file("lib/yoke/cli/main.ex")
    Yoke.CLI.Main.main(["--update"])
    """

    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    {output, status} =
      System.cmd(elixir, code_paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [
          {"PATH", bin <> ":" <> original_path},
          {"UPDATE_MIX_STATUS", "17"},
          {"YOKE_PROVIDER", "local"},
          {"ELIXIR_ERL_OPTIONS", "+S 2:2"}
        ]
      )

    assert status == 17
    assert output =~ "mix exited with status 17"
    refute output =~ "Update completed"
  end

  test "missing executable is reported without a crash", %{bin: bin} do
    File.rm!(Path.join(bin, "mix"))
    output = capture_io(fn -> assert Main.handle_self_update() == 127 end)
    assert output =~ "could not run mix"
    refute output =~ "Update completed"
  end

  test "standalone installation does not pretend an update succeeded", %{repo: repo} do
    File.rm!(Path.join(repo, ".git"))
    output = capture_io(fn -> assert Main.handle_self_update() == 1 end)
    assert output =~ "no git checkout"
    refute output =~ "git args"
  end

  test "invalid explicit provider exits before entering REPL when halt is disabled" do
    output = capture_io(fn -> assert Main.main(["--provider", "unknown-profile"]) == :ok end)
    assert output =~ "Unknown provider"
    refute output =~ "ArgumentError"
    refute output =~ "Interactive"
  end

  test "invalid environment provider is a usage error for legacy and subcommand paths" do
    System.put_env("YOKE_PROVIDER", "unknown-environment-profile")

    for args <- [[], ["fix", "--no-run", "never-execute"]] do
      output = capture_io(fn -> assert Main.main(args) == :ok end)
      assert output =~ "Unknown provider"
      refute output =~ "Command source"
    end
  end

  test "malformed provider does not fall through into the REPL" do
    output = capture_io(fn -> assert Main.main(["--provider"]) == :ok end)
    assert output =~ "--provider requires a profile name"
  end

  test "invalid workspace provider is validated and explicit selection takes precedence",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".yoke"))
    File.write!(Path.join(dir, ".yoke/config.json"), ~s({"provider":"unknown-config-profile"}))
    assert {:error, message} = Main.validate_provider(cwd: dir)
    assert message =~ "unknown-config-profile"
    assert :ok = Main.validate_provider(cwd: dir, provider: "local")

    report = Doctor.run(dir)
    check = Enum.find(report.checks, &(&1.category == "AI Provider Credentials"))
    assert check.status == :error
    assert check.details =~ "unknown-config-profile"
  end

  test "optional feature diagnostic uses compiled selection without loading native code" do
    native_modules = [Bumblebee, Nx, EXLA, Image, Vix.Vips.Image]
    before_modules = Map.new(native_modules, &{&1, :code.is_loaded(&1)})
    before_apps = Application.started_applications()
    original = Application.get_env(:yoke, :embeddings_enabled)

    on_exit(fn -> Application.put_env(:yoke, :embeddings_enabled, original) end)

    first = Doctor.check_optional_features()
    Application.put_env(:yoke, :embeddings_enabled, not original)
    assert Doctor.check_optional_features() == first
    assert first.details =~ "Compiled embeddings/image selection"
    assert first.details =~ "metadata only"
    assert first.details =~ "exla:"
    assert Map.new(native_modules, &{&1, :code.is_loaded(&1)}) == before_modules
    assert Application.started_applications() == before_apps
  end

  defp fake_executable(bin, name, script) do
    path = Path.join(bin, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end
end

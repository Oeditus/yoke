defmodule Yoke.CLI.FixTest do
  use ExUnit.Case, async: false
  # Drives `yoke fix`, which starts a session actor.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.CLI.Fix

  setup do
    dir = Path.join(System.tmp_dir!(), "yoke_fix_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_history(dir, content) do
    path = Path.join(dir, "zsh_history")
    File.write!(path, content)
    path
  end

  describe "usage/0" do
    test "documents the exit codes and the main options" do
      usage = Fix.usage()
      assert usage =~ "yoke fix"
      assert usage =~ "--no-run"
      assert usage =~ "--apply"
      assert usage =~ "--history-file"
      assert usage =~ "EXIT CODES"
    end
  end

  describe "analyze/2" do
    test "recognises an Elixir compile error and its location" do
      output = """
      Compiling 1 file (.ex)
      ** (CompileError) lib/foo.ex:12: undefined function bar/1
          (elixir) lib/code.ex:1
      """

      analysis = Fix.analyze(output, 1)

      assert analysis.status == 1
      assert "Elixir compile error" in analysis.signatures
      assert Enum.any?(analysis.locations, &(&1 =~ "lib/foo.ex:12"))
    end

    test "recognises an ExUnit test failure" do
      output = """
        1) test adds numbers (MyTest)
           test/my_test.exs:5
           Assertion with == failed
      """

      analysis = Fix.analyze(output, 1)
      assert "Elixir test failure" in analysis.signatures
      assert Enum.any?(analysis.locations, &(&1 =~ "test/my_test.exs:5"))
    end

    test "recognises a Rust compile error" do
      output = "error[E0308]: mismatched types\n --> src/main.rs:10:5"
      analysis = Fix.analyze(output, 101)
      assert "Rust compile error" in analysis.signatures
    end

    test "recognises a Python traceback" do
      output = "Traceback (most recent call last):\n  File \"app.py\", line 3"
      analysis = Fix.analyze(output, 1)
      assert "Python traceback" in analysis.signatures
    end

    test "recognises a command-not-found failure" do
      analysis = Fix.analyze("sh: 1: mix: not found", 127)
      assert "Command not found" in analysis.signatures
    end

    test "reports no signatures for clean output" do
      analysis = Fix.analyze("all good\n", 0)
      assert analysis.signatures == []
      assert analysis.locations == []
    end

    test "keeps the tail of the output as the summary" do
      output = Enum.map_join(1..40, "\n", &"line #{&1}")
      analysis = Fix.analyze(output, 1)
      assert length(analysis.summary) == 15
      assert List.last(analysis.summary) == "line 40"
    end

    test "handles nil output without crashing" do
      analysis = Fix.analyze(nil, nil)
      assert analysis.signatures == []
      assert analysis.summary == []
    end
  end

  describe "build_prompt/3" do
    test "includes the command, exit status and captured output" do
      outcome = %{
        status: 1,
        output: "** (CompileError) lib/a.ex:1: boom",
        ran?: true,
        duration_ms: 5
      }

      prompt = Fix.build_prompt("mix compile", outcome)

      assert prompt =~ "mix compile"
      assert prompt =~ "Exit status"
      assert prompt =~ "CompileError"
      assert prompt =~ "ROOT CAUSE"
    end

    test "asks for a plan only unless --apply is given" do
      outcome = %{status: 1, output: "boom", ran?: true, duration_ms: 5}

      plan_prompt = Fix.build_prompt("mix test", outcome)
      apply_prompt = Fix.build_prompt("mix test", outcome, apply: true)

      assert plan_prompt =~ "Do NOT modify files yet"
      assert apply_prompt =~ "You MAY now apply the fix"
    end

    test "notes that the command was not re-run under --no-run" do
      outcome = %{status: nil, output: "", ran?: false, duration_ms: 0}
      prompt = Fix.build_prompt("mix test", outcome)
      assert prompt =~ "NOT re-run"
    end

    test "truncates very large output while keeping head and tail" do
      big = String.duplicate("x", 100_000) <> "THE_TAIL"
      outcome = %{status: 1, output: big, ran?: true, duration_ms: 1}
      prompt = Fix.build_prompt("mix test", outcome)

      assert prompt =~ "characters elided"
      assert prompt =~ "THE_TAIL"
      assert String.length(prompt) < 100_000
    end
  end

  describe "fix/1 exit codes" do
    setup do
      prior = Application.get_env(:yoke, :system_halt_enabled)
      Application.put_env(:yoke, :system_halt_enabled, false)
      on_exit(fn -> Application.put_env(:yoke, :system_halt_enabled, prior) end)
    end

    test "returns 0 for --help" do
      assert ExUnit.CaptureIO.capture_io(fn -> assert Fix.fix(["--help"]) == 0 end) =~ "yoke fix"
    end

    test "returns 2 for an unknown option" do
      out = ExUnit.CaptureIO.capture_io(fn -> assert Fix.fix(["--nonsense"]) == 2 end)
      assert out =~ "Unknown or malformed option"
    end

    test "returns 3 when no command can be found in history", %{dir: dir} do
      path = write_history(dir, "yoke\nyoke fix\n")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path]) == 3
        end)

      assert out =~ "No usable command"
    end

    test "returns 0 when the replayed command succeeds", %{dir: dir} do
      path = write_history(dir, "true\n")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path]) == 0
        end)

      assert out =~ "nothing to fix"
    end

    test "returns 1 and prints triage when the command fails", %{dir: dir} do
      path = write_history(dir, "exit 3\n")

      # `--plan-only` stops before the agent hand-off. Without it this test
      # reaches `dispatch_to_agent/2`, which starts a real Brain session and
      # calls `send_user_message/2` -- a `GenServer.call` with an `:infinity`
      # timeout around an HTTP request that also uses `receive_timeout:
      # :infinity`. In a full-suite run the SessionSupervisor is alive and an
      # API key may be configured, so the test would block on a live network
      # call until ExUnit's 60s timeout killed it. That was the intermittent
      # `mix test test/cli_fix_test.exs:176` timeout.
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path, "--no-run", "--plan-only"]) == 1
        end)

      assert out =~ "Fix Triage"
      assert out =~ "not re-run"
    end

    test "an explicit command on the command line wins over history", %{dir: dir} do
      path = write_history(dir, "exit 9\n")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path, "--no-run", "--plan-only", "echo", "hello"]) ==
                   1
        end)

      assert out =~ "Command source: command line"
      assert out =~ "echo hello"
    end

    test "never crashes when the Brain supervisor is unavailable", %{dir: dir} do
      path = write_history(dir, "exit 3\n")

      # Regression: `dispatch_to_agent/2` used to let the supervisor's `:noproc`
      # exit escape, killing the CLI after the triage report was already
      # printed. It must degrade to exit code 1 with a readable message.
      #
      # `--plan-only` keeps this test off the network: asserting the crash is
      # handled does not require actually attempting a live model turn, and
      # doing so here is what made the suite hang intermittently.
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path, "--no-run", "--plan-only"]) == 1
        end)

      assert out =~ "Fix Triage"
    end

    test "--plan-only prints the prompt and never starts a session", %{dir: dir} do
      path = write_history(dir, "exit 3\n")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Fix.fix(["--history-file", path, "--no-run", "--plan-only"]) == 1
        end)

      assert out =~ "Plan-only mode"
      assert out =~ "ROOT CAUSE"
    end
  end
end

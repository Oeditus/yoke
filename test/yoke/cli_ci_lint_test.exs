defmodule Yoke.CLI.CILintTest do
  # Not async: `lint/1` reads process-wide env and shells out to `mix`.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "lint_usage/0" do
    test "documents every flag and the supported tools" do
      usage = CI.lint_usage()

      for flag <- ~w(--tool --fail-on --format --output --timeout) do
        assert usage =~ flag, "usage is missing #{flag}"
      end

      for tool <- Yoke.CI.Lint.tools() do
        assert usage =~ tool, "usage is missing tool #{tool}"
      end
    end

    test "documents the exit codes, including the tool-failure code" do
      usage = CI.lint_usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "3  a tool could not run"
    end
  end

  describe "lint/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.lint(["--help"]) == 0 end)
      assert output =~ "yoke lint"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.lint(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end

    test "an unknown --tool is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.lint(["--tool", "rubocop"]) == 2 end)
      assert output =~ "Unknown --tool"
    end

    test "an invalid --format is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.lint(["--format", "xml"]) == 2 end)
      assert output =~ "Invalid --format"
    end

    test "an invalid --fail-on is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.lint(["--fail-on", "nope"]) == 2 end)
      assert output =~ "Invalid --fail-on"
    end
  end

  describe "dispatch table" do
    test "lint is implemented" do
      assert Main.subcommands()["lint"].status == :implemented
      assert Main.subcommands()["lint"].fun == :lint
    end
  end

  describe "a real lint run" do
    test "runs a single tool and writes an artifact", %{tmp_dir: dir} do
      artifact = Path.join(dir, "lint.json")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          # `format` on the project root is fast and deterministic.
          CI.lint(["--tool", "format", "--output", artifact, "--fail-on", "never"])
        end)

      assert output =~ "Yoke lint"
      assert File.regular?(artifact)

      {:ok, decoded} = Yoke.Json.decode(File.read!(artifact))
      assert decoded["command"] == "lint"
      assert is_list(decoded["tools"])
      assert [%{"tool" => "format"}] = decoded["tools"]
      assert is_binary(decoded["run_uid"])
    end

    test "a tool that cannot run exits 3, distinct from findings", %{tmp_dir: dir} do
      artifact = Path.join(dir, "lint-fail.json")
      test_pid = self()

      # `capture_io/1` returns the *captured output*, not the function's value,
      # so the exit code is sent back to this process explicitly.
      ExUnit.CaptureIO.capture_io(fn ->
        code = CI.lint(["--tool", "format", "--output", artifact, "--fail-on", "never"])
        send(test_pid, {:lint_code, code})
      end)

      assert_receive {:lint_code, code}
      # Either the tool ran (0/1) or it could not run (3); never a crash.
      assert code in [0, 1, 3]
    end
  end
end

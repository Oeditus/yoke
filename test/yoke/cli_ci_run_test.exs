defmodule Yoke.CLI.CIRunTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "run_usage/0" do
    test "documents every flag and the CI degradation" do
      usage = CI.run_usage()

      assert usage =~ "--prompt"
      assert usage =~ "--list"
      assert usage =~ "--output"
      assert usage =~ "single task"
      assert usage =~ "no git worktrees"
    end

    test "documents the exit codes, including halted" do
      usage = CI.run_usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "1  workflow halted"
      assert usage =~ "3  the workflow could not run"
    end
  end

  describe "run_workflow/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.run_workflow(["--help"]) == 0 end)
      assert output =~ "yoke run"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.run_workflow(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end

    test "a missing workflow name is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.run_workflow([]) == 2 end)
      assert output =~ "Missing workflow name"
    end
  end

  describe "run_workflow/1 --list" do
    test "lists the bundled workflows" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.run_workflow(["--list"]) == 0 end)

      assert output =~ "Available workflows"
      assert output =~ "elixir"
    end

    test "the -l alias works" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.run_workflow(["-l"]) == 0 end)
      assert output =~ "Available workflows"
    end
  end

  describe "run_workflow/1 failure path" do
    test "an unknown workflow exits 3", %{tmp_dir: dir} do
      test_pid = self()

      ExUnit.CaptureIO.capture_io(fn ->
        code = File.cd!(dir, fn -> CI.run_workflow(["no-such-workflow", "--prompt", "x"]) end)
        send(test_pid, {:code, code})
      end)

      assert_receive {:code, 3}
    end
  end

  describe "dispatch table" do
    test "run is implemented with the right function" do
      assert Main.subcommands()["run"].status == :implemented
      assert Main.subcommands()["run"].fun == :run_workflow
    end
  end
end

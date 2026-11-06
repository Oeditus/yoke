defmodule Yoke.CLI.CIRagTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "rag_usage/0" do
    test "documents every flag" do
      usage = CI.rag_usage()

      for flag <- ~w(--index --status --strict --timeout) do
        assert usage =~ flag, "usage is missing #{flag}"
      end
    end

    test "explains that Ragex is optional and non-fatal" do
      usage = CI.rag_usage()

      assert usage =~ "enhancement, not a dependency"
      assert usage =~ "must not fail"
      assert usage =~ "--strict"
    end

    test "documents the exit codes" do
      usage = CI.rag_usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "3  unavailable with --strict"
    end
  end

  describe "rag/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.rag(["--help"]) == 0 end)
      assert output =~ "yoke rag"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.rag(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end
  end

  describe "rag/1 --status" do
    test "reports graph presence and exits 0", %{tmp_dir: dir} do
      test_pid = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          code = File.cd!(dir, fn -> CI.rag(["--status"]) end)
          send(test_pid, {:code, code})
        end)

      assert_receive {:code, 0}
      assert output =~ "Ragex running"
      assert output =~ "graph present"
    end

    test "detects an existing .ragex graph", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".ragex"))

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          File.cd!(dir, fn -> CI.rag(["--status"]) end)
        end)

      assert output =~ "graph present: true"
    end
  end

  describe "dispatch table" do
    test "rag is implemented" do
      assert Main.subcommands()["rag"].status == :implemented
      assert Main.subcommands()["rag"].fun == :rag
    end

    test "every Milestone 2 command is now implemented" do
      table = Main.subcommands()

      for command <- ~w(review lint describe run audit rag) do
        assert table[command].status == :implemented, "#{command} should be implemented"
      end
    end
  end
end

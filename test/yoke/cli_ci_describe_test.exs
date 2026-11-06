defmodule Yoke.CLI.CIDescribeTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "describe_usage/0" do
    test "documents every flag" do
      usage = CI.describe_usage()

      for flag <- ~w(--base --head --pr --model --endpoint --max-cost --format --output) do
        assert usage =~ flag, "usage is missing #{flag}"
      end
    end

    test "documents the exit codes" do
      usage = CI.describe_usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "0  summary produced"
      assert usage =~ "3  the summary could not be produced"
    end
  end

  describe "describe/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.describe(["--help"]) == 0 end)
      assert output =~ "yoke describe"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.describe(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end

    test "an invalid --format is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.describe(["--format", "xml"]) == 2 end)
      assert output =~ "Invalid --format"
    end
  end

  describe "describe/1 failure path" do
    test "an empty range exits 3 with an error", %{tmp_dir: dir} do
      test_pid = self()

      ExUnit.CaptureIO.capture_io(fn ->
        code =
          File.cd!(dir, fn ->
            CI.describe(["--base", "HEAD", "--head", "HEAD"])
          end)

        send(test_pid, {:code, code})
      end)

      assert_receive {:code, code}
      assert code == 3
    end
  end

  describe "dispatch table" do
    test "describe is implemented" do
      assert Main.subcommands()["describe"].status == :implemented
      assert Main.subcommands()["describe"].fun == :describe
    end
  end
end

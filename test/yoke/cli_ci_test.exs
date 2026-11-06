defmodule Yoke.CLI.CITest do
  # Not async: `review/1` reads process-wide env and the dispatch table is
  # global app state.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Findings
  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "usage/0" do
    test "documents every flag the parser accepts" do
      usage = CI.usage()

      for flag <- ~w(--base --head --pr --fail-on --format --output --post --model --endpoint) do
        assert usage =~ flag, "usage text is missing #{flag}"
      end
    end

    test "documents the exit codes" do
      usage = CI.usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "2  usage error"
      assert usage =~ "3  infrastructure failure"
    end
  end

  describe "review/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.review(["--help"]) == 0 end)
      assert output =~ "yoke review"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.review(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end

    test "an invalid --format is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.review(["--format", "xml"]) == 2 end)
      assert output =~ "Invalid --format"
    end

    test "an invalid --fail-on is a usage error" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert CI.review(["--fail-on", "catastrophic"]) == 2
        end)

      assert output =~ "Invalid --fail-on"
    end

    test "every accepted --fail-on level parses" do
      for level <- Findings.thresholds() do
        # `--dry-run` keeps this from spending a model call; a bad revision
        # then yields a usage error (2) rather than a crash.
        ExUnit.CaptureIO.capture_io(fn ->
          assert CI.review(["--fail-on", level, "--dry-run", "--base", "nope"]) == 2
        end)
      end
    end
  end

  describe "review_opts/1" do
    test "defaults head to HEAD and post to false" do
      opts = CI.review_opts(base: "main")

      assert opts[:base] == "main"
      assert opts[:head] == "HEAD"
      assert opts[:post] == false
    end

    test "drops nil options so they never override a default" do
      opts = CI.review_opts(base: "main", model: nil)
      refute Keyword.has_key?(opts, :model)
    end

    test "carries every provided option through" do
      opts =
        CI.review_opts(
          base: "main",
          head: "feature",
          pr: "7",
          fail_on: "low",
          output: "/tmp/x.json",
          post: true,
          model: "m",
          endpoint: "http://e"
        )

      assert opts[:head] == "feature"
      assert opts[:pr] == "7"
      assert opts[:fail_on] == "low"
      assert opts[:output] == "/tmp/x.json"
      assert opts[:post] == true
      assert opts[:model] == "m"
      assert opts[:endpoint] == "http://e"
    end
  end

  describe "exit_code_for/1" do
    test "maps a passing report to 0" do
      report = Findings.report([], "high")
      assert CI.exit_code_for({:ok, %{report: report}}) == 0
    end

    test "maps a gating report to 1" do
      finding = %{
        id: 1,
        file: "a.ex",
        line: 1,
        title: "t",
        description: "d",
        severity: "high",
        kind: "issue",
        fix_suggestion: ""
      }

      report = Findings.report([finding], "high")
      assert CI.exit_code_for({:ok, %{report: report}}) == 1
    end

    test "maps an infrastructure error to 3" do
      assert CI.exit_code_for({:error, "boom"}) == 3
    end
  end

  describe "Main dispatch table" do
    test "advertises the full planned command surface" do
      table = Main.subcommands()

      for command <- ~w(review lint describe run audit rag) do
        assert Map.has_key?(table, command), "dispatch table is missing #{command}"
      end
    end

    test "review is implemented and the rest are planned" do
      table = Main.subcommands()

      assert table["review"].status == :implemented

      for command <- ~w(lint describe run audit rag) do
        assert table[command].status == :planned
      end
    end
  end

  describe "Main.split_subcommand/1" do
    test "recognises a leading subcommand" do
      assert Main.split_subcommand(["review", "--base", "main"]) ==
               {"review", ["--base", "main"]}
    end

    test "recognises a subcommand after flags" do
      assert Main.split_subcommand(["--verbose", "review", "--base", "main"]) ==
               {"review", ["--verbose", "--base", "main"]}
    end

    test "returns nil for a non-subcommand prompt" do
      assert Main.split_subcommand(["fix the bug"]) == nil
    end

    test "returns nil when there is nothing but flags" do
      assert Main.split_subcommand(["--help"]) == nil
      assert Main.split_subcommand([]) == nil
    end
  end

  describe "a planned subcommand" do
    test "reports not-implemented and exits 2" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert Main.main(["lint"]) == :ok end)

      assert output =~ "not implemented yet"
    end
  end
end

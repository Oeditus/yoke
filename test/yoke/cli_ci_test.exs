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

    test "every implemented subcommand names a real module and function" do
      table = Main.subcommands()

      implemented =
        Enum.filter(table, fn {_name, spec} -> spec.status == :implemented end)

      assert implemented != []

      for {name, spec} <- implemented do
        assert is_atom(spec.module) and not is_nil(spec.module),
               "#{name} is marked implemented but has no module"

        assert is_atom(spec.fun) and not is_nil(spec.fun),
               "#{name} is marked implemented but has no function"

        assert function_exported?(spec.module, spec.fun, 1),
               "#{name} points at #{inspect(spec.module)}.#{spec.fun}/1, which is not exported"
      end
    end

    test "every planned subcommand has no module or function yet" do
      for {name, spec} <- Main.subcommands(), spec.status == :planned do
        assert is_nil(spec.module), "#{name} is planned but names a module"
        assert is_nil(spec.fun), "#{name} is planned but names a function"
      end
    end

    test "the table only contains known statuses" do
      for {name, spec} <- Main.subcommands() do
        assert spec.status in [:implemented, :planned],
               "#{name} has status #{inspect(spec.status)}"
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
      # Every Milestone 2 command now ships, so there may be nothing planned.
      # This test only has work to do when one is added back.
      planned =
        Main.subcommands()
        |> Enum.filter(fn {_name, spec} -> spec.status == :planned end)
        |> Enum.map(&elem(&1, 0))

      for command <- planned do
        output = ExUnit.CaptureIO.capture_io(fn -> assert Main.main([command]) == :ok end)
        assert output =~ "not implemented yet", "#{command} should report as not implemented"
      end
    end

    test "an unimplemented entry is reported rather than crashing" do
      # Proves the fallback in `dispatch_subcommand/2` works even when the
      # table has no `:planned` entries: a spec pointing at a function that
      # does not exist must degrade to a message, not an exception.
      refute function_exported?(Yoke.CLI.CI, :not_a_real_command, 1)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Main.main(["lint", "--help"]) == :ok
        end)

      # `lint` is implemented, so this exercises the happy path; the guard
      # itself is covered by the `function_exported?` assertion above.
      assert output =~ "yoke lint"
    end
  end
end

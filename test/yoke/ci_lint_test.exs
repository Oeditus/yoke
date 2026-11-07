defmodule Yoke.CI.LintTest do
  # Not async: `run/1` shells out to `mix` in the current project directory.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Lint

  describe "tools/0" do
    test "lists every supported tool" do
      tools = Lint.tools()

      for tool <- ~w(format credo oeditus_credo dialyzer deps.audit) do
        assert tool in tools
      end
    end
  end

  describe "run_tool/3" do
    test "reports a clean tool as :ok with no findings", %{tmp_dir: dir} do
      # `mix format --check-formatted` on an empty dir has nothing to check.
      File.write!(Path.join(dir, "mix.exs"), "defmodule X do\n  use Mix.Project\nend\n")

      outcome = Lint.run_tool("format", dir, 60_000)

      assert outcome.tool == "format"
      assert outcome.status in [:ok, :findings, :error]
      assert is_list(outcome.findings)
      assert is_integer(outcome.duration_ms)
    end

    test "reports a missing tool as :error rather than raising", %{tmp_dir: dir} do
      outcome = Lint.run_tool("nonexistent_tool_xyz", dir, 60_000)

      assert outcome.tool == "nonexistent_tool_xyz"
      assert outcome.status == :error
      assert [finding] = outcome.findings
      assert finding.severity == "high"
      assert finding.title =~ "could not run"
    end

    test "enforces the timeout", %{tmp_dir: dir} do
      # `mix` in an empty dir is fast; use a 1ms budget to force the timeout.
      outcome = Lint.run_tool("format", dir, 1)

      assert outcome.status == :error
      assert hd(outcome.findings).description =~ "timed out"
    end
  end

  describe "run/1" do
    test "returns a report in the shape the sinks expect", %{tmp_dir: dir} do
      {:ok, report} = Lint.run(cwd: dir, tools: ["format"], timeout: 60_000)

      # Same keys `Yoke.CI.Findings.report/2` produces, plus `:tools`.
      assert Map.has_key?(report, :findings)
      assert Map.has_key?(report, :issues)
      assert Map.has_key?(report, :endorsements)
      assert Map.has_key?(report, :findings_count)
      assert Map.has_key?(report, :max_severity)
      assert Map.has_key?(report, :fail_on)
      assert Map.has_key?(report, :gating)
      assert Map.has_key?(report, :failed?)
      assert Map.has_key?(report, :tools)
    end

    test "records one outcome per selected tool", %{tmp_dir: dir} do
      {:ok, report} = Lint.run(cwd: dir, tools: ["format", "credo"], timeout: 60_000)

      assert length(report.tools) == 2
      assert Enum.map(report.tools, & &1.tool) == ["format", "credo"]
      assert Enum.all?(report.tools, &Map.has_key?(&1, :status))
      assert Enum.all?(report.tools, &Map.has_key?(&1, :duration_ms))
    end

    test "a tool that cannot run yields a gating finding", %{tmp_dir: dir} do
      {:ok, report} = Lint.run(cwd: dir, tools: ["nonexistent_tool_xyz"], timeout: 60_000)

      assert report.findings_count >= 1
      assert report.max_severity == "high"
      assert [tool] = report.tools
      assert tool.status == :error
    end

    test "honours the fail_on threshold", %{tmp_dir: dir} do
      {:ok, report} = Lint.run(cwd: dir, tools: ["nonexistent_tool_xyz"], fail_on: "never")

      refute report.failed?
      assert report.gating == []
    end
  end
end

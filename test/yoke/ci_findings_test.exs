defmodule Yoke.CI.FindingsTest do
  use ExUnit.Case, async: true

  alias Yoke.CI.Findings

  defp finding(attrs) do
    Map.merge(
      %{
        id: 1,
        file: "lib/foo.ex",
        line: 10,
        title: "Something",
        description: "Details",
        severity: "high",
        kind: "issue",
        fix_suggestion: "Do the thing"
      },
      Map.new(attrs)
    )
  end

  describe "rank/1" do
    test "orders severities from most to least severe" do
      assert Findings.rank("high") > Findings.rank("medium")
      assert Findings.rank("medium") > Findings.rank("low")
      assert Findings.rank("low") > Findings.rank("info")
    end

    test "is case- and whitespace-insensitive" do
      assert Findings.rank("HIGH") == Findings.rank("high")
      assert Findings.rank("  Medium  ") == Findings.rank("medium")
    end

    test "ranks unknown or missing severities below everything" do
      assert Findings.rank("catastrophic") == 0
      assert Findings.rank(nil) == 0
      assert Findings.rank("") == 0
      assert Findings.rank("high") > Findings.rank("nonsense")
    end
  end

  describe "at_or_above?/2" do
    test "compares against the threshold" do
      assert Findings.at_or_above?("high", "high")
      assert Findings.at_or_above?("high", "medium")
      assert Findings.at_or_above?("medium", "medium")
      refute Findings.at_or_above?("low", "medium")
      refute Findings.at_or_above?("info", "low")
    end

    test "never exceeds the never threshold" do
      for severity <- ~w(high medium low info) do
        refute Findings.at_or_above?(severity, "never")
      end
    end

    test "an unknown severity never gates" do
      refute Findings.at_or_above?("catastrophic", "low")
    end
  end

  describe "classify/1" do
    test "splits issues from endorsements" do
      issue = finding(%{kind: "issue"})
      endorsement = finding(%{kind: "endorsement", severity: "info", fix_suggestion: ""})

      assert {[^issue], [^endorsement]} = Findings.classify([issue, endorsement])
    end

    test "treats legacy informational praise as an endorsement" do
      # No `kind`, severity info, no fix -- the legacy shape.
      legacy = finding(%{kind: nil, severity: "info", fix_suggestion: ""})
      {issues, endorsements} = Findings.classify([legacy])

      assert issues == []
      assert length(endorsements) == 1
    end
  end

  describe "max_severity/1" do
    test "returns none for an empty list" do
      assert Findings.max_severity([]) == "none"
    end

    test "returns the highest severity present" do
      findings = [
        finding(%{severity: "low"}),
        finding(%{severity: "high"}),
        finding(%{severity: "medium"})
      ]

      assert Findings.max_severity(findings) == "high"
    end

    test "ignores unknown severities when a known one is present" do
      findings = [finding(%{severity: "catastrophic"}), finding(%{severity: "low"})]
      assert Findings.max_severity(findings) == "low"
    end
  end

  describe "report/2" do
    test "counts issues but not endorsements" do
      findings = [
        finding(%{severity: "high"}),
        finding(%{kind: "endorsement", severity: "info", fix_suggestion: ""})
      ]

      report = Findings.report(findings, "high")

      assert report.findings_count == 1
      assert length(report.issues) == 1
      assert length(report.endorsements) == 1
      assert report.max_severity == "high"
    end

    test "gates only findings at or above the threshold" do
      findings = [finding(%{severity: "high"}), finding(%{severity: "low"})]

      high = Findings.report(findings, "high")
      assert length(high.gating) == 1
      assert high.failed?

      low = Findings.report(findings, "low")
      assert length(low.gating) == 2
      assert low.failed?
    end

    test "never gating passes even with critical findings" do
      report = Findings.report([finding(%{severity: "high"})], "never")

      assert report.gating == []
      refute report.failed?
      assert Findings.exit_code(report) == 0
    end

    test "an empty review passes" do
      report = Findings.report([], "high")

      assert report.findings_count == 0
      assert report.max_severity == "none"
      refute report.failed?
      assert Findings.exit_code(report) == 0
    end

    test "endorsements never gate" do
      findings = [finding(%{kind: "endorsement", severity: "info", fix_suggestion: ""})]
      report = Findings.report(findings, "info")

      assert report.gating == []
      refute report.failed?
    end
  end

  describe "exit_code/1" do
    test "is 1 when gating and 0 otherwise" do
      assert Findings.exit_code(%{failed?: true}) == 1
      assert Findings.exit_code(%{failed?: false}) == 0
    end
  end
end

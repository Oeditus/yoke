defmodule Yoke.CI.AuditTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Yoke.CI.Audit

  defp write_trail(dir, entries) do
    path = Path.join(dir, Audit.audit_path())
    File.mkdir_p!(Path.dirname(path))
    body = Enum.map_join(entries, "", &(Yoke.Json.encode!(&1) <> "\n"))
    File.write!(path, body)
    path
  end

  defp entry(attrs) do
    Map.merge(
      %{
        "timestamp" => "2026-01-01T00:00:00Z",
        "phase" => "tool_call",
        "target" => "bash",
        "action" => "pass",
        "mode" => "observe",
        "reason" => nil,
        "duration_ms" => 1
      },
      attrs
    )
  end

  describe "read/1" do
    test "returns an empty list when there is no trail", %{tmp_dir: dir} do
      assert {:ok, []} = Audit.read(dir)
    end

    test "reads every entry", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{}), entry(%{"action" => "flagged"})])
      assert {:ok, entries} = Audit.read(dir)
      assert length(entries) == 2
    end

    test "skips malformed lines rather than failing", %{tmp_dir: dir} do
      path = Path.join(dir, Audit.audit_path())
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Yoke.Json.encode!(entry(%{})) <> "\nnot json\n")

      assert {:ok, entries} = Audit.read(dir)
      assert length(entries) == 1
    end
  end

  describe "counts/1" do
    test "counts by phase and action, including zero buckets" do
      entries = [
        entry(%{"phase" => "input", "action" => "pass"}),
        entry(%{"phase" => "output", "action" => "flagged"}),
        entry(%{"phase" => "tool_call", "action" => "blocked"})
      ]

      counts = Audit.counts(entries)

      assert counts.total == 3
      assert counts.by_phase == %{"input" => 1, "output" => 1, "tool_call" => 1}
      assert counts.by_action == %{"pass" => 1, "flagged" => 1, "blocked" => 1}
    end

    test "reports zero for absent buckets" do
      counts = Audit.counts([])

      assert counts.total == 0
      assert counts.by_action == %{"pass" => 0, "flagged" => 0, "blocked" => 0}
    end
  end

  describe "run/1" do
    test "passes are counted but never become findings", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "pass"})])
      {:ok, report} = Audit.run(cwd: dir)

      assert report.counts.by_action["pass"] == 1
      assert report.findings_count == 0
      refute report.failed?
    end

    test "a blocked entry is a high-severity finding", %{tmp_dir: dir} do
      write_trail(dir, [
        entry(%{"action" => "blocked", "phase" => "tool_call", "reason" => "rm -rf detected"})
      ])

      {:ok, report} = Audit.run(cwd: dir, fail_on: "high")

      assert report.findings_count == 1
      assert report.max_severity == "high"
      assert report.failed?
      assert hd(report.issues).description =~ "rm -rf detected"
    end

    test "a flagged entry is a medium-severity finding", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "flagged"})])
      {:ok, report} = Audit.run(cwd: dir, fail_on: "medium")

      assert report.max_severity == "medium"
      assert report.failed?
    end

    test "a flagged entry does not gate at high", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "flagged"})])
      {:ok, report} = Audit.run(cwd: dir, fail_on: "high")

      refute report.failed?
    end

    test "an absent trail is not a failure", %{tmp_dir: dir} do
      {:ok, report} = Audit.run(cwd: dir)

      refute report.trail_present?
      refute report.failed?
      assert report.counts.total == 0
    end

    test "the entry title names the phase and action", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "blocked", "phase" => "input"})])
      {:ok, report} = Audit.run(cwd: dir)

      assert hd(report.issues).title == "blocked: input"
    end
  end

  describe "run/1 with :since" do
    test "excludes entries before the cutoff", %{tmp_dir: dir} do
      write_trail(dir, [
        entry(%{"timestamp" => "2020-01-01T00:00:00Z", "action" => "blocked"}),
        entry(%{"timestamp" => "2030-01-01T00:00:00Z", "action" => "blocked"})
      ])

      {:ok, report} = Audit.run(cwd: dir, since: "2025-01-01T00:00:00Z")

      assert report.counts.total == 1
      assert report.since == "2025-01-01T00:00:00Z"
    end

    test "keeps entries with an unparseable timestamp rather than dropping evidence", %{
      tmp_dir: dir
    } do
      write_trail(dir, [entry(%{"timestamp" => "not-a-date", "action" => "blocked"})])

      {:ok, report} = Audit.run(cwd: dir, since: "2025-01-01T00:00:00Z")

      assert report.counts.total == 1
    end

    test "an unparseable cutoff is ignored", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{})])
      {:ok, report} = Audit.run(cwd: dir, since: "nonsense")
      assert report.counts.total == 1
    end
  end

  describe "run/1 with :limit" do
    test "caps the rendered findings and flags truncation", %{tmp_dir: dir} do
      entries = for _ <- 1..10, do: entry(%{"action" => "blocked"})
      write_trail(dir, entries)

      {:ok, report} = Audit.run(cwd: dir, limit: 3)

      assert length(report.issues) == 3
      assert report.truncated?
      assert report.total_findings == 10
    end

    test "does not flag truncation when everything fits", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "blocked"})])
      {:ok, report} = Audit.run(cwd: dir, limit: 50)

      refute report.truncated?
      assert report.total_findings == 1
    end
  end

  describe "render/1" do
    test "states there is no trail when none exists", %{tmp_dir: dir} do
      {:ok, report} = Audit.run(cwd: dir)
      assert Audit.render(report) =~ "no audit trail"
    end

    test "renders counts and findings", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "blocked", "reason" => "secret found"})])
      {:ok, report} = Audit.run(cwd: dir)
      md = Audit.render(report)

      assert md =~ "Total guarded actions"
      assert md =~ "blocked"
      assert md =~ "secret found"
    end

    test "signposts truncation", %{tmp_dir: dir} do
      write_trail(dir, for(_ <- 1..5, do: entry(%{"action" => "blocked"})))
      {:ok, report} = Audit.run(cwd: dir, limit: 2)

      assert Audit.render(report) =~ "Showing 2 of 5 findings"
    end

    test "shows the since window when one was applied", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{})])
      {:ok, report} = Audit.run(cwd: dir, since: "2025-01-01T00:00:00Z")

      assert Audit.render(report) =~ "Entries at or after 2025-01-01T00:00:00Z"
    end

    test "escapes pipes so the table stays well-formed", %{tmp_dir: dir} do
      write_trail(dir, [entry(%{"action" => "blocked", "reason" => "a | b"})])
      {:ok, report} = Audit.run(cwd: dir)

      assert Audit.render(report) =~ "a \\| b"
    end
  end
end

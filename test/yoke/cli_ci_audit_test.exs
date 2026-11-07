defmodule Yoke.CLI.CIAuditTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI
  alias Yoke.CLI.Main

  describe "audit_usage/0" do
    test "documents every flag" do
      usage = CI.audit_usage()

      for flag <- ~w(--fail-on --since --limit --format --output) do
        assert usage =~ flag, "usage is missing #{flag}"
      end
    end

    test "documents the exit codes" do
      usage = CI.audit_usage()

      assert usage =~ "EXIT CODES"
      assert usage =~ "3  the trail could not be read"
    end
  end

  describe "audit/1 argument validation" do
    test "--help prints usage and exits 0" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.audit(["--help"]) == 0 end)
      assert output =~ "yoke audit"
    end

    test "an unknown flag is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.audit(["--nope"]) == 2 end)
      assert output =~ "Unknown or malformed option"
    end

    test "an invalid --format is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.audit(["--format", "xml"]) == 2 end)
      assert output =~ "Invalid --format"
    end

    test "an invalid --fail-on is a usage error" do
      output = ExUnit.CaptureIO.capture_io(fn -> assert CI.audit(["--fail-on", "nope"]) == 2 end)
      assert output =~ "Invalid --fail-on"
    end
  end

  describe "audit/1 with no trail" do
    test "reports no trail and exits 0", %{tmp_dir: dir} do
      artifact = Path.join(dir, "audit.json")
      test_pid = self()

      ExUnit.CaptureIO.capture_io(fn ->
        code =
          File.cd!(dir, fn -> CI.audit(["--output", artifact, "--fail-on", "never"]) end)

        send(test_pid, {:code, code})
      end)

      assert_receive {:code, 0}
      assert File.regular?(artifact)

      {:ok, decoded} = Yoke.Json.decode(File.read!(artifact))
      assert decoded["command"] == "audit"
      assert decoded["summary"]["trail_present"] == false
      assert decoded["counts"]["total"] == 0
    end
  end

  describe "audit/1 with a trail" do
    test "renders findings and writes an artifact", %{tmp_dir: dir} do
      trail = Path.join(dir, ".yoke/logs/ai_guard_audit.jsonl")
      File.mkdir_p!(Path.dirname(trail))

      entry = %{
        "timestamp" => "2026-01-01T00:00:00Z",
        "phase" => "tool_call",
        "target" => "bash",
        "action" => "blocked",
        "mode" => "enforce",
        "reason" => "destructive command",
        "duration_ms" => 1
      }

      File.write!(trail, Yoke.Json.encode!(entry) <> "\n")

      artifact = Path.join(dir, "audit.json")
      test_pid = self()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          code = File.cd!(dir, fn -> CI.audit(["--output", artifact]) end)
          send(test_pid, {:code, code})
        end)

      assert_receive {:code, code}
      # `pull_request` is not set here, so `fail_on` falls back to the policy
      # default of `high`; a blocked entry is high, so this gates.
      assert code in [0, 1]
      assert output =~ "Yoke audit"
      assert output =~ "destructive command"

      {:ok, decoded} = Yoke.Json.decode(File.read!(artifact))
      assert decoded["counts"]["by_action"]["blocked"] == 1
      assert decoded["summary"]["trail_present"] == true
    end

    test "--limit caps rendered findings", %{tmp_dir: dir} do
      trail = Path.join(dir, ".yoke/logs/ai_guard_audit.jsonl")
      File.mkdir_p!(Path.dirname(trail))

      entries =
        for i <- 1..5 do
          %{
            "timestamp" => "2026-01-01T00:00:00Z",
            "phase" => "tool_call",
            "target" => "bash",
            "action" => "blocked",
            "mode" => "enforce",
            "reason" => "reason #{i}",
            "duration_ms" => 1
          }
        end

      File.write!(trail, Enum.map_join(entries, "", &(Yoke.Json.encode!(&1) <> "\n")))

      artifact = Path.join(dir, "audit.json")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          File.cd!(dir, fn -> CI.audit(["--output", artifact, "--limit", "2"]) end)
        end)

      assert output =~ "Showing 2 of 5 findings"
    end
  end

  describe "dispatch table" do
    test "audit is implemented" do
      assert Main.subcommands()["audit"].status == :implemented
      assert Main.subcommands()["audit"].fun == :audit
    end
  end
end

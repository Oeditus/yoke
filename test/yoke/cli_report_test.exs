defmodule Yoke.CLI.ReportTest do
  @moduledoc """
  `yoke report` reads a review artifact and uploads it (`docs/YAAS.md` §5.1).

  The exit-code contract is the point of this module: an upload that did not
  happen must exit `0`, because the review it describes already ran and gated
  correctly. Only a local, operator-fixable problem exits `3`.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.Main
  alias Yoke.CLI.Report

  setup do
    prior_endpoint = System.get_env("YOKE_CLOUD_ENDPOINT")
    prior_token = System.get_env("YOKE_CLOUD_TOKEN")
    System.delete_env("YOKE_CLOUD_ENDPOINT")
    System.delete_env("YOKE_CLOUD_TOKEN")

    on_exit(fn ->
      restore("YOKE_CLOUD_ENDPOINT", prior_endpoint)
      restore("YOKE_CLOUD_TOKEN", prior_token)
    end)

    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp run(args, dir) do
    test_pid = self()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        code = File.cd!(dir, fn -> Report.report(args) end)
        send(test_pid, {:code, code})
      end)

    assert_receive {:code, code}
    {code, output}
  end

  defp write_artifact(dir, payload) do
    path = Path.join(dir, "yoke-review.json")
    File.write!(path, Yoke.Json.encode!(payload))
    path
  end

  describe "usage/0" do
    test "documents every flag" do
      usage = Report.usage()

      for flag <- ~w(--upload --artifact --endpoint --token --timeout --format) do
        assert usage =~ flag, "usage is missing #{flag}"
      end
    end

    test "documents the fail-open exit code" do
      assert Report.usage() =~ "EXIT CODES"
      assert Report.usage() =~ "unreachable service exits 0"
    end
  end

  describe "argument validation" do
    test "--help prints usage and exits 0", %{tmp_dir: dir} do
      {code, output} = run(["--help"], dir)

      assert code == 0
      assert output =~ "yoke report"
    end

    test "an unknown flag is a usage error", %{tmp_dir: dir} do
      {code, output} = run(["--nope"], dir)

      assert code == 2
      assert output =~ "Unknown or malformed option"
    end
  end

  describe "missing or unreadable artifact" do
    test "a missing artifact exits 3 with a fixable message", %{tmp_dir: dir} do
      {code, output} = run(["--upload", "--artifact", Path.join(dir, "nope.json")], dir)

      assert code == 3
      assert output =~ "No artifact at"
      assert output =~ "Run `yoke review` first"
    end

    test "a non-object artifact exits 3", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "[1, 2, 3]")

      {code, output} = run(["--upload", "--artifact", path], dir)

      assert code == 3
      assert output =~ "is not a JSON object"
    end
  end

  describe "upload behaviour" do
    test "without --upload nothing is sent and the exit code is 0", %{tmp_dir: dir} do
      path = write_artifact(dir, %{"run_uid" => "abc", "findings" => []})

      {code, output} = run(["--artifact", path], dir)

      assert code == 0
      assert output =~ "Upload skipped"
    end

    test "with --upload but no endpoint configured, exits 0", %{tmp_dir: dir} do
      path = write_artifact(dir, %{"run_uid" => "abc"})

      {code, output} = run(["--upload", "--artifact", path], dir)

      assert code == 0
      assert output =~ "Upload skipped"
    end

    test "an unreachable endpoint exits 0, never 3", %{tmp_dir: dir} do
      path = write_artifact(dir, %{"run_uid" => "abc"})

      # A closed loopback port. The review this artifact describes already
      # succeeded; the upload failing must not change that verdict.
      {code, _output} =
        run(["--upload", "--artifact", path, "--endpoint", "http://127.0.0.1:1"], dir)

      assert code == 0
    end

    test "json format reports the status", %{tmp_dir: dir} do
      path = write_artifact(dir, %{"run_uid" => "abc"})

      {code, output} = run(["--artifact", path, "--format", "json"], dir)

      assert code == 0
      assert {:ok, decoded} = Yoke.Json.decode(String.trim(output))
      assert decoded["status"] == "skipped"
      assert decoded["artifact_path"] == path
    end
  end

  describe "dispatch table" do
    test "report is implemented" do
      assert Main.subcommands()["report"].status == :implemented
      assert Main.subcommands()["report"].fun == :report
    end
  end
end

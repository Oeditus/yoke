defmodule Yoke.CLI.CIActionContractTest do
  @moduledoc """
  `action.yml` passes a common set of flags to **every** subcommand. If one
  command rejects a flag the action always supplies, that command fails with a
  usage error the moment anyone selects it — a bug no per-command test would
  catch, because each command's own tests only exercise its own flags.

  This module asserts the shared contract instead.

  ## Distinguishing a rejected flag from a legitimate failure

  Exit code `2` means "usage error", but several commands also return `2` for
  a legitimate reason (an empty commit range, for instance). Asserting
  `refute code == 2` would therefore produce false failures. Instead, each
  command is run twice — once without the flag and once with it — and the flag
  is only judged rejected if it *changes* the outcome to a usage error.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CLI.CI

  defp commands do
    %{
      "review" => &CI.review/1,
      "lint" => &CI.lint/1,
      "describe" => &CI.describe/1,
      "audit" => &CI.audit/1,
      "run" => &CI.run_workflow/1,
      "rag" => &CI.rag/1
    }
  end

  defp run_capturing(fun, args) do
    test_pid = self()

    ExUnit.CaptureIO.capture_io(fn ->
      code = fun.(args)
      send(test_pid, {:code, code})
    end)

    assert_receive {:code, code}
    code
  end

  describe "the action's shared flag contract" do
    test "every subcommand accepts --output", %{tmp_dir: dir} do
      assert_accepts(["--output", Path.join(dir, "out.json")])
    end

    test "every subcommand accepts --fail-on" do
      assert_accepts(["--fail-on", "never"])
    end

    test "every subcommand accepts --format" do
      assert_accepts(["--format", "json"])
    end
  end

  # A flag is "accepted" when adding it does not turn a non-usage outcome into
  # a usage error. Commands that already fail for their own reasons (an empty
  # range, no provider) are therefore not misreported as rejecting flags.
  defp assert_accepts(extra_args) do
    for {name, fun} <- commands() do
      base_args = args_for(name)

      baseline = run_capturing(fun, base_args)
      with_flag = run_capturing(fun, base_args ++ extra_args)

      refute baseline != 2 and with_flag == 2,
             "#{name} rejected #{inspect(extra_args)} (exit 2), but action.yml supplies it"
    end
  end

  # Minimal arguments that get each command past its own required-argument
  # check, so the flag under test is what decides the outcome.
  defp args_for("run"), do: ["--list"]
  defp args_for("rag"), do: ["--status"]
  defp args_for("audit"), do: []
  defp args_for("lint"), do: ["--tool", "format"]
  defp args_for("describe"), do: ["--base", "HEAD", "--head", "HEAD"]
  defp args_for("review"), do: ["--base", "HEAD", "--head", "HEAD", "--dry-run"]
end

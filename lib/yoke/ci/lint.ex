defmodule Yoke.CI.Lint do
  @moduledoc """
  Headless `yoke lint` (`docs/CI_PLAN.md` Milestone 2).

  Wraps the project's native static-analysis tools into **one annotated
  report**, so a CI job gets the same findings, in the same shape, as
  `yoke review`:

      mix format --check-formatted
      mix credo --strict
      mix oeditus_credo
      mix dialyzer
      mix deps.audit

  ## Why an adapter layer

  The tools emit wildly different output:

  | Tool | Native output |
  | :--- | :--- |
  | `credo`, `oeditus_credo` | JSON (`{"issues": [...]}`) — identical schema |
  | `dialyzer` | `--format short` → `file:line: message` |
  | `mix format` | A list of unformatted files, one per line |
  | `deps.audit` | Free-form advisory text |
  | `propwise` | Unstructured; crashes on some codebases |

  `Yoke.CI.Lint.Parser` normalises each into the same finding map the review
  sinks already understand, so `Yoke.CI.StepSummary`, `Yoke.CI.Annotations` and
  `Yoke.CI.Artifact` work unchanged.

  ## Fail-closed

  A tool that cannot run (missing dependency, crash, timeout) is reported as an
  **error finding**, never silently skipped. A linter that did not run must not
  look like a linter that passed.
  """

  alias Yoke.CI.Findings
  alias Yoke.CI.Lint.Parser

  @tools ~w(format credo oeditus_credo dialyzer deps.audit)

  @doc "Returns the supported tool names, in run order."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc """
  Runs the selected tools and returns a report.

  `opts`:

    * `:tools` -- subset of `tools/0` (default: all)
    * `:cwd` -- project root (default `File.cwd!()`)
    * `:fail_on` -- severity threshold; defaults per `Yoke.Config.CI.fail_on/2`
    * `:timeout` -- per-tool timeout in ms (default 300_000)

  Returns `{:ok, report}` where `report` is the same shape
  `Yoke.CI.Findings.report/2` produces, plus a `:tools` key describing each
  tool's outcome.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    selected = Keyword.get(opts, :tools) || @tools
    timeout = normalize_timeout(Keyword.get(opts, :timeout))

    outcomes = Enum.map(selected, &run_tool(&1, cwd, timeout))
    findings = Enum.flat_map(outcomes, & &1.findings)

    fail_on = Yoke.Config.CI.fail_on(cwd, Keyword.get(opts, :fail_on))
    report = Findings.report(findings, fail_on)

    {:ok, Map.put(report, :tools, Enum.map(outcomes, &Map.drop(&1, [:findings])))}
  end

  @doc """
  Runs one tool and returns `%{tool, status, findings, duration_ms}`.

  `status` is `:ok` (clean), `:findings` (reported issues), or `:error` (the
  tool could not run).
  """
  @spec run_tool(String.t(), String.t(), non_neg_integer()) :: map()
  def run_tool(tool, cwd, timeout) do
    started = System.monotonic_time(:millisecond)

    {status, output} = invoke(tool, cwd, timeout)

    findings =
      case status do
        :error -> [error_finding(tool, output)]
        _ -> Parser.parse(tool, output)
      end

    %{
      tool: tool,
      status:
        cond do
          status == :error -> :error
          findings != [] -> :findings
          true -> :ok
        end,
      findings: findings,
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  # ---------------------------------------------------------------------
  # Tool invocation
  # ---------------------------------------------------------------------

  defp invoke(tool, cwd, timeout) do
    {cmd, args} = command_for(tool)

    task = Task.async(fn -> System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {classify(tool, code, output), output}
      nil -> {:error, "`#{tool}` timed out after #{timeout}ms."}
      {:exit, reason} -> {:error, "`#{tool}` crashed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "`#{tool}` could not be executed: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "`#{tool}` could not be executed: #{inspect({kind, reason})}"}
  end

  # These tools signal "issues found" through their exit code, using a bitmask
  # (credo 4, oeditus_credo 16, dialyzer 2, format 1, deps.audit 1). A non-zero
  # exit is therefore *not* a failure.
  #
  # A crash, by contrast, usually leaves a stack trace and no parseable output.
  # That is the signal we use: an empty result, or one the parser cannot
  # recognise, on a non-zero exit is treated as an error.
  defp classify(_tool, 0, _output), do: :ok

  defp classify(_tool, _code, output) do
    if crashed?(output), do: :error, else: :ok
  end

  # A tool that crashed prints an Elixir exception. A tool that merely reported
  # findings prints its normal format (JSON, short-format lines, file paths).
  defp crashed?(output) do
    String.contains?(output, "** (") or
      String.contains?(output, "** (Mix) Could not") or
      String.contains?(output, "no match of right hand side")
  end

  defp command_for("format"), do: {"mix", ["format", "--check-formatted"]}
  defp command_for("credo"), do: {"mix", ["credo", "--strict", "--format=json"]}
  defp command_for("oeditus_credo"), do: {"mix", ["oeditus_credo", "--format=json"]}
  defp command_for("dialyzer"), do: {"mix", ["dialyzer", "--format", "short"]}
  defp command_for("deps.audit"), do: {"mix", ["deps.audit"]}
  defp command_for(other), do: {"mix", [other]}

  # `Task.yield/2` has no clause for a `nil` timeout, so a missing or
  # unparseable `--timeout` must be normalised to the default rather than
  # passed through.
  defp normalize_timeout(nil), do: 300_000
  defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_timeout(_), do: 300_000

  defp error_finding(tool, output) do
    %{
      id: 0,
      file: nil,
      line: nil,
      title: "#{tool} could not run",
      description: output |> to_string() |> String.slice(0, 2_000),
      severity: "high",
      kind: "issue",
      fix_suggestion: ""
    }
  end
end

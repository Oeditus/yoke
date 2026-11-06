defmodule Yoke.CLI.CI do
  @moduledoc """
  The `yoke review` subcommand (`docs/CI_PLAN.md` Phase 1.1).

  Parses the command-line surface, runs `Yoke.CI.Review`, prints the report,
  and returns the process exit code. Kept separate from `Yoke.CLI.Main` so the
  flag parsing and exit-code policy are unit-testable without invoking
  `System.halt/1`.

  ## Flags

  | Flag | Meaning |
  | :--- | :--- |
  | `--base <rev>` | Base revision for a branch review |
  | `--head <rev>` | Head revision (default `HEAD`) |
  | `--pr <number>` | Review a GitHub PR instead of a branch range |
  | `--fail-on <level>` | `high` \\| `medium` \\| `low` \\| `info` \\| `never` |
  | `--format <fmt>` | `markdown` \\| `json` \\| `summary` |
  | `--output <path>` | Artifact path (default `$RUNNER_TEMP/yoke-review.json`) |
  | `--post` | Post the review to the PR via `gh` |
  | `--model <name>` | Model override |
  | `--endpoint <url>` | Endpoint override |
  | `--max-cost <usd>` | Hard USD budget for the run |
  | `--dry-run` | Resolve the context and exit without calling the model |

  ## Exit codes

  | Code | Meaning |
  | :--- | :--- |
  | `0` | Review completed; nothing at or above `--fail-on` |
  | `1` | Review completed; at least one finding at or above `--fail-on` |
  | `2` | Usage error (bad flag, missing revision) |
  | `3` | Infrastructure failure (model error, posting failed, invalid output) |
  """

  alias Yoke.CI.Findings
  alias Yoke.CI.Review
  alias Yoke.CLI.Formatter

  @switches [
    base: :string,
    head: :string,
    pr: :string,
    fail_on: :string,
    format: :string,
    output: :string,
    post: :boolean,
    model: :string,
    endpoint: :string,
    max_cost: :string,
    dry_run: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @formats ~w(markdown json summary)

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke lint`."
  @spec lint([String.t()]) :: non_neg_integer()
  def lint(args) do
    switches = [
      tool: :keep,
      fail_on: :string,
      format: :string,
      output: :string,
      timeout: :string,
      help: :boolean
    ]

    {opts, _extra, invalid} = OptionParser.parse(args, strict: switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(lint_usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      (message = validate_format(opts[:format])) != nil ->
        usage_error(message)

      (message = validate_fail_on(opts[:fail_on])) != nil ->
        usage_error(message)

      (message = validate_tools(Keyword.get_values(opts, :tool))) != nil ->
        usage_error(message)

      true ->
        run_lint(opts)
    end
  end

  @doc "Returns the usage text for `yoke lint`."
  @spec lint_usage() :: String.t()
  def lint_usage do
    """
    yoke lint — run the project's static analysis tools as one annotated report

    USAGE:
      yoke lint [options]

    OPTIONS:
      --tool <name>       Run only this tool (repeatable). One of:
                          #{Enum.join(Yoke.CI.Lint.tools(), ", ")}
      --fail-on <level>   high | medium | low | info | never (default: high on
                          pull_request, never on push)
      --format <fmt>      markdown | json | summary (default: summary)
      --output <path>     Artifact path (default: $RUNNER_TEMP/yoke-lint.json)
      --timeout <ms>      Per-tool timeout (default: 300000)
      -h, --help          Show this help

    EXIT CODES:
      0  all tools ran, nothing at or above --fail-on
      1  findings at or above --fail-on
      2  usage error
      3  a tool could not run
    """
  end

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke describe`."
  @spec describe([String.t()]) :: non_neg_integer()
  def describe(args) do
    switches = [
      base: :string,
      head: :string,
      pr: :string,
      model: :string,
      endpoint: :string,
      max_cost: :string,
      output: :string,
      format: :string,
      # Accepted for parity with the other subcommands, because `action.yml`
      # passes `--fail-on` to every command. A summary has no findings to gate
      # on, so the value is ignored rather than rejected.
      fail_on: :string,
      help: :boolean
    ]

    {opts, _extra, invalid} = OptionParser.parse(args, strict: switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(describe_usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      (message = validate_format(opts[:format])) != nil ->
        usage_error(message)

      true ->
        run_describe(opts)
    end
  end

  @doc "Returns the usage text for `yoke describe`."
  @spec describe_usage() :: String.t()
  def describe_usage do
    """
    yoke describe — summarize a commit range or pull request in one model call

    USAGE:
      yoke describe --base <rev> [--head <rev>] [options]
      yoke describe --pr <number> [options]

    OPTIONS:
      --base <rev>        Base revision
      --head <rev>        Head revision (default: HEAD)
      --pr <number>       Describe a GitHub PR instead of a branch range
      --model <name>      Model override
      --endpoint <url>    Endpoint override
      --max-cost <usd>    Hard USD budget for this run
      --format <fmt>      markdown | json | summary (default: summary)
      --output <path>     Artifact path (default: $RUNNER_TEMP/yoke-describe.json)
      -h, --help          Show this help

    EXIT CODES:
      0  summary produced
      2  usage error
      3  the summary could not be produced (provider error, empty diff)
    """
  end

  defp run_describe(opts) do
    describe_opts =
      [
        base: opts[:base],
        head: opts[:head] || "HEAD",
        pr: opts[:pr],
        model: opts[:model],
        endpoint: opts[:endpoint],
        max_cost: parse_cost(opts[:max_cost])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Yoke.CI.Describe.run(describe_opts) do
      {:ok, result} ->
        emit_description(result, opts)
        0

      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        3
    end
  end

  defp emit_description(result, opts) do
    summary = result.summary <> "\n"

    # In CI the description belongs on the run page, not buried in the log.
    _ = Yoke.CI.StepSummary.write("## Yoke describe\n\n" <> summary)

    case opts[:format] do
      "json" ->
        IO.puts(
          Yoke.Json.encode!(%{
            "summary" => result.summary,
            "identity" => stringify(result.identity),
            "usage" => stringify(result.usage)
          })
        )

      _ ->
        IO.write(summary)
    end

    artifact =
      opts[:output] ||
        Path.join(System.get_env("RUNNER_TEMP") || System.tmp_dir!(), "yoke-describe.json")

    _ =
      Yoke.CI.Artifact.write(
        %{
          "schema_version" => 1,
          "run_uid" => Yoke.CI.Review.run_uid(),
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "command" => "describe",
          "identity" => stringify(result.identity),
          "usage" => stringify(result.usage),
          "summary" => result.summary
        },
        artifact
      )

    IO.puts(Formatter.format_info("Artifact: #{artifact}"))
  end

  defp parse_cost(nil), do: nil

  defp parse_cost(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {cost, _} -> cost
      :error -> nil
    end
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke audit`."
  @spec audit([String.t()]) :: non_neg_integer()
  def audit(args) do
    switches = [
      fail_on: :string,
      format: :string,
      output: :string,
      since: :string,
      limit: :string,
      help: :boolean
    ]

    {opts, _extra, invalid} = OptionParser.parse(args, strict: switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(audit_usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      (message = validate_format(opts[:format])) != nil ->
        usage_error(message)

      (message = validate_fail_on(opts[:fail_on])) != nil ->
        usage_error(message)

      true ->
        run_audit(opts)
    end
  end

  @doc "Returns the usage text for `yoke audit`."
  @spec audit_usage() :: String.t()
  def audit_usage do
    """
    yoke audit — emit the AI Guard audit trail as a CI artifact and step summary

    USAGE:
      yoke audit [options]

    Reads .yoke/logs/ai_guard_audit.jsonl and reports every guarded LLM call
    and tool execution from this run, so a reviewer can tell after the fact
    what the agent did and what the guard stopped.

    OPTIONS:
      --fail-on <level>   high | medium | low | info | never (default: high on
                          pull_request, never on push)
      --since <iso8601>   Only include entries at or after this timestamp.
                          Defaults to the job's start time when the runner
                          provides one, so a trail accumulated over many local
                          runs does not swamp the report.
      --limit <n>         Maximum findings to render (default 50). The artifact
                          always contains every entry.
      --format <fmt>      markdown | json | summary (default: summary)
      --output <path>     Artifact path (default: $RUNNER_TEMP/yoke-audit.json)
      -h, --help          Show this help

    EXIT CODES:
      0  trail read; nothing at or above --fail-on
      1  blocked/flagged actions at or above --fail-on
      2  usage error
      3  the trail could not be read
    """
  end

  defp run_audit(opts) do
    cwd = File.cwd!()

    audit_opts =
      [
        cwd: cwd,
        fail_on: opts[:fail_on],
        since: opts[:since] || job_started_at(),
        limit: parse_limit(opts[:limit])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Yoke.CI.Audit.run(audit_opts) do
      {:ok, report} ->
        summary = Yoke.CI.Audit.render(report)
        _ = Yoke.CI.StepSummary.write(summary)

        artifact =
          opts[:output] ||
            Path.join(System.get_env("RUNNER_TEMP") || System.tmp_dir!(), "yoke-audit.json")

        _ =
          Yoke.CI.Artifact.write(
            %{
              "schema_version" => 1,
              "run_uid" => Yoke.CI.Review.run_uid(),
              "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "command" => "audit",
              "summary" => %{
                "findings_count" => report.findings_count,
                "max_severity" => report.max_severity,
                "fail_on" => report.fail_on,
                "failed" => report.failed?,
                "trail_present" => report.trail_present?
              },
              "counts" => report.counts,
              "entries" => report.entries
            },
            artifact
          )

        emit_audit(report, summary, artifact, opts[:format] || "summary")
        Findings.exit_code(report)

      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        3
    end
  end

  # GitHub does not expose a job start timestamp directly, so the closest
  # stable signal is the runner's temp-dir creation, which is per-job. Falling
  # back to `nil` (no filtering) is safer than guessing wrongly and hiding
  # evidence.
  defp job_started_at do
    case System.get_env("YOKE_AUDIT_SINCE") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp emit_audit(report, summary, artifact, format) do
    case format do
      "json" ->
        IO.puts(
          Yoke.Json.encode!(%{
            "findings_count" => report.findings_count,
            "max_severity" => report.max_severity,
            "fail_on" => report.fail_on,
            "failed" => report.failed?,
            "trail_present" => report.trail_present?,
            "counts" => report.counts,
            "artifact_path" => artifact
          })
        )

      _ ->
        IO.write(summary)
    end

    IO.puts(Formatter.format_info("Artifact: #{artifact}"))
  end

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke run`."
  @spec run_workflow([String.t()]) :: non_neg_integer()
  def run_workflow(args) do
    switches = [
      prompt: :string,
      list: :boolean,
      output: :string,
      # Accepted for parity with the other subcommands, because `action.yml`
      # passes `--format` and `--fail-on` to every command. A workflow either
      # completes or halts, so neither applies; they are ignored.
      format: :string,
      fail_on: :string,
      help: :boolean
    ]

    {opts, extra, invalid} =
      OptionParser.parse(args, strict: switches, aliases: [p: :prompt, l: :list, h: :help])

    cond do
      opts[:help] ->
        IO.puts(run_usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      opts[:list] ->
        list_workflows()

      true ->
        case extra do
          [workflow | _] -> execute_workflow(workflow, opts)
          [] -> usage_error("Missing workflow name. Run `yoke run --help`.")
        end
    end
  end

  @doc "Returns the usage text for `yoke run`."
  @spec run_usage() :: String.t()
  def run_usage do
    """
    yoke run <workflow> — run a workflow definition headlessly

    USAGE:
      yoke run <workflow> [--prompt <text>] [options]
      yoke run --list

    In CI the workflow engine degrades cleanly: `task_split` collapses to a
    single task (no git worktrees), and `branch` halts rather than creating a
    branch on a runner.

    OPTIONS:
      -p, --prompt <text>  Seed the workflow with a task description
      -l, --list           List available workflow definitions and exit
          --output <path>  Artifact path (default: $RUNNER_TEMP/yoke-run.json)
      -h, --help           Show this help

    EXIT CODES:
      0  workflow completed
      1  workflow halted (a step declined to continue)
      2  usage error
      3  the workflow could not run
    """
  end

  defp list_workflows do
    {:ok, definitions} = Yoke.CI.Run.list(File.cwd!())

    if definitions == [] do
      IO.puts(Formatter.format_warning("No workflow definitions found."))
    else
      IO.puts("Available workflows:\n")

      Enum.each(definitions, fn def_ ->
        IO.puts("  #{def_.name}  (#{def_.source})")
        if def_.description, do: IO.puts("    #{def_.description}")
      end)
    end

    0
  end

  defp execute_workflow(workflow, opts) do
    case Yoke.CI.Run.run(workflow, seed_prompt: opts[:prompt] || "", cwd: File.cwd!()) do
      {:ok, %{status: :completed} = result} ->
        emit_run_result(result, opts)
        0

      {:ok, %{status: :halted} = result} ->
        IO.puts(Formatter.format_warning("Workflow halted: #{result.reason}"))
        emit_run_result(result, opts)
        1

      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        3
    end
  end

  defp emit_run_result(result, opts) do
    artifact =
      opts[:output] ||
        Path.join(System.get_env("RUNNER_TEMP") || System.tmp_dir!(), "yoke-run.json")

    _ =
      Yoke.CI.Artifact.write(
        %{
          "schema_version" => 1,
          "run_uid" => Yoke.CI.Review.run_uid(),
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "command" => "run",
          "workflow_run_id" => result.run_id,
          "status" => to_string(result.status),
          "reason" => Map.get(result, :reason),
          "steps" => result.steps
        },
        artifact
      )

    IO.puts(Formatter.format_info("Artifact: #{artifact}"))
  end

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke rag`."
  @spec rag([String.t()]) :: non_neg_integer()
  def rag(args) do
    switches = [
      index: :boolean,
      status: :boolean,
      strict: :boolean,
      timeout: :string,
      # Accepted for parity with the other subcommands, because `action.yml`
      # passes `--output` to every command. `rag` has no report to write, so
      # the value is ignored rather than rejected.
      output: :string,
      # Likewise for `--format`: `rag` emits a fixed human-readable status.
      format: :string,
      # And `--fail-on`: Ragex availability is not a finding to gate on.
      fail_on: :string,
      help: :boolean
    ]

    {opts, _extra, invalid} = OptionParser.parse(args, strict: switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(rag_usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      opts[:status] ->
        report_rag_status()

      true ->
        run_rag_index(opts)
    end
  end

  @doc "Returns the usage text for `yoke rag`."
  @spec rag_usage() :: String.t()
  def rag_usage do
    """
    yoke rag — build or inspect Ragex code intelligence (optional)

    USAGE:
      yoke rag --index [--strict] [--timeout <ms>]
      yoke rag --status

    Ragex builds a symbol/reference graph that makes review tools more
    effective. It is opt-in because it spawns a dllb-server and may download an
    embedding model -- 2-4 minutes on a cold runner. Cache .ragex between runs.

    Ragex is an enhancement, not a dependency: if it cannot start, this command
    reports why and exits 0, because a review that would merely have been
    slower must not fail. Pass --strict to exit non-zero instead.

    OPTIONS:
          --index          Start Ragex and wait for indexing to finish
          --status         Report whether Ragex is running and whether a graph exists
          --strict         Exit 3 when Ragex is unavailable
          --timeout <ms>   Indexing timeout (default 600000)
      -h, --help           Show this help

    EXIT CODES:
      0  ready (or unavailable, without --strict)
      2  usage error
      3  unavailable with --strict
    """
  end

  defp report_rag_status do
    {:ok, status} = Yoke.CI.Rag.status(File.cwd!())

    IO.puts(
      Formatter.format_info(
        "Ragex running: #{status.running} · graph present: #{status.graph_present}"
      )
    )

    0
  end

  defp run_rag_index(opts) do
    {:ok, result} =
      Yoke.CI.Rag.index(
        cwd: File.cwd!(),
        timeout: parse_timeout(opts[:timeout]) || 600_000
      )

    case result.status do
      :ready ->
        IO.puts(Formatter.format_success("Ragex is ready."))
        0

      :unavailable ->
        IO.puts(Formatter.format_warning("Ragex unavailable: #{result.reason}"))

        if opts[:strict] do
          IO.puts(Formatter.format_error("--strict requested; failing the run."))
          3
        else
          IO.puts(
            Formatter.format_info(
              "Continuing without Ragex; review tools will fall back to plain search."
            )
          )

          0
        end
    end
  end

  # ---------------------------------------------------------------------
  # lint
  # ---------------------------------------------------------------------

  defp run_lint(opts) do
    cwd = File.cwd!()

    lint_opts =
      [
        cwd: cwd,
        fail_on: opts[:fail_on],
        timeout: parse_timeout(opts[:timeout]) || 300_000
      ]
      |> maybe_put(:tools, nonempty(normalize_tools(Keyword.get_values(opts, :tool))))

    {:ok, report} = Yoke.CI.Lint.run(lint_opts)

    identity = %{base_sha: nil, head_sha: nil, pr_number: nil, repository: nil}
    summary = Yoke.CI.StepSummary.render(report, title: "Yoke lint", identity: identity)

    _ = Yoke.CI.StepSummary.write(summary)
    _ = Yoke.CI.Annotations.emit(report)

    artifact_path =
      opts[:output] ||
        Path.join(
          System.get_env("RUNNER_TEMP") || System.tmp_dir!(),
          "yoke-lint.json"
        )

    _ =
      Yoke.CI.Artifact.write(
        %{
          "schema_version" => 1,
          "run_uid" => Yoke.CI.Review.run_uid(),
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "command" => "lint",
          "summary" => %{
            "findings_count" => report.findings_count,
            "max_severity" => report.max_severity,
            "fail_on" => report.fail_on,
            "failed" => report.failed?
          },
          "tools" => report.tools,
          "findings" => Enum.map(report.findings, &stringify_finding/1)
        },
        artifact_path
      )

    print_lint_result(report, summary, artifact_path, opts[:format] || "summary")
    lint_exit_code(report)
  end

  defp print_lint_result(report, summary, artifact_path, format) do
    case format do
      "json" ->
        IO.puts(
          Yoke.Json.encode!(%{
            "findings_count" => report.findings_count,
            "max_severity" => report.max_severity,
            "fail_on" => report.fail_on,
            "failed" => report.failed?,
            "tools" => report.tools,
            "artifact_path" => artifact_path
          })
        )

      _ ->
        IO.write(summary)
    end

    IO.puts(Formatter.format_info("Artifact: #{artifact_path}"))
  end

  # A tool that could not run is an infrastructure failure (3), not a finding
  # (1): a linter that did not run must not look like a linter that passed.
  defp lint_exit_code(report) do
    if Enum.any?(report.tools, &(&1.status == :error)) do
      3
    else
      Findings.exit_code(report)
    end
  end

  defp parse_timeout(nil), do: nil

  defp parse_timeout(value) do
    case Integer.parse(String.trim(value)) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  # Findings are plain maps (not structs), so `Map.from_struct/1` does not
  # apply. Convert to a JSON-friendly map with string keys explicitly.
  defp stringify_finding(finding) when is_map(finding) do
    Map.new(finding, fn {k, v} -> {to_string(k), v} end)
  end

  # `OptionParser` with `:keep` returns a bare value when the flag appears
  # once and a list when it repeats, so normalise before validating.
  defp validate_tools(nil), do: nil

  defp validate_tools(tools) do
    unknown = Enum.reject(normalize_tools(tools), &(&1 in Yoke.CI.Lint.tools()))

    if unknown == [] do
      nil
    else
      "Unknown --tool #{inspect(unknown)}; expected one of " <>
        "#{Enum.join(Yoke.CI.Lint.tools(), ", ")}."
    end
  end

  defp normalize_tools(tool) when is_binary(tool), do: [tool]
  defp normalize_tools(tools) when is_list(tools), do: tools
  defp normalize_tools(_), do: []

  # ---------------------------------------------------------------------
  # review
  # ---------------------------------------------------------------------

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table."
  @spec review([String.t()]) :: non_neg_integer()
  def review(args) do
    # `strict:` (not `switches:`) so an unknown flag lands in `invalid` and is
    # reported as a usage error instead of being silently ignored.
    {opts, _extra, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      (message = validate_format(opts[:format])) != nil ->
        usage_error(message)

      (message = validate_fail_on(opts[:fail_on])) != nil ->
        usage_error(message)

      true ->
        run_review(opts)
    end
  end

  @doc "Returns the usage text for `yoke review`."
  @spec usage() :: String.t()
  def usage do
    """
    yoke review — review a commit range or pull request, headlessly

    USAGE:
      yoke review --base <rev> [--head <rev>] [options]
      yoke review --pr <number> [options]

    OPTIONS:
      --base <rev>        Base revision for a branch review
      --head <rev>        Head revision (default: HEAD)
      --pr <number>       Review a GitHub PR instead of a branch range
      --fail-on <level>   high | medium | low | info | never (default: high on
                          pull_request, never on push)
      --format <fmt>      markdown | json | summary (default: summary)
      --output <path>     Artifact path (default: $RUNNER_TEMP/yoke-review.json)
      --post              Post the review to the PR via `gh`
      --model <name>      Model override
      --endpoint <url>    Endpoint override
      --max-cost <usd>    Hard USD budget for this run
      --dry-run           Resolve the review context and exit without calling the model
      -h, --help          Show this help

    EXIT CODES:
      0  reviewed, nothing at or above --fail-on
      1  reviewed, findings at or above --fail-on
      2  usage error
      3  infrastructure failure
    """
  end

  @doc """
  Builds the option keyword list for `Yoke.CI.Review.run/1` from parsed flags.

  Exposed for tests: this is the pure part of the command.
  """
  @spec review_opts(keyword()) :: keyword()
  def review_opts(opts) do
    [
      base: opts[:base],
      head: opts[:head] || "HEAD",
      pr: opts[:pr],
      fail_on: opts[:fail_on],
      output: opts[:output],
      post: opts[:post] || false,
      model: opts[:model],
      endpoint: opts[:endpoint]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Maps a completed review result onto a process exit code.

  This is the single place the exit-code policy lives, so `--fail-on` can
  never be interpreted two different ways.
  """
  @spec exit_code_for({:ok, map()} | {:error, String.t()}) :: non_neg_integer()
  def exit_code_for({:ok, %{report: report}}), do: Findings.exit_code(report)
  def exit_code_for({:error, _}), do: 3

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp run_review(opts) do
    review_opts = review_opts(opts)

    if opts[:dry_run] do
      dry_run(review_opts)
    else
      result = Review.run(review_opts)
      print_result(result, opts[:format] || "summary")
      exit_code_for(result)
    end
  end

  defp dry_run(review_opts) do
    cwd = File.cwd!()

    case Review.resolve_context(review_opts, cwd) do
      {:ok, context} ->
        IO.puts(
          Formatter.format_info(
            "Would review #{context.base_sha}...#{context.head_sha} " <>
              "(#{byte_size(context.raw_diff)} bytes of diff)"
          )
        )

        0

      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        2
    end
  end

  defp print_result({:ok, result}, format) do
    case format do
      "json" -> IO.puts(Yoke.Json.encode!(json_view(result)))
      "markdown" -> IO.write(result.summary)
      _ -> IO.write(result.summary)
    end

    IO.puts(Formatter.format_info("Artifact: #{result.artifact_path}"))
  end

  defp print_result({:error, reason}, _format) do
    IO.puts(Formatter.format_error(reason))
  end

  defp json_view(result) do
    %{
      "findings_count" => result.report.findings_count,
      "max_severity" => result.report.max_severity,
      "fail_on" => result.report.fail_on,
      "failed" => result.report.failed?,
      "exit_code" => result.exit_code,
      "artifact_path" => result.artifact_path,
      "identity" => result.identity
    }
  end

  defp usage_error(message) do
    IO.puts(Formatter.format_error(message))
    IO.puts(usage())
    2
  end

  defp validate_format(nil), do: nil

  defp validate_format(format) do
    if format in @formats do
      nil
    else
      "Invalid --format #{inspect(format)}; expected one of #{Enum.join(@formats, ", ")}."
    end
  end

  defp validate_fail_on(nil), do: nil

  defp validate_fail_on(level) do
    if level in Findings.thresholds() do
      nil
    else
      "Invalid --fail-on #{inspect(level)}; expected one of " <>
        "#{Enum.join(Findings.thresholds(), ", ")}."
    end
  end
end

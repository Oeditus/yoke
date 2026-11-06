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

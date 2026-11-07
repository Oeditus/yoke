defmodule Yoke.CI.Audit do
  @moduledoc """
  Headless `yoke audit` — the `Yoke.AIGuard` audit trail as a CI artifact
  (`docs/CI_PLAN.md` Milestone 2).

  `Yoke.AIGuard` already records every guarded LLM call and tool execution to
  `.yoke/logs/ai_guard_audit.jsonl`. This command turns that raw JSONL into
  something a reviewer can actually read after the run: a summary, a table of
  anything that was flagged or blocked, and a JSON artifact for tooling.

  ## Why this matters

  A CI review is an opaque model call plus a pile of tool executions. Without
  an audit trail there is no way to answer "did anything try to exfiltrate a
  secret?" or "did the guard block anything?" after the fact. This command is
  what makes those questions answerable.

  ## What it reports

    * **Counts** by phase (`input` / `output` / `tool_call`) and by action
      (`pass` / `flagged` / `blocked`).
    * **Findings** for anything that was `flagged` or `blocked`, as the same
      finding shape the other sinks render — so `--fail-on` works identically.
    * **The raw trail**, embedded in the artifact.

  A `blocked` entry is `high` severity; a `flagged` entry is `medium`. Passes
  are counted but never reported as findings: an audit trail is mostly
  evidence that things were fine.
  """

  alias Yoke.AIGuard
  alias Yoke.CI.Findings

  @audit_file ".yoke/logs/ai_guard_audit.jsonl"

  @doc "Returns the repo-relative audit trail path."
  @spec audit_path() :: String.t()
  def audit_path, do: @audit_file

  @doc """
  Reads the audit trail for `cwd`.

  Returns `{:ok, entries}` (possibly empty when nothing was guarded) or
  `{:error, reason}`.
  """
  @spec read(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read(cwd \\ ".") do
    path = Path.join(cwd, @audit_file)

    if File.regular?(path) do
      entries =
        path
        |> File.stream!()
        |> Enum.flat_map(&decode_line/1)

      {:ok, entries}
    else
      {:ok, []}
    end
  rescue
    e -> {:error, "Cannot read the audit trail: #{Exception.message(e)}"}
  end

  @doc """
  Builds a report from the audit trail.

  `opts`:

    * `:cwd` -- repository root (default `File.cwd!()`)
    * `:fail_on` -- severity threshold; defaults per `Yoke.Config.CI.fail_on/2`
    * `:since` -- only include entries at or after this ISO 8601 timestamp.
      In CI this is normally the job's start time, so a trail accumulated over
      many local runs does not swamp the report.
    * `:limit` -- maximum number of findings to report (default 50). The
      artifact always carries every entry; this only caps the rendered table,
      because a 300-row step summary is unreadable.

  Returns `{:ok, report}` in the shape the sinks expect, plus `:counts`,
  `:entries`, `:truncated?` and `:since`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, all_entries} <- read(cwd) do
      entries = filter_since(all_entries, since)
      all_findings = Enum.flat_map(entries, &entry_findings/1)
      fail_on = Yoke.Config.CI.fail_on(cwd, Keyword.get(opts, :fail_on))

      findings = Enum.take(all_findings, limit)
      report = Findings.report(findings, fail_on)

      {:ok,
       Map.merge(report, %{
         counts: counts(entries),
         entries: entries,
         trail_present?: all_entries != [],
         truncated?: length(all_findings) > length(findings),
         total_findings: length(all_findings),
         since: since
       })}
    end
  end

  @doc """
  Counts entries by phase and by action.

  Always returns every bucket, including zeros, so a summary table has stable
  rows whether or not anything happened.
  """
  @spec counts([map()]) :: map()
  def counts(entries) when is_list(entries) do
    %{
      total: length(entries),
      by_phase: %{
        "input" => count_where(entries, "phase", "input"),
        "output" => count_where(entries, "phase", "output"),
        "tool_call" => count_where(entries, "phase", "tool_call")
      },
      by_action: %{
        "pass" => count_where(entries, "action", "pass"),
        "flagged" => count_where(entries, "action", "flagged"),
        "blocked" => count_where(entries, "action", "blocked")
      }
    }
  end

  @doc """
  Renders the audit report as Markdown for `$GITHUB_STEP_SUMMARY`.
  """
  @spec render(map()) :: String.t()
  def render(report) do
    [
      "## Yoke audit",
      "",
      verdict_line(report),
      "",
      window_line(report),
      counts_table(report.counts),
      "",
      findings_section(report)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp decode_line(line) do
    case Yoke.Json.decode(line) do
      {:ok, %{} = map} -> [map]
      _ -> []
    end
  end

  # Entries are appended chronologically, but comparing timestamps is safer
  # than assuming order. An entry without a parseable timestamp is kept: it is
  # more useful to over-report than to silently drop evidence.
  defp filter_since(entries, nil), do: entries

  defp filter_since(entries, since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, cutoff, _offset} ->
        Enum.filter(entries, fn entry ->
          case DateTime.from_iso8601(to_string(entry["timestamp"])) do
            {:ok, at, _} -> DateTime.compare(at, cutoff) != :lt
            _ -> true
          end
        end)

      _ ->
        entries
    end
  end

  # Only `flagged` and `blocked` entries become findings. A `pass` is evidence
  # the guard ran, not something to report.
  defp entry_findings(%{"action" => action} = entry) when action in ["flagged", "blocked"] do
    [
      %{
        id: 0,
        file: nil,
        line: nil,
        title: "#{action}: #{entry["phase"] || "unknown"}",
        description: describe_entry(entry),
        severity: if(action == "blocked", do: "high", else: "medium"),
        kind: "issue",
        fix_suggestion: ""
      }
    ]
  end

  defp entry_findings(_), do: []

  defp describe_entry(entry) do
    target = entry["target"] || "unknown"
    reason = entry["reason"] || "no reason recorded"
    "#{target} — #{reason}"
  end

  defp count_where(entries, key, value) do
    Enum.count(entries, fn entry -> Map.get(entry, key) == value end)
  end

  defp verdict_line(%{trail_present?: false}) do
    "**Result: no audit trail** — nothing was guarded in this run."
  end

  defp verdict_line(%{failed?: true} = report) do
    "**Result: failing** — #{length(report.gating)} guarded action(s) at or above " <>
      "`#{report.fail_on}`."
  end

  defp verdict_line(report) do
    "**Result: passing** — #{report.counts.by_action["blocked"]} blocked, " <>
      "#{report.counts.by_action["flagged"]} flagged, " <>
      "#{report.counts.by_action["pass"]} passed."
  end

  defp counts_table(counts) do
    """
    | | Count |
    | :--- | ---: |
    | Total guarded actions | #{counts.total} |
    | input | #{counts.by_phase["input"]} |
    | output | #{counts.by_phase["output"]} |
    | tool_call | #{counts.by_phase["tool_call"]} |
    | pass | #{counts.by_action["pass"]} |
    | flagged | #{counts.by_action["flagged"]} |
    | blocked | #{counts.by_action["blocked"]} |
    """
  end

  defp findings_section(report) do
    issues = report.issues

    if issues == [] do
      "### Guard findings\n\nNone."
    else
      rows =
        issues
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {finding, idx} ->
          "| #{idx} | `#{finding.severity}` | #{escape(finding.title)} | " <>
            "#{escape(finding.description)} |"
        end)

      footer =
        if Map.get(report, :truncated?, false) do
          "\n\n_Showing #{length(issues)} of #{report.total_findings} findings. " <>
            "The artifact contains every entry._"
        else
          ""
        end

      """
      ### Guard findings

      | # | Severity | Event | Detail |
      | ---: | :--- | :--- | :--- |
      #{rows}#{footer}
      """
    end
  end

  defp window_line(%{since: since}) when is_binary(since) and since != "" do
    "_Entries at or after #{since}._"
  end

  defp window_line(_), do: nil

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  @doc "Returns the number of entries `Yoke.AIGuard` has recorded for `cwd`."
  @spec entry_count(String.t()) :: non_neg_integer()
  def entry_count(cwd \\ ".") do
    case read(cwd) do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  end

  @doc false
  # Re-exported so callers do not need to know which module owns the trail.
  defdelegate audit_log(cwd), to: AIGuard
end

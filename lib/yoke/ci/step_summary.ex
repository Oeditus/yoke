defmodule Yoke.CI.StepSummary do
  @moduledoc """
  Renders a review report as GitHub Actions step summary Markdown
  (`docs/CI_PLAN.md` Phase 1.1).

  The summary is appended to the file named by `$GITHUB_STEP_SUMMARY`, which
  GitHub renders on the workflow run page. When that variable is unset (local
  runs, tests) the rendered Markdown is returned but nothing is written, so the
  same code path is exercised everywhere.

  ## Format

  A one-line verdict, a counts table, then one row per issue and (separately)
  per endorsement. Endorsements are listed **after** issues and are explicitly
  labelled as observations so they are never mistaken for requests for
  changes.
  """

  alias Yoke.CI.Findings

  @doc """
  Renders the summary Markdown for `report`.

  `opts`:

    * `:title` -- heading text (default `"Yoke review"`)
    * `:identity` -- an optional map with `:base_sha`, `:head_sha`, `:pr_number`
      used to caption the report
  """
  @spec render(map(), keyword()) :: String.t()
  def render(report, opts \\ []) do
    title = Keyword.get(opts, :title, "Yoke review")
    identity = Keyword.get(opts, :identity, %{})

    [
      "## #{title}",
      "",
      verdict_line(report),
      "",
      identity_line(identity),
      counts_table(report),
      "",
      issues_section(report.issues),
      endorsements_section(report.endorsements)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Appends `markdown` to `$GITHUB_STEP_SUMMARY`.

  Returns `{:ok, :written}` when the file was written, `{:ok, :skipped}` when
  the variable is unset (not running in Actions), or `{:error, reason}`.
  """
  @spec write(String.t()) :: {:ok, :written | :skipped} | {:error, String.t()}
  def write(markdown) when is_binary(markdown) do
    case System.get_env("GITHUB_STEP_SUMMARY") do
      path when is_binary(path) and path != "" ->
        case File.write(path, markdown, [:append]) do
          :ok -> {:ok, :written}
          {:error, reason} -> {:error, "Cannot append to step summary: #{inspect(reason)}"}
        end

      _ ->
        {:ok, :skipped}
    end
  end

  @doc """
  Convenience: render then write. Returns the rendered Markdown so a caller can
  also echo it to stdout.
  """
  @spec emit(map(), keyword()) :: {:ok, String.t()}
  def emit(report, opts \\ []) do
    markdown = render(report, opts)
    _ = write(markdown)
    {:ok, markdown}
  end

  # ---------------------------------------------------------------------
  # Sections
  # ---------------------------------------------------------------------

  defp verdict_line(%{failed?: true} = report) do
    "**Result: failing** — #{length(report.gating)} finding(s) at or above " <>
      "`#{report.fail_on}`."
  end

  defp verdict_line(report) do
    "**Result: passing** — no findings at or above `#{report.fail_on}`."
  end

  defp identity_line(identity) when map_size(identity) == 0, do: nil

  defp identity_line(identity) do
    parts =
      [
        pr_part(identity),
        sha_part(identity)
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      _ -> "Reviewed " <> Enum.join(parts, " · ")
    end
  end

  defp pr_part(%{pr_number: number}) when is_binary(number) and number != "",
    do: "PR ##{number}"

  defp pr_part(%{pr_number: number}) when is_integer(number), do: "PR ##{number}"
  defp pr_part(_), do: nil

  defp sha_part(%{base_sha: base, head_sha: head})
       when is_binary(base) and is_binary(head) do
    "`#{short(base)}...#{short(head)}`"
  end

  defp sha_part(_), do: nil

  defp short(sha) when byte_size(sha) > 12, do: binary_part(sha, 0, 12)
  defp short(sha), do: sha

  defp counts_table(report) do
    """
    | | Count |
    | :--- | ---: |
    | Issues | #{length(report.issues)} |
    | Endorsements | #{length(report.endorsements)} |
    | Gating (`#{report.fail_on}`) | #{length(report.gating)} |
    | Max severity | #{report.max_severity} |
    """
  end

  defp issues_section([]), do: "### Issues\n\nNone."

  defp issues_section(issues) do
    rows =
      issues
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {finding, idx} ->
        "| #{idx} | #{severity_cell(finding.severity)} | #{location_cell(finding)} | " <>
          "#{title_cell(finding)} |"
      end)

    """
    ### Issues

    | # | Severity | Location | Title |
    | ---: | :--- | :--- | :--- |
    #{rows}
    """
  end

  defp endorsements_section([]), do: nil

  defp endorsements_section(endorsements) do
    rows =
      endorsements
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {finding, idx} ->
        "| #{idx} | #{location_cell(finding)} | #{title_cell(finding)} |"
      end)

    """
    ### Endorsements

    Observations only — these are not requests for changes and never gate.

    | # | Location | Note |
    | ---: | :--- | :--- |
    #{rows}
    """
  end

  defp severity_cell(severity), do: "`#{severity}`"

  defp location_cell(%{file: nil}), do: "General"

  defp location_cell(%{file: file, line: nil}), do: "`#{escape(file)}`"

  defp location_cell(%{file: file, line: line}),
    do: "`#{escape(file)}:#{line}`"

  defp title_cell(%{title: title}) do
    title
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp escape(text), do: text |> to_string() |> String.replace("|", "\\|")

  @doc """
  Returns the numeric rank of a severity, re-exported for sink callers that
  only need ordering.
  """
  @spec rank(String.t()) :: non_neg_integer()
  defdelegate rank(severity), to: Findings
end

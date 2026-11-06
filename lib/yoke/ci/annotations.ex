defmodule Yoke.CI.Annotations do
  @moduledoc """
  Renders a review report as GitHub Actions workflow commands
  (`docs/CI_PLAN.md` Phase 1.1).

  GitHub turns lines of the form

      ::error file=lib/foo.ex,line=42::message

  into inline annotations on the changed file in the PR's "Files changed" tab.
  This is what makes a finding land on the *right line* rather than in a wall
  of log text.

  ## Why the escaping matters

  Workflow commands are line-oriented and comma-delimited. A finding whose
  message contains a newline would silently truncate the annotation, and a
  message containing `::` could inject a *different* workflow command (for
  example one that sets an output variable). Both are escaped here per
  GitHub's documented rules:

    * `%` → `%25`
    * `\\r` → `%0D`
    * `\\n` → `%0A`
    * `:` → `%3A` (message only)
    * `,` → `%2C` (property values only)

  ## Severity mapping

  `high` and `medium` become `::error`, `low` and `info` become
  `::warning`. This is a *display* choice only — what actually fails the run
  is `--fail-on`, evaluated by `Yoke.CI.Findings`.
  """

  alias Yoke.CI.Findings

  @doc """
  Renders one workflow command per issue.

  Endorsements are deliberately excluded: an annotation is a call to action,
  and an endorsement is not one. They are reported in the step summary and the
  artifact instead.
  """
  @spec render(map()) :: String.t()
  def render(report) when is_map(report) do
    report
    |> Map.get(:issues, [])
    |> Enum.map_join("", &annotation/1)
  end

  @doc """
  Renders a single finding as a workflow command line (with trailing newline).
  """
  @spec annotation(map()) :: String.t()
  def annotation(finding) when is_map(finding) do
    level = level_for(finding.severity)
    properties = properties_for(finding)
    message = escape_message(annotation_message(finding))

    "::#{level}#{properties}::#{message}\n"
  end

  @doc """
  Writes annotations to stdout, which is where the Actions runner reads
  workflow commands from.

  Returns the rendered text so a caller can also persist it.
  """
  @spec emit(map()) :: String.t()
  def emit(report) do
    text = render(report)
    if text != "", do: IO.write(text)
    text
  end

  @doc """
  Maps a finding severity onto a workflow-command level.

  Unknown severities fall back to `warning` rather than `error`, so a
  malformed severity can never fail a build by itself.
  """
  @spec level_for(String.t()) :: String.t()
  def level_for(severity) do
    medium = Findings.rank("medium")

    if Findings.rank(severity) >= medium, do: "error", else: "warning"
  end

  @doc "Escapes a workflow-command message body."
  @spec escape_message(String.t()) :: String.t()
  def escape_message(text) when is_binary(text) do
    text
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
    |> String.replace(":", "%3A")
  end

  @doc "Escapes a workflow-command property value (file, title, ...)."
  @spec escape_property(String.t()) :: String.t()
  def escape_property(text) when is_binary(text) do
    text
    |> escape_message()
    |> String.replace(",", "%2C")
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp properties_for(%{file: nil}), do: ""

  defp properties_for(finding) do
    base = " file=#{escape_property(to_string(finding.file))}"

    base =
      case finding.line do
        line when is_integer(line) and line > 0 -> base <> ",line=#{line}"
        _ -> base
      end

    base <> ",title=#{escape_property(short_title(finding.title))}"
  end

  defp annotation_message(finding) do
    title = to_string(finding.title)

    case finding[:fix_suggestion] do
      fix when is_binary(fix) and fix != "" -> "#{title} — #{first_line(fix)}"
      _ -> title
    end
  end

  # An annotation title is rendered in a fixed-width badge; long titles are
  # truncated so the annotation stays readable.
  defp short_title(title) when is_binary(title) do
    if String.length(title) > 80 do
      String.slice(title, 0, 77) <> "..."
    else
      title
    end
  end

  defp short_title(title), do: to_string(title)

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end
end

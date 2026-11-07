defmodule Yoke.CI.Lint.Parser do
  @moduledoc """
  Normalises heterogeneous linter output into the finding map the review sinks
  already understand (`docs/CI_PLAN.md` Milestone 2).

  Each tool speaks a different dialect; this module is the single place that
  knows about all of them. Keeping it separate from `Yoke.CI.Lint` means the
  parsing is exhaustively unit-testable without shelling out to `mix`.

  ## Dialects

    * **`credo` / `oeditus_credo`** — JSON `{"issues": [...]}`, identical schema.
      Credo `priority` (1 = highest) maps onto severity.
    * **`dialyzer`** — `--format short` lines of `file:line: message`.
    * **`format`** — one unformatted file path per line.
    * **`deps.audit`** — advisory blocks; each `Name`/`Dependency`/`Title` is one
      finding, always `high` (a vulnerable dependency is not negotiable).
    * **`propwise`** — unstructured; reported as a single informational finding
      rather than guessed at.
  """

  alias Yoke.Json

  @doc """
  Parses `output` from `tool` into a list of finding maps.

  Unknown or unparseable output yields `[]` rather than raising: a parser bug
  must never take down a CI job.
  """
  @spec parse(String.t(), String.t()) :: [map()]
  def parse("credo", output), do: parse_credo(output, "credo")
  def parse("oeditus_credo", output), do: parse_credo(output, "oeditus_credo")
  def parse("dialyzer", output), do: parse_dialyzer(output)
  def parse("format", output), do: parse_format(output)
  def parse("deps.audit", output), do: parse_deps_audit(output)
  def parse("propwise", output), do: parse_propwise(output)
  def parse(_tool, _output), do: []

  # ---------------------------------------------------------------------
  # Credo (and oeditus_credo, which shares the schema)
  # ---------------------------------------------------------------------

  defp parse_credo(output, tool) do
    case decode_json(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        issues
        |> Enum.with_index(1)
        |> Enum.map(fn {issue, index} -> credo_finding(issue, index, tool) end)

      _ ->
        []
    end
  end

  defp credo_finding(issue, index, tool) do
    %{
      id: index,
      file: blank_to_nil(issue["filename"]),
      line: positive_int(issue["line_no"]),
      title: credo_title(issue, tool),
      description: to_string(issue["message"] || ""),
      severity: credo_severity(issue["priority"]),
      kind: "issue",
      fix_suggestion: ""
    }
  end

  # A Credo check name is `Credo.Check.Category.Name`; the last segment is the
  # most useful label for a CI annotation badge. Falling back to the tool name
  # keeps the title meaningful when the check name is absent.
  defp credo_title(issue, tool) do
    case issue["check"] do
      check when is_binary(check) and check != "" ->
        check |> String.split(".") |> List.last()

      _ ->
        tool
    end
  end

  # Credo priorities run 1 (highest) .. 4 (lowest). Map onto the review
  # severities so `--fail-on` means the same thing for both commands.
  defp credo_severity(priority) do
    case positive_int(priority) do
      1 -> "high"
      2 -> "medium"
      3 -> "low"
      _ -> "info"
    end
  end

  # ---------------------------------------------------------------------
  # Dialyzer (`--format short`)
  # ---------------------------------------------------------------------

  # Short format lines look like:
  #   lib/foo.ex:12: Function bar/1 has no local return
  #   lib/foo.ex:12:no_return Function bar/1 has no local return
  @dialyzer_line ~r/^(.+?):(\d+):(?:\d+:)?\s*(.+)$/

  defp parse_dialyzer(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&dialyzer_finding/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {finding, index} -> %{finding | id: index} end)
  end

  defp dialyzer_finding(line) do
    case Regex.run(@dialyzer_line, line) do
      [_, file, line_no, message] ->
        [
          %{
            id: 0,
            file: file,
            line: String.to_integer(line_no),
            title: "dialyzer",
            description: String.trim(message),
            severity: "high",
            kind: "issue",
            fix_suggestion: ""
          }
        ]

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------
  # mix format --check-formatted
  # ---------------------------------------------------------------------

  defp parse_format(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&unformatted_path?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {path, index} ->
      %{
        id: index,
        file: path,
        line: nil,
        title: "not formatted",
        description: "`#{path}` is not formatted; run `mix format`.",
        severity: "low",
        kind: "issue",
        fix_suggestion: ""
      }
    end)
  end

  # `mix format --check-formatted` prints a bare path per line. Anything that
  # looks like a log line, an error, or a summary is not a path.
  defp unformatted_path?(line) do
    line != "" and
      not String.starts_with?(line, ["**", "mix ", "Compiling", "Generated", "==>"]) and
      not String.contains?(line, " ") and
      (String.ends_with?(line, ".ex") or String.ends_with?(line, ".exs"))
  end

  # ---------------------------------------------------------------------
  # mix deps.audit
  # ---------------------------------------------------------------------

  defp parse_deps_audit(output) do
    output
    |> String.split(~r/\n\s*\n/)
    |> Enum.filter(&String.contains?(&1, "Dependency"))
    |> Enum.with_index(1)
    |> Enum.map(fn {block, index} -> deps_finding(block, index) end)
  end

  defp deps_finding(block, index) do
    dependency = extract_field(block, "Dependency")
    title = extract_field(block, "Title")
    advisory = extract_field(block, "Name")

    %{
      id: index,
      file: "mix.lock",
      line: nil,
      title: title || advisory || "vulnerable dependency",
      description: "Dependency `#{dependency || "unknown"}`: #{title || advisory || block}",
      severity: "high",
      kind: "issue",
      fix_suggestion: "Upgrade `#{dependency || "the dependency"}` to a patched version."
    }
  end

  defp extract_field(block, field) do
    case Regex.run(~r/^#{Regex.escape(field)}:\s*(.+)$/m, block) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------
  # propwise
  # ---------------------------------------------------------------------

  # propwise emits prose suggestions, not machine-readable issues, and crashes
  # on some codebases. Rather than guess at structure, surface it as a single
  # informational finding so its output is visible but never gates.
  defp parse_propwise(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      []
    else
      [
        %{
          id: 1,
          file: nil,
          line: nil,
          title: "propwise suggestions",
          description: String.slice(trimmed, 0, 4_000),
          severity: "info",
          kind: "issue",
          fix_suggestion: ""
        }
      ]
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp decode_json(output) do
    case Json.decode(output) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_int(_), do: nil
end

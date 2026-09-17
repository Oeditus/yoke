defmodule Yoke.Linter.Interactive do
  @moduledoc """
  Orchestrates the interactive TUI approval modal loop for applying linter diff fixes.
  """
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.QuestionPrompt
  alias Yoke.Linter.Fixer
  alias Yoke.Linter.Parser

  @doc """
  Runs interactive fix session on raw linter output.
  """
  def run(linter_output, tool \\ "credo", cwd \\ ".") do
    findings = Parser.parse(linter_output, tool)

    if findings == [] do
      {:ok, "No fixable linter findings identified in output."}
    else
      total = length(findings)

      IO.puts(
        Formatter.cyan() <>
          "\n🔍 Identified #{total} linter finding(s). Entering interactive fix mode…\n" <>
          Formatter.reset()
      )

      {applied_count, skipped_count} = loop_findings(findings, 1, total, cwd, false, {0, 0})

      summary =
        Formatter.green() <>
          "\n✨ Interactive fix session complete!\n" <>
          Formatter.reset() <>
          "   Applied: #{applied_count}\n" <>
          "   Skipped: #{skipped_count}\n"

      {:ok, summary}
    end
  end

  defp loop_findings([], _idx, _total, _cwd, _auto_apply, {applied, skipped}) do
    {applied, skipped}
  end

  defp loop_findings([finding | rest], idx, total, cwd, auto_apply, {applied, skipped}) do
    case Fixer.propose_fix(finding, cwd) do
      {:ok, patch} ->
        if auto_apply do
          case Fixer.apply_patch(patch) do
            :ok ->
              IO.puts(
                Formatter.green() <>
                  "  [Auto-Applied] #{finding.file}:#{finding.line} (#{finding.message})" <>
                  Formatter.reset()
              )

              loop_findings(rest, idx + 1, total, cwd, true, {applied + 1, skipped})

            _ ->
              loop_findings(rest, idx + 1, total, cwd, true, {applied, skipped + 1})
          end
        else
          prompt_text =
            "Linter Finding #{idx}/#{total} in `#{finding.file}:#{finding.line}`\n" <>
              "Check: #{finding.check || finding.tool}\n" <>
              "Issue: #{finding.message}\n\n" <>
              "Proposed Diff:\n" <>
              patch.diff

          options = [
            "Apply diff (Recommended)",
            "Skip / Deny finding",
            "Apply all remaining diffs"
          ]

          res =
            QuestionPrompt.ask_single_question(
              prompt_text,
              options,
              false,
              true,
              progress: {idx, total}
            )

          case res do
            %{selected: [selected]} ->
              cond do
                String.contains?(selected, "Apply diff") ->
                  Fixer.apply_patch(patch)

                  IO.puts(
                    Formatter.green() <>
                      "  ✓ Applied diff to #{finding.file}:#{finding.line}" <> Formatter.reset()
                  )

                  loop_findings(rest, idx + 1, total, cwd, false, {applied + 1, skipped})

                String.contains?(selected, "all remaining") ->
                  Fixer.apply_patch(patch)

                  IO.puts(
                    Formatter.green() <>
                      "  ✓ Applied diff to #{finding.file}:#{finding.line}" <> Formatter.reset()
                  )

                  loop_findings(rest, idx + 1, total, cwd, true, {applied + 1, skipped})

                true ->
                  IO.puts(
                    Formatter.dim() <>
                      "  ✗ Skipped finding at #{finding.file}:#{finding.line}" <>
                      Formatter.reset()
                  )

                  loop_findings(rest, idx + 1, total, cwd, false, {applied, skipped + 1})
              end

            _ ->
              IO.puts(
                Formatter.dim() <>
                  "  ✗ Skipped finding at #{finding.file}:#{finding.line}" <> Formatter.reset()
              )

              loop_findings(rest, idx + 1, total, cwd, false, {applied, skipped + 1})
          end
        end

      {:error, _reason} ->
        IO.puts(
          Formatter.dim() <>
            "  ℹ Skipping #{finding.file}:#{finding.line} (could not formulate valid diff fix)" <>
            Formatter.reset()
        )

        loop_findings(rest, idx + 1, total, cwd, auto_apply, {applied, skipped + 1})
    end
  end
end

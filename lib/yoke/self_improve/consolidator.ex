defmodule Yoke.SelfImprove.Consolidator do
  @moduledoc """
  Sleep-cycle memory consolidation & morning briefing generator.

  Intended to run on idle, `/exit`, or `/memory consolidate`:
  1. Prunes stale single-hit episodes (`Decay.prune_stale_episodes/1`).
  2. Graduates qualified staging items (`Guardrails.auto_graduate/1`) and applies
     promoted rules/lessons to `Yoke.Rules` and `Yoke.Lessons`.
  3. Summarizes recent failed/undone turns from `Telemetry` with a counterfactual
     `Yoke.Sparring` prompt hook.
  4. Writes `.yoke/briefing.md` for transparent review on next session start.
  """

  alias Yoke.Lessons
  alias Yoke.Rules
  alias Yoke.SelfImprove.{Decay, Guardrails, Telemetry}
  alias Yoke.Sparring

  @briefing_file ".yoke/briefing.md"

  @doc "Returns `.yoke/briefing.md` path under `cwd`."
  def briefing_path(cwd \\ "."), do: Path.join(cwd, @briefing_file)

  @doc """
  Runs a full consolidation pass for `cwd` and writes `.yoke/briefing.md`.
  Returns `{:ok, report}`.
  """
  def consolidate(cwd \\ ".") do
    {:ok, %{kept: kept_ep, pruned: pruned_ep}} = Decay.prune_stale_episodes(cwd)
    {:ok, %{promoted: promoted, expired: expired}} = Guardrails.auto_graduate(cwd: cwd)

    applied =
      Enum.map(promoted, fn item ->
        case item["kind"] do
          "rule" ->
            Rules.add_rule(item["content"], cwd)
            {:rule, item["content"]}

          "lesson" ->
            Lessons.append_lesson(item["content"], cwd: cwd)
            {:lesson, item["content"]}

          kind ->
            {String.to_atom(kind), item["content"]}
        end
      end)

    summary = Telemetry.summary(cwd)

    undone_or_failed =
      Telemetry.load(cwd)
      |> Enum.filter(&(&1["undone"] || &1["outcome"] == "failed"))
      |> Enum.take(-3)

    sparring_note =
      if undone_or_failed != [] do
        prompt =
          Sparring.build_adversarial_prompt(
            "recent-turn-failures",
            "#{length(undone_or_failed)} undone/failed turns"
          )

        "Prepared adversarial reflection prompt (#{String.length(prompt)} chars) for #{length(undone_or_failed)} recent failure(s)."
      else
        "No recent undone or failed turns to reflect on."
      end

    report = %{
      kept_episodes: kept_ep,
      pruned_episodes: pruned_ep,
      promoted_count: length(promoted),
      expired_count: length(expired),
      applied: applied,
      total_turns: summary.total_turns,
      sparring_note: sparring_note
    }

    write_briefing(report, cwd)
    {:ok, report}
  end

  @doc "Reads `.yoke/briefing.md` if it exists, or returns `nil`."
  def read_briefing(cwd \\ ".") do
    path = briefing_path(cwd)
    if File.exists?(path), do: File.read!(path), else: nil
  end

  defp write_briefing(report, cwd) do
    path = briefing_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

    applied_lines =
      if report.applied == [] do
        "- None"
      else
        Enum.map_join(report.applied, "\n", fn {kind, text} -> "- [#{kind}] #{text}" end)
      end

    md = """
    # Yoke Self-Improvement Briefing (#{timestamp})

    - **Turns observed**: #{report.total_turns}
    - **Episodic memory**: #{report.kept_episodes} active, #{report.pruned_episodes} stale pruned
    - **Staging graduation**: #{report.promoted_count} promoted, #{report.expired_count} expired
    - **Reflection**: #{report.sparring_note}

    ## Newly Applied Patterns
    #{applied_lines}
    """

    File.write!(path, md)
  end
end

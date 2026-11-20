defmodule Yoke.SelfImprove.Router do
  @moduledoc """
  Dynamic Cognitive Gear-Shifting ("System 1 vs. System 2" model router).

  Classifies the current task phase (`:explore`, `:design`, `:codegen`, `:debug`)
  and recommends model/reasoning transitions when failure streaks, tool loops,
  or narrated-intent stalls occur—subject to `Guardrails.can_auto_switch?/3` hysteresis.
  """

  alias Yoke.SelfImprove.{Guardrails, Telemetry}

  @default_fast_model "deepseek-flash"
  @default_reasoning_model "deepseek-reasoner"

  @doc """
  Classifies the task phase from the user prompt and recent tool names.
  """
  def classify_phase(prompt, recent_tools \\ []) when is_binary(prompt) do
    down = String.downcase(prompt)

    cond do
      Regex.match?(~r/\b(debug|fix|failing|error|crash|traceback|exception|stack|broken)\b/, down) ->
        :debug

      Regex.match?(~r/\b(design|architect|plan|refactor|trade-?off|review|spar)\b/, down) ->
        :design

      Regex.match?(~r/\b(implement|add|create|write|build|edit|patch|test)\b/, down) ->
        :codegen

      Enum.any?(recent_tools, &(&1 in ["replace_file", "write_file", "mcp_ragex_edit_file"])) ->
        :codegen

      true ->
        :explore
    end
  end

  @doc """
  Evaluates whether the active session should shift cognitive gears (switch model).

  Returns:
  - `{:switch, target_model, reason}` when an escalation or step-down is recommended
    and allowed by hysteresis.
  - `:keep` otherwise.

  Context map keys:
  - `:current_model` (required)
  - `:turn_count` (integer, default `0`)
  - `:last_auto_switch_turn` (integer | nil)
  - `:consecutive_errors` (integer, default `0`)
  - `:loop_hits` (integer, default `0`)
  - `:intent_stalls` (integer, default `0`)
  - `:phase` (atom, optional)
  - `:language` (string, optional)
  - `:reasoning_model` (default `"deepseek-reasoner"`)
  - `:fast_model` (default `"deepseek-flash"`)
  - `:cwd` (default `"."`)
  """
  def recommend(ctx) when is_map(ctx) do
    current = Map.get(ctx, :current_model, @default_fast_model)
    turn = Map.get(ctx, :turn_count, 0)
    last_switch = Map.get(ctx, :last_auto_switch_turn)
    errors = Map.get(ctx, :consecutive_errors, 0)
    loops = Map.get(ctx, :loop_hits, 0)
    stalls = Map.get(ctx, :intent_stalls, 0)
    phase = Map.get(ctx, :phase, :explore)
    reasoning_model = Map.get(ctx, :reasoning_model, @default_reasoning_model)
    fast_model = Map.get(ctx, :fast_model, @default_fast_model)

    can_switch? = Guardrails.can_auto_switch?(turn, last_switch)

    cond do
      not can_switch? ->
        :keep

      (errors >= 2 or loops >= 1 or stalls >= 2) and current != reasoning_model ->
        {:switch, reasoning_model,
         "Escalating to reasoning mode (#{errors} errors, #{loops} loops, #{stalls} stalls)."}

      phase == :explore and errors == 0 and loops == 0 and current == reasoning_model ->
        {:switch, fast_model, "Stepping down to fast mode for exploration."}

      true ->
        maybe_bandit_switch(ctx, current, phase, [fast_model, reasoning_model])
    end
  end

  defp maybe_bandit_switch(ctx, current, phase, candidates) do
    cwd = Map.get(ctx, :cwd, ".")
    language = Map.get(ctx, :language)
    scores = Telemetry.bandit_scores(candidates, cwd: cwd, phase: phase, language: language)

    case scores do
      [%{model: best, runs: runs, score: best_score} | _]
      when runs >= 5 and best != current ->
        current_entry = Enum.find(scores, &(&1.model == current))
        current_score = if current_entry, do: current_entry.score, else: 0.0

        if best_score - current_score >= 0.2 do
          {:switch, best,
           "Bandit router selected #{best} (score #{best_score} vs #{current_score} for #{phase})."}
        else
          :keep
        end

      _ ->
        :keep
    end
  end
end

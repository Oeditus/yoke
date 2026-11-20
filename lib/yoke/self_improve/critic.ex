defmodule Yoke.SelfImprove.Critic do
  @moduledoc """
  Asynchronous "Critic" sidecar for turn self-assessment.

  Evaluates completed turns using deterministic heuristics (tool-efficiency,
  repeated edits without test reads, loop hits, bash fallbacks) and optionally
  an injected LLM evaluator, then emits non-blocking `{:critic_nudge, text}`
  messages to the owning `Yoke.Brain.Session` when a turn is spiraling.
  """

  @doc """
  Spawns a non-blocking assessment task for a completed turn.
  If `Yoke.TaskEngine.TaskSupervisor` is running, runs under it; otherwise falls
  back to `Task.start/1`.
  """
  def assess_async(turn_summary, opts \\ []) when is_map(turn_summary) do
    session_pid = Keyword.get(opts, :session_pid)

    fun = fn ->
      result = evaluate(turn_summary, opts)

      if result.nudge && is_pid(session_pid) && Process.alive?(session_pid) do
        send(session_pid, {:critic_nudge, result.nudge})
      end

      result
    end

    if Process.whereis(Yoke.TaskEngine.TaskSupervisor) do
      Task.Supervisor.start_child(Yoke.TaskEngine.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end

  @doc """
  Synchronously evaluates a turn summary map:
  - `:tool_calls` — list of `%{name: ..., args: ..., error?: ...}`
  - `:edited_files` — list of file paths edited
  - `:read_files` — list of file paths read
  - `:loop_hits` — integer
  - `:bash_fallbacks` — integer (e.g. `grep`/`cat` via bash instead of Ragex)
  - `:evaluator` — optional 1-arity callback `fn summary -> %{score: float, nudge: binary | nil}`

  Returns `%{score: float, findings: [String.t()], nudge: String.t() | nil}`.
  """
  def evaluate(summary, opts \\ []) when is_map(summary) do
    tool_calls = Map.get(summary, :tool_calls, [])
    edited_files = Map.get(summary, :edited_files, [])
    read_files = Map.get(summary, :read_files, [])
    loop_hits = Map.get(summary, :loop_hits, 0)
    bash_fallbacks = Map.get(summary, :bash_fallbacks, 0)
    errors = Enum.count(tool_calls, &Map.get(&1, :error?, false))

    findings = []

    findings =
      if loop_hits > 0,
        do: ["Tool loop detected (#{loop_hits}x)" | findings],
        else: findings

    findings =
      if bash_fallbacks > 0,
        do: ["Used plain bash #{bash_fallbacks}x where dedicated/Ragex tools exist" | findings],
        else: findings

    # Detect thrashing: same file edited 3+ times without reading a test file
    edit_counts = Enum.frequencies(edited_files)
    thrashed = Enum.find(edit_counts, fn {_f, count} -> count >= 3 end)
    read_test? = Enum.any?(read_files, &String.contains?(&1, "test"))

    {findings, nudge} =
      case {thrashed, read_test?} do
        {{file, count}, false} ->
          msg =
            "You edited #{Path.basename(file)} #{count} times without reading its test file. Inspect the test assertions before editing again."

          {[msg | findings], msg}

        _ ->
          {findings, nil}
      end

    findings = Enum.reverse(findings)

    penalty =
      min(
        1.0,
        loop_hits * 0.25 + bash_fallbacks * 0.1 + errors * 0.08 + if(thrashed, do: 0.2, else: 0.0)
      )

    base_score = Float.round(max(0.0, 1.0 - penalty), 3)

    case Keyword.get(opts, :evaluator) do
      fun when is_function(fun, 1) ->
        extra = fun.(summary)

        %{
          score: Map.get(extra, :score, base_score),
          findings: findings ++ Map.get(extra, :findings, []),
          nudge: Map.get(extra, :nudge) || nudge
        }

      _ ->
        %{score: base_score, findings: findings, nudge: nudge}
    end
  end
end

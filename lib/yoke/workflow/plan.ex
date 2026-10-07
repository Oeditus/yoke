defmodule Yoke.Workflow.Plan do
  @moduledoc """
  Drafts an execution plan for a non-trivial task by reusing the workflow's
  task-description (`Steps.TaskDescription.prompt/1`) and task-split
  (`Steps.TaskSplit.split_prompt/1`) prompts, without requiring a live
  workflow run or its `context` map.

  This is the single public entry point the main session's plan gate uses to
  draft a plan from the user's original task text. It produces a plan map of
  the shape

      %{
        "summary" => "the structured task specification (Markdown)",
        "steps"   => [%{"id" => ..., "summary" => ..., "owns" => [...]}, ...]
      }

  It deliberately does NOT depend on `Workflow.Engine.ask_llm/2`, which reads
  `context.workflow.rules_scope` and therefore requires a live workflow run the
  session plan gate does not have. Instead it calls
  `Yoke.Client.DeepSeekAPI.chat_completion/3` directly with a plain
  `[system, user]` message pair, mirroring how `Engine.ask_llm/2` works
  internally but with zero coupling to workflow state.

  Like `Engine`, `Plan` is a plain module (no `GenServer`).
  """
  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Workflow.Steps.TaskDescription
  alias Yoke.Workflow.Steps.TaskSplit

  @system_prompt """
  You are assisting Yoke's plan gate on a single, focused, tool-free \
  reasoning task. Follow the instruction exactly and respond with only what was \
  asked for -- no conversational preamble, no postamble, no markdown code fences \
  unless explicitly requested.
  """

  @doc """
  Drafts an execution plan for `task_text` by asking the model to (1) turn it
  into a structured task specification and (2) propose a non-clashing split
  into independent subtasks.

  `opts` may carry:
    * `:cwd`   - working root (currently unused by the LLM calls, kept for
      parity with the workflow context; default `"."`).
    * `:model` - model name (default `"deepseek-chat"`).
    * `:mock`  - force mock mode (default: auto-enabled in the `:test` env by
      `DeepSeekAPI`).

  Returns `{:ok, plan_map}` where `plan_map` is a string-keyed map with a
  `"summary"` (the structured task specification generated from
  `TaskDescription.prompt/1`) and a `"steps"` list (derived from a split
  proposal via `TaskSplit.split_prompt/1` + `build_plan/1`). When the task
  cannot be split -- the model declines, or the split response is unparseable
  -- `"steps"` is empty, signalling the task should be run as a single unit.

  Returns `{:error, reason}` if either LLM call fails.
  """
  def draft(task_text, opts \\ []) when is_binary(task_text) do
    with {:ok, summary} <- llm_call(TaskDescription.prompt(task_text), opts),
         {:ok, split_text} <- llm_call(TaskSplit.split_prompt(summary), opts) do
      {:ok, build_plan(summary, split_text)}
    end
  end

  defp build_plan(summary, split_text) do
    case TaskSplit.build_plan(split_text) do
      %{"subtasks" => []} ->
        %{"summary" => String.trim(summary), "steps" => []}

      %{"subtasks" => subtasks} ->
        %{"summary" => String.trim(summary), "steps" => subtasks}
    end
  end

  # Shared one-shot completion used for both the summary call and the split
  # call. Returns `{:ok, text}` / `{:error, reason}` to match `Engine.ask_llm/2`'s
  # shape so callers that already handle workflow meta-calls can reuse the same
  # pattern.
  defp llm_call(user_prompt, opts) do
    messages = [
      %{"role" => "system", "content" => @system_prompt},
      %{"role" => "user", "content" => user_prompt}
    ]

    call_opts =
      [model: Keyword.get(opts, :model, "deepseek-chat")]
      |> maybe_put(:api_key, opts)
      |> maybe_put(:endpoint, opts)
      |> maybe_put(:session_id, opts)
      |> maybe_put(:max_tokens, opts)
      |> maybe_put_mock(opts)

    case DeepSeekAPI.chat_completion(messages, [], call_opts) do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # Threads an optional keyword through to the API call only when the caller
  # supplied it (so live sessions can pass their own api_key / max_tokens).
  # Piped as `acc |> maybe_put(:key, opts)`, so the accumulator comes first.
  defp maybe_put(list, key, opts) do
    if Keyword.has_key?(opts, key) and not is_nil(Keyword.get(opts, key)) do
      Keyword.put(list, key, Keyword.get(opts, key))
    else
      list
    end
  end

  # Only thread an explicit `:mock` through when the caller supplied one, so
  # `DeepSeekAPI.build_config/1`'s automatic `Mix.env() == :test` mock still
  # kicks in for offline tests that don't pass it.
  defp maybe_put_mock(list, opts) do
    if Keyword.has_key?(opts, :mock), do: Keyword.put(list, :mock, opts[:mock]), else: list
  end
end

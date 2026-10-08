defmodule Yoke.Workflow.Engine do
  @moduledoc """
  Drives execution of a workflow run: loads/validates its
  `Workflow.Definition`, initializes (or resumes) its `Workflow.Store` run
  directory, and executes each step in order, checkpointing `state.json`
  after every transition so a crash, `/workflow abort`, or a Ctrl+C can
  be picked back up later with `resume/2`.

  Deliberately a plain module rather than a `GenServer`: Yoke's actual
  concurrency model is "one thing happens at a time in the interactive
  TTY, with real BEAM concurrency only where it's genuinely needed" (see
  `Brain.Session.spawn_subagent/3`, `TaskEngine.Orchestrator`), and a
  workflow run is no exception -- the caller (the REPL) already blocks
  synchronously on `Brain.Session.send_user_message/2` the same way, and
  the genuine parallelism a workflow's split subtasks need comes from
  spawning real concurrent `Brain.Session` processes (see
  `Steps.TaskSplit`), not from the engine itself being a separate,
  independently-schedulable process.
  """
  require Logger

  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Rules
  alias Yoke.Workflow.Definition
  alias Yoke.Workflow.Store

  @step_modules %{
    "branch" => Yoke.Workflow.Steps.Branch,
    "task_description" => Yoke.Workflow.Steps.TaskDescription,
    "task_split" => Yoke.Workflow.Steps.TaskSplit,
    "tests_and_docs" => Yoke.Workflow.Steps.TestsAndDocs,
    "lint" => Yoke.Workflow.Steps.Lint,
    "commit" => Yoke.Workflow.Steps.Commit,
    "prompt" => Yoke.Workflow.Steps.Prompt
  }

  @doc "Registered step type names, used for definition validation/error messages."
  def step_types, do: Map.keys(@step_modules)

  @doc """
  Starts a brand-new run of `workflow_name`, seeded with `:seed_prompt`
  (the user's original task request text), and executes it to completion
  or until a step halts (a declined gate) or errors.
  """
  def run(workflow_name, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    seed_prompt = Keyword.get(opts, :seed_prompt, "")

    with {:ok, definition} <- Definition.load(workflow_name, cwd) do
      run_id = Store.new_run_id(definition.name)
      {:ok, _dir} = Store.init_run!(run_id, definition, cwd)
      Store.save_state!(run_id, %{"status" => "running"}, cwd)

      pipeline_item =
        case Yoke.WorkflowIndex.find_and_activate(seed_prompt, cwd) do
          {:ok, item} -> item
          _ -> nil
        end

      context = %{
        run_id: run_id,
        cwd: cwd,
        workflow: definition,
        seed_prompt: seed_prompt,
        pipeline_item: pipeline_item
      }

      execute_from(context, definition.steps, 0)
    end
  end

  @doc """
  Resumes a previously started run from wherever it left off, using the
  step spec it was *originally* started with (the `workflow.json`
  snapshot), not whatever the live definition file currently says --
  editing a workflow definition must never reinterpret a run already in
  progress.
  """
  def resume(run_id, cwd \\ ".") do
    with {:ok, state} <- Store.load_state(run_id, cwd),
         {:ok, snapshot} <- Store.load_snapshot(run_id, cwd),
         {:ok, definition} <- Definition.parse(snapshot, :run_snapshot) do
      cond do
        state["status"] == "aborted" ->
          {:error, "Workflow run '#{run_id}' was aborted and cannot be resumed."}

        state["status"] == "completed" ->
          {:error, "Workflow run '#{run_id}' already completed; nothing to resume."}

        true ->
          context =
            %{run_id: run_id, cwd: cwd, workflow: definition}
            |> put_if_present(:branch, state["branch"])
            |> put_if_present(:original_branch, state["base_branch"])
            |> put_if_present(:task_description, Store.read_task_description(run_id, cwd))

          execute_from(context, definition.steps, state["step_index"] || 0)
      end
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc "Reads a run's persisted status without needing a live process (works after a crash, abort, or completion)."
  def status(run_id, cwd \\ "."), do: Store.load_state(run_id, cwd)

  @doc """
  Marks a run as aborted. Best-effort: this only prevents `resume/2` from
  picking the run back up afterwards -- like a regular agent turn, it
  cannot forcibly interrupt synchronous work already in flight.
  """
  def abort(run_id, cwd \\ ".") do
    with {:ok, state} <- Store.load_state(run_id, cwd) do
      updated = Store.save_state!(run_id, Map.put(state, "status", "aborted"), cwd)
      {:ok, updated}
    end
  end

  # ---------------------------------------------------------------------
  # Step execution
  # ---------------------------------------------------------------------

  defp execute_from(context, steps, index) when index >= length(steps) do
    persist_checkpoint(context, "completed", index)
    {:ok, context}
  end

  defp execute_from(context, steps, index) do
    step = Enum.at(steps, index)
    type = step["type"]

    case Map.get(@step_modules, type) do
      nil ->
        fail(
          context,
          index,
          "Unknown workflow step type: '#{type}'. Known types: #{Enum.join(step_types(), ", ")}."
        )

      module ->
        Logger.info(
          "[Workflow.Engine] Run #{context.run_id}: step #{index + 1}/#{length(steps)} (#{type})"
        )

        case module.run(context, Map.drop(step, ["type"])) do
          {:ok, new_context} ->
            persist_checkpoint(new_context, "running", index + 1)
            execute_from(new_context, steps, index + 1)

          {:halt, reason} ->
            persist_checkpoint(context, "halted", index, reason)

            Store.append_transcript(
              context.run_id,
              :halted,
              %{"step" => type, "reason" => reason},
              context.cwd
            )

            {:halt, reason}

          {:error, reason} ->
            fail(context, index, reason)
        end
    end
  end

  defp persist_checkpoint(context, status, step_index, reason \\ nil) do
    base = %{
      "status" => status,
      "step_index" => step_index,
      "branch" => Map.get(context, :branch),
      "base_branch" => Map.get(context, :original_branch)
    }

    fields = if reason, do: Map.put(base, "reason", to_string(reason)), else: base
    Store.save_state!(context.run_id, fields, context.cwd)
  end

  defp fail(context, index, reason) do
    persist_checkpoint(context, "failed", index, reason)

    Store.append_transcript(
      context.run_id,
      :failed,
      %{"step_index" => index, "reason" => to_string(reason)},
      context.cwd
    )

    {:error, reason}
  end

  # ---------------------------------------------------------------------
  # Shared LLM helper for "meta" calls (description/split/commit message)
  # ---------------------------------------------------------------------

  @doc """
  Performs a single one-shot chat completion -- no tools, and never
  appended to any `Brain.Session`'s visible message history -- for steps
  that only need the model's text reasoning (summarizing a task,
  proposing a split, drafting a commit message) rather than full
  tool-calling capability. Keeping these "meta" calls out of the user's
  own conversation avoids polluting their context window with plumbing,
  and automatically benefits from `DeepSeekAPI`'s existing test-mode mock.
  """
  def ask_llm(context, user_prompt, opts \\ []) do
    preamble = Rules.build_preamble(context.workflow.rules_scope, context.cwd)

    system = """
    You are assisting Yoke's workflow engine on a single, focused, tool-free \
    reasoning task. Follow the instruction exactly and respond with only what was asked for -- \
    no conversational preamble, no postamble, no markdown code fences unless explicitly requested.

    #{preamble}
    """

    messages = [
      %{"role" => "system", "content" => system},
      %{"role" => "user", "content" => user_prompt}
    ]

    default_model =
      System.get_env("DEEPSEEK_MODEL") ||
        Map.get(Yoke.Config.load_config("."), "model", "deepseek-chat")

    case DeepSeekAPI.chat_completion(messages, [], Keyword.put_new(opts, :model, default_model)) do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end
end

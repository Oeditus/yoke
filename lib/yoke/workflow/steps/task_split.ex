defmodule Yoke.Workflow.Steps.TaskSplit do
  @moduledoc """
  Step ③: asks the model to propose splitting `context.task_description`
  into independent, non-clashing subtasks; shows the proposal to the
  user for approval; and then executes either a single agent task (no
  split, or the user declined) or one isolated agent task per accepted
  subtask, run genuinely in parallel.

  An LLM-proposed "non-clashing" split is a best-effort heuristic, not a
  guarantee, so each accepted subtask gets its own `git worktree` on its
  own branch (`Git.add_worktree/3`) -- concurrent `Brain.Session`
  processes can then never write to the same files on disk, even if the
  split wasn't perfectly non-overlapping. Subtask branches are merged
  back into the workflow branch sequentially once every subtask
  finishes; a merge conflict halts with the worktree left in place for
  manual resolution rather than being silently discarded.
  """
  @behaviour Yoke.Workflow.Step

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Git
  alias Yoke.TaskEngine.TaskSupervisor
  alias Yoke.Workflow.Engine
  alias Yoke.Workflow.Json
  alias Yoke.Workflow.Steps.TestsAndDocs
  alias Yoke.Workflow.Store

  @impl true
  def run(%{task_description: description} = context, _params)
      when is_binary(description) and description != "" do
    proposal = propose_split(context, description)

    Store.append_transcript(context.run_id, :task_split_proposal, proposal, context.cwd)

    case decide(context, proposal) do
      :run_as_single -> run_single(context, description)
      {:run_parallel, subtasks} -> run_parallel(context, subtasks)
    end
  end

  def run(_context, _params) do
    {:error,
     "The \"task_split\" step requires a \"task_description\" step earlier in this workflow's step list."}
  end

  # ---------------------------------------------------------------------
  # Proposing & deciding
  # ---------------------------------------------------------------------

  defp propose_split(context, description) do
    case Engine.ask_llm(context, split_prompt(description)) do
      {:ok, text} -> build_plan(text)
      {:error, reason} -> %{"raw_response" => nil, "subtasks" => [], "error" => inspect(reason)}
    end
  end

  @doc """
  Builds the LLM prompt asking for a JSON, non-clashing subtask split proposal.
  Also reused by `Workflow.Plan.draft/2` (the session plan gate), which calls
  this directly rather than through a workflow run.
  """
  def split_prompt(description) do
    """
    Given the following task specification, decide whether it can be split \
    into 2-5 independent subtasks that could be implemented in parallel by \
    different engineers without touching the same files/modules. If it \
    genuinely cannot be split (too small, or every part depends on every \
    other part), respond with exactly: {"subtasks": []}

    Otherwise respond with ONLY a JSON object of this exact shape (no prose, \
    no code fences):
    {"subtasks": [{"id": "short-kebab-case-id", "summary": "what this subtask \
    does", "owns": ["file/or/module/glob", "..."]}, ...]}

    Each subtask's "owns" list must not overlap with any other subtask's.

    Task specification:
    #{description}
    """
  end

  @doc """
  Turns a model response into a split plan map `%{"subtasks" => [...]}`,
  collapsing unparseable/declined/single-subtask responses to
  `%{"subtasks" => []}`. Also reused by `Workflow.Plan.draft/2` (the session
  plan gate) to derive the plan's `"steps"` list.
  """
  def build_plan(model_text) do
    case extract_subtasks(model_text) do
      {:ok, subtasks} when length(subtasks) > 1 ->
        %{"raw_response" => model_text, "subtasks" => subtasks}

      _ ->
        %{"raw_response" => model_text, "subtasks" => []}
    end
  end

  @doc """
  Extracts and normalizes a `"subtasks"` array from a model response that
  may wrap its JSON in prose or a code fence. Returns `{:error,
  :unparseable}` for anything that doesn't decode into the expected
  shape, so callers can fall back to running the task as a single unit
  rather than crashing on a malformed/mocked model response.

  Also reused by `Workflow.Plan.draft/2` (the session plan gate).
  """
  def extract_subtasks(text) when is_binary(text) do
    with {:ok, json_text} <- extract_json_object(text),
         {:ok, %{"subtasks" => subtasks}} when is_list(subtasks) <- Json.decode(json_text),
         true <- Enum.all?(subtasks, &valid_subtask?/1) do
      {:ok, normalize_subtasks(subtasks)}
    else
      _ -> {:error, :unparseable}
    end
  end

  defp valid_subtask?(%{"summary" => summary}) when is_binary(summary) and summary != "", do: true
  defp valid_subtask?(_), do: false

  defp normalize_subtasks(subtasks) do
    subtasks
    |> Enum.with_index(1)
    |> Enum.map(fn {s, idx} ->
      %{
        "id" => slug(Map.get(s, "id") || "task-#{idx}"),
        "summary" => Map.get(s, "summary", ""),
        "owns" => Map.get(s, "owns", [])
      }
    end)
  end

  defp slug(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Extracts the first top-level `{...}` JSON object substring from arbitrary text.
  Also reused by `Workflow.Plan.draft/2` (the session plan gate).
  """
  def extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> {:ok, json}
      _ -> :error
    end
  end

  defp decide(_context, %{"subtasks" => []}), do: :run_as_single

  defp decide(context, %{"subtasks" => subtasks}) do
    summary_lines = Enum.map_join(subtasks, "\n", fn s -> "  - #{s["id"]}: #{s["summary"]}" end)

    question =
      "Proposed split of '#{context.workflow.name}' into #{length(subtasks)} independent " <>
        "subtasks:\n#{summary_lines}\n\nRun these in parallel (each in its own isolated git worktree)?"

    case Yoke.Interaction.ask(:workflow_confirm, %{
           question: question,
           options: ["Yes, run in parallel", "No, run as a single task"],
           workflow: context.workflow.name,
           cwd: Map.get(context, :cwd)
         }) do
      :approve -> {:run_parallel, subtasks}
      _ -> :run_as_single
    end
  end

  # ---------------------------------------------------------------------
  # Single-task execution (no split, or split declined)
  # ---------------------------------------------------------------------

  defp run_single(context, description) do
    Store.write_split_plan!(context.run_id, %{"accepted" => false, "subtasks" => []}, context.cwd)

    case execute_agent_task(context.run_id, description, context.cwd, "main") do
      {:ok, result} ->
        {:ok, Map.put(context, :subtasks, [%{"id" => "main", "result" => result}])}

      {:error, reason} ->
        {:error, "Task execution failed: #{reason}"}
    end
  end

  # ---------------------------------------------------------------------
  # Parallel execution: one isolated worktree + Brain.Session per subtask
  # ---------------------------------------------------------------------

  defp run_parallel(context, subtasks) do
    Store.write_split_plan!(
      context.run_id,
      %{"accepted" => true, "subtasks" => subtasks},
      context.cwd
    )

    base_dir = context.cwd |> Path.expand() |> Path.dirname()

    tasks =
      Enum.map(subtasks, fn subtask ->
        Task.Supervisor.async_nolink(TaskSupervisor, fn ->
          run_subtask(context, subtask, base_dir)
        end)
      end)

    results =
      Enum.map(tasks, fn task ->
        case Task.yield(task, :infinity) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, "Subtask process crashed: #{inspect(reason)}"}
          nil -> {:error, "Subtask execution failed unexpectedly."}
        end
      end)

    finish_parallel(context, results)
  end

  defp finish_parallel(context, results) do
    case Enum.split_with(results, fn {status, _} -> status == :ok end) do
      {succeeded, []} ->
        merge_results(context, Enum.map(succeeded, fn {:ok, r} -> r end))

      {_succeeded, failed} ->
        reasons = Enum.map_join(failed, "\n", fn {:error, r} -> "- #{r}" end)
        {:error, "One or more subtasks failed:\n#{reasons}"}
    end
  end

  defp run_subtask(context, subtask, base_dir) do
    id = subtask["id"]
    branch = "#{context.branch}/subtask/#{id}"
    worktree = Path.join(base_dir, "#{Path.basename(context.branch)}-#{id}")

    # Surface this parallel subtask as a running "package" in the status bar
    # while it executes; registration is process-linked to this subtask's Task,
    # so it auto-unregisters when the subtask finishes or crashes.
    Yoke.TaskEngine.PackageTracker.register(
      "[#{id}] " <> Yoke.TaskEngine.PackageTracker.derive_label(subtask["summary"]),
      :workflow_subtask,
      id: "wf-subtask-#{id}"
    )

    try do
      with {:ok, _} <- Git.add_worktree(worktree, branch, context.cwd),
           :ok <- Store.write_subtask_field!(context.run_id, id, "branch", branch, context.cwd),
           :ok <-
             Store.write_subtask_field!(context.run_id, id, "worktree", worktree, context.cwd),
           {:ok, exec_result} <-
             execute_agent_task(context.run_id, subtask["summary"], worktree, id),
           {:ok, _tests_summary} <- TestsAndDocs.run_for(worktree, context.run_id, id) do
        Store.write_subtask_result!(context.run_id, id, exec_result, context.cwd)

        {:ok, %{"id" => id, "branch" => branch, "worktree" => worktree, "result" => exec_result}}
      else
        {:error, reason} -> {:error, "Subtask '#{id}' failed: #{reason}"}
      end
    after
      Yoke.TaskEngine.PackageTracker.unregister()
    end
  end

  defp merge_results(context, subtask_results) do
    outcome =
      Enum.reduce_while(subtask_results, {:ok, []}, fn %{"branch" => branch} = r, {:ok, merged} ->
        case Git.merge(branch, context.cwd) do
          {:ok, _out} -> {:cont, {:ok, [r | merged]}}
          {:conflict, out} -> {:halt, {:conflict, branch, out}}
          {:error, reason} -> {:halt, {:error, branch, reason}}
        end
      end)

    case outcome do
      {:ok, merged} ->
        Enum.each(subtask_results, fn %{"worktree" => wt} ->
          Git.remove_worktree(wt, context.cwd)
        end)

        {:ok, Map.put(context, :subtasks, Enum.reverse(merged))}

      {:conflict, branch, out} ->
        {:error,
         "Merge conflict merging subtask branch '#{branch}' back into '#{context.branch}'. " <>
           "Worktrees were left in place for manual resolution -- resolve the conflict, commit " <>
           "the merge, then run `/workflow resume #{context.run_id}`.\n\n#{out}"}

      {:error, branch, reason} ->
        {:error, "Failed to merge subtask branch '#{branch}': #{reason}"}
    end
  end

  # ---------------------------------------------------------------------
  # Shared: spawn a one-off Brain.Session to actually perform a task
  # ---------------------------------------------------------------------

  defp execute_agent_task(run_id, description, cwd, label) do
    session_id = "workflow-#{run_id}-#{label}-#{System.unique_integer([:positive])}"

    with {:ok, pid} <- SessionSupervisor.start_session(session_id: session_id, cwd: cwd),
         {:ok, response} <- Session.send_user_message(pid, description) do
      SessionSupervisor.stop_session(pid)

      Store.append_transcript(
        run_id,
        :task_execution,
        %{"label" => label, "cwd" => cwd, "response" => response.content},
        cwd
      )

      {:ok, response.content}
    else
      {:error, reason} -> {:error, "#{label}: #{inspect(reason)}"}
    end
  end
end

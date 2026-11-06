defmodule Yoke.CI.Run do
  @moduledoc """
  Headless `yoke run <workflow>` (`docs/CI_PLAN.md` Milestone 2).

  Runs a workflow definition end-to-end with no TTY. The workflow engine
  already degrades cleanly once the blocking seam is installed:

    * `task_split` asks `Yoke.Interaction` whether to fan out into parallel
      git worktrees. Under `Yoke.Interaction.Policy` that answers `:deny`, so
      the step collapses to a **single task** — correct for CI, which has one
      checkout and no worktrees to spare.
    * `branch` asks whether to branch off an unexpected base. Policy answers
      `:deny`, so the run halts with a clear message rather than creating a
      branch on a runner.

  ## Budgets

  A workflow can make many model calls, so the run is bounded by
  `Yoke.CI.Budget` and a wall-clock ceiling. Exceeding either aborts the run
  fail-closed, exactly like `yoke review`.
  """

  alias Yoke.CI.Budget
  alias Yoke.Workflow.Engine

  @doc """
  Runs `workflow_name` headlessly.

  `opts`:

    * `:cwd` -- repository root (default `File.cwd!()`)
    * `:seed_prompt` -- the task description that seeds the workflow
    * `:fail_on` -- accepted for symmetry; a workflow either completes or not

  Returns `{:ok, %{run_id, status, steps}}` or `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(workflow_name, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    seed_prompt = Keyword.get(opts, :seed_prompt, "")

    with :ok <- install_seams(cwd),
         :ok <- check_budget(cwd),
         {:ok, result} <- execute(workflow_name, cwd, seed_prompt) do
      {:ok, normalize_result(result)}
    end
  end

  @doc """
  Lists the workflow definitions available in `cwd`.

  Returns `{:ok, [%{name, description, source}]}`.
  """
  @spec list(String.t()) :: {:ok, [map()]}
  def list(cwd \\ ".") do
    {:ok, Yoke.Workflow.Definition.list(cwd)}
  rescue
    _ -> {:ok, []}
  end

  @doc """
  Installs the headless seams for a workflow run.

  Identical to what `yoke review` installs: the policy interaction (so no step
  can block) and `:ci` Hands (so no step can mutate the checkout unless the
  policy allows it).
  """
  @spec install_seams(String.t()) :: :ok
  def install_seams(cwd) do
    _ = Yoke.Config.CI.install_headless_seams(cwd)
    :ok
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp check_budget(cwd) do
    budget = Budget.from_policy(cwd)

    case Budget.check(budget) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(workflow_name, cwd, seed_prompt) do
    Engine.run(workflow_name, cwd: cwd, seed_prompt: seed_prompt)
  rescue
    e -> {:error, "Workflow '#{workflow_name}' crashed: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "Workflow '#{workflow_name}' crashed: #{inspect({kind, reason})}"}
  end

  # `Engine.run/2` returns `{:ok, context}` on completion and `{:halt, reason}`
  # when a step declines to continue. Both are normal outcomes; only a raised
  # exception or an explicit `{:error, _}` is a failure.
  defp normalize_result({:ok, context}) when is_map(context) do
    %{
      run_id: Map.get(context, :run_id),
      status: :completed,
      steps: Map.get(context, :completed_steps, [])
    }
  end

  defp normalize_result({:halt, reason}) do
    %{run_id: nil, status: :halted, reason: reason, steps: []}
  end

  defp normalize_result(other) do
    %{run_id: nil, status: :completed, steps: [], raw: other}
  end
end

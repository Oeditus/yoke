defmodule Yoke.Workflow.Steps.Branch do
  @moduledoc """
  Step ①: creates and checks out a dedicated branch for this workflow
  run, off the current branch. Warns and asks for confirmation first if
  the current branch isn't one of the workflow's `base_branch_prefixes`
  (default `main`/`master`), since branching a workflow off some other,
  possibly unrelated feature branch is rarely what was intended.
  """
  @behaviour Yoke.Workflow.Step

  alias Yoke.Git
  alias Yoke.Workflow.Store

  @impl true
  def run(context, params) do
    prefix = Map.get(params, "branch_prefix") || "yoke/#{context.workflow.name}"
    current = Git.current_branch(context.cwd)

    if current in context.workflow.base_branch_prefixes do
      create(context, prefix, current)
    else
      warn_and_confirm(context, prefix, current)
    end
  end

  @doc "Deterministically builds a branch name from a prefix and this run's unique ID."
  def branch_name(prefix, run_id), do: Path.join(prefix, run_id)

  defp warn_and_confirm(context, prefix, current) do
    allowed = Enum.join(context.workflow.base_branch_prefixes, "/")

    question =
      "Current branch is '#{current}', not one of the expected base branches (#{allowed}). " <>
        "Branch the '#{context.workflow.name}' workflow off '#{current}' anyway?"

    case Yoke.Interaction.ask(:workflow_confirm, %{
           question: question,
           options: ["Yes, branch off '#{current}'", "Abort workflow"],
           workflow: context.workflow.name,
           cwd: Map.get(context, :cwd)
         }) do
      :approve ->
        create(context, prefix, current)

      _ ->
        {:halt,
         "Workflow aborted before branching: no explicit confirmation to branch off '#{current}'."}
    end
  end

  defp create(context, prefix, base_branch) do
    branch = branch_name(prefix, context.run_id)

    case Git.create_branch(branch, context.cwd) do
      {:ok, _out} ->
        Store.append_transcript(
          context.run_id,
          :branch_created,
          %{"branch" => branch, "base_branch" => base_branch},
          context.cwd
        )

        {:ok, Map.merge(context, %{branch: branch, original_branch: base_branch})}

      {:error, reason} ->
        {:error, "Failed to create workflow branch '#{branch}': #{reason}"}
    end
  end
end

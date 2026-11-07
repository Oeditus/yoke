defmodule Yoke.Workflow.Steps.Prompt do
  @moduledoc """
  Free-form step type for custom workflows: sends a `{{variable}}`-
  interpolated `"template"` string as an instruction to a session rooted
  at the workflow's own branch, so a custom `.yoke/workflows/definitions/`
  file can splice bespoke instructions between the built-in step types
  without writing any Elixir code.
  """
  @behaviour Yoke.Workflow.Step

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Workflow.Store

  @impl true
  def run(context, params) do
    template = Map.get(params, "template", "")
    text = interpolate(template, context)
    session_id = "workflow-#{context.run_id}-prompt-#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(Map.get(context, :provider_options, []),
        session_id: session_id,
        cwd: context.cwd
      )

    with {:ok, pid} <- SessionSupervisor.start_session(opts),
         {:ok, response} <- Session.send_user_message(pid, text) do
      SessionSupervisor.stop_session(pid)

      Store.append_transcript(
        context.run_id,
        :custom_prompt,
        %{"template" => template, "response" => response.content},
        context.cwd
      )

      {:ok, context}
    else
      {:error, reason} -> {:error, "Custom prompt step failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Interpolates `{{key}}` placeholders in `template` using values drawn
  from the workflow context (`task_description`, `branch`, `workflow`,
  `run_id`). Unknown placeholders are left untouched.
  """
  def interpolate(template, context) when is_binary(template) do
    vars = %{
      "task_description" => Map.get(context, :task_description, ""),
      "branch" => Map.get(context, :branch, ""),
      "workflow" => context.workflow.name,
      "run_id" => context.run_id
    }

    Enum.reduce(vars, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", value)
    end)
  end
end

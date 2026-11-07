defmodule Yoke.Workflow.Steps.TestsAndDocs do
  @moduledoc """
  Step ④: after a (sub)task's code changes, requires tests and
  documentation to be added or updated for them, then actually runs
  `mix test` to verify it rather than trusting the model's own claim.

  `run_for/3` is the reusable core: it's called once at the top level
  (against the workflow's own branch, via the `run/2` behaviour
  callback) and again internally, once per accepted subtask, by
  `Steps.TaskSplit` -- before that subtask's branch is merged back, so a
  broken test/doc pass is caught and attributed to the right subtask
  instead of surfacing only after everything has already been merged.
  """
  @behaviour Yoke.Workflow.Step

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Workflow.Store

  @instruction """
  Review the code changes made so far on this branch (compare against the \
  branch's starting point/base). For every behavioral change: (1) add or \
  update automated tests covering it, and (2) update any affected \
  documentation (@doc/@moduledoc, README, or docs/ pages) to reflect the new \
  behavior. Do not skip this even if you believe a change is trivial. When \
  finished, briefly summarize exactly what tests and documentation you added \
  or updated.
  """

  @impl true
  def run(context, _params) do
    case run_for(context.cwd, context.run_id, "workflow", Map.get(context, :provider_options, [])) do
      {:ok, summary} -> {:ok, Map.update(context, :notes, [summary], &(&1 ++ [summary]))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawns a one-off `Brain.Session` rooted at `cwd`, instructs it to
  add/update tests and documentation for whatever changed there, then
  runs `mix test` to actually verify the claim.
  """
  def run_for(cwd, run_id, label, provider_opts \\ []) do
    session_id = "workflow-#{run_id}-tests-#{label}-#{System.unique_integer([:positive])}"

    opts = Keyword.merge(provider_opts, session_id: session_id, cwd: cwd)

    with {:ok, pid} <- SessionSupervisor.start_session(opts),
         {:ok, response} <- Session.send_user_message(pid, @instruction) do
      SessionSupervisor.stop_session(pid)

      Store.append_transcript(
        run_id,
        :tests_and_docs,
        %{"label" => label, "cwd" => cwd, "response" => response.content},
        cwd
      )

      case run_mix_test(cwd) do
        {:ok, _out} ->
          {:ok, response.content}

        {:error, out} ->
          {:error, "`mix test` failed after the tests/docs pass for #{label}:\n#{out}"}
      end
    else
      {:error, reason} -> {:error, "Tests/docs pass failed for #{label}: #{inspect(reason)}"}
    end
  end

  defp run_mix_test(cwd) do
    if File.exists?(Path.join(cwd, "mix.exs")) do
      case System.cmd("mix", ["test"], cd: cwd, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, _code} -> {:error, out}
      end
    else
      {:ok, "(no mix.exs found at #{cwd}; skipping `mix test`)"}
    end
  rescue
    e -> {:error, "Failed to run `mix test`: #{Exception.message(e)}"}
  end
end

defmodule Yoke.TaskEngine.PackageTracker do
  @moduledoc """
  Tracks long-running, named parallel "packages" so the status bar and
  spinner can surface them to the user in real time.

  Individual tool calls are already tracked per-batch by the
  `TaskEngine.TaskRegistry` (see `TaskEngine.Supervisor.list_active_tasks/0`),
  but a *package* is a higher-level unit of parallel work that outlives any
  single tool call -- an async `spawn_subagent` worker, or one of a
  workflow's parallel subtasks, each of which runs its own full agentic
  `Brain.Session` loop. Surfacing those packages (with human labels like
  `[A] plan_gate`) keeps the user aware of what is still running while the
  main turn proceeds.

  Backed by a `:duplicate` `Registry` (`Yoke.PackageRegistry`)
  started under `TaskEngine.Supervisor`. Registration is process-linked, so
  if the worker process that registered a package crashes or is killed, its
  entry is removed automatically -- no stale "running" label can leak into
  the status bar.

  Mirrors the conventions of `TaskEngine.Orchestrator`'s active-task
  registration and `TaskEngine.Supervisor.list_active_tasks/0`.
  """

  @registry Yoke.PackageRegistry
  @key "running_package"

  @doc "Registers a running package under a given label and returns its id."
  def register(label, kind \\ :package, opts \\ []) when is_binary(label) do
    id = opts[:id] || "pkg_#{System.unique_integer([:positive])}"

    entry = %{
      id: id,
      label: label,
      kind: kind,
      started_at: System.system_time(:second)
    }

    case Registry.register(@registry, @key, entry) do
      {:ok, _owner} -> {:ok, id}
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @doc "Unregisters the calling process's running-package entry (if any)."
  def unregister do
    Registry.unregister(@registry, @key)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Lists all currently running packages, oldest first."
  def list do
    @registry
    |> Registry.lookup(@key)
    |> Enum.map(fn {_pid, entry} -> entry end)
    |> Enum.sort_by(& &1.started_at)
  rescue
    _ -> []
  end

  @doc "Returns a short, comma-joined label summary of all running packages."
  def list_labels do
    Enum.map_join(list(), ", ", fn %{label: label} -> label end)
  end

  @doc """
  Derives a compact, human label from a free-form prompt or task description
  (e.g. a subagent prompt or workflow subtask summary), for use as a package
  label in the status bar. Takes the first sentence/fragment, strips the
  rules preamble and newlines, and truncates to ~28 chars.
  """
  def derive_label(text) when is_binary(text) do
    text
    |> strip_preamble()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate_label()
  end

  def derive_label(_), do: "task"

  defp strip_preamble(text) do
    # Drop leading execution rules, language practices, or system preambles if present.
    case Yoke.Brain.SessionStore.clean_prompt_text(text) do
      "" ->
        case String.split(text, "===============================", parts: 2) do
          [_preamble, rest] -> String.trim(rest)
          _ -> text
        end

      cleaned ->
        cleaned
    end
  end

  defp truncate_label(label) do
    if String.length(label) > 28 do
      String.slice(label, 0, 25) <> "..."
    else
      label
    end
  end
end

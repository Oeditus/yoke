defmodule Yoke.TaskEngine.Supervisor do
  @moduledoc """
  OTP Supervisor for the TaskEngine subsystem in Yoke.
  Supervises the Task.Supervisor for concurrent worker processes,
  the LockRegistry for mutating resource locks, and the TaskRegistry
  for real-time active task tracking.
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Task.Supervisor, name: Yoke.TaskEngine.TaskSupervisor},
      {Registry, keys: :unique, name: Yoke.TaskEngine.LockRegistry},
      {Registry, keys: :duplicate, name: Yoke.TaskEngine.TaskRegistry},
      # Duplicate registry tracking long-running named "packages" (async
      # subagents, workflow parallel subtasks) so the status bar & spinner
      # can surface them. See `TaskEngine.PackageTracker`.
      {Registry, keys: :duplicate, name: Yoke.PackageRegistry},
      {Yoke.TaskEngine.JobManager, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Lists all currently active parallel tasks registered in TaskRegistry."
  def list_active_tasks do
    Yoke.TaskEngine.TaskRegistry
    |> Registry.lookup("active_task")
    |> Enum.map(fn {_pid, info} -> info end)
  rescue
    _ -> []
  end
end

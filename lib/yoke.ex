defmodule Yoke do
  @moduledoc """
  Top-level module for Yoke (Yoke).
  Exposes public API helper methods to interact with sessions, plugins, and distribution.
  """

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Plugin.Loader, as: PluginLoader

  @version Mix.Project.config()[:version]

  @doc "Returns the version of Yoke."
  def version do
    case Application.spec(:yoke, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> @version
    end
  end

  @doc "Starts a new session actor with given options."
  def start_session(opts \\ []) do
    SessionSupervisor.start_session(opts)
  end

  @doc "Sends a message to an active session actor."
  def send_message(session_pid, text) do
    Session.send_user_message(session_pid, text)
  end

  @doc "Loads a plugin file dynamically."
  def load_plugin(path) do
    PluginLoader.load_file(path)
  end

  @doc "Reloads all loaded plugins dynamically without dropping state."
  def reload_plugins do
    PluginLoader.reload_all()
  end

  @doc "Returns total number of BEAM processes currently serving across the system."
  def serving_process_count do
    length(Process.list())
  end

  @doc "Returns structured process status map reporting current serving processes and task workers."
  def process_status do
    active_task_workers =
      case Process.whereis(Yoke.TaskEngine.TaskSupervisor) do
        nil -> 0
        sup -> length(Task.Supervisor.children(sup))
      end

    active_sessions =
      if Process.whereis(Yoke.Registry) != nil do
        Registry.select(Yoke.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.count(&(is_binary(&1) and String.starts_with?(&1, "session_")))
      else
        0
      end

    %{
      total_serving_processes: length(Process.list()),
      active_task_workers: active_task_workers,
      active_sessions: active_sessions,
      schedulers_online: System.schedulers_online()
    }
  end

  @doc "Returns a human-readable status banner of active task workers and sessions."
  def report_serving_processes do
    status = process_status()

    "#{status.active_task_workers} active task workers, #{status.active_sessions} session actors"
  end
end

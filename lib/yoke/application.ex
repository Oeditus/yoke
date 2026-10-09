defmodule Yoke.Application do
  @moduledoc """
  OTP Application supervision tree for Yoke (Yoke).
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Yoke.CLI.LogFormatter.install()

    children = [
      # Unique registry for process naming via tuple
      {Registry, keys: :unique, name: Yoke.Registry},
      # Duplicate registry for session broadcasting (pubsub)
      {Registry, keys: :duplicate, name: Yoke.PubSubRegistry},
      # Coordinates Logger output with whichever CLI surface (idle prompt,
      # question modal) currently owns the terminal
      Yoke.CLI.TerminalOwner,
      # Synchronizes all user interactions and questions (interruptions) across main agents & subagents
      Yoke.CLI.InteractionServer,
      # Tracks and analyzes bash command calls, counts, frequencies, and Ragex analogs
      Yoke.BashTracker,
      # Dynamic plugin hot-reloader & tool registry
      Yoke.Plugin.Loader,
      # MCP Server Manager
      Yoke.MCP.ServerManager,
      # OTP Task Subsystem (Task.Supervisor & LockRegistry)
      Yoke.TaskEngine.Supervisor,
      # Supervisor for session actors ("Brains")
      Yoke.Brain.SessionSupervisor
    ]

    opts = [strategy: :one_for_all, name: Yoke.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        install_sigterm_trap()
        Logger.info("[Yoke] Application started successfully.")
        {:ok, pid}

      error ->
        error
    end
  end

  # Terminal/process-manager shutdowns (e.g. `kill`, closing the terminal tab)
  # commonly deliver SIGTERM rather than going through the REPL's `/exit`
  # path. Without this, the per-project Ragex/dllb OS process is left
  # running as an orphan, so the next launch can't reliably reuse its
  # on-disk cache and ends up doing a full re-index every time.
  defp install_sigterm_trap do
    System.trap_signal(:sigterm, :yoke_graceful_shutdown, fn ->
      try do
        Yoke.MCP.ServerManager.stop_ragex()
      catch
        _, _ -> :ok
      end

      :ok
    end)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

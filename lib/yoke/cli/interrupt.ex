defmodule Yoke.CLI.Interrupt do
  @moduledoc """
  Lets the user break out of an in-flight "AI is responding" turn by
  pressing Ctrl+Q, instead of only Ctrl+C -- which raises SIGINT and tears
  down the whole Erlang VM (losing the entire session, not just the one
  long/misbehaving turn).

  `run/2` executes `turn_fun` (a blocking call into
  `Yoke.Brain.Session`, e.g. `Session.send_user_message/2` or
  `Session.generate_code_review/3`) in its own Task while concurrently
  watching raw keystrokes for Ctrl+Q. On Ctrl+Q, `Session.cancel_current_turn/1`
  is called against `session_pid`, which aborts the session's own in-flight
  agent-loop Task and makes the still-pending `turn_fun` call return
  `{:error, "Turn cancelled by user (Ctrl+Q)."}` almost immediately -- the
  session process itself is never killed, so conversation history up to
  (but not including) the interrupted turn is preserved intact.

  Known limitation: while a permission-confirmation or `ask_question`
  modal is on-screen (i.e. `Yoke.CLI.Spinner` is paused -- see
  `Yoke.CLI.Spinner.with_paused/1`), the keystroke watcher below
  backs off entirely rather than competing with that modal for keystrokes.
  Ctrl+Q is only recognized while the spinner itself is actively showing
  ("AI is responding"), not while the AI is waiting on a modal answer --
  use the modal's own Ctrl+C ("deny"/"cancelled") in that case.
  """
  alias Yoke.Brain.Session
  alias Yoke.CLI.Spinner

  @ctrl_q "\x11"
  @ctrl_o "\x0f"
  @paused_poll_interval_ms 120

  use Agent

  @doc "Starts the (named, singleton) Interrupt agent."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Pauses the Ctrl+Q keystroke watcher if running, killing its process so it
  releases any pending I/O read requests on stdin while a modal is open.
  """
  def pause do
    ensure_started()

    case Agent.get(__MODULE__, & &1) do
      %{watcher: watcher, ref: ref, session_pid: session_pid} ->
        stop_watcher(watcher, ref)
        Agent.update(__MODULE__, fn _ -> %{session_pid: session_pid, paused: true} end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Resumes the Ctrl+Q keystroke watcher if it was previously paused for a modal.
  """
  def resume do
    ensure_started()

    case Agent.get(__MODULE__, & &1) do
      %{session_pid: session_pid, paused: true} ->
        {watcher, watcher_ref} = spawn_monitor(fn -> watch_for_interrupt(session_pid) end)

        Agent.update(__MODULE__, fn _ ->
          %{watcher: watcher, ref: watcher_ref, session_pid: session_pid}
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Runs `turn_fun` (a zero-arity function) to completion, or until the user
  presses Ctrl+Q while it's running -- in which case
  `Session.cancel_current_turn/1` is called against `session_pid` and this
  returns as soon as `turn_fun` itself then returns (almost immediately
  after cancellation).

  Falls back to running `turn_fun.()` directly, without any keystroke
  watching, when stdin isn't a real interactive terminal (tests, CI,
  piped input) -- there would be no keyboard to watch for Ctrl+Q anyway.
  """
  def run(session_pid, turn_fun) when is_function(turn_fun, 0) do
    if tty?() do
      run_interruptible(session_pid, turn_fun)
    else
      turn_fun.()
    end
  end

  defp run_interruptible(session_pid, turn_fun) do
    ensure_started()
    task = Task.async(turn_fun)

    # `spawn_monitor/1` (rather than `spawn/1` + a later `Process.monitor/1`)
    # guarantees we hold a monitor ref for the watcher from the instant it
    # exists, so the `after` block below can synchronously wait for it to
    # die before touching the terminal mode.
    {watcher, watcher_ref} = spawn_monitor(fn -> watch_for_interrupt(session_pid) end)

    Agent.update(__MODULE__, fn _ ->
      %{watcher: watcher, ref: watcher_ref, session_pid: session_pid}
    end)

    try do
      Task.await(task, :infinity)
    after
      pause()
      Agent.update(__MODULE__, fn _ -> nil end)
      Yoke.CLI.LineEditor.purge_dead_io_requests()
      restore_tty_mode()
      Yoke.CLI.Formatter.flush()
    end
  end

  # Kills the watcher and waits (bounded) for its `:DOWN` before returning,
  # so no in-flight `set_raw_mode/0` can race the caller's `restore_tty_mode/0`,
  # then purges the killed watcher's orphaned `:get_chars` request from `:group`.
  defp stop_watcher(watcher, ref) do
    Process.exit(watcher, :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      500 -> :ok
    end

    Yoke.CLI.LineEditor.purge_dead_io_requests()
  end

  defp watch_for_interrupt(session_pid) do
    if Spinner.active?() and Spinner.paused?() do
      # A confirmation/question modal (or the max-tool-depth "continue?"
      # prompt) currently owns the TTY -- see the moduledoc's "Known
      # limitation" -- back off and check again shortly rather than racing
      # it for keystrokes.
      Process.sleep(@paused_poll_interval_ms)
      watch_for_interrupt(session_pid)
    else
      # Re-assert raw mode on every iteration: a modal that just finished
      # (`Yoke.CLI.QuestionPrompt`) unconditionally restores
      # cooked mode when *it* exits, since it has no idea this outer
      # "AI is responding" phase still wants raw mode for the rest of the
      # turn. Cooked mode would otherwise silently break Ctrl+Q detection
      # (many terminals treat it as XON software flow control, consuming
      # it before it ever reaches this program) for whatever remains of
      # the turn. Idempotent/cheap when already raw.
      set_raw_mode()

      case read_char() do
        @ctrl_q ->
          Session.cancel_current_turn(session_pid)

        @ctrl_o ->
          Yoke.CLI.LineEditor.toggle_expand_tool_calls(%{})
          watch_for_interrupt(session_pid)

        :eof ->
          :ok

        _other ->
          watch_for_interrupt(session_pid)
      end
    end
  end

  defp read_char do
    case :io.get_chars("", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
    end
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      false
    else
      case :io.columns() do
        {:ok, _} -> true
        _ -> false
      end
    end
  end
end

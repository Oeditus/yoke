defmodule Yoke.CLI.Spinner do
  @moduledoc """
  Terminal spinner component for Yoke.
  Renders a single animated progress indicator ("⠋") at the bottom of the screen.
  Coordinates with Logger and LogFormatter to ensure log lines print above the spinner
  without corrupting or duplicating the spinner indicator.
  """
  use GenServer

  alias Yoke.CLI.Formatter

  @frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @default_title "Thinking & coordinating with Hands…"

  # Client API

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    if active?() do
      case GenServer.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          ref = Process.monitor(pid)
          res = GenServer.call(pid, :stop)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            500 -> :ok
          end

          res

        _ ->
          :ok
      end
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Pauses spinner redraws without stopping the process.

  Any other process that needs to render its own content to the terminal
  (e.g. `Yoke.CLI.QuestionPrompt`) MUST call this before writing,
  otherwise the spinner's periodic `\r\e[2K<frame>` redraws race with that
  output and corrupt the terminal. Safe to call even if the spinner isn't
  running.
  """
  def pause do
    Yoke.CLI.Interrupt.pause()

    if active?() do
      try do
        GenServer.call(__MODULE__, :pause, 500)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc "Resumes spinner redraws after a previous `pause/0`. Safe to call even if the spinner isn't running."
  def resume do
    if active?() do
      try do
        GenServer.call(__MODULE__, :resume, 500)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end

    # Resume the Ctrl+Q watcher if one was paused for a modal.
    Yoke.CLI.Interrupt.resume()
  end

  @doc """
  Runs `fun` with the spinner paused, then resumes it (if it was active).
  No-op wrapper around `fun.()` when the spinner isn't running.
  """
  def with_paused(fun) when is_function(fun, 0) do
    pause()

    try do
      fun.()
    after
      resume()
    end
  end

  def active? do
    match?({:ok, _pid}, GenServer.whereis(__MODULE__) |> case_pid())
  end

  @doc """
  Returns whether the spinner is currently active but paused (e.g. via
  `with_paused/1`, used while a question modal or other one-off terminal
  render is shown). `active?/0` alone stays `true` while paused since the
  process is still alive, so callers that need to know whether the
  spinner is actually *redrawing* right now (as opposed to merely started)
  should check `active?() and not paused?()`.
  """
  def paused? do
    if active?() do
      try do
        GenServer.call(__MODULE__, :paused?, 500)
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end

  def current_line do
    if active?() do
      try do
        GenServer.call(__MODULE__, :get_current_line, 50)
      catch
        :exit, _ -> ""
      end
    else
      ""
    end
  end

  def run(fun, opts \\ []) when is_function(fun, 0) do
    {:ok, _pid} = start(opts)

    try do
      fun.()
    after
      stop()
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    title = Keyword.get(opts, :title, @default_title)
    refresh_every = Keyword.get(opts, :refresh_every, 80)
    user_tip = Keyword.get(opts, :tip, :auto)

    {tip, auto_tip?} =
      case user_tip do
        :auto -> {Formatter.random_tip(), true}
        nil -> {Formatter.random_tip(), true}
        false -> {nil, false}
        "" -> {nil, false}
        custom when is_binary(custom) -> {custom, false}
        _ -> {Formatter.random_tip(), true}
      end

    enabled? = tty?()

    state = %{
      title: title,
      refresh_every: refresh_every,
      frame_idx: 0,
      tick_count: 0,
      tip: tip,
      auto_tip?: auto_tip?,
      enabled?: enabled?,
      timer: nil,
      paused: false,
      start_time: System.monotonic_time(:millisecond)
    }

    state =
      if enabled? do
        timer = Process.send_after(self(), :tick, refresh_every)
        render_frame(state)
        %{state | timer: timer}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if state.enabled? do
      clear_line()
      # Flush the clear immediately so the next writer (e.g. the REPL
      # printing an assistant response) starts from a clean, current line
      # rather than racing a still-buffered `\r\e[2K`.
      Formatter.flush()
    end

    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:paused?, _from, state) do
    {:reply, state.paused, state}
  end

  @impl true
  def handle_call(:get_current_line, _from, state) do
    # `current_line/0` reports what the spinner would render right now. It is
    # a pure query of state, so it does NOT depend on `enabled?` (whether this
    # process is attached to a real terminal and actually writing frames) --
    # that flag only gates the write path (`render_frame`/`clear_line`). Gating
    # the query on it made the getter return "" in non-TTY test/CI runs even
    # though the spinner was active and unpaused. Only an explicit `pause`
    # suppresses the current line.
    line =
      if state.paused do
        ""
      else
        frame = Enum.at(@frames, state.frame_idx)
        raw_line = format_line(frame, state.title, state.tip, status_extra(state))
        truncate_line(raw_line, terminal_cols() - 1)
      end

    {:reply, line, state}
  end

  @impl true
  def handle_call(:pause, _from, %{paused: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:pause, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.enabled?, do: clear_line()
    {:reply, :ok, %{state | timer: nil, paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, %{paused: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    state = %{state | paused: false}

    if state.enabled? do
      render_frame(state)
      timer = Process.send_after(self(), :tick, state.refresh_every)
      {:reply, :ok, %{state | timer: timer}}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:tick, %{paused: true} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    new_idx = rem(state.frame_idx + 1, length(@frames))
    new_tick_count = state.tick_count + 1

    new_tip =
      if state.auto_tip? and rem(new_tick_count, 50) == 0 do
        Formatter.random_tip()
      else
        state.tip
      end

    new_state = %{state | frame_idx: new_idx, tick_count: new_tick_count, tip: new_tip}

    if state.enabled? do
      render_frame(new_state)
      timer = Process.send_after(self(), :tick, state.refresh_every)
      {:noreply, %{new_state | timer: timer}}
    else
      {:noreply, new_state}
    end
  end

  def format_line(frame, title, tip \\ nil, extra \\ nil) do
    base = "#{frame} #{title}"
    base = if is_binary(extra) and extra != "", do: "#{base} #{extra}", else: base

    case tip do
      nil ->
        base

      "" ->
        base

      false ->
        base

      tip_str when is_binary(tip_str) ->
        "#{base}  #{Formatter.gray()}(Tip: #{tip_str})#{Formatter.reset()}"
    end
  end

  defp render_frame(state) do
    frame = Enum.at(@frames, state.frame_idx)
    raw_line = format_line(frame, state.title, state.tip, status_extra(state))
    cols = terminal_cols()
    line = truncate_line(raw_line, cols - 1)
    IO.write("\r\e[2K")
    IO.write(line)
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, c} when is_integer(c) and c > 10 -> c
      _ -> 120
    end
  end

  defp truncate_line(line, max_cols) do
    if Yoke.CLI.QuestionPrompt.display_width(line) > max_cols do
      try do
        Owl.Data.truncate(line, max_cols) |> to_string()
      rescue
        _ -> line
      end
    else
      line
    end
  end

  # Builds the live "(elapsed) ⚡N parallel" fragment shown while the spinner
  # runs, surfacing the OTP TaskEngine's real-time parallel task count AND any
  # named packages (async subagents, workflow subtasks) currently running, so
  # the user stays aware of what is in flight.
  defp status_extra(state) do
    elapsed = format_elapsed(System.monotonic_time(:millisecond) - Map.get(state, :start_time, 0))

    packages = Yoke.TaskEngine.PackageTracker.list()

    tasks =
      case Yoke.TaskEngine.Supervisor.list_active_tasks() do
        [] -> []
        ts -> ts
      end

    unit_count = length(packages) + length(tasks)

    labels = Enum.map(packages, fn p -> p.label end)
    summaries = Enum.map(tasks, fn t -> t.summary end)

    detail =
      case labels ++ summaries do
        [] -> ""
        list -> " (" <> Enum.join(list, ", ") <> ")"
      end

    task_str =
      if unit_count > 0 do
        " #{Formatter.yellow()}⚡#{unit_count} running#{Formatter.reset()}"
      else
        ""
      end

    "#{Formatter.dim()}(#{elapsed})#{Formatter.reset()}#{task_str}#{Formatter.dim()}#{detail}#{Formatter.reset()}"
  rescue
    _ -> ""
  end

  defp format_elapsed(ms) when is_integer(ms) and ms < 60_000 do
    :erlang.float_to_binary(max(ms, 0) / 1000, decimals: 1) <> "s"
  end

  defp format_elapsed(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)
    m = div(total_seconds, 60)
    s = rem(total_seconds, 60)
    "#{m}m #{String.pad_leading(Integer.to_string(s), 2, "0")}s"
  end

  defp format_elapsed(_), do: "0.0s"

  defp clear_line do
    IO.write("\r\e[2K")
  end

  defp tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp case_pid(nil), do: :error
  defp case_pid(pid) when is_pid(pid), do: {:ok, pid}
end

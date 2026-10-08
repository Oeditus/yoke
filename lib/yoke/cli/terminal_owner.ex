defmodule Yoke.CLI.TerminalOwner do
  @moduledoc """
  Tracks whichever CLI surface currently "owns" the bottom of the terminal
  (the idle REPL prompt via `Yoke.CLI.LineEditor`, or an
  interactive modal via `Yoke.CLI.QuestionPrompt`), so that
  asynchronous `Logger` output can be interleaved safely instead of
  printing directly into the middle of whatever is currently rendered.

  Any surface that draws itself using relative ANSI cursor movement (i.e.
  it erases its own last render before redrawing) should register an
  `{erase, redraw, state}` triple here on every render via `set/3`, and
  clear the registration via `clear/0` once it stops owning the terminal
  (finished, cancelled, or crashed). `Yoke.CLI.LogFormatter`
  calls `interject/1` for every log line: if a surface is registered, the
  line is erase -> printed -> redrawn around; otherwise it's printed as-is.

  Only a single registration is tracked at a time, matching this CLI's
  actual usage: the idle prompt and a question modal never render
  concurrently (question prompts always run with the prompt loop blocked
  on the call, and `Yoke.CLI.Spinner.with_paused/1` already
  ensures the spinner isn't independently redrawing at the same time).
  """
  use Agent

  @doc "Starts the (named, singleton) TerminalOwner agent."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Registers the currently active foreground surface.

  `erase` and `redraw` are 1-arity functions taking `state` (whatever the
  caller needs to erase/redraw its last render) and performing the actual
  terminal I/O. Re-registering (e.g. on every keystroke) simply replaces
  the previous registration with a fresher `state` snapshot.
  """
  def set(erase, redraw, state) when is_function(erase, 1) and is_function(redraw, 1) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %{erase: erase, redraw: redraw, state: state} end)
  end

  @doc "Clears the current registration, if any. Safe to call even if nothing is registered."
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.update(pid, fn _ -> nil end)
    end
  end

  @doc "Returns whether a foreground surface is currently registered."
  def active? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Agent.get(pid, & &1) != nil
    end
  end

  @doc """
  Interjects `line` above the currently registered surface (erase -> print
  -> redraw), or prints it as-is when nothing is registered.
  """
  def interject(line) do
    case Process.whereis(__MODULE__) && Agent.get(__MODULE__, & &1) do
      %{erase: erase, redraw: redraw, state: state} ->
        erase.(state)
        IO.write(line)
        redraw.(state)

      _ ->
        IO.write(line)
    end
  rescue
    _ -> IO.write(line)
  catch
    _, _ -> IO.write(line)
  end

  @doc "Redraws the currently registered surface in place without printing any line."
  def redraw do
    case Process.whereis(__MODULE__) && Agent.get(__MODULE__, & &1) do
      %{erase: erase, redraw: redraw, state: state} ->
        erase.(state)
        redraw.(state)

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
end

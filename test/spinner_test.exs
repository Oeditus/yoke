defmodule Yoke.CLI.SpinnerTest do
  use ExUnit.Case, async: false

  alias Yoke.CLI.Spinner

  setup do
    Spinner.stop()
    on_exit(fn -> Spinner.stop() end)

    # This module's assertions describe the interactive spinner line, which
    # is the only mode that emits ANSI. Pin the output seam to `:tty` so the
    # suite is deterministic regardless of whether it runs in CI.
    prior = Application.get_env(:yoke, :output_mode)
    Application.put_env(:yoke, :output_mode, :tty)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:yoke, :output_mode),
        else: Application.put_env(:yoke, :output_mode, prior)
    end)

    :ok
  end

  @tag ragex: true
  test "starts and stops spinner safely" do
    assert :ok = Spinner.stop()
    refute Spinner.active?()

    {:ok, _pid} = Spinner.start(title: "Testing Spinner")
    assert Spinner.active?()
    assert Spinner.current_line() =~ "Testing Spinner"

    assert :ok = Spinner.stop()
    refute Spinner.active?()
  end

  test "runs function wrapped in spinner" do
    res =
      Spinner.run(
        fn ->
          assert Spinner.active?()
          :done
        end,
        title: "Running test"
      )

    assert res == :done
    refute Spinner.active?()
  end

  test "formats spinner line with gray tip" do
    gray = Yoke.CLI.Formatter.gray()
    reset = Yoke.CLI.Formatter.reset()

    formatted_custom = Spinner.format_line("⠋", "Thinking…", "Use /compact")
    assert formatted_custom == "⠋ Thinking…  #{gray}(Tip: Use /compact)#{reset}"

    formatted_none = Spinner.format_line("⠋", "Thinking…", nil)
    assert formatted_none == "⠋ Thinking…"
  end

  test "spinner includes gray tip when active" do
    {:ok, _pid} = Spinner.start(title: "Processing task", tip: "Use /help for commands")
    raw_line = Spinner.format_line("⠋", "Processing task", "Use /help for commands")
    assert raw_line =~ "Processing task"
    assert raw_line =~ "(Tip: Use /help for commands)"
    assert raw_line =~ Yoke.CLI.Formatter.gray()
    Spinner.stop()
  end

  test "pauses and resumes spinner around nested function execution" do
    {:ok, _pid} = Spinner.start(title: "Active task")
    assert Spinner.active?()

    result =
      Spinner.with_paused(fn ->
        # The spinner process stays alive while paused (so `resume/0` can
        # find and restart it afterwards) -- pausing suppresses rendering,
        # which is what `current_line/0` reflects, not `active?/0`.
        assert Spinner.active?()
        assert Spinner.current_line() == ""
        :paused_result
      end)

    assert result == :paused_result
    assert Spinner.active?()
    Spinner.stop()
  end

  test "paused?/0 reflects pause state while the spinner stays active" do
    refute Spinner.paused?()

    {:ok, _pid} = Spinner.start(title: "Active task")
    assert Spinner.active?()
    refute Spinner.paused?()

    Spinner.pause()
    assert Spinner.active?()
    assert Spinner.paused?()

    Spinner.resume()
    assert Spinner.active?()
    refute Spinner.paused?()

    Spinner.stop()
    refute Spinner.paused?()
  end

  describe "interrupt watcher wake-up" do
    # The Ctrl+Q watcher used to poll `Spinner.paused?()` every 120ms while a
    # modal owned the TTY -- a process spinning at ~8Hz for as long as the
    # human took to answer. It now parks in a `receive` and `Spinner.resume/0`
    # wakes it explicitly.
    test "resume/0 wakes a parked interrupt watcher" do
      alias Yoke.CLI.Interrupt

      Interrupt.ensure_started_for_test()
      test_pid = self()

      # Stand in for the watcher process: record the wake message instead of
      # entering the raw-mode read loop.
      watcher =
        spawn_link(fn ->
          receive do
            {:yoke_interrupt, :resume} -> send(test_pid, :watcher_woken)
          after
            2_000 -> send(test_pid, :watcher_timed_out)
          end
        end)

      Interrupt.__put_watcher_for_test__(watcher)

      Spinner.resume()

      assert_receive :watcher_woken, 1_000
    end

    test "wake_watcher/0 is a no-op when no watcher is parked" do
      alias Yoke.CLI.Interrupt

      Interrupt.ensure_started_for_test()
      Interrupt.__put_watcher_for_test__(nil)

      assert :ok = Interrupt.wake_watcher()
    end
  end
end

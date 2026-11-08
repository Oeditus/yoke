defmodule Yoke.CLI.TerminalOwnerTest do
  # Not async: this module manages a single named, global registration
  # (mirroring its real single-foreground-surface usage), so concurrent
  # tests would stomp on each other's registrations.
  use ExUnit.Case, async: false
  # `Yoke.CLI.TerminalOwner` is a supervised process, and this module's
  # `on_exit` calls `clear/0` on it. Without the tag, `--no-start` fails in the
  # teardown callback with `(EXIT) no process`. See `test/test_helper.exs`.
  @moduletag :app
  import ExUnit.CaptureIO

  alias Yoke.CLI.TerminalOwner

  setup do
    TerminalOwner.clear()
    on_exit(fn -> TerminalOwner.clear() end)
    :ok
  end

  test "active?/0 is false when nothing is registered" do
    refute TerminalOwner.active?()
  end

  test "set/3 registers a surface and active?/0 reflects it" do
    TerminalOwner.set(fn _ -> :ok end, fn _ -> :ok end, %{})
    assert TerminalOwner.active?()
  end

  test "clear/0 unregisters the current surface" do
    TerminalOwner.set(fn _ -> :ok end, fn _ -> :ok end, %{})
    TerminalOwner.clear()
    refute TerminalOwner.active?()
  end

  test "interject/1 prints the line as-is when nothing is registered" do
    output = capture_io(fn -> TerminalOwner.interject("hello\r\n") end)
    assert output == "hello\r\n"
  end

  test "interject/1 erases, prints, then redraws using the latest registered state" do
    parent = self()

    erase = fn state ->
      send(parent, {:erased, state})
      IO.write("ERASE(#{state.n})")
    end

    redraw = fn state ->
      send(parent, {:redrawn, state})
      IO.write("REDRAW(#{state.n})")
    end

    TerminalOwner.set(erase, redraw, %{n: 1})
    output = capture_io(fn -> TerminalOwner.interject("LOG\r\n") end)

    assert output == "ERASE(1)LOG\r\nREDRAW(1)"
    assert_received {:erased, %{n: 1}}
    assert_received {:redrawn, %{n: 1}}
  end

  test "re-registering with set/3 replaces the previous registration's state" do
    parent = self()
    redraw = fn state -> send(parent, {:redrawn, state}) end

    TerminalOwner.set(fn _ -> :ok end, redraw, %{n: 1})
    TerminalOwner.set(fn _ -> :ok end, redraw, %{n: 2})

    capture_io(fn -> TerminalOwner.interject("x") end)
    assert_received {:redrawn, %{n: 2}}
    refute_received {:redrawn, %{n: 1}}
  end
end

defmodule Yoke.CLI.LogFormatterTest do
  # Not async: several tests below drive the globally-named `Spinner` and
  # `TerminalOwner` singletons, which would race against each other (or
  # against `spinner_test.exs`, itself `async: false` for the same reason)
  # if run concurrently.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Yoke.CLI.LineEditor
  alias Yoke.CLI.LogFormatter
  alias Yoke.CLI.Spinner
  alias Yoke.CLI.TerminalOwner

  setup do
    Spinner.stop()
    TerminalOwner.clear()

    on_exit(fn ->
      Spinner.stop()
      TerminalOwner.clear()
    end)

    :ok
  end

  test "formats info log event with blue circle and no timestamp" do
    event = %{
      level: :info,
      msg: {:string, "[Hands.Executor] [local] Executing bash with args: %{}"}
    }

    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "[Hands.Executor] [local] Executing bash with args: %{}")
    refute String.contains?(formatted, "[info]")
  end

  test "formats error log event with red circle" do
    event = %{level: :error, msg: "Failed to connect"}
    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "Failed to connect")
  end

  test "formats warning log event with yellow circle" do
    event = %{level: :warning, msg: "Deprecated tool call"}
    formatted = LogFormatter.format(event, %{})

    assert String.contains?(formatted, "●")
    assert String.contains?(formatted, "Deprecated tool call")
  end

  test "suppresses noisy low-level socket transport logs" do
    event1 = %{level: :info, msg: "[HANDLER] Received data: ping"}
    event2 = %{level: :info, msg: "[ACCEPT LOOP] Starting, socket: #Port<0.35>"}
    event3 = %{level: :info, msg: "Client connected: #Port<0.39>"}

    assert LogFormatter.format(event1, %{}) == ""
    assert LogFormatter.format(event2, %{}) == ""
    assert LogFormatter.format(event3, %{}) == ""
  end

  test "formats reasoning log event with yellow styling and quotes without stair-stepping" do
    event = %{
      level: :info,
      msg: "[DeepSeek-R1 Reasoning]\nNow I have an understanding.\nLet me run some tools."
    }

    formatted = LogFormatter.format(event, %{})

    assert formatted =~ IO.ANSI.yellow()
    assert formatted =~ "● [DeepSeek-R1 Reasoning]"
    assert formatted =~ "“ Now I have an understanding."
    assert formatted =~ "Let me run some tools. ”"
    # All interior newlines must be \r\n
    assert formatted =~ "\r\n"
    refute formatted =~ ~r/[^\r]\n/
  end

  test "ensures multi-line log events use CRLF to prevent stair-stepping in raw mode" do
    event = %{
      level: :info,
      msg: "Line 1\nLine 2\nLine 3"
    }

    formatted = LogFormatter.format(event, %{})

    assert formatted =~ "\r\n"
    refute formatted =~ ~r/[^\r]\n/
  end

  test "installs log formatter handler without raising" do
    assert LogFormatter.install() == :ok or LogFormatter.install() == :error
  end

  test "does not use the spinner's single-line redraw while the spinner is paused" do
    {:ok, _pid} = Spinner.start(title: "Working")
    Spinner.pause()
    assert Spinner.active?()
    assert Spinner.paused?()

    event = %{level: :info, msg: "Some background notice"}
    formatted = LogFormatter.format(event, %{})

    # Falls through to the plain-line branch (no TerminalOwner registered
    # either), rather than the spinner's `\r\e[2K...` single-line redraw --
    # otherwise this would corrupt a multi-line surface (e.g. a question
    # modal) shown while the spinner is merely paused underneath it.
    refute formatted =~ "\e[2K"
    assert formatted =~ "Some background notice"
  end

  test "uses the spinner's single-line redraw while the spinner is active and not paused" do
    {:ok, _pid} = Spinner.start(title: "Working")
    assert Spinner.active?()
    refute Spinner.paused?()

    event = %{level: :info, msg: "Some background notice"}
    formatted = LogFormatter.format(event, %{})

    assert formatted =~ "\e[2K"
    assert formatted =~ "Some background notice"
  end

  test "interjects through a registered TerminalOwner surface and returns an empty string" do
    parent = self()

    erase = fn _state -> send(parent, :erased) end
    redraw = fn _state -> send(parent, :redrawn) end
    TerminalOwner.set(erase, redraw, %{})

    event = %{level: :info, msg: "Some background notice"}

    output =
      capture_io(fn ->
        formatted = LogFormatter.format(event, %{})
        assert formatted == ""
      end)

    assert output =~ "Some background notice"
    assert_received :erased
    assert_received :redrawn
  end

  test "falls back to a plain line when neither the spinner nor a TerminalOwner surface is active" do
    refute Spinner.active?()
    refute TerminalOwner.active?()

    event = %{level: :info, msg: "Idle-time notice"}
    formatted = LogFormatter.format(event, %{})

    assert formatted =~ "Idle-time notice"
    refute formatted == ""
  end

  describe "terminal-width truncation" do
    test "leaves a short message unchanged, without an ellipsis" do
      msg = ~s|bash(command: "ls -la")|
      event = %{level: :info, msg: msg}
      formatted = LogFormatter.format(event, %{})

      refute formatted =~ "…"
      assert formatted =~ msg
    end

    test "truncates an overly long single-line message to the terminal width, appending an ellipsis" do
      long_command = String.duplicate("x", 300)
      event = %{level: :info, msg: ~s|bash(command: "#{long_command}")|}
      formatted = LogFormatter.format(event, %{})

      content = String.trim_trailing(formatted, "\r\n")
      assert content =~ "…"
      assert LineEditor.display_width(content) <= expected_budget()
    end

    test "truncates each line of a multi-line message independently" do
      long_line = String.duplicate("y", 300)
      event = %{level: :info, msg: "first line\n#{long_line}"}
      formatted = LogFormatter.format(event, %{})

      [line1, line2] =
        formatted
        |> String.trim_trailing("\r\n")
        |> String.split("\n")

      refute line1 =~ "…"
      assert line2 =~ "…"
      assert LineEditor.display_width(line2) <= expected_budget()
    end

    test "bypasses line truncation when expand_tool_calls? is toggled ON via Ctrl+O" do
      long_command = String.duplicate("z", 300)
      event = %{level: :info, msg: ~s|bash(command: "#{long_command}")|}

      Application.put_env(:yoke, :expand_tool_calls, true)
      formatted = LogFormatter.format(event, %{})

      assert formatted =~ long_command
      refute formatted =~ "…"

      Application.put_env(:yoke, :expand_tool_calls, false)
    end
  end

  defp expected_budget do
    cols =
      case :io.columns() do
        {:ok, c} when is_integer(c) and c > 10 -> c
        _ -> 120
      end

    max(cols - 2, 1)
  end
end

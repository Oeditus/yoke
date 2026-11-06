defmodule Yoke.CLI.OutputTest do
  # Not async: these assertions swap the global `:yoke, :output_mode` env.
  use ExUnit.Case, async: false

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.Output

  setup do
    prior = Application.get_env(:yoke, :output_mode)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:yoke, :output_mode),
        else: Application.put_env(:yoke, :output_mode, prior)
    end)

    :ok
  end

  defp put_mode(mode), do: Application.put_env(:yoke, :output_mode, mode)

  describe "mode/0" do
    test "honours an explicitly forced mode" do
      put_mode(:tty)
      assert Output.mode() == :tty
      assert Output.tty?()
      refute Output.plain?()

      put_mode(:plain)
      assert Output.mode() == :plain
      refute Output.tty?()
      assert Output.plain?()
    end

    test "detect_mode/0 never reports a TTY inside the test environment" do
      assert Output.detect_mode() == :plain
    end

    test "prime/0 caches the detected mode and reset/0 clears it" do
      put_mode(:auto)
      assert Output.prime() == :plain
      assert Application.get_env(:yoke, :output_mode) == :plain

      assert Output.reset() == :ok
      assert Application.get_env(:yoke, :output_mode) == :auto
    end
  end

  describe "style/1 and style/2" do
    test "passes styling through in :tty mode" do
      put_mode(:tty)
      assert Output.style("\e[36m") == "\e[36m"
      assert Output.style("\e[36m", "fallback") == "\e[36m"
    end

    test "suppresses styling in :plain mode" do
      put_mode(:plain)
      assert Output.style("\e[36m") == ""
      assert Output.style("\e[36m", "fallback") == "fallback"
    end
  end

  describe "display_width/1" do
    test "is ANSI-aware in :tty mode" do
      put_mode(:tty)
      assert Output.display_width("\e[31mhello\e[0m") == 5
      assert Output.display_width("漢字") == 4
      assert Output.display_width("🚀") == 2
    end

    test "still measures true display width in :plain mode" do
      put_mode(:plain)
      assert Output.display_width("hello") == 5
      # Plain mode strips ANSI too: the escape bytes are not printed, so they
      # occupy no columns.
      assert Output.display_width("\e[31mhello\e[0m") == 5
      # Wide characters stay 2 columns each -- the width algorithm is shared
      # with `:tty` mode, only the styling is suppressed.
      assert Output.display_width("漢字") == 4
      assert Output.display_width("🚀") == 2
      assert Output.display_width("") == 0
      assert Output.display_width(nil) == 0
    end
  end

  describe "strip_ansi/1" do
    test "removes CSI and OSC sequences" do
      assert Output.strip_ansi("\e[31mred\e[0m") == "red"
      assert Output.strip_ansi("\e]8;;file:///tmp/x\e\\link\e]8;;\e\\") == "link"
      assert Output.strip_ansi("plain") == "plain"
      assert Output.strip_ansi(nil) == ""
    end
  end

  describe "Formatter degradation" do
    test "every colour helper returns an empty string in :plain mode" do
      put_mode(:plain)

      for helper <- [
            :reset,
            :bold,
            :dim,
            :cyan,
            :green,
            :yellow,
            :magenta,
            :red,
            :blue,
            :gray,
            :italic,
            :blink
          ] do
        assert apply(Formatter, helper, []) == "", "#{helper}/0 leaked ANSI in plain mode"
      end
    end

    test "status message helpers emit no escape bytes in :plain mode" do
      put_mode(:plain)

      for message <- [
            Formatter.format_error("boom"),
            Formatter.format_success("ok"),
            Formatter.format_info("note"),
            Formatter.format_warning("careful")
          ] do
        refute message =~ "\e["
        assert message =~ "●"
      end
    end

    test "the banner and help menu are escape-free in :plain mode" do
      put_mode(:plain)

      refute Formatter.banner() =~ "\e["
      refute Formatter.help_menu() =~ "\e["
      refute Formatter.getting_started_guide() =~ "\e["
    end

    test "colour helpers are restored in :tty mode" do
      put_mode(:tty)
      assert Formatter.cyan() == IO.ANSI.cyan()
      assert Formatter.reset() == IO.ANSI.reset()
    end
  end
end

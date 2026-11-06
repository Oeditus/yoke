defmodule Yoke.CLI.HeadlessTest do
  @moduledoc """
  Regression tests for the headless (non-TTY) presentation guarantees.

  These exist because a CI smoke test caught two real leaks that unit tests
  alone had missed:

    1. `Yoke.CLI.LogFormatter` built its severity circle from raw `IO.ANSI`
       instead of the presentation seam, so every startup log line carried
       escape bytes into a CI log.
    2. `Yoke.CLI.Main.main/1` primed the output mode *after*
       `Application.ensure_all_started/1`, so the whole boot sequence logged
       in colour before the seam was pinned.

  Both are asserted here so neither can regress silently.
  """
  use ExUnit.Case, async: false

  alias Yoke.CLI.LogFormatter
  alias Yoke.CLI.Output

  setup do
    prior = Application.get_env(:yoke, :output_mode)
    Application.put_env(:yoke, :output_mode, :plain)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:yoke, :output_mode),
        else: Application.put_env(:yoke, :output_mode, prior)
    end)

    :ok
  end

  describe "LogFormatter in plain mode" do
    test "emits no ANSI for any log level" do
      for level <- [:info, :warning, :warn, :error, :debug] do
        formatted = LogFormatter.format(%{level: level, msg: "a message"}, %{})

        refute formatted =~ "\e[",
               "LogFormatter leaked ANSI for level #{inspect(level)}: #{inspect(formatted)}"
      end
    end

    test "still renders the severity circle glyph" do
      formatted = LogFormatter.format(%{level: :info, msg: "hello"}, %{})
      assert formatted =~ "●"
      assert formatted =~ "hello"
    end

    test "does not emit a cursor-control sequence for the spinner branch" do
      # Even with the spinner nominally active, plain mode must not emit
      # `\e[2K`.
      formatted = LogFormatter.format(%{level: :info, msg: "hello"}, %{})
      refute formatted =~ "\e[2K"
    end
  end

  describe "Output.prime/0 ordering" do
    test "main/1 primes the output mode before starting the application" do
      # A structural assertion: the source must call `Output.prime()` before
      # `Application.ensure_all_started/1`. Anything logged during app startup
      # would otherwise be styled before the seam is pinned.
      source = File.read!("lib/yoke/cli/main.ex")

      prime_at = :binary.match(source, "Yoke.CLI.Output.prime()") |> elem(0)
      start_at = :binary.match(source, "Application.ensure_all_started(:yoke)") |> elem(0)

      assert prime_at < start_at,
             "Output.prime/0 must run before Application.ensure_all_started/1"
    end

    test "prime/0 pins the mode so later writes are styled consistently" do
      Application.put_env(:yoke, :output_mode, :auto)

      # In the test environment the probe always resolves to `:plain`.
      assert Output.prime() == :plain
      assert Application.get_env(:yoke, :output_mode) == :plain
    end
  end
end

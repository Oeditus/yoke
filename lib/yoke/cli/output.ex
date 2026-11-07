defmodule Yoke.CLI.Output do
  @moduledoc """
  The presentation seam: decides whether Yoke is writing to a real terminal.

  When it is not (CI logs, piped output, `</dev/null`), every ANSI escape
  sequence must disappear from stdout -- otherwise GitHub Actions renders raw
  `\\e[36m` byte soup in the log viewer and in `$GITHUB_STEP_SUMMARY`.

  The decision is made **once** per process and cached in the application
  environment (`:yoke, :output_mode`), so call sites are cheap and there is no
  per-call pseudo-terminal probing.

  ## Modes

    * `:tty` -- a real terminal; colour and cursor control are emitted.
    * `:plain` -- not a terminal; all colour functions return `""` and
      `display_width/1` returns a plain grapheme count.

  ## Configuration

  `Application.get_env(:yoke, :output_mode, :auto)` selects the mode:

    * `:auto` (default) -- probe the way `Yoke.CLI.QuestionPrompt` already
      does: tests, `CI`, and `:yoke, :non_interactive` are never a TTY.
    * `:tty` / `:plain` -- force a mode (used by tests and by
      `yoke --doctor`).
  """

  @doc "Returns the cached output mode, probing and caching it on first use."
  @spec mode() :: :tty | :plain
  def mode do
    case Application.get_env(:yoke, :output_mode, :auto) do
      :tty -> :tty
      :plain -> :plain
      _ -> detect_mode()
    end
  end

  @doc "Returns true when output goes to a real terminal."
  @spec tty?() :: boolean()
  def tty?, do: mode() == :tty

  @doc "Returns true when ANSI styling must be suppressed."
  @spec plain?() :: boolean()
  def plain?, do: mode() == :plain

  @doc """
  Returns `styled` when output is a TTY and `""` otherwise.

  This is the single helper every colour function in
  `Yoke.CLI.Formatter` delegates to.
  """
  @spec style(String.t()) :: String.t()
  def style(styled) when is_binary(styled) do
    if tty?(), do: styled, else: ""
  end

  @doc """
  Returns `styled` when output is a TTY, else `fallback`.

  Used where a colour function's output is concatenated into a line that
  still needs to be readable in plain mode (e.g. a bullet glyph).
  """
  @spec style(String.t(), String.t()) :: String.t()
  def style(styled, fallback) do
    if tty?(), do: styled, else: fallback
  end

  @doc """
  Computes the column width of `text`.

  ANSI escape sequences are always stripped (they occupy no columns) and each
  remaining grapheme contributes its rendered width: 1 column for ordinary
  characters, 2 for East-Asian-Wide/Fullwidth code points and the common emoji
  blocks. This is the single implementation of that algorithm — both
  `Yoke.CLI.Formatter.display_width/1` and the plain-mode sinks delegate here,
  so the two can never disagree.
  """
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(text) when is_binary(text) do
    text
    |> sanitize_utf8()
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, acc -> acc + grapheme_width(grapheme) end)
  rescue
    _ -> 0
  end

  def display_width(_), do: 0

  @doc "Removes any ANSI escape sequence from `text` (used by plain-mode sinks)."
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text) when is_binary(text) do
    String.replace(text, ~r/\e\][^\e\a]*(?:\e\\|\a)|\e\[[0-9;?]*[a-zA-Z~]/, "")
  end

  def strip_ansi(_), do: ""

  @doc false
  def sanitize_utf8(text) when is_binary(text), do: String.replace_invalid(text)
  def sanitize_utf8(_), do: ""

  # A grapheme cluster's rendered width is the width of its base (first)
  # code point -- combining marks, variation selectors, and any other code
  # points that follow within the same cluster render as zero-width
  # modifiers of that base character.
  @doc false
  def grapheme_width(<<first::utf8, _rest::binary>>), do: codepoint_width(first)
  def grapheme_width(<<_byte, _rest::binary>>), do: 1
  def grapheme_width(""), do: 0
  def grapheme_width(_), do: 0

  # Approximates POSIX `wcwidth(3)` for the ranges that matter to a terminal
  # UI: East Asian Wide/Fullwidth blocks (CJK ideographs, Hangul syllables,
  # fullwidth forms) and the common emoji blocks render as 2 terminal columns
  # in essentially every modern terminal emulator; everything else --
  # including Latin text and Nerd Font Private-Use-Area icons, which render in
  # a single cell -- is 1 column.
  @doc false
  def codepoint_width(cp) do
    cond do
      cp in 0x1100..0x115F -> 2
      cp == 0x26A1 -> 2
      cp in 0x2E80..0x303E -> 2
      cp in 0x3041..0x33FF -> 2
      cp in 0x3400..0x4DBF -> 2
      cp in 0x4E00..0x9FFF -> 2
      cp in 0xA000..0xA4CF -> 2
      cp in 0xAC00..0xD7A3 -> 2
      cp in 0xF900..0xFAFF -> 2
      cp in 0xFE30..0xFE4F -> 2
      cp in 0xFF00..0xFF60 -> 2
      cp in 0xFFE0..0xFFE6 -> 2
      cp in 0x16FE0..0x16FE4 -> 2
      cp in 0x17000..0x18CFF -> 2
      cp in 0x1B000..0x1B2FF -> 2
      cp in 0x1F000..0x1F2FF -> 2
      cp in 0x1F300..0x1F64F -> 2
      cp in 0x1F680..0x1F6FF -> 2
      cp in 0x1F900..0x1F9FF -> 2
      cp in 0x1FA00..0x1FA6F -> 2
      cp in 0x1FA70..0x1FAFF -> 2
      cp in 0x20000..0x3FFFD -> 2
      true -> 1
    end
  end

  @doc """
  Caches the detected mode in the application environment.

  Called once at CLI startup so the (relatively expensive) terminal probe
  happens exactly once instead of on every styled write.
  """
  @spec prime() :: :tty | :plain
  def prime do
    mode = detect_mode()
    Application.put_env(:yoke, :output_mode, mode)
    mode
  end

  @doc "Clears the cached mode so the next `mode/0` re-probes."
  @spec reset() :: :ok
  def reset do
    Application.put_env(:yoke, :output_mode, :auto)
    :ok
  end

  @doc """
  Probes the environment for terminal capability without consulting the cache.

  Mirrors `Yoke.CLI.QuestionPrompt`'s existing `tty?/0` heuristics so the two
  never disagree about whether a human is present.
  """
  @spec detect_mode() :: :tty | :plain
  def detect_mode do
    if test_env?() or System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      :plain
    else
      case :io.columns(:user) do
        {:ok, _} ->
          :tty

        _ ->
          case :io.columns() do
            {:ok, _} -> :tty
            _ -> :plain
          end
      end
    end
  end

  defp test_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end

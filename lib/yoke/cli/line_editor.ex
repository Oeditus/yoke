defmodule Yoke.CLI.LineEditor do
  @moduledoc """
  Modern TUI Line Editor & Readline Engine for Yoke (YOKE RAGE).

  Features:
    - Fixed bottom command bar with horizontal ruler (Yoke style), redrawn in
      place on every keystroke instead of scrolling the terminal
    - Buffer managed as a list of Unicode graphemes with an explicit
      0-indexed cursor position, so combining marks and multi-byte
      characters never corrupt navigation or editing
    - Full keyboard cursor navigation (Left/Right, Home/End, Backspace/Delete)
    - Persistent history navigation (Up/Down arrows) with ~/.yoke/history
    - Reverse incremental search (Ctrl+R)
    - Tab auto-completion for slash commands
    - Emacs shortcuts (Ctrl+A, Ctrl+E, Ctrl+U, Ctrl+K, Ctrl+W, Ctrl+C, Ctrl+D)
    - Live status bar hotkeys: Ctrl+P (permission mode), Ctrl+G (sandbox),
      Ctrl+B (status bar gauge/compact toggle)

  The module is split into pure state-transition functions (safe to unit
  test without a real TTY) and the impure raw-mode read/render loop that
  drives them.
  """
  alias Yoke.Brain.Session
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.TerminalOwner
  alias Yoke.Config
  alias Yoke.TaskEngine.PackageTracker

  @slash_commands [
    "/cb",
    "/checkpoint",
    "/clear",
    "/clipboard",
    "/commit",
    "/compact",
    "/config",
    "/conversation",
    "/cost",
    "/cr",
    "/diff",
    "/docs",
    "/edit",
    "/exit",
    "/explorer",
    "/getting-started",
    "/god",
    "/guide",
    "/help",
    "/lint",
    "/linter",
    "/mcp",
    "/mode",
    "/model",
    "/models",
    "/nodes",
    "/permissions",
    "/plugins",
    "/quit",
    "/ragex",
    "/reset",
    "/resume",
    "/review",
    "/review-conversation",
    "/review_conversation",
    "/rules",
    "/session",
    "/skill",
    "/skills",
    "/subagent",
    "/undo",
    "/update",
    "/workflow"
  ]

  # A pasted clipboard block (see `handle_paste/2`) collapses into a
  # compact "📋 [N lines]" placeholder chip once it exceeds either of
  # these thresholds -- otherwise it's inserted as ordinary, fully-
  # editable multi-line text, same as a Ctrl+J-composed entry.
  @paste_inline_max_lines 3
  @paste_inline_max_chars 300

  # ---------------------------------------------------------------------
  # History persistence
  # ---------------------------------------------------------------------

  @doc "Loads persistent history lines from the history file, most recent first."
  def load_history do
    path = history_file()

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&decode_history_line/1)
      |> Enum.reverse()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Appends a new non-empty command line to persistent history."
  def add_history(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      path = history_file()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{encode_history_line(trimmed)}\n", [:append])
    end
  rescue
    _ -> :ok
  end

  # `~/.yoke/history` stores one entry per line, but a Ctrl+J-composed
  # message may itself contain literal newlines -- escape them (and any
  # literal backslash, so the escape itself round-trips) on write, and
  # reverse on read, so a multi-line entry never gets split into several
  # bogus history lines or corrupts entries after it.
  defp encode_history_line(line) do
    line
    |> String.graphemes()
    |> Enum.map_join(fn
      "\\" -> "\\\\"
      "\n" -> "\\n"
      ch -> ch
    end)
  end

  defp decode_history_line(line) do
    line
    |> String.graphemes()
    |> decode_graphemes([])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp decode_graphemes([], acc), do: acc
  defp decode_graphemes(["\\", "n" | rest], acc), do: decode_graphemes(rest, ["\n" | acc])
  defp decode_graphemes(["\\", "\\" | rest], acc), do: decode_graphemes(rest, ["\\" | acc])
  defp decode_graphemes([g | rest], acc), do: decode_graphemes(rest, [g | acc])

  @doc """
  Resolves the persistent history file path. Defaults to `~/.yoke/history`,
  but can be overridden via the `:history_file` application environment key
  (used by tests so they never read from or write to the real user history).
  """
  def history_file do
    Application.get_env(:yoke, :history_file) || Path.expand("~/.yoke/history")
  end

  @doc """
  Formats a configurable prompt string using config template or default.

  `sandbox_override` (optional 5th arg), when a boolean, reflects the live
  session's actual sandbox state (as set via `/sandbox` or the Ctrl+G
  hotkey) instead of the static `sandbox_workspace` config file value, so
  the prompt's sandbox indicator matches reality. Omit it (or pass `nil`) to
  fall back to the config-file value, e.g. from tests or one-shot contexts
  with no live session.
  """
  def build_prompt(session_id, model, hands_mode \\ "local", cwd \\ ".", sandbox_override \\ nil) do
    config = Config.load_config(cwd)
    style = Map.get(config, "prompt_style", "starship")

    sandbox? =
      if is_boolean(sandbox_override),
        do: sandbox_override,
        else: Map.get(config, "sandbox_workspace", false)

    case style do
      "starship" ->
        build_starship_prompt(session_id, model, hands_mode, cwd, sandbox?)

      "extended" ->
        build_extended_prompt(session_id, model, hands_mode, cwd, sandbox?)

      "compact" ->
        build_compact_prompt(session_id, model, cwd)

      "minimal" ->
        "#{Formatter.cyan()}❯#{Formatter.reset()} "

      _ ->
        template = Map.get(config, "prompt_format", "user@{session} [{model}]> ")

        task_str =
          if running_units_count() > 0, do: "󱐋#{running_units_count()} running", else: "idle"

        template
        |> String.replace("{session}", session_id)
        |> String.replace("{model}", model)
        |> String.replace("{mode}", to_string(hands_mode))
        |> String.replace("{tasks}", task_str)
    end
  end

  defp build_starship_prompt(_session_id, model, hands_mode, cwd, sandbox?) do
    folder = Path.basename(Path.expand(cwd))
    branch = Yoke.Git.current_branch(cwd)
    branch_str = if branch != "", do: " 󰘬 #{branch}", else: ""
    sandbox = if sandbox?, do: " 󰌾 sandbox", else: ""

    active_tasks = Yoke.TaskEngine.Supervisor.list_active_tasks()
    task_count = length(active_tasks)

    task_badge =
      if task_count > 0 do
        " #{Formatter.yellow()}⚡#{task_count} running#{Formatter.reset()}"
      else
        ""
      end

    model_icon =
      case model do
        "deepseek-reasoner" -> "󰧑"
        "deepseek-coder" -> "󰘦"
        _ -> "󰚩"
      end

    mode_badge =
      case to_string(hands_mode) do
        "local" -> ""
        other -> " 󰖟 #{other}"
      end

    line =
      "#{Formatter.cyan()}󰉋 #{folder}#{Formatter.reset()}" <>
        "#{Formatter.magenta()}#{branch_str}#{Formatter.reset()}" <>
        " #{Formatter.green()}#{model_icon} #{model}#{Formatter.reset()}" <>
        "#{Formatter.yellow()}#{sandbox}#{mode_badge}#{Formatter.reset()}" <>
        task_badge

    "#{line} #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  defp build_extended_prompt(session_id, model, hands_mode, cwd, sandbox?) do
    folder = Path.basename(Path.expand(cwd))
    branch = Yoke.Git.current_branch(cwd)
    branch_str = if branch != "", do: " 󰘬 #{branch}", else: ""
    sandbox = if sandbox?, do: " 󰌾 sandbox", else: ""

    task_badge =
      if running_units_count() > 0 do
        " #{Formatter.yellow()}⚡#{running_units_count()} running#{Formatter.reset()}"
      else
        ""
      end

    mode_badge =
      case to_string(hands_mode) do
        "local" -> ""
        other -> " 󰖟 #{other}"
      end

    short_id = String.slice(session_id, 0, 8)

    line =
      "#{Formatter.cyan()}󰉋 #{folder}#{Formatter.reset()}" <>
        "#{Formatter.magenta()}#{branch_str}#{Formatter.reset()}" <>
        " #{Formatter.green()}󰚩 #{model}#{Formatter.reset()}" <>
        "#{Formatter.dim()} [id:#{short_id}]#{Formatter.reset()}" <>
        "#{Formatter.yellow()}#{sandbox}#{mode_badge}#{Formatter.reset()}" <>
        task_badge

    "#{line} #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  defp build_compact_prompt(_session_id, model, cwd) do
    folder = Path.basename(Path.expand(cwd))
    branch = Yoke.Git.current_branch(cwd)
    branch_str = if branch != "", do: "  #{branch}", else: ""

    "#{Formatter.cyan()}#{folder}#{Formatter.magenta()}#{branch_str}#{Formatter.reset()} [#{model}] #{Formatter.cyan()}❯#{Formatter.reset()} "
  end

  # ---------------------------------------------------------------------
  # Pure state helpers (unit-testable without a TTY)
  # ---------------------------------------------------------------------

  @doc "Builds a fresh editor state for a new input line."
  def new_state(prompt_text, history \\ [], context \\ %{}) do
    # `gauge_content/1` and `compact_session_content/1` fall back to a live
    # `length(Process.list())` count whenever `:serving_processes` is absent
    # from `context`. That count naturally drifts from one BEAM scheduler
    # tick to the next (timers, monitors, GC helper processes, etc.), so
    # leaving it to be recomputed on every `render_bar/1` call would make
    # `render_signature/1` compare unequal almost every keystroke -- quietly
    # defeating the "skip redraw unless changed" optimization below and
    # reintroducing the exact status-bar blinking it exists to prevent.
    # Freezing it once here, for the lifetime of this single line-edit
    # session, keeps the signature stable while the user is simply typing.
    context = Map.put_new_lazy(context, :serving_processes, fn -> length(Process.list()) end)

    %{
      buffer: [],
      cursor: 0,
      history: history,
      hist_idx: -1,
      saved_buffer: [],
      prompt: prompt_text,
      search_mode: false,
      search_query: [],
      search_offset: 0,
      first_render: true,
      # Total terminal rows the last-drawn ruler+prompt block occupied,
      # including any wrapping caused by a long typed line or ghost
      # suggestion. Needed so `erase_prefix/1` erases exactly what was
      # drawn instead of assuming a fixed 2-row block.
      last_rows: 0,
      # Absolute row (0-indexed from the very top of the last-drawn
      # ruler+prompt block) where the terminal's REAL cursor was left after
      # the last draw. `draw_only/1` moves the cursor from the bottom of
      # the block up to wherever the logical cursor belongs (see
      # `compute_cursor_positioning/4`), so on a multi-row buffer the
      # physical cursor often does NOT sit on the last row. `erase_prefix/1`
      # must move up by exactly this many rows -- not `last_rows - 1`,
      # which silently assumes the cursor is always at the bottom -- or
      # moving the cursor within a multi-line/wrapped entry (arrow keys,
      # Home/End) desyncs the next erase and the status bar visibly drifts.
      last_cursor_row: 0,
      # Signature of the last-rendered ruler+prompt+text block plus the
      # cursor's {row, col}. Used by `render_bar/1` to skip the erase+redraw
      # entirely when nothing visible changed (see `render_signature/1`), so
      # the status bar stops blinking on every keystroke.
      last_render: nil,
      # Maps a collapsed paste placeholder chip (e.g. "📋 [42 lines]",
      # inserted by `handle_paste/2` for a large clipboard paste) back to
      # the full original pasted text, so `handle_enter/1` can expand it
      # before the line is submitted or saved to history -- the chip is
      # purely a display convenience, never a loss of data.
      pastes: %{},
      context: context
    }
  end

  @doc "Moves the cursor one grapheme to the left, clamped at 0."
  def move_left(%{cursor: cursor, buffer: buffer} = state) do
    clamped = max(0, min(cursor, length(buffer)))
    %{state | cursor: max(clamped - 1, 0)}
  end

  @doc "Moves the cursor one grapheme to the right, clamped at buffer length."
  def move_right(%{cursor: cursor, buffer: buffer} = state) do
    len = length(buffer)
    clamped = max(0, min(cursor, len))
    %{state | cursor: min(clamped + 1, len)}
  end

  @doc "Jumps the cursor to the start of the line (Home / Ctrl+A)."
  def move_to_start(state), do: %{state | cursor: 0}

  @doc "Jumps the cursor to the end of the line (End / Ctrl+E)."
  def move_to_end(%{buffer: buffer} = state), do: %{state | cursor: length(buffer)}

  @doc """
  Moves the cursor up or down one LOGICAL line (split on hard `\n`
  boundaries, e.g. from Ctrl+J or a large inline clipboard paste) within a
  multi-line buffer, preserving the in-line column as closely as possible
  (clamped to the target line's length) -- the same "sticky column"
  behavior most text editors use.

  Returns `{:ok, new_state}` when the buffer has another logical line in
  that direction, or `:out_of_bounds` when the buffer is single-line, or
  the cursor is already on its first (for `:up`) or last (for `:down`)
  line -- signaling the caller to fall back to history navigation instead.
  """
  def move_cursor_within_buffer(%{buffer: buffer, cursor: cursor} = state, direction)
      when direction in [:up, :down] do
    lines = buffer |> Enum.join() |> String.split("\n")

    if length(lines) <= 1 do
      :out_of_bounds
    else
      {line_idx, col} = line_and_column(lines, cursor)
      target_idx = if direction == :up, do: line_idx - 1, else: line_idx + 1

      if target_idx < 0 or target_idx >= length(lines) do
        :out_of_bounds
      else
        target_line = Enum.at(lines, target_idx)
        target_col = min(col, String.length(target_line))
        new_cursor = cursor_for_line_and_column(lines, target_idx, target_col)
        {:ok, %{state | cursor: new_cursor}}
      end
    end
  end

  defp line_and_column(lines, cursor) do
    Enum.reduce_while(lines, {0, cursor}, fn line, {idx, remaining} ->
      len = String.length(line)

      if remaining <= len do
        {:halt, {idx, remaining}}
      else
        {:cont, {idx + 1, remaining - len - 1}}
      end
    end)
  end

  defp cursor_for_line_and_column(lines, target_idx, target_col) do
    lines
    |> Enum.take(target_idx)
    |> Enum.reduce(0, fn line, acc -> acc + String.length(line) + 1 end)
    |> Kernel.+(target_col)
  end

  @doc "Deletes the grapheme left of the cursor (Backspace)."
  def delete_backward(%{buffer: buffer, cursor: cursor} = state) do
    clamped = max(0, min(cursor, length(buffer)))

    if clamped == 0 do
      %{state | cursor: 0}
    else
      {left, right} = Enum.split(buffer, clamped)
      new_left = Enum.drop(left, -1)
      %{state | buffer: new_left ++ right, cursor: clamped - 1}
    end
  end

  @doc "Deletes the grapheme at the cursor (Delete / \\e[3~)."
  def delete_forward(%{buffer: buffer, cursor: cursor} = state) do
    clamped = max(0, min(cursor, length(buffer)))
    {left, right} = Enum.split(buffer, clamped)

    case right do
      [] -> %{state | cursor: clamped}
      [_ | rest] -> %{state | buffer: left ++ rest, cursor: clamped}
    end
  end

  @doc "Clears the line left of the cursor (Ctrl+U)."
  def kill_to_start(%{buffer: buffer, cursor: cursor} = state) do
    clamped = max(0, min(cursor, length(buffer)))
    {_left, right} = Enum.split(buffer, clamped)
    %{state | buffer: right, cursor: 0}
  end

  @doc "Clears the line right of the cursor (Ctrl+K)."
  def kill_to_end(%{buffer: buffer, cursor: cursor} = state) do
    clamped = max(0, min(cursor, length(buffer)))
    {left, _right} = Enum.split(buffer, clamped)
    %{state | buffer: left, cursor: length(left)}
  end

  @doc "Deletes the word behind the cursor (Ctrl+W)."
  def delete_word_backward(%{buffer: buffer, cursor: cursor} = state) do
    clamped = max(0, min(cursor, length(buffer)))
    {left, right} = Enum.split(buffer, clamped)
    left_str = Enum.join(left)
    new_left_str = Regex.replace(~r/\S+\s*$/, left_str, "")
    new_left = String.graphemes(new_left_str)
    %{state | buffer: new_left ++ right, cursor: length(new_left)}
  end

  @doc """
  Inserts `char` at the cursor position, re-splitting the prefix into
  graphemes so that combining marks merge correctly with the previous
  character regardless of how they were typed.
  """
  def insert_char(%{buffer: buffer, cursor: cursor} = state, char) when is_binary(char) do
    clamped = max(0, min(cursor, length(buffer)))
    {left, right} = Enum.split(buffer, clamped)
    new_prefix = String.graphemes(Enum.join(left) <> char)
    %{state | buffer: new_prefix ++ right, cursor: length(new_prefix)}
  end

  @doc """
  Inserts a literal newline at the cursor position without submitting the
  line (Ctrl+J -- Warp's own "Insert Newline" input-editor binding, and
  the cross-terminal-reliable stand-in for "Shift+Enter", which most
  terminals cannot distinguish from a plain Enter keypress in raw mode).
  """
  def insert_newline(state), do: insert_char(state, "\n")

  @doc """
  Normalizes clipboard line endings (`\\r\\n` and bare `\\r`, e.g. from a
  Windows-originated clipboard, or a terminal that doesn't fully translate
  them) to plain `\\n`, so a paste's embedded carriage returns are never
  later misread as an Enter keypress.
  """
  def normalize_paste_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  @doc """
  Inserts a clipboard paste at the cursor position (see
  `enable_bracketed_paste/0` and `read_bracketed_paste/0` for how the full
  payload is captured atomically, without ever being misread as Enter or
  other editor commands). A no-op during reverse-incremental search
  (pasting into a search query isn't supported) and for an empty payload.

  Short pastes (within `@paste_inline_max_lines` lines and
  `@paste_inline_max_chars` display columns) are inserted as ordinary,
  fully-editable text -- multi-line ones render using the same hard-
  newline layout as Ctrl+J. Anything larger collapses into a compact
  "📋 [N lines]" (or "📋 [N chars]" for one very long line) placeholder
  chip so a huge paste never floods the terminal; the full original text
  is preserved in `state.pastes` and transparently restored by
  `expand_pastes/2` when the line is submitted.
  """
  def handle_paste(%{search_mode: true} = state, _text), do: state

  def handle_paste(state, text) when is_binary(text) do
    normalized = normalize_paste_text(text)

    if normalized == "" do
      state
    else
      {display_text, state} = paste_display_text(state, normalized)
      insert_char(state, display_text)
    end
  end

  defp paste_display_text(state, text) do
    line_count = text |> String.split("\n") |> length()

    if line_count <= @paste_inline_max_lines and display_width(text) <= @paste_inline_max_chars do
      {text, state}
    else
      pastes = Map.get(state, :pastes, %{})
      placeholder = unique_paste_placeholder(pastes, text, line_count)
      {placeholder, %{state | pastes: Map.put(pastes, placeholder, text)}}
    end
  end

  defp unique_paste_placeholder(pastes, text, line_count) do
    base =
      if line_count > 1 do
        "📋 [#{line_count} lines]"
      else
        "📋 [#{String.length(text)} chars]"
      end

    disambiguate_placeholder(base, pastes, text, 1)
  end

  # A repeat paste of the EXACT same content is allowed to reuse its
  # existing label (harmless -- both refer to identical text), but a
  # different paste that happens to collapse to the same base label (e.g.
  # two different 10-line pastes) gets a "(2)", "(3)", ... suffix so
  # `expand_pastes/2` can never confuse one paste's content for another's.
  defp disambiguate_placeholder(base, pastes, text, attempt) do
    candidate = if attempt == 1, do: base, else: "#{base} (#{attempt})"

    case Map.fetch(pastes, candidate) do
      {:ok, ^text} -> candidate
      {:ok, _other} -> disambiguate_placeholder(base, pastes, text, attempt + 1)
      :error -> candidate
    end
  end

  @doc """
  Expands every collapsed paste placeholder chip in `text` back into its
  full original content (see `handle_paste/2`). A no-op when `pastes` is
  empty, and safe to call unconditionally since a buffer with no collapsed
  pastes simply has nothing to substitute.
  """
  def expand_pastes(text, pastes) when map_size(pastes) == 0, do: text

  def expand_pastes(text, pastes) when is_map(pastes) do
    Enum.reduce(pastes, text, fn {placeholder, full_text}, acc ->
      String.replace(acc, placeholder, full_text)
    end)
  end

  @doc "Handles explicit clipboard paste (Ctrl+V / Ctrl+Shift+V), prioritizing image data on the OS clipboard."
  def handle_clipboard_paste(%{search_mode: true} = state), do: state

  def handle_clipboard_paste(state) do
    case Yoke.Clipboard.fetch_image() do
      {:ok, mime, bytes} ->
        paste_image_bytes(state, mime, bytes)

      _ ->
        case Yoke.Clipboard.fetch_text() do
          {:ok, text} -> handle_paste(state, text)
          _ -> state
        end
    end
  end

  @doc "Handles bracketed paste, inserting clipboard image if present, or falling back to text paste."
  def handle_paste_or_clipboard_image(%{search_mode: true} = state, text),
    do: handle_paste(state, text)

  def handle_paste_or_clipboard_image(state, text) do
    case Yoke.Clipboard.fetch_image() do
      {:ok, mime, bytes} ->
        paste_image_bytes(state, mime, bytes)

      _ ->
        handle_paste(state, text)
    end
  end

  @doc "Saves raw image bytes from clipboard to .yoke/sessions/assets and inserts reference into prompt buffer."
  def paste_image_bytes(state, mime, bytes) when is_binary(bytes) do
    ext =
      case mime do
        "image/jpeg" -> ".jpg"
        "image/webp" -> ".webp"
        "image/gif" -> ".gif"
        _ -> ".png"
      end

    cwd = "."
    dir = Path.join(cwd, ".yoke/sessions/assets")
    File.mkdir_p!(dir)

    timestamp = System.system_time(:millisecond)
    filename = "clipboard_#{timestamp}#{ext}"
    filepath = Path.join(dir, filename)
    File.write!(filepath, bytes)

    ref_text = "@" <> Path.join(".yoke/sessions/assets", filename)
    insert_char(state, ref_text)
  end

  @doc """
  Navigates history up (older) or down (newer), preserving uncommitted
  input when entering navigation and restoring it when returning to -1.
  """
  def history_navigate(%{history: history, hist_idx: hist_idx} = state, :up) do
    if hist_idx < length(history) - 1 do
      new_idx = hist_idx + 1
      saved = if hist_idx == -1, do: state.buffer, else: state.saved_buffer
      chars = String.graphemes(Enum.at(history, new_idx, ""))
      %{state | hist_idx: new_idx, saved_buffer: saved, buffer: chars, cursor: length(chars)}
    else
      state
    end
  end

  def history_navigate(%{history: history, hist_idx: hist_idx} = state, :down) do
    cond do
      hist_idx > 0 ->
        new_idx = hist_idx - 1
        chars = String.graphemes(Enum.at(history, new_idx, ""))
        %{state | hist_idx: new_idx, buffer: chars, cursor: length(chars)}

      hist_idx == 0 ->
        chars = state.saved_buffer
        %{state | hist_idx: -1, buffer: chars, cursor: length(chars)}

      true ->
        state
    end
  end

  @doc "Finds the most recent history entry containing `query`."
  def find_in_history(query, history), do: find_in_history(query, history, 0)

  @doc "Finds the (offset + 1)-th most recent history entry containing `query`."
  def find_in_history("", _history, _offset), do: ""

  def find_in_history(query, history, offset) do
    history
    |> Enum.filter(&String.contains?(&1, query))
    |> Enum.at(offset, "")
  end

  @doc "Enters reverse-incremental-search mode (Ctrl+R)."
  def toggle_reverse_search(%{search_mode: false} = state) do
    %{
      state
      | search_mode: true,
        search_query: [],
        search_offset: Map.get(state, :search_offset, 0)
    }
  end

  def toggle_reverse_search(%{search_mode: true} = state), do: state

  @ragex_subcommands [
    "/ragex audit",
    "/ragex export",
    "/ragex help",
    "/ragex quality",
    "/ragex reindex",
    "/ragex stats",
    "/ragex url"
  ]
  @export_subcommands ["/export json", "/export lmml", "/export lmmlz", "/export markdown"]
  @skills_subcommands ["/skills show", "/skills path", "/skills edit", "/skills new"]

  @doc """
  Tab-completes slash commands and subcommands given input.

  Returns `{:ok, completed}` when the prefix uniquely resolves or extends to
  a longer common prefix, `{:ambiguous, matches}` when multiple candidates
  share no longer common prefix, and `:none` when nothing matches.
  """
  def tab_complete(input) when is_binary(input) do
    cond do
      String.starts_with?(input, "/ragex ") ->
        complete_candidates(input, @ragex_subcommands)

      String.starts_with?(input, "/export ") ->
        complete_candidates(input, @export_subcommands)

      String.starts_with?(input, "/skills ") ->
        complete_candidates(input, @skills_subcommands)

      String.starts_with?(input, "/") ->
        complete_candidates(input, @slash_commands)

      true ->
        :none
    end
  end

  defp complete_candidates(input, candidates) do
    case Enum.filter(candidates, &String.starts_with?(&1, input)) do
      [] ->
        :none

      [single] ->
        {:ok, single}

      multiple ->
        prefix = common_prefix(multiple)

        if String.length(prefix) > String.length(input) do
          {:ok, prefix}
        else
          {:ambiguous, multiple}
        end
    end
  end

  defp common_prefix([head | tail]) do
    Enum.reduce(tail, head, fn str, prefix ->
      prefix
      |> String.graphemes()
      |> Enum.zip(String.graphemes(str))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map_join("", &elem(&1, 0))
    end)
  end

  # ---------------------------------------------------------------------
  # Impure entry point & raw-mode loop
  # ---------------------------------------------------------------------

  @doc """
  Reads interactive input line with persistent history and TUI key controls.

  `context` optionally carries live session stats (e.g. `:total_tokens`,
  `:estimated_cost_usd`, `:model`) used to render the status bar's context
  usage gauge above the prompt when no background tasks are active.
  """
  def get_line(prompt_text, history \\ [], context \\ %{}) do
    if tty?() do
      read_tty_line(prompt_text, history, context)
    else
      IO.gets(prompt_text)
    end
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

  # Raw keystrokes are read via OTP 28+'s native `shell:start_interactive/1`
  # noshell "raw" submode (see the "Creating a terminal application" guide in
  # the stdlib docs). This reads keystrokes as they happen with echo disabled
  # directly through BEAM's own terminal handling, instead of shelling out to
  # `stty`/depending on a resolvable `/dev/tty` path, both of which are
  # unreliable across the different ways this CLI can be launched (mix run,
  # escript, iex, a release) and can fight with BEAM's own terminal driver.
  defp read_tty_line(prompt_text, history, context) do
    set_raw_mode()
    # Defensive: clear any stale registration left behind by a prior loop
    # that exited abnormally (e.g. via the `catch` clause below) without
    # going through one of the normal unregistration points.
    TerminalOwner.clear()

    try do
      result = raw_loop(new_state(prompt_text, history, context))
      restore_tty_mode()
      result
    catch
      _kind, _err ->
        restore_tty_mode()
        TerminalOwner.clear()
        IO.gets(prompt_text)
    end
  end

  defp set_raw_mode do
    result =
      case :shell.start_interactive({:noshell, :raw}) do
        :ok -> :ok
        {:error, :already_started} -> :ok
        _ -> :error
      end

    enable_bracketed_paste()
    result
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    disable_bracketed_paste()

    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # xterm-style "bracketed paste mode": once enabled, the terminal wraps a
  # pasted clipboard chunk in `\e[200~ ... \e[201~` instead of streaming it
  # as ordinary keystrokes, letting `read_bracketed_paste/0` slurp the
  # entire payload atomically -- including embedded `\r`/`\n` bytes -- so a
  # pasted carriage return is never misread as pressing Enter. Disabled
  # again on every exit path (normal return, crash, EOF) so it never leaks
  # into a subsequent plain `IO.gets/1` prompt or an unrelated program.
  defp enable_bracketed_paste do
    IO.write("\e[?2004h")
  rescue
    _ -> :ok
  end

  defp disable_bracketed_paste do
    IO.write("\e[?2004l")
  rescue
    _ -> :ok
  end

  defp raw_loop(state) do
    state = render_bar(state)

    case read_key() do
      :enter -> handle_enter(state)
      :tab -> handle_tab(state)
      :ctrl_c -> handle_interrupt(state)
      :ctrl_d -> handle_eof(state)
      :up -> raw_loop(handle_vertical_move(state, :up))
      :down -> raw_loop(handle_vertical_move(state, :down))
      :left -> raw_loop(edit_unless_searching(state, &move_left/1))
      :right -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :home -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :end -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :ctrl_a -> raw_loop(edit_unless_searching(state, &move_to_start/1))
      :ctrl_e -> raw_loop(edit_unless_searching(state, &accept_ghost_suggestion/1))
      :ctrl_u -> raw_loop(edit_unless_searching(state, &kill_to_start/1))
      :ctrl_k -> raw_loop(edit_unless_searching(state, &kill_to_end/1))
      :ctrl_w -> raw_loop(edit_unless_searching(state, &delete_word_backward/1))
      :ctrl_p -> raw_loop(edit_unless_searching(state, &toggle_permission_mode/1))
      :ctrl_g -> raw_loop(edit_unless_searching(state, &toggle_sandbox_mode/1))
      :ctrl_b -> raw_loop(edit_unless_searching(state, &toggle_status_bar_mode/1))
      :ctrl_o -> raw_loop(edit_unless_searching(state, &toggle_expand_tool_calls/1))
      :ctrl_r -> raw_loop(handle_ctrl_r(state))
      :ctrl_v -> raw_loop(handle_clipboard_paste(state))
      :newline -> raw_loop(edit_unless_searching(state, &insert_newline/1))
      :backspace -> raw_loop(handle_backspace(state))
      :delete -> raw_loop(edit_unless_searching(state, &delete_forward/1))
      {:paste, text} -> raw_loop(handle_paste_or_clipboard_image(state, text))
      {:char, 64} -> raw_loop(file_picker_modal(state))
      {:char, char_code} -> raw_loop(handle_char(state, <<char_code::utf8>>))
      _ -> raw_loop(state)
    end
  end

  defp handle_vertical_move(%{search_mode: true} = state, _direction), do: state

  defp handle_vertical_move(state, direction) do
    case move_cursor_within_buffer(state, direction) do
      {:ok, new_state} -> new_state
      :out_of_bounds -> history_navigate(state, direction)
    end
  end

  defp edit_unless_searching(%{search_mode: true} = state, _fun), do: state
  defp edit_unless_searching(state, fun), do: fun.(state)

  defp handle_enter(%{search_mode: true} = state) do
    query = Enum.join(state.search_query)
    match = find_in_history(query, state.history, state.search_offset)
    chars = String.graphemes(match)

    raw_loop(%{
      state
      | buffer: chars,
        cursor: length(chars),
        search_mode: false,
        search_query: [],
        search_offset: 0
    })
  end

  defp handle_enter(state) do
    raw_line = Enum.join(state.buffer)
    line = expand_pastes(raw_line, Map.get(state, :pastes, %{}))

    if multiline_continuation?(raw_line) do
      render_final(state)
      clean_current = String.trim_trailing(line, "\\")
      next_line = read_tty_line("... > ", state.history, Map.get(state, :context, %{}))
      full_line = clean_current <> "\n" <> next_line
      add_history(full_line)
      full_line
    else
      render_final(state)
      add_history(line)
      line <> "\n"
    end
  end

  defp multiline_continuation?(line) when is_binary(line) do
    String.ends_with?(line, "\\") or
      (String.contains?(line, "\"\"\"") and count_occurrences(line, "\"\"\"") |> rem(2) == 1)
  end

  defp count_occurrences(str, sub) do
    length(String.split(str, sub)) - 1
  end

  defp handle_tab(%{search_mode: true} = state), do: raw_loop(state)

  defp handle_tab(state) do
    buf_str = Enum.join(state.buffer)

    case tab_complete(buf_str) do
      {:ok, completed} ->
        chars = String.graphemes(completed)
        raw_loop(%{state | buffer: chars, cursor: length(chars)})

      {:ambiguous, matches} ->
        show_completions(matches)
        raw_loop(%{state | first_render: true})

      :none ->
        raw_loop(state)
    end
  end

  defp handle_ctrl_r(%{search_mode: false} = state) do
    %{state | search_mode: true, search_query: [], search_offset: 0}
  end

  defp handle_ctrl_r(state), do: %{state | search_offset: state.search_offset + 1}

  # ---------------------------------------------------------------------
  # Status bar hotkey toggles (Ctrl+P / Ctrl+G / Ctrl+B)
  #
  # These mutate the live session (permission mode, sandbox bounds) or
  # persisted config (status bar display mode) and update the in-memory
  # `state.context` so the ruler redraws immediately with the new value.
  # They are best-effort: if there's no live session_pid in context (e.g.
  # a bare `get_line/1,2` call with no context), they no-op safely.
  # ---------------------------------------------------------------------

  defp toggle_permission_mode(state) do
    context = Map.get(state, :context, %{})

    case Map.get(context, :session_pid) do
      pid when is_pid(pid) ->
        current = Map.get(context, :permission_mode, :ask_confirm)
        new_mode = if current == :auto_approve, do: :ask_confirm, else: :auto_approve

        case Session.set_permission_mode(pid, new_mode) do
          {:ok, applied} ->
            %{state | context: Map.put(context, :permission_mode, applied)}

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  defp toggle_sandbox_mode(state) do
    context = Map.get(state, :context, %{})

    case Map.get(context, :session_pid) do
      pid when is_pid(pid) ->
        current = Map.get(context, :sandbox_workspace, false)

        case Session.set_sandbox_mode(pid, not current) do
          {:ok, applied} ->
            %{state | context: Map.put(context, :sandbox_workspace, applied)}

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  defp toggle_status_bar_mode(state) do
    context = Map.get(state, :context, %{})
    new_val = not Map.get(context, :compact_status_bar?, false)

    persist_compact_status_bar(new_val)
    %{state | context: Map.put(context, :compact_status_bar?, new_val)}
  end

  @doc "Returns true when tool call expansion mode (Ctrl+O) is toggled ON."
  def expand_tool_calls? do
    Application.get_env(:yoke, :expand_tool_calls, false)
  end

  @doc "Toggles tool call expansion mode (Ctrl+O) between collapsed (truncated) and expanded (full text)."
  def toggle_expand_tool_calls(state) do
    current = expand_tool_calls?()
    new_val = not current
    Application.put_env(:yoke, :expand_tool_calls, new_val)

    status_str = if new_val, do: "expanded (full text)", else: "collapsed (truncated)"
    msg = Formatter.format_info("Tool call log mode: #{status_str} (Ctrl+O to toggle)")

    if TerminalOwner.active?() do
      TerminalOwner.interject(msg <> "\r\n")
    else
      IO.puts(msg)
    end

    context = Map.get(state, :context, %{})
    Map.put(state, :context, Map.put(context, :expand_tool_calls, new_val))
  end

  defp persist_compact_status_bar(value) do
    cfg = Config.load_config()
    Config.save_config(Map.put(cfg, "compact_status_bar", value))
  rescue
    _ -> :ok
  end

  defp handle_backspace(%{search_mode: true} = state) do
    %{state | search_query: Enum.drop(state.search_query, -1), search_offset: 0}
  end

  defp handle_backspace(state), do: delete_backward(state)

  defp handle_char(%{search_mode: true} = state, char) do
    %{state | search_query: state.search_query ++ [char], search_offset: 0}
  end

  defp handle_char(state, char), do: insert_char(state, char)

  defp handle_interrupt(state) do
    redraw_prefix = erase_prefix(state)
    IO.write(redraw_prefix <> "^C\r\n")
    TerminalOwner.clear()
    ""
  end

  defp handle_eof(%{buffer: [], search_mode: false} = state) do
    render_final(state)
    :eof
  end

  defp handle_eof(state), do: raw_loop(state)

  # ---------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------

  defp render_bar(state) do
    # "Redraw if and only if changed": compute the full render signature
    # (ruler + prompt + text + cursor position) and, if it matches the last
    # render exactly, skip the erase+redraw cycle entirely. This stops the
    # status bar from blinking on every keystroke -- the common fast-typing
    # path produces an identical surface (same buffer, same ruler, same
    # cursor) and would otherwise erase and redraw it pointlessly, which is
    # what reads as flicker. Only re-register with TerminalOwner so an
    # interjecting log line still redraws the current (unchanged) surface.
    signature = render_signature(state)

    if signature == Map.get(state, :last_render, :sentinel) do
      TerminalOwner.set(&erase_only/1, &draw_only/1, state)
      state
    else
      erase_only(state)
      new_state = draw_only(state)
      %{new_state | last_render: signature}
    end
  end

  # A single tuple capturing everything that affects what is written to the
  # terminal: the ruler string, the prompt+text string, and the cursor's
  # {row, col}. `last_rows` is deliberately omitted -- it is a pure function
  # of the ruler/text widths, so if those are unchanged it is unchanged too,
  # and including it would only make the comparison noisier.
  defp render_signature(state) do
    cols = terminal_cols()
    ruler = ruler_line(Map.get(state, :context, %{}))
    {prompt_str, text_str, cursor_offset} = compute_display(state)
    prompt_visible_len = strip_ansi_length(prompt_str)

    raw_cursor_text =
      if Map.get(state, :search_mode, false), do: text_str, else: Enum.join(state.buffer)

    cursor_index = if Map.get(state, :search_mode, false), do: cursor_offset, else: state.cursor

    {cursor_row, cursor_col} =
      layout_cursor(prompt_visible_len, raw_cursor_text, cursor_index, cols)

    {ruler, prompt_str <> text_str, cursor_row, cursor_col}
  end

  # Writes the ruler+prompt+text block fresh (no erase of any prior render
  # -- callers erase separately via `erase_only/1` when needed) and
  # re-registers the result with `TerminalOwner` so an interjecting log
  # line always has an up-to-date snapshot to redraw. Split out from
  # `render_bar/1` so `Yoke.CLI.LogFormatter` can redraw this
  # surface on its own, after it has already erased it.
  defp draw_only(state) do
    cols = terminal_cols()
    ruler = ruler_line(Map.get(state, :context, %{}))
    {prompt_str, text_str, cursor_offset} = compute_display(state)
    prompt_visible_len = strip_ansi_length(prompt_str)

    ruler_rows = rows_for(display_width(ruler), cols)
    content_rows = layout_rows(prompt_visible_len, text_str, cols)

    IO.write(ruler <> "\r\n" <> to_crlf(prompt_str <> text_str))

    raw_cursor_text =
      if Map.get(state, :search_mode, false), do: text_str, else: Enum.join(state.buffer)

    cursor_index = if Map.get(state, :search_mode, false), do: cursor_offset, else: state.cursor

    {cursor_row, cursor_col} =
      layout_cursor(prompt_visible_len, raw_cursor_text, cursor_index, cols)

    {positioning_seq, content_target_row} =
      compute_cursor_positioning(cursor_row, cursor_col, content_rows, cols)

    IO.write(positioning_seq)

    new_state = %{
      state
      | first_render: false,
        last_rows: ruler_rows + content_rows,
        last_cursor_row: ruler_rows + content_target_row
    }

    TerminalOwner.set(&erase_only/1, &draw_only/1, new_state)
    new_state
  end

  defp erase_only(state) do
    IO.write(erase_prefix(state))
  end

  defp render_final(state) do
    {prompt_str, text_str, _cursor_offset} = compute_display(%{state | search_mode: false})
    IO.write(erase_prefix(state) <> to_crlf(prompt_str <> text_str) <> "\r\n")
    TerminalOwner.clear()
  end

  # Erases the previously drawn ruler+prompt block in place, or emits
  # nothing on the very first render (when nothing has been drawn yet).
  # Moves the cursor up by exactly `state.last_cursor_row` -- the absolute
  # row (from the block's top) where the terminal's REAL cursor was left
  # after the last draw (see `last_cursor_row` in `new_state/3`) -- rather
  # than assuming it always sits on the block's last row. A long typed
  # line, embedded Ctrl+J newline, or a long fish-style ghost suggestion
  # can wrap/expand the prompt across multiple terminal rows, and the
  # logical cursor can be sitting anywhere within that block (e.g. after
  # moving it with arrow keys or Home/End), so using the wrong row count
  # here erases/redraws the wrong lines and the status bar visibly drifts
  # out of place.
  defp erase_prefix(%{first_render: true}), do: ""

  defp erase_prefix(state) do
    case Map.get(state, :last_cursor_row, 0) do
      up when up > 0 -> "\e[#{up}A\r\e[J"
      _ -> "\r\e[J"
    end
  end

  # Raw mode has `OPOST` disabled, so a bare `\n` (from a Ctrl+J-inserted
  # literal newline) would move the cursor down a row without returning it
  # to column 0, staircasing the output. Translate to `\r\n` before writing.
  defp to_crlf(text), do: String.replace(text, "\n", "\r\n")

  @doc """
  Total terminal rows spanned by `text`, which starts at display column
  `start_col` and may contain embedded hard newlines (from Ctrl+J) in
  addition to soft, width-based wrapping. Safe to call with ANSI-escaped
  (highlighted/ghost-suggested) text, since `display_width/1` already
  strips escape sequences before counting.
  """
  def layout_rows(start_col, text, cols) do
    text
    |> String.split("\n")
    |> Enum.reduce({0, true}, fn line, {acc, first?} ->
      col_start = if first?, do: start_col, else: 0
      {acc + rows_for(col_start + display_width(line), cols), false}
    end)
    |> elem(0)
    |> max(1)
  end

  @doc """
  Cursor's `{row, col}` (both 0-indexed, relative to the start of the
  block at display column `start_col`) within `raw_text`. `raw_text`
  must NOT contain ANSI escapes -- callers pass the plain, unhighlighted
  buffer text so that `cursor_offset` (a grapheme index into that same
  text) lines up exactly with `String.graphemes/1`.
  """
  def layout_cursor(start_col, raw_text, cursor_offset, cols) do
    cols = max(cols, 1)
    graphemes = String.graphemes(raw_text)
    total_graphemes = length(graphemes)
    cursor_offset = max(0, min(cursor_offset, total_graphemes))
    lines = String.split(raw_text, "\n")

    {result, _rows_acc, _consumed} =
      Enum.reduce_while(lines, {nil, 0, 0}, fn line, {_, rows_acc, consumed} ->
        col_start = if rows_acc == 0, do: start_col, else: 0
        chars = String.graphemes(line)
        line_len = length(chars)

        if cursor_offset <= consumed + line_len do
          offset_in_line = cursor_offset - consumed
          prefix_width = chars |> Enum.take(offset_in_line) |> Enum.join() |> display_width()
          abs_col = col_start + prefix_width
          found = {rows_acc + div(abs_col, cols), rem(abs_col, cols)}
          {:halt, {found, rows_acc, consumed}}
        else
          line_rows = rows_for(col_start + display_width(line), cols)
          {:cont, {nil, rows_acc + line_rows, consumed + line_len + 1}}
        end
      end)

    result || {0, start_col}
  end

  @doc """
  Computes the ANSI escape sequence that repositions the terminal's real
  cursor -- currently sitting at the end of everything `draw_only/1` just
  wrote (the block's last row) -- to the (possibly hard-broken and/or
  wrapped) `{cursor_row, cursor_col}` computed by `layout_cursor/4`.
  `content_rows` is how many terminal rows the block spans in total.

  Returns `{ansi_sequence, target_row}` rather than writing to the
  terminal directly, so `draw_only/1` can both perform the write AND
  remember `target_row` (as `state.last_cursor_row`, offset by the
  ruler's own row count) for the next `erase_prefix/1` call -- and so
  this exact positioning math is unit-testable without a real TTY.

  The cursor can legitimately be computed to sit one row past the last
  occupied one: `layout_cursor/4` derives its row via `div(abs_col, cols)`,
  so when the cursor lands exactly on a wrap boundary (the block's last
  column) it reports the *next* row's column 0, while `layout_rows/3`
  (ceiling division) counts that block as ending on the current row. In
  that case we pin the cursor to the last column of the last occupied row
  rather than letting the stale column place it at the block's top-left,
  which is the source of the occasional "cursor 1 position off" glitch.
  """
  def compute_cursor_positioning(cursor_row, cursor_col, content_rows, cols) do
    last_row_index = max(content_rows - 1, 0)

    {target_row, target_col} =
      if cursor_row > last_row_index do
        # Cursor at a wrap boundary: pin to the end of the last row.
        {last_row_index, max(cols - 1, 0)}
      else
        {cursor_row, cursor_col}
      end

    rows_up = last_row_index - target_row

    up_seq = if rows_up > 0, do: "\e[#{rows_up}A", else: ""
    col_seq = if target_col > 0, do: "\e[#{target_col}C", else: ""

    {up_seq <> "\r" <> col_seq, target_row}
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, c} when c > 10 -> c
      _ -> 80
    end
  end

  # Ceiling-divides a visible character width by the terminal width to get
  # the number of terminal rows it occupies, with a floor of 1 row (even
  # empty content still occupies the row it's written on).
  defp rows_for(width, _cols) when width <= 0, do: 1

  defp rows_for(width, cols) do
    cols = max(cols, 1)
    div(width - 1, cols) + 1
  end

  # Renders the fixed status bar ruler above the prompt. Priority order:
  #   1. Active parallel task badge (highest priority -- surfaces background
  #      work tracked by the OTP TaskEngine in real time)
  #   2. Idle status bar: an ambient segment (permission mode, sandbox state,
  #      MCP/tool counts, git dirty indicator) plus a toggleable segment
  #      (token/cost gauge, or a compact session summary -- Ctrl+B/
  #      `/config toggle compact_status_bar` to switch)
  #   3. A plain dim divider, when the status bar is disabled entirely
  defp ruler_line(context) do
    cols = terminal_cols()
    packages = PackageTracker.list()
    active_tasks = Yoke.TaskEngine.Supervisor.list_active_tasks()

    ruler =
      cond do
        packages != [] or active_tasks != [] ->
          activity_badge_ruler(cols, packages, active_tasks)

        context_gauge_enabled?() and is_map(context) and map_size(context) > 0 ->
          idle_status_ruler(cols, context)

        true ->
          plain_ruler(cols)
      end

    # Hard safety net: whatever the branch above computed, never let the
    # ruler exceed the terminal width. Individual branches try to size
    # their own content (badge truncation, ambient/toggle fallback), but
    # their arithmetic assumes plain-ASCII segment lengths; a segment that
    # grows unexpectedly (e.g. the process-count gauge crossing into
    # double digits) must not be allowed to wrap the ruler onto a second
    # terminal row, since that desyncs the redraw math in `render_bar/1`.
    truncate_to_width(ruler, max(cols - 1, 1))
  end

  defp plain_ruler(cols) do
    Formatter.dim() <> String.duplicate("─", max(10, cols - 1)) <> Formatter.reset()
  end

  # Renders the status-bar badge for in-flight work: named parallel packages
  # (async subagents, workflow subtasks) take precedence and are shown by
  # label, with any individual tool-call workers appended after them.
  defp activity_badge_ruler(cols, packages, active_tasks) do
    package_labels = Enum.map(packages, fn p -> p.label end)
    task_summaries = Enum.map(active_tasks, fn t -> t.summary end)
    units = package_labels ++ task_summaries
    count = length(units)
    summaries = Enum.join(units, ", ")
    raw_badge = " 󱐋 #{count} running: #{summaries} "

    max_allowed = max(10, cols - 12)

    truncated =
      if String.length(raw_badge) > max_allowed do
        String.slice(raw_badge, 0, max_allowed - 4) <> "... "
      else
        raw_badge
      end

    badge_fmt =
      "#{Formatter.cyan()}[#{Formatter.yellow()}#{Formatter.bold()}#{truncated}#{Formatter.reset()}#{Formatter.cyan()}]#{Formatter.reset()}"

    center_in_ruler(cols, badge_fmt, String.length(truncated) + 2)
  end

  # Combines the always-on ambient segment with the toggleable gauge/compact
  # segment. Falls back to the toggle segment alone on narrow terminals.
  defp idle_status_ruler(cols, context) do
    ambient = ambient_segment(context)
    toggle_part = toggle_segment(context)
    separator = " #{Formatter.dim()}│#{Formatter.reset()} "
    combined = ambient <> separator <> toggle_part
    combined_len = display_width(combined)

    if combined_len > cols - 4 do
      center_in_ruler(cols, toggle_part, display_width(toggle_part))
    else
      center_in_ruler(cols, combined, combined_len)
    end
  end

  # Ambient "what's up internally" icons: permission mode, sandbox bounds,
  # connected MCP server count, registered tool count, and (only when the
  # workspace has uncommitted changes) a small dirty-state dot.
  defp ambient_segment(context) do
    permission_mode = Map.get(context, :permission_mode, :ask_confirm)
    perm_label = if permission_mode == :auto_approve, do: "auto", else: "ask"
    sandbox? = Map.get(context, :sandbox_workspace, false)
    mcp_count = Map.get(context, :mcp_servers_count, 0)
    tools_count = Map.get(context, :tools_count, 0)
    dot = " #{Formatter.dim()}•#{Formatter.reset()} "

    perm_str = "#{Formatter.magenta()}󰈤 #{perm_label}#{Formatter.reset()}"
    sandbox_str = "#{Formatter.blue()}#{if sandbox?, do: "󰌾", else: "󰌿"}#{Formatter.reset()}"
    mcp_str = "#{Formatter.cyan()}🔌 #{mcp_count}#{Formatter.reset()}"
    tools_str = "#{Formatter.cyan()}󰒓 #{tools_count}#{Formatter.reset()}"

    parts = [perm_str, sandbox_str, mcp_str, tools_str]

    parts =
      if Map.get(context, :git_dirty?, false) do
        parts ++ ["#{Formatter.yellow()}●#{Formatter.reset()}"]
      else
        parts
      end

    Enum.join(parts, dot)
  end

  defp toggle_segment(context) do
    if Map.get(context, :compact_status_bar?, false) do
      compact_session_content(context)
    else
      gauge_content(context)
    end
  end

  defp gauge_content(context) do
    total_tokens = Map.get(context, :total_tokens, 0)
    cost_usd = Map.get(context, :estimated_cost_usd, 0.0)
    delta = Map.get(context, :last_turn_tokens, 0)
    max_tokens = context_window_tokens(Map.get(context, :model))
    serving_procs = Map.get(context, :serving_processes, length(Process.list()))

    Formatter.format_context_gauge(total_tokens, max_tokens, cost_usd, delta, serving_procs)
  end

  defp compact_session_content(context) do
    short_id = context |> Map.get(:session_id, "") |> to_string() |> String.slice(0, 8)
    msg_count = Map.get(context, :message_count, 0)
    serving_procs = Map.get(context, :serving_processes, length(Process.list()))

    "#{Formatter.cyan()}id:#{short_id}#{Formatter.reset()} #{Formatter.dim()}•#{Formatter.reset()} #{msg_count} msgs #{Formatter.dim()}•#{Formatter.reset()} ⚡ #{serving_procs} procs"
  end

  defp context_gauge_enabled? do
    Map.get(Config.load_config(), "enable_context_gauge", true)
  end

  # Total in-flight units (named packages + individual tool-call workers) for
  # the prompt's "N running" badge.
  defp running_units_count do
    length(PackageTracker.list()) +
      length(Yoke.TaskEngine.Supervisor.list_active_tasks())
  end

  # DeepSeek's chat/reasoner models currently expose a 64K-token context
  # window. This is overridable per-workspace by setting "max_context_tokens"
  # in .yoke/config.json (or ~/.yoke/config.json), in case that limit changes.
  defp context_window_tokens(_model) do
    Map.get(Config.load_config(), "max_context_tokens", 64_000)
  end

  defp center_in_ruler(cols, content_str, content_visible_len) do
    left_len = max(2, div(cols - content_visible_len, 2))
    right_len = max(2, cols - left_len - content_visible_len - 1)

    Formatter.dim() <>
      String.duplicate("─", left_len) <>
      Formatter.reset() <>
      content_str <>
      Formatter.dim() <>
      String.duplicate("─", right_len) <>
      Formatter.reset()
  end

  # The 3rd tuple element is the cursor's grapheme offset into `text_str`
  # (the 2nd element) alone -- NOT combined with the prompt's width. Both
  # `draw_only/1` and `render_final/1` add the prompt's own display width
  # separately via `layout_cursor/4`'s `start_col` argument.
  defp compute_display(%{search_mode: true} = state) do
    query = Enum.join(state.search_query)
    match = find_in_history(query, state.history, state.search_offset)
    prompt = "(reverse-i-search)'#{query}': "
    {prompt, match, String.length(match)}
  end

  defp compute_display(state) do
    config = Config.load_config()
    prompt_str = Formatter.format_user_prompt_str(state.prompt)
    raw_text = Enum.join(state.buffer)
    highlighted_text = highlight_input(raw_text, config)

    suggestion = get_ghost_suggestion(raw_text, state.history, config)

    ghost_str =
      if suggestion != "" do
        # The fish-style hint must never wrap onto a second terminal row:
        # a long history tail would otherwise expand the rendered block and
        # scroll the content above it up. Truncate the hint to whatever
        # width remains on the prompt's own line, reserving room for an
        # ellipsis so the user still sees there is more.
        cols = terminal_cols()
        prompt_visible_len = strip_ansi_length(prompt_str)
        used = prompt_visible_len + display_width(highlighted_text)
        remaining = max(cols - used - 1, 0)

        hint = truncate_to_width(suggestion, remaining)

        if hint != "",
          do: "#{Formatter.gray()}#{hint}#{Formatter.reset()}",
          else: ""
      else
        ""
      end

    clamped_cursor = max(0, min(state.cursor, length(state.buffer)))

    buffer_prefix_len =
      state.buffer |> Enum.take(clamped_cursor) |> Enum.join() |> String.length()

    {prompt_str, highlighted_text <> ghost_str, buffer_prefix_len}
  end

  def accept_ghost_suggestion(%{cursor: cursor, buffer: buffer, history: history} = state) do
    clamped = max(0, min(cursor, length(buffer)))

    if clamped == length(buffer) do
      raw_text = Enum.join(buffer)
      config = Config.load_config()
      suggestion = get_ghost_suggestion(raw_text, history, config)

      if suggestion != "" do
        new_chars = String.graphemes(raw_text <> suggestion)
        %{state | buffer: new_chars, cursor: length(new_chars)}
      else
        move_right(%{state | cursor: clamped})
      end
    else
      move_right(%{state | cursor: clamped})
    end
  end

  def get_ghost_suggestion(buffer_text, history, config) do
    if Map.get(config, "enable_autosuggestions", true) and buffer_text != "" do
      match =
        Enum.find(history, fn line ->
          String.starts_with?(line, buffer_text) and line != buffer_text
        end)

      if match do
        len = String.length(buffer_text)
        String.slice(match, len..-1//1)
      else
        ""
      end
    else
      ""
    end
  end

  def highlight_input(input, config) do
    if Map.get(config, "enable_syntax_highlighting", true) do
      cond do
        String.starts_with?(input, "/") ->
          parts = String.split(input, " ", parts: 2)

          case parts do
            [cmd, rest] ->
              "#{Formatter.cyan()}#{cmd}#{Formatter.reset()} #{rest}"

            [cmd] ->
              "#{Formatter.cyan()}#{cmd}#{Formatter.reset()}"
          end

        String.starts_with?(input, "!") ->
          "#{Formatter.yellow()}#{input}#{Formatter.reset()}"

        true ->
          input
      end
    else
      input
    end
  end

  def file_picker_modal(state) do
    cwd =
      Map.get(state, :cwd) || get_in(state, [:context, :cwd]) || get_in(state, [:context, "cwd"]) ||
        File.cwd!()

    config = Config.load_config(cwd)

    if Map.get(config, "enable_file_picker", true) do
      all_files = list_workspace_files()

      opts =
        Enum.map(all_files, fn f ->
          icon = if File.dir?(f), do: "󰉋", else: "󰈔"
          "#{icon} #{f}"
        end)

      if opts == [] do
        insert_char(state, "@")
      else
        {left, right} = Enum.split(state.buffer, state.cursor)
        left_str = Enum.join(left)

        {initial_filter, strip_count} =
          case Regex.run(~r/@([^\s@]*)$/, left_str) do
            [full_match, prefix] -> {prefix, String.length(full_match)}
            _ -> {"", 0}
          end

        ans =
          Yoke.CLI.Spinner.with_paused(fn ->
            Yoke.CLI.QuestionPrompt.ask_single_question(
              "Select file context to attach:",
              opts,
              false,
              false,
              filterable: true,
              initial_filter: initial_filter,
              clear_on_done: true
            )
          end)

        case ans do
          %{selected: [sel]} when is_binary(sel) and sel != "" ->
            clean_path = sel |> String.split(" ", parts: 2) |> List.last()
            replace_or_insert_file_ref(state, clean_path, strip_count, left, right)

          %{custom: custom_val} when is_binary(custom_val) and custom_val != "" ->
            replace_or_insert_file_ref(state, custom_val, strip_count, left, right)

          _ ->
            if strip_count == 0 do
              st = insert_char(state, "@")
              %{st | first_render: true}
            else
              %{state | first_render: true}
            end
        end
      end
    else
      st = insert_char(state, "@")
      %{st | first_render: true}
    end
  end

  def replace_or_insert_file_ref(state, clean_path, strip_count, left, right) do
    clean_path = String.trim_leading(clean_path, "@")
    inserted = "@" <> clean_path <> " "
    chars = String.graphemes(inserted)

    left_trimmed =
      if strip_count > 0 and length(left) >= strip_count do
        Enum.slice(left, 0, length(left) - strip_count)
      else
        left
      end

    new_buffer = left_trimmed ++ chars ++ right
    new_cursor = length(left_trimmed) + length(chars)

    %{
      state
      | buffer: new_buffer,
        cursor: new_cursor,
        first_render: true
    }
  end

  defp list_workspace_files do
    raw_files =
      case System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          String.split(out, "\n", trim: true)

        _ ->
          fallback_wildcard_files()
      end

    raw_files
    |> Enum.reject(fn path ->
      String.starts_with?(path, ".git") or
        String.starts_with?(path, "_build") or
        String.contains?(path, "/_build/") or
        String.starts_with?(path, "deps") or
        String.contains?(path, "/deps/") or
        String.starts_with?(path, ".elixir_ls") or
        String.contains?(path, "/.elixir_ls/") or
        String.starts_with?(path, "node_modules") or
        String.contains?(path, "/node_modules/") or
        String.starts_with?(path, "dist") or
        String.contains?(path, "/dist/") or
        String.starts_with?(path, "build") or
        String.contains?(path, "/build/")
    end)
  rescue
    _ -> fallback_wildcard_files()
  end

  defp fallback_wildcard_files do
    Path.wildcard("**/*")
    |> Enum.reject(fn path ->
      String.starts_with?(path, ".git") or
        String.starts_with?(path, "_build") or
        String.contains?(path, "/_build/") or
        String.starts_with?(path, "deps") or
        String.contains?(path, "/deps/") or
        String.starts_with?(path, ".elixir_ls") or
        String.contains?(path, "/.elixir_ls/") or
        String.starts_with?(path, "node_modules") or
        String.contains?(path, "/node_modules/") or
        String.starts_with?(path, "dist") or
        String.contains?(path, "/dist/") or
        String.starts_with?(path, "build") or
        String.contains?(path, "/build/")
    end)
  end

  def display_width(str) when is_binary(str), do: Formatter.display_width(str)

  defp strip_ansi_length(str), do: display_width(str)

  @ansi_escape_pattern ~r/(\e\][^\e\a]*(?:\e\\|\a)|\e\[[0-9;?]*[a-zA-Z~])/

  @doc """
  Truncates a possibly ANSI-colored string to at most `max_width` visible
  terminal columns.

  Embedded escape sequences (zero display width) are always preserved
  intact -- never split mid-sequence -- and a trailing reset code is
  appended whenever truncation actually occurs, so cutting a string mid-
  color never bleeds that color onto whatever is printed afterwards. This
  is the last-resort guarantee that a rendered status bar segment can
  never exceed the terminal width, regardless of how its own length
  accounting was computed.
  """
  def truncate_to_width(str, max_width) when is_binary(str) and max_width <= 0, do: ""

  def truncate_to_width(str, max_width) when is_binary(str) do
    if display_width(str) <= max_width do
      str
    else
      budget = max(max_width - 1, 0)

      {truncated, _width} =
        str
        |> tokenize_ansi()
        |> Enum.reduce_while({"", 0}, fn
          {:escape, code}, {acc, width} ->
            {:cont, {acc <> code, width}}

          {:char, char}, {acc, width} ->
            char_width = display_width(char)

            if width + char_width > budget do
              {:halt, {acc, width}}
            else
              {:cont, {acc <> char, width + char_width}}
            end
        end)

      truncated <> "…" <> Formatter.reset()
    end
  end

  # Splits a string into an ordered list of `{:escape, code}` (a zero-width
  # ANSI CSI sequence) and `{:char, grapheme}` tokens, so truncation can
  # walk the string counting only visible characters towards the width
  # budget while always copying escape codes through untouched.
  defp tokenize_ansi(str) do
    @ansi_escape_pattern
    |> Regex.split(str, include_captures: true)
    |> Enum.flat_map(fn chunk ->
      if String.match?(chunk, ~r/^(\e\][^\e\a]*(?:\e\\|\a)|\e\[[0-9;?]*[a-zA-Z~])$/) do
        [{:escape, chunk}]
      else
        chunk |> String.graphemes() |> Enum.map(&{:char, &1})
      end
    end)
  end

  defp show_completions(matches) do
    IO.write(
      "\r\n" <>
        Formatter.dim() <>
        "Completions: " <> Enum.join(matches, "  ") <> Formatter.reset() <> "\r\n"
    )
  end

  # ---------------------------------------------------------------------
  # Raw key reading
  # ---------------------------------------------------------------------

  defp read_key do
    case get_raw_input_chunk() do
      "\e[200~" -> {:paste, read_bracketed_paste()}
      other -> match_key(other)
    end
  end

  defp match_key("\e[A"), do: :up
  defp match_key("\e[B"), do: :down
  defp match_key("\e[C"), do: :right
  defp match_key("\e[D"), do: :left
  defp match_key("\eOA"), do: :up
  defp match_key("\eOB"), do: :down
  defp match_key("\eOC"), do: :right
  defp match_key("\eOD"), do: :left
  defp match_key("\e[H"), do: :home
  defp match_key("\e[F"), do: :end
  defp match_key("\e[1~"), do: :home
  defp match_key("\e[4~"), do: :end
  defp match_key("\e[3~"), do: :delete
  defp match_key("\r"), do: :enter
  defp match_key("\r\n"), do: :enter
  # A bare `\n` (Ctrl+J / linefeed, without a preceding `\r`) is raw mode's
  # unambiguous "Insert Newline" keystroke -- matching Warp's own Input
  # Editor binding for the same action -- distinct from Enter/`\r`, which
  # submits. Also produced by pasting multi-line clipboard text.
  defp match_key("\n"), do: :newline
  defp match_key("\t"), do: :tab
  defp match_key("\x01"), do: :ctrl_a
  defp match_key("\x02"), do: :ctrl_b
  defp match_key("\x03"), do: :ctrl_c
  defp match_key("\x04"), do: :ctrl_d
  defp match_key("\x05"), do: :ctrl_e
  defp match_key("\x07"), do: :ctrl_g
  defp match_key("\x0b"), do: :ctrl_k
  defp match_key("\x0c"), do: :ctrl_l
  defp match_key("\x0f"), do: :ctrl_o
  defp match_key("\x10"), do: :ctrl_p
  defp match_key("\x12"), do: :ctrl_r
  defp match_key("\x15"), do: :ctrl_u
  defp match_key("\x16"), do: :ctrl_v
  defp match_key("\x17"), do: :ctrl_w
  defp match_key("\x7f"), do: :backspace
  defp match_key("\x08"), do: :backspace
  defp match_key("\e"), do: :escape

  defp match_key(other) when is_binary(other) do
    cond do
      String.contains?(other, "[A") or String.contains?(other, "OA") ->
        :up

      String.contains?(other, "[B") or String.contains?(other, "OB") ->
        :down

      String.contains?(other, "[C") or String.contains?(other, "OC") ->
        :right

      String.contains?(other, "[D") or String.contains?(other, "OD") ->
        :left

      String.starts_with?(other, "\e") ->
        :other

      true ->
        case String.to_charlist(other) do
          [c | _] -> {:char, c}
          _ -> :other
        end
    end
  end

  # Reads exactly one character via OTP's native raw-mode stdin handling
  # (see `set_raw_mode/0`). `:io.get_chars/2` returns as soon as data is
  # available, so this behaves like a blocking single-keystroke read.
  defp get_raw_input_chunk do
    case read_char() do
      "\e" ->
        read_escape_sequence()

      :eof ->
        "\x04"

      char when is_binary(char) ->
        char

      _ ->
        ""
    end
  end

  defp read_escape_sequence do
    case read_char_with_timeout(50) do
      char when char in ["[", "O"] ->
        read_csi_sequence("\e" <> char, 16)

      char when is_binary(char) and char != "" ->
        "\e" <> char

      _ ->
        "\e"
    end
  end

  defp read_csi_sequence(acc, count) when count > 0 do
    case read_char_with_timeout(50) do
      char when is_binary(char) and char != "" ->
        new_acc = acc <> char
        last_char = String.last(new_acc)

        if last_char in ["A", "B", "C", "D", "H", "F", "~", "M", "Z"] or
             (byte_size(new_acc) >= 3 and last_char >= "a" and last_char <= "z") or
             (byte_size(new_acc) >= 3 and last_char >= "A" and last_char <= "Z") do
          new_acc
        else
          read_csi_sequence(new_acc, count - 1)
        end

      _ ->
        acc
    end
  end

  defp read_csi_sequence(acc, _count), do: acc

  defp read_char_with_timeout(timeout_ms) do
    task = Task.async(fn -> read_char() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  @paste_end_marker "\e[201~"
  @paste_end_marker_length String.length(@paste_end_marker)

  # Reads the remainder of a bracketed-paste payload (see
  # `enable_bracketed_paste/0`) one raw character at a time until the
  # terminating `\e[201~` marker is seen, returning everything up to (but
  # not including) that marker -- including any embedded `\r`, `\n`, or
  # other control bytes, none of which are interpreted as editor commands
  # while a paste is being captured. Bytes are accumulated as a reversed
  # list so checking for the terminator only ever inspects the last few
  # characters, rather than re-scanning the whole (potentially very large)
  # paste on every single character.
  defp read_bracketed_paste, do: read_bracketed_paste([])

  defp read_bracketed_paste(acc) do
    case read_char() do
      char when is_binary(char) and char != "" ->
        new_acc = [char | acc]

        if paste_terminated?(new_acc) do
          new_acc
          |> Enum.reverse()
          |> Enum.join()
          |> String.trim_trailing(@paste_end_marker)
        else
          read_bracketed_paste(new_acc)
        end

      _ ->
        # EOF or a read error mid-paste: return whatever was captured
        # rather than blocking forever waiting for a terminator that will
        # never arrive.
        acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp paste_terminated?(acc) do
    acc
    |> Enum.take(@paste_end_marker_length)
    |> Enum.reverse()
    |> Enum.join()
    |> String.ends_with?(@paste_end_marker)
  end

  defp read_char do
    case :io.get_chars("", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
      _ -> ""
    end
  end
end

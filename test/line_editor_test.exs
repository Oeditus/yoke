defmodule Yoke.LineEditorTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.LineEditor

  describe "prompt building" do
    test "builds prompt string with configurable interpolation" do
      prompt = LineEditor.build_prompt("main", "deepseek-chat", :local)
      assert String.contains?(prompt, "deepseek-chat")
    end

    test "supports extended prompt style" do
      # `prompt_style` is read from `.yoke/config.json` (via Yoke.Config),
      # not from Application env, so exercise the real config-file mechanism
      # against an isolated temp workspace instead of the user's real config.
      tmp_dir =
        Path.join(System.tmp_dir!(), "yoke_test_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, ".yoke"))
      File.write!(Path.join(tmp_dir, ".yoke/config.json"), ~s({"prompt_style": "extended"}))
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      prompt =
        LineEditor.build_prompt("02ec14fa-0fae-62b0-9b52", "deepseek-chat", :local, tmp_dir)

      assert String.contains?(prompt, "deepseek-chat")
      assert String.contains?(prompt, "id:02ec14fa")
    end
  end

  describe "persistent history" do
    test "loads and appends persistent history safely" do
      assert is_list(LineEditor.load_history())
      LineEditor.add_history("test_command_123")
      history = LineEditor.load_history()
      assert "test_command_123" in history
    end

    test "loads history most-recent-first, matching in-memory prepend order" do
      LineEditor.add_history("first_recorded_#{System.unique_integer([:positive])}")
      LineEditor.add_history("second_recorded_#{System.unique_integer([:positive])}")
      [most_recent | _rest] = LineEditor.load_history()
      assert String.starts_with?(most_recent, "second_recorded_")
    end
  end

  describe "cursor navigation" do
    test "moves cursor left and right without corrupting the buffer" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}

      assert LineEditor.move_left(state).cursor == 2
      assert LineEditor.move_right(state).cursor == 4

      assert LineEditor.move_left(%{state | cursor: 0}).cursor == 0
      assert LineEditor.move_right(%{state | cursor: 5}).cursor == 5
    end

    test "jumps to start and end of line" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 2}

      assert LineEditor.move_to_start(state).cursor == 0
      assert LineEditor.move_to_end(state).cursor == 5
    end

    test "backspace deletes the grapheme left of the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}
      result = LineEditor.delete_backward(state)

      assert result.buffer == String.graphemes("helo")
      assert result.cursor == 2

      unchanged = LineEditor.delete_backward(%{state | cursor: 0})
      assert unchanged.buffer == String.graphemes("hello")
      assert unchanged.cursor == 0
    end

    test "delete removes the grapheme at the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 1}
      result = LineEditor.delete_forward(state)

      assert result.buffer == String.graphemes("hllo")
      assert result.cursor == 1

      at_end = %{state | cursor: 5}
      assert LineEditor.delete_forward(at_end).buffer == String.graphemes("hello")
    end

    test "ctrl+u clears left of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 6
      }

      result = LineEditor.kill_to_start(state)

      assert result.buffer == String.graphemes("world")
      assert result.cursor == 0
    end

    test "ctrl+k clears right of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 5
      }

      result = LineEditor.kill_to_end(state)

      assert result.buffer == String.graphemes("hello")
      assert result.cursor == 5
    end

    test "ctrl+w deletes the word behind the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("git commit "),
          cursor: 11
      }

      result = LineEditor.delete_word_backward(state)

      assert Enum.join(result.buffer) == "git "
      assert result.cursor == 4
    end

    test "inserts unicode graphemes and keeps combining marks clustered" do
      state =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("é")
        |> LineEditor.insert_char("ñ")

      assert state.buffer == String.graphemes("éñ")
      assert state.cursor == 2

      # A base char followed by a combining accent should merge into one
      # grapheme cluster even though they arrive as separate keystrokes.
      combining_accent = <<0x0301::utf8>>
      composed = "e" <> combining_accent

      merged =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("e")
        |> LineEditor.insert_char(combining_accent)

      assert merged.buffer == String.graphemes(composed)
      assert length(merged.buffer) == 1
    end
  end

  describe "history navigation" do
    test "navigates history up and down, preserving uncommitted input" do
      history = ["cmd_two", "cmd_one"]
      state = %{LineEditor.new_state("prompt> ", history) | buffer: String.graphemes("draft")}

      up_state = LineEditor.history_navigate(state, :up)
      assert up_state.hist_idx == 0
      assert up_state.buffer == String.graphemes("cmd_two")
      assert up_state.saved_buffer == String.graphemes("draft")

      up_again = LineEditor.history_navigate(up_state, :up)
      assert up_again.hist_idx == 1
      assert up_again.buffer == String.graphemes("cmd_one")

      # Cannot go further back than the oldest entry.
      assert LineEditor.history_navigate(up_again, :up) == up_again

      down_state = LineEditor.history_navigate(up_again, :down)
      assert down_state.hist_idx == 0
      assert down_state.buffer == String.graphemes("cmd_two")

      restored = LineEditor.history_navigate(down_state, :down)
      assert restored.hist_idx == -1
      assert restored.buffer == String.graphemes("draft")
    end
  end

  describe "reverse-incremental search" do
    test "finds items in history by substring" do
      history = ["git status", "mix test", "yoke review"]
      assert LineEditor.find_in_history("git", history) == "git status"
      assert LineEditor.find_in_history("xyz", history) == ""
      assert LineEditor.find_in_history("", history) == ""
    end

    test "cycles through multiple matches via offset" do
      history = ["mix test", "git commit", "git status"]
      assert LineEditor.find_in_history("git", history, 0) == "git commit"
      assert LineEditor.find_in_history("git", history, 1) == "git status"
      assert LineEditor.find_in_history("git", history, 2) == ""
    end

    test "toggles search mode on and is idempotent while already active" do
      state = LineEditor.new_state("prompt> ")
      activated = LineEditor.toggle_reverse_search(state)

      assert activated.search_mode == true
      assert activated.search_query == []
      assert LineEditor.toggle_reverse_search(activated) == activated
    end
  end

  describe "Ctrl+J newline insertion" do
    test "insert_newline/1 inserts a literal newline at the cursor without submitting" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 5}
      result = LineEditor.insert_newline(state)

      assert Enum.join(result.buffer) == "hello\n"
      assert result.cursor == 6
    end

    test "insert_newline/1 splits the buffer when the cursor is mid-line" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("abcd"), cursor: 2}
      result = LineEditor.insert_newline(state)

      assert Enum.join(result.buffer) == "ab\ncd"
      assert result.cursor == 3
    end

    test "a multi-line buffer joins into one logical string with embedded newlines" do
      state =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("a")
        |> LineEditor.insert_newline()
        |> LineEditor.insert_char("b")

      assert Enum.join(state.buffer) == "a\nb"
    end
  end

  describe "multi-line layout math" do
    test "layout_rows/3 counts a single row for short single-line text" do
      assert LineEditor.layout_rows(8, "hello", 80) == 1
    end

    test "layout_rows/3 counts one additional row per embedded hard newline" do
      assert LineEditor.layout_rows(8, "line one\nline two\nline three", 80) == 3
    end

    test "layout_rows/3 also accounts for soft, width-based wrapping" do
      # Starting at column 0 in an 8-column terminal, a 20-character line
      # wraps across 3 rows (8 + 8 + 4).
      assert LineEditor.layout_rows(0, String.duplicate("x", 20), 8) == 3
    end

    test "layout_rows/3 combines hard breaks with soft wraps across segments" do
      # First segment starts at column 5 in a 10-column terminal ("first"
      # fits within the remaining 5 columns on row 0); second segment
      # starts fresh at column 0 and wraps once (12 chars / 10 cols).
      text = "first\n" <> String.duplicate("y", 12)
      assert LineEditor.layout_rows(5, text, 10) == 3
    end

    test "layout_rows/3 is ANSI-safe (escape codes don't inflate the row count)" do
      plain = LineEditor.layout_rows(0, "hello world", 80)
      ansi = LineEditor.layout_rows(0, "\e[36mhello\e[0m world", 80)
      assert plain == ansi
    end

    test "layout_cursor/4 finds the cursor on a single line" do
      assert LineEditor.layout_cursor(8, "hello", 3, 80) == {0, 11}
    end

    test "layout_cursor/4 finds the cursor on a later line after a hard newline" do
      # "ab\ncd", cursor offset 4 -> after "c" on the second line (row 1).
      assert LineEditor.layout_cursor(0, "ab\ncd", 4, 80) == {1, 1}
    end

    test "layout_cursor/4 places the cursor at the end of a line when it sits right before a hard newline" do
      # "ab\ncd", cursor offset 2 -> right after "ab", still row 0.
      assert LineEditor.layout_cursor(0, "ab\ncd", 2, 80) == {0, 2}
    end

    test "layout_cursor/4 accounts for soft wrapping when locating the cursor" do
      # 12 'x' chars in an 8-column terminal wrap after column 8; cursor at
      # offset 10 sits on the second wrapped row, column 2.
      text = String.duplicate("x", 12)
      assert LineEditor.layout_cursor(0, text, 10, 8) == {1, 2}
    end

    test "layout_cursor/4 reports the wrap boundary when the cursor lands exactly at the last column" do
      # 8 'x' chars in an 8-column terminal exactly fill one row; cursor at
      # offset 8 (right after the last char) is at the wrap point, i.e.
      # row 1, column 0. `draw_only/1`'s `position_cursor_2d/4` then pins
      # this to the last column of the last occupied row so it doesn't jump
      # to the block's top-left.
      text = String.duplicate("x", 8)
      assert LineEditor.layout_cursor(0, text, 8, 8) == {1, 0}
    end
  end

  describe "history persistence with embedded newlines" do
    test "round-trips a multi-line entry without corrupting the history file" do
      unique = System.unique_integer([:positive])
      multiline = "first line #{unique}\nsecond line #{unique}"

      LineEditor.add_history(multiline)
      history = LineEditor.load_history()

      assert multiline in history
      # The embedded newline must not have been split into two separate entries.
      refute "first line #{unique}" in history
      refute "second line #{unique}" in history
    end

    test "round-trips an entry containing a literal backslash" do
      unique = System.unique_integer([:positive])
      line = "regex \\d+ test #{unique}"

      LineEditor.add_history(line)
      history = LineEditor.load_history()

      assert line in history
    end
  end

  describe "tab completion" do
    test "completes a unique slash command match" do
      assert {:ok, "/ragex"} = LineEditor.tab_complete("/ra")
      # "/re" alone is ambiguous between "/resume" and "/review"; "/rev" is the
      # shortest unambiguous prefix that resolves to "/review".
      assert {:ok, "/review"} = LineEditor.tab_complete("/rev")
      assert {:ok, "/checkpoint"} = LineEditor.tab_complete("/ch")
      assert {:ok, "/plugins"} = LineEditor.tab_complete("/pl")
    end

    test "extends to the common prefix when ambiguous but extendable" do
      assert {:ok, "/skill"} = LineEditor.tab_complete("/sk")
      assert {:ok, "/mode"} = LineEditor.tab_complete("/mod")
    end

    test "reports ambiguity when the common prefix cannot be extended" do
      assert {:ambiguous, matches} = LineEditor.tab_complete("/m")
      assert "/mcp" in matches
      assert "/mode" in matches
      assert "/model" in matches
    end

    test "returns :none for input with no matches or non-slash input" do
      assert :none = LineEditor.tab_complete("not_a_slash_cmd")
      assert :none = LineEditor.tab_complete("/zzz")
    end

    test "completes /skills subcommands" do
      assert {:ok, "/skills show"} = LineEditor.tab_complete("/skills sh")
      assert {:ok, "/skills path"} = LineEditor.tab_complete("/skills pa")
      assert {:ok, "/skills edit"} = LineEditor.tab_complete("/skills ed")
      assert {:ok, "/skills new"} = LineEditor.tab_complete("/skills ne")
    end

    test "completes multi-word /ragex and /export subcommands" do
      assert {:ok, "/ragex audit"} = LineEditor.tab_complete("/ragex au")
      assert {:ok, "/ragex reindex"} = LineEditor.tab_complete("/ragex re")
      assert {:ok, "/export markdown"} = LineEditor.tab_complete("/export mark")
    end

    test "completes /jobs and its subcommands" do
      assert {:ok, "/jobs"} = LineEditor.tab_complete("/job")
      assert {:ok, "/jobs kill all"} = LineEditor.tab_complete("/jobs kill a")
      assert {:ok, "/jobs kill"} = LineEditor.tab_complete("/jobs k")
    end
  end

  describe "syntax highlighting and ghost suggestions" do
    test "highlights slash commands and shell commands" do
      cfg = %{"enable_syntax_highlighting" => true}
      assert LineEditor.highlight_input("/model chat", cfg) =~ "model"
      assert LineEditor.highlight_input("!git status", cfg) =~ "git status"
    end

    test "computes ghost auto-suggestions from history" do
      cfg = %{"enable_autosuggestions" => true}
      history = ["git commit -m 'fix'"]
      assert LineEditor.get_ghost_suggestion("git com", history, cfg) == "mit -m 'fix'"
    end

    test "calculates physical terminal display width of prompts with Nerd Font symbols" do
      prompt_str = "\e[36m󰉋 ragec\e[0m \e[32m󰚩 deepseek-chat\e[0m ❯ "

      raw_len = String.length(String.replace(prompt_str, ~r/\e\[[0-9;]*[mGKH]/, ""))
      width = LineEditor.display_width(prompt_str)

      assert width == raw_len
      assert LineEditor.display_width("❯ ") == 2
    end

    test "positions cursor at exact prompt boundary without +1 offset" do
      prompt_width = LineEditor.display_width("\e[36m❯\e[0m ")
      assert prompt_width == 2

      {row, col} = LineEditor.layout_cursor(prompt_width, "", 0, 80)
      assert {row, col} == {0, 2}

      {row_h, col_h} = LineEditor.layout_cursor(prompt_width, "hello", 0, 80)
      assert {row_h, col_h} == {0, 2}
    end
  end

  describe "status bar width safety net" do
    test "leaves content untouched when it already fits within max_width" do
      short = "\e[36mhello\e[0m"
      assert LineEditor.truncate_to_width(short, 80) == short
    end

    test "never returns a string wider than max_width, even for long ANSI content" do
      # Simulates a status bar segment (e.g. the token/cost gauge) that grew
      # past the terminal width, such as when a process count crosses into
      # double digits and pushes previously-borderline content over the edge.
      long =
        "\e[32m[████████░░░░░░░░] 75%\e[0m " <>
          "\e[2m(12000/64000 tokens\e[0m \e[32m(+500)\e[0m " <>
          "\e[2m| $0.1234 USD | ⚡ 12 procs serving)\e[0m"

      for max_width <- [10, 20, 40, 79, 80] do
        truncated = LineEditor.truncate_to_width(long, max_width)
        assert LineEditor.display_width(truncated) <= max_width
      end
    end

    test "never exceeds max_width even when the budget is smaller than 1" do
      assert LineEditor.truncate_to_width("anything", 0) == ""
    end

    test "preserves embedded ANSI escapes without splitting them mid-sequence" do
      long = String.duplicate("a", 50) <> "\e[31m" <> String.duplicate("b", 50) <> "\e[0m"
      truncated = LineEditor.truncate_to_width(long, 30)

      assert LineEditor.display_width(truncated) <= 30
      # Every remaining escape sequence must be well-formed (fully matched by
      # the escape regex); stripping them should leave no stray `\e` bytes.
      stripped = String.replace(truncated, ~r/\e\[[0-9;]*[mGKH]/, "")
      refute stripped =~ "\e"
    end
  end

  describe "fish-style hint truncation" do
    test "truncate_to_width/2 appends an ellipsis and stays within the width budget" do
      # A long history tail that would wrap past the prompt's remaining line
      # width must be cut down to fit, with an ellipsis signalling more.
      long_tail = String.duplicate("x", 100)
      truncated = LineEditor.truncate_to_width(long_tail, 20)

      assert LineEditor.display_width(truncated) <= 20
      assert String.contains?(truncated, "…")
    end

    test "truncate_to_width/2 leaves a hint that already fits untouched (no ellipsis)" do
      short = "git status"
      assert LineEditor.truncate_to_width(short, 80) == short
      refute String.contains?(LineEditor.truncate_to_width(short, 80), "…")
    end
  end

  describe "clipboard paste handling" do
    test "handle_paste/2 inserts short multi-line pastes inline without collapsing" do
      state = LineEditor.new_state("> ")
      text = "line one\nline two"
      new_state = LineEditor.handle_paste(state, text)

      assert Enum.join(new_state.buffer) == text
      assert new_state.cursor == length(String.graphemes(text))
      assert new_state.pastes == %{}
    end

    test "handle_paste/2 collapses large multi-line pastes into a placeholder chip" do
      state = LineEditor.new_state("> ")
      text = Enum.map_join(1..20, "\n", &"line #{&1}")
      new_state = LineEditor.handle_paste(state, text)

      assert Enum.join(new_state.buffer) == "📋 [20 lines]"
      assert new_state.pastes["📋 [20 lines]"] == text
    end

    test "handle_paste/2 collapses a single very long line by character count" do
      state = LineEditor.new_state("> ")
      text = String.duplicate("x", 500)
      new_state = LineEditor.handle_paste(state, text)

      assert Enum.join(new_state.buffer) == "📋 [500 chars]"
      assert new_state.pastes["📋 [500 chars]"] == text
    end

    test "handle_paste/2 normalizes CRLF and bare CR line endings before inserting" do
      state = LineEditor.new_state("> ")
      new_state = LineEditor.handle_paste(state, "a\r\nb\rc")

      assert Enum.join(new_state.buffer) == "a\nb\nc"
    end

    test "handle_paste/2 disambiguates two distinct pastes that would collapse to the same label" do
      state = LineEditor.new_state("> ")
      text_a = Enum.map_join(1..10, "\n", &"a#{&1}")
      text_b = Enum.map_join(1..10, "\n", &"b#{&1}")

      state = LineEditor.handle_paste(state, text_a)
      state = LineEditor.handle_paste(state, text_b)

      assert state.pastes["📋 [10 lines]"] == text_a
      assert state.pastes["📋 [10 lines] (2)"] == text_b
      assert Enum.join(state.buffer) == "📋 [10 lines]📋 [10 lines] (2)"
    end

    test "handle_paste/2 reuses the same label for a repeated identical paste" do
      state = LineEditor.new_state("> ")
      text = Enum.map_join(1..10, "\n", &"a#{&1}")

      state = LineEditor.handle_paste(state, text)
      state = LineEditor.handle_paste(state, text)

      assert map_size(state.pastes) == 1
      assert Enum.join(state.buffer) == "📋 [10 lines]📋 [10 lines]"
    end

    test "handle_paste/2 ignores pastes while in reverse-search mode" do
      state = %{LineEditor.new_state("> ") | search_mode: true}
      new_state = LineEditor.handle_paste(state, "anything")

      assert new_state == state
    end

    test "handle_paste/2 no-ops on an empty paste" do
      state = LineEditor.new_state("> ")
      new_state = LineEditor.handle_paste(state, "")

      assert new_state == state
    end

    test "expand_pastes/2 substitutes placeholder chips back into their full original content" do
      pastes = %{"📋 [3 lines]" => "a\nb\nc"}
      line = "prefix 📋 [3 lines] suffix"

      assert LineEditor.expand_pastes(line, pastes) == "prefix a\nb\nc suffix"
    end

    test "expand_pastes/2 is a no-op when there are no tracked pastes" do
      assert LineEditor.expand_pastes("hello", %{}) == "hello"
    end
  end

  describe "vertical cursor movement within a multi-line buffer" do
    test "signals out of bounds on a single-line buffer, deferring to history navigation" do
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes("hello"), cursor: 3}

      assert LineEditor.move_cursor_within_buffer(state, :up) == :out_of_bounds
      assert LineEditor.move_cursor_within_buffer(state, :down) == :out_of_bounds
    end

    test "moves the cursor to the previous logical line, clamping the column" do
      text = "ab\nlong line\nxy"
      # Column 5 of the middle line -> absolute offset 2 + 1 + 5 = 8.
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes(text), cursor: 8}

      {:ok, new_state} = LineEditor.move_cursor_within_buffer(state, :up)
      # First line "ab" has length 2, so the column clamps to its end.
      assert new_state.cursor == 2
    end

    test "moves the cursor to the next logical line, clamping the column" do
      text = "ab\nlong line\nxy"
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes(text), cursor: 8}

      {:ok, new_state} = LineEditor.move_cursor_within_buffer(state, :down)
      # Last line "xy" has length 2, so the column clamps to its end.
      assert new_state.cursor == length(String.graphemes(text))
    end

    test "preserves the in-line column when the target line is long enough" do
      text = "hello\nworld"
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes(text), cursor: 2}

      {:ok, new_state} = LineEditor.move_cursor_within_buffer(state, :down)
      # Column 2 within "hello" -> column 2 within "world" -> offset 6 + 2.
      assert new_state.cursor == 8
    end

    test "signals out of bounds at the buffer's first line when moving up" do
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes("a\nb"), cursor: 0}
      assert LineEditor.move_cursor_within_buffer(state, :up) == :out_of_bounds
    end

    test "signals out of bounds at the buffer's last line when moving down" do
      state = %{LineEditor.new_state("> ") | buffer: String.graphemes("a\nb"), cursor: 2}
      assert LineEditor.move_cursor_within_buffer(state, :down) == :out_of_bounds
    end
  end

  describe "cursor repositioning math after a multi-row draw" do
    test "moves straight over when the cursor already sits on the last row" do
      assert LineEditor.compute_cursor_positioning(2, 5, 3, 80) == {"\r\e[5C", 2}
    end

    test "moves up the correct number of rows when the cursor sits above the last row" do
      assert LineEditor.compute_cursor_positioning(0, 3, 3, 80) == {"\e[2A\r\e[3C", 0}
    end

    test "pins the cursor to the end of the last row at a wrap boundary" do
      assert LineEditor.compute_cursor_positioning(2, 0, 2, 8) == {"\r\e[7C", 1}
    end

    test "omits the column-move segment when the target column is 0" do
      assert LineEditor.compute_cursor_positioning(0, 0, 1, 80) == {"\r", 0}
    end
  end

  describe "cursor placement safety and wide character / pasted text navigation" do
    test "layout_cursor/4 clamps out-of-bounds cursor_offset to the end of input" do
      # 5 'x' chars, start_col = 10 -> offset 999 should place cursor at col 15 (10 + 5)
      assert LineEditor.layout_cursor(10, "hello", 999, 80) == {0, 15}
    end

    test "navigates wide characters correctly with move_left and move_right" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("你好"), cursor: 0}

      # Cursor at 0: prefix_width 0 -> col 8
      assert LineEditor.layout_cursor(8, "你好", state.cursor, 80) == {0, 8}

      # Right once -> cursor 1 (after "你") -> prefix_width 2 -> col 10
      state1 = LineEditor.move_right(state)
      assert state1.cursor == 1
      assert LineEditor.layout_cursor(8, "你好", state1.cursor, 80) == {0, 10}

      # Right again -> cursor 2 (after "好") -> prefix_width 4 -> col 12
      state2 = LineEditor.move_right(state1)
      assert state2.cursor == 2
      assert LineEditor.layout_cursor(8, "你好", state2.cursor, 80) == {0, 12}

      # Left -> cursor 1
      state_back = LineEditor.move_left(state2)
      assert state_back.cursor == 1
      assert LineEditor.layout_cursor(8, "你好", state_back.cursor, 80) == {0, 10}
    end

    test "inserting multi-character pasted text updates cursor to the end of inserted text" do
      state = LineEditor.new_state("prompt> ")
      new_state = LineEditor.insert_char(state, "hello")

      assert Enum.join(new_state.buffer) == "hello"
      assert new_state.cursor == 5

      assert LineEditor.layout_cursor(8, Enum.join(new_state.buffer), new_state.cursor, 80) ==
               {0, 13}
    end

    test "clamps cursor bounds when state.cursor is out of bounds" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("abc"), cursor: 10}
      moved = LineEditor.move_left(state)
      assert moved.cursor == 2

      state_right = LineEditor.move_right(state)
      assert state_right.cursor == 3
    end
  end

  describe "file picker modal integration" do
    test "inserts @ when enable_file_picker is false" do
      tmp_dir = Path.join(System.tmp_dir!(), "yoke_test_fp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, ".yoke"))
      File.write!(Path.join(tmp_dir, ".yoke/config.json"), ~s({"enable_file_picker": false}))
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      state = LineEditor.new_state("prompt> ", [], %{cwd: tmp_dir})
      result = LineEditor.file_picker_modal(state)
      assert Enum.join(result.buffer) == "@"
      assert result.cursor == 1
    end

    test "replaces file reference and formats inserted @file.name as simple editable text with trailing space" do
      state = LineEditor.new_state("prompt> ")
      state = %{state | buffer: String.graphemes("@lib/yo"), cursor: 7}

      {left, right} = Enum.split(state.buffer, state.cursor)
      result = LineEditor.replace_or_insert_file_ref(state, "lib/yoke.ex", 7, left, right)

      assert Enum.join(result.buffer) == "@lib/yoke.ex "
      assert result.cursor == 13
      assert result.first_render == true
    end
  end
end

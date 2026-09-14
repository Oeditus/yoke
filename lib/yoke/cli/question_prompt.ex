defmodule Yoke.CLI.QuestionPrompt do
  @moduledoc """
  Interactive TUI Question Modal & User Feedback UI for Yoke.

  Renders Warp-styled terminal menus for asking single-choice or
  multi-choice questions to the user during agent execution.
  """
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.TerminalOwner

  @doc """
  Main entry point to ask a list of questions to the user and return formatted answers.

  When more than one question is provided, each question's modal header
  shows its position (e.g. "Question 2/3 from AI") so the user always
  knows how many are left to answer -- otherwise it's easy to lose track
  of how many separate questions the AI is waiting on.
  """
  def ask(questions, opts \\ [])

  def ask(questions, opts) when is_list(questions) do
    case Process.whereis(Yoke.CLI.InteractionServer) do
      nil ->
        do_ask(questions, opts)

      pid ->
        if self() == pid do
          do_ask(questions, opts)
        else
          Yoke.CLI.InteractionServer.ask(questions, opts)
        end
    end
  end

  def ask(_, _opts), do: "No questions provided."

  @doc "Internal execution of ask/2."
  def do_ask(questions, opts \\ [])

  def do_ask(questions, opts) when is_list(questions) do
    total = length(questions)

    answers =
      questions
      |> Enum.with_index(1)
      |> Enum.map(fn {q, idx} ->
        question_text = Map.get(q, "question") || Map.get(q, :question, "")
        options = Map.get(q, "options") || Map.get(q, :options, [])
        is_multi = Map.get(q, "is_multi_select") || Map.get(q, :is_multi_select, false)
        progress = if total > 1, do: {idx, total}, else: nil
        single_opts = Keyword.merge(opts, progress: progress)

        ans = do_ask_single_question(question_text, options, is_multi, true, single_opts)
        format_answer(question_text, ans)
      end)

    Enum.join(answers, "\n\n")
  end

  def do_ask(_, _opts), do: "No questions provided."

  @doc "Delegates God mode check to Yoke.Config."
  def god_mode?, do: Yoke.Config.god_mode?()

  @doc """
  Asks a single question and returns choice result map.

  Routes through Yoke.CLI.InteractionServer when active.
  """
  def ask_single_question(question, options, is_multi \\ false, show_numbers \\ true, opts \\ []) do
    case Process.whereis(Yoke.CLI.InteractionServer) do
      nil ->
        do_ask_single_question(question, options, is_multi, show_numbers, opts)

      pid ->
        if self() == pid do
          do_ask_single_question(question, options, is_multi, show_numbers, opts)
        else
          Yoke.CLI.InteractionServer.ask_single_question(
            question,
            options,
            is_multi,
            show_numbers,
            opts
          )
        end
    end
  end

  @doc "Internal execution of ask_single_question/5."
  def do_ask_single_question(
        question,
        options,
        is_multi \\ false,
        show_numbers \\ true,
        opts \\ []
      ) do
    options = if is_list(options) and options != [], do: options, else: ["Yes", "No"]
    filterable = Keyword.get(opts, :filterable, false)

    has_recommended? =
      Enum.any?(options, fn opt ->
        String.contains?(String.downcase(to_string(opt)), "recommended")
      end)

    options =
      cond do
        filterable ->
          options

        has_recommended? ->
          options

        true ->
          List.update_at(options, 0, fn opt -> "#{opt} (Recommended)" end)
      end

    if god_mode?() do
      selected_opt =
        Enum.find(options, Enum.at(options, 0), fn opt ->
          String.contains?(to_string(opt), "(Recommended)")
        end)

      selected = [selected_opt]
      write_god_mode_notice(question, selected_opt)
      %{selected: selected}
    else
      all_options = if filterable, do: options, else: options ++ ["Write custom response…"]
      custom_idx = if filterable, do: -1, else: length(all_options) - 1
      progress = Keyword.get(opts, :progress)
      subagent = Keyword.get(opts, :subagent)

      if tty?() do
        prompt_tty(
          question,
          all_options,
          is_multi,
          custom_idx,
          show_numbers,
          progress,
          subagent,
          opts
        )
      else
        prompt_non_tty(question, all_options, is_multi, custom_idx, progress, subagent)
      end
    end
  end

  defp write_god_mode_notice(question, selected_opt) do
    q_short =
      if String.length(question) > 60, do: String.slice(question, 0, 57) <> "...", else: question

    target = if Process.whereis(:user), do: :user, else: :stdio

    IO.write(
      target,
      "\r\n" <>
        Formatter.cyan() <>
        "⚡ [God Mode] Auto-answering question: " <>
        Formatter.bold() <>
        q_short <>
        Formatter.reset() <>
        "\r\n" <>
        Formatter.dim() <>
        "   Selected option: #{selected_opt}" <>
        Formatter.reset() <> "\r\n"
    )
  rescue
    _ -> :ok
  end

  def filter_options(all_options, "") do
    Enum.take(all_options, 30)
  end

  def filter_options(all_options, query) do
    tokens =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    filtered =
      Enum.filter(all_options, fn opt ->
        opt_str = to_string(opt)
        opt_down = String.downcase(opt_str)
        Enum.all?(tokens, fn token -> String.contains?(opt_down, token) end)
      end)

    Enum.take(filtered, 30)
  end

  def handle_filter_char(state, char_code) when char_code >= 32 and char_code != 127 do
    char_str = <<char_code::utf8>>
    new_query = state.filter_query <> char_str
    new_options = filter_options(state.all_options, new_query)

    %{
      state
      | filter_query: new_query,
        options: new_options,
        cursor: 0
    }
  end

  def handle_filter_char(state, _), do: state

  def handle_filter_backspace(%{filter_query: ""} = state) do
    {:ok, state}
  end

  def handle_filter_backspace(state) do
    new_query =
      if String.length(state.filter_query) > 1 do
        String.slice(state.filter_query, 0, String.length(state.filter_query) - 1)
      else
        ""
      end

    new_options = filter_options(state.all_options, new_query)

    {:ok,
     %{
       state
       | filter_query: new_query,
         options: new_options,
         cursor: 0
     }}
  end

  # ---------------------------------------------------------------------
  # Pure state management (unit-testable)
  # ---------------------------------------------------------------------

  def new_state(
        question,
        options,
        is_multi,
        custom_idx,
        show_numbers \\ true,
        progress \\ nil,
        subagent \\ nil,
        opts \\ []
      ) do
    filterable = Keyword.get(opts, :filterable, false)
    initial_filter = Keyword.get(opts, :initial_filter, "")
    all_options = options

    filtered_options =
      if filterable do
        filter_options(all_options, initial_filter)
      else
        options
      end

    %{
      question: question,
      all_options: all_options,
      options: filtered_options,
      is_multi: is_multi,
      custom_idx: custom_idx,
      show_numbers: show_numbers,
      progress: progress,
      subagent: subagent,
      filterable: filterable,
      filter_query: initial_filter,
      clear_on_done: Keyword.get(opts, :clear_on_done, false),
      cursor: 0,
      selected: MapSet.new(),
      rendered_lines: 0
    }
  end

  def move_up(%{options: []} = state), do: state

  def move_up(%{cursor: cursor, options: options} = state) do
    new_cursor = if cursor > 0, do: cursor - 1, else: length(options) - 1
    %{state | cursor: new_cursor}
  end

  def move_down(%{options: []} = state), do: state

  def move_down(%{cursor: cursor, options: options} = state) do
    new_cursor = if cursor < length(options) - 1, do: cursor + 1, else: 0
    %{state | cursor: new_cursor}
  end

  def toggle_selection(%{cursor: cursor, selected: selected, is_multi: true} = state) do
    new_selected =
      if MapSet.member?(selected, cursor) do
        MapSet.delete(selected, cursor)
      else
        MapSet.put(selected, cursor)
      end

    %{state | selected: new_selected}
  end

  def toggle_selection(state), do: state

  def select_index(%{options: options} = state, idx) when idx >= 0 and idx < length(options) do
    %{state | cursor: idx}
  end

  def select_index(state, _), do: state

  # ---------------------------------------------------------------------
  # Formatting results
  # ---------------------------------------------------------------------

  def format_answer(question, %{cancelled: true}) do
    Yoke.Json.encode!(%{
      "question" => question,
      "status" => "cancelled",
      "selected_options" => [],
      "custom_response" => nil
    })
  end

  def format_answer(question, %{selected: selected, custom: custom}) when is_binary(custom) do
    Yoke.Json.encode!(%{
      "question" => question,
      "status" => "answered",
      "selected_options" => selected,
      "custom_response" => custom
    })
  end

  def format_answer(question, %{selected: selected}) when is_list(selected) do
    Yoke.Json.encode!(%{
      "question" => question,
      "status" => "answered",
      "selected_options" => selected,
      "custom_response" => nil
    })
  end

  # ---------------------------------------------------------------------
  # TTY Interactive Raw Loop
  # ---------------------------------------------------------------------

  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      false
    else
      case :io.columns(:user) do
        {:ok, _} ->
          true

        _ ->
          case :io.columns() do
            {:ok, _} -> true
            _ -> false
          end
      end
    end
  end

  defp prompt_tty(question, options, is_multi, custom_idx, show_numbers, progress, subagent, opts) do
    set_raw_mode()
    drain_stale_input()

    state =
      new_state(question, options, is_multi, custom_idx, show_numbers, progress, subagent, opts)

    res =
      try do
        tui_loop(state)
      catch
        :exit, _ ->
          restore_tty_mode()
          prompt_non_tty(question, options, is_multi, custom_idx, progress, subagent)

        :error, _ ->
          restore_tty_mode()
          prompt_non_tty(question, options, is_multi, custom_idx, progress, subagent)
      after
        # Guarantees the modal is unregistered as the terminal's foreground
        # surface however `tui_loop/1` exits (normal confirm/cancel, the
        # `:eof` branch inside it, or either `catch` clause above), so a
        # stray `Logger` call afterwards never tries to redraw a modal that
        # is no longer showing.
        TerminalOwner.clear()
      end

    restore_tty_mode()

    unless Keyword.get(opts, :clear_on_done, false) do
      IO.write(:user, "\r\n")
    end

    res
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp erase_modal(%{rendered_lines: n}) when is_integer(n) and n > 0 do
    IO.write(:user, "\r\e[#{n}A\e[0J")
  end

  defp erase_modal(_), do: :ok

  defp tui_loop(state) do
    state = render_modal(state)
    TerminalOwner.set(&erase_for_log/1, &redraw_for_log/1, state)

    case read_key() do
      :up ->
        tui_loop(move_up(state))

      :down ->
        tui_loop(move_down(state))

      :space ->
        if Map.get(state, :filterable, false) do
          tui_loop(handle_filter_char(state, ?\s))
        else
          tui_loop(toggle_selection(state))
        end

      :backspace ->
        if Map.get(state, :filterable, false) do
          {:ok, new_state} = handle_filter_backspace(state)
          tui_loop(new_state)
        else
          tui_loop(state)
        end

      :escape ->
        if Map.get(state, :clear_on_done, false) or Map.get(state, :filterable, false) do
          if Map.get(state, :clear_on_done, false), do: erase_modal(state)
          %{cancelled: true, selected: []}
        else
          tui_loop(state)
        end

      {:char, char_code} when char_code >= ?1 and char_code <= ?9 ->
        if Map.get(state, :filterable, false) do
          tui_loop(handle_filter_char(state, char_code))
        else
          idx = char_code - ?1
          tui_loop(select_index(state, idx))
        end

      {:char, char_code} ->
        if Map.get(state, :filterable, false) do
          tui_loop(handle_filter_char(state, char_code))
        else
          tui_loop(state)
        end

      :ctrl_o ->
        Yoke.CLI.LineEditor.toggle_expand_tool_calls(state)
        tui_loop(state)

      :enter ->
        case handle_confirm(state) do
          :reloop ->
            tui_loop(state)

          result ->
            if Map.get(state, :clear_on_done, false), do: erase_modal(state)
            result
        end

      :ctrl_c ->
        if Map.get(state, :clear_on_done, false), do: erase_modal(state)
        %{cancelled: true, selected: []}

      :eof ->
        if Map.get(state, :clear_on_done, false), do: erase_modal(state)
        restore_tty_mode()

        prompt_non_tty(
          state.question,
          state.options,
          state.is_multi,
          state.custom_idx,
          Map.get(state, :progress)
        )

      _ ->
        tui_loop(state)
    end
  end

  # `TerminalOwner` erase/redraw callbacks -- see `Yoke.CLI.TerminalOwner`.
  # `render_modal/2`'s own internal erase (used for its own key-driven
  # redraws) is skipped when redrawing this way, since `erase_for_log/1`
  # has already cleared the modal by the time this runs.
  defp erase_for_log(%{rendered_lines: n}) when is_integer(n) and n > 0 do
    IO.write(:user, "\r\e[#{n}A\e[0J")
  end

  defp erase_for_log(_state), do: :ok

  defp redraw_for_log(state), do: render_modal(state, erase?: false)

  defp handle_confirm(state) do
    if state.cursor == state.custom_idx and not Map.get(state, :filterable, false) do
      # User selected write-in custom response
      restore_tty_mode()

      IO.write(
        :user,
        "\r\n" <> Formatter.cyan() <> "󰏫  Enter custom response: " <> Formatter.reset()
      )

      custom_input =
        case IO.gets(:user, "") do
          line when is_binary(line) -> String.trim(line)
          _ -> ""
        end

      chosen_standard =
        state.selected
        |> Enum.reject(&(&1 == state.custom_idx))
        |> Enum.map(&Enum.at(state.options, &1))

      %{selected: chosen_standard, custom: custom_input}
    else
      if state.is_multi do
        selected_set =
          if MapSet.size(state.selected) == 0 do
            MapSet.new([state.cursor])
          else
            state.selected
          end

        chosen =
          selected_set
          |> Enum.reject(&(&1 == state.custom_idx))
          |> Enum.map(&Enum.at(state.options, &1))

        %{selected: chosen}
      else
        if state.options != [] and state.cursor >= 0 and state.cursor < length(state.options) do
          chosen = Enum.at(state.options, state.cursor)
          %{selected: [chosen]}
        else
          if Map.get(state, :filterable, false) and state.filter_query != "" do
            %{custom: state.filter_query, selected: []}
          else
            :reloop
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # TUI Box Renderer
  # ---------------------------------------------------------------------

  @doc "Calculates terminal display width in columns, handling wide symbols and stripping ANSI escapes."
  def display_width(str) when is_binary(str), do: Formatter.display_width(str)

  defp header_title({idx, total}, subagent)
       when is_integer(idx) and is_integer(total) and total > 1 do
    sub_prefix = if is_binary(subagent) and subagent != "", do: "[#{subagent}] ", else: ""
    " 󰋗 #{sub_prefix}Question #{idx}/#{total} from AI "
  end

  defp header_title(_, subagent) do
    sub_prefix = if is_binary(subagent) and subagent != "", do: "[#{subagent}] ", else: ""
    " 󰋗 #{sub_prefix}Question from AI "
  end

  @doc "Calculates terminal column count for modal width calculation."
  def get_terminal_columns do
    case :io.columns(:user) do
      {:ok, cols} when is_integer(cols) and cols > 0 ->
        cols

      _ ->
        case :io.columns() do
          {:ok, cols} when is_integer(cols) and cols > 0 -> cols
          _ -> 72
        end
    end
  end

  @doc """
  Renders the question modal box.

  `opts` supports `:erase?` (default `true`): when `false`, skips this
  function's own erase of its last render, since the caller (e.g.
  `Yoke.CLI.LogFormatter`, interjecting a log line above the
  modal) has already erased it.
  """
  def render_modal(state, opts \\ []) do
    # Total box width including left/right border chars adapts to screen width.
    cols = get_terminal_columns()
    inner_width = max(cols - 2, 40)

    if Keyword.get(opts, :erase?, true) and state.rendered_lines > 0 do
      # Move cursor to column 0, move UP rendered_lines, clear to bottom
      IO.write(:user, "\r\e[#{state.rendered_lines}A\e[0J")
    end

    header_title = header_title(Map.get(state, :progress), Map.get(state, :subagent))
    header_len = display_width(header_title)

    header_padding =
      String.duplicate("─", max(0, inner_width - 1 - header_len))

    header =
      "#{Formatter.cyan()}╭─#{Formatter.bold()}#{header_title}#{Formatter.reset()}#{Formatter.cyan()}#{header_padding}╮#{Formatter.reset()}"

    footer_text =
      cond do
        Map.get(state, :filterable, false) ->
          "[Type to filter | ↑/↓: Select | Enter: Confirm | Esc: Cancel]"

        state.is_multi ->
          "[↑/↓ or 1-#{length(state.options)}: Navigate | Space: Toggle | Enter: Confirm]"

        true ->
          "[↑/↓ or 1-#{length(state.options)}: Select | Enter: Confirm]"
      end

    footer_len = display_width(footer_text)

    footer_padding =
      String.duplicate("─", max(0, inner_width - 1 - footer_len))

    footer =
      "#{Formatter.cyan()}╰─#{Formatter.dim()}#{footer_text}#{Formatter.reset()}#{Formatter.cyan()}#{footer_padding}╯#{Formatter.reset()}"

    blank_line =
      "#{Formatter.cyan()}│#{Formatter.reset()}#{String.duplicate(" ", inner_width)}#{Formatter.cyan()}│#{Formatter.reset()}"

    # Question lines are indented 2 spaces left and 2 spaces right (usable text width 66)
    q_wrapped = wrap_text(state.question, inner_width - 4)

    q_lines =
      Enum.map(q_wrapped, fn line ->
        len = display_width(line)
        pad = String.duplicate(" ", max(0, inner_width - 4 - len))

        "#{Formatter.cyan()}│#{Formatter.reset()}  #{Formatter.bold()}#{line}#{Formatter.reset()}#{pad}  #{Formatter.cyan()}│#{Formatter.reset()}"
      end)

    search_lines =
      if Map.get(state, :filterable, false) do
        query_str = state.filter_query
        len = display_width("  Search: " <> query_str <> "█")
        pad = String.duplicate(" ", max(0, inner_width - 4 - len))

        [
          "#{Formatter.cyan()}│#{Formatter.reset()}  #{Formatter.yellow()}Search: #{Formatter.reset()}#{Formatter.bold()}#{query_str}#{Formatter.reset()}█#{pad}  #{Formatter.cyan()}│#{Formatter.reset()}"
        ]
      else
        []
      end

    opt_lines =
      if Map.get(state, :filterable, false) and state.options == [] do
        msg = "(No matching files found)"
        len = display_width(msg)
        pad = String.duplicate(" ", max(0, inner_width - 4 - len))

        [
          "#{Formatter.cyan()}│#{Formatter.reset()}  #{Formatter.dim()}#{msg}#{Formatter.reset()}#{pad}  #{Formatter.cyan()}│#{Formatter.reset()}"
        ]
      else
        state.options
        |> Enum.with_index()
        |> Enum.flat_map(fn {opt, idx} ->
          is_current = idx == state.cursor
          is_checked = MapSet.member?(state.selected, idx)
          is_custom = idx == state.custom_idx

          prefix =
            cond do
              state.is_multi and is_checked -> "[󰄬] "
              state.is_multi -> "[ ] "
              true -> ""
            end

          clean_opt = String.replace(to_string(opt), ~r/^\d+[\.\)\-]\s*/, "")

          num_prefix = if Map.get(state, :show_numbers, true), do: "#{idx + 1}. ", else: ""

          label =
            if is_custom do
              "#{prefix}#{num_prefix}󰏫 #{clean_opt}"
            else
              "#{prefix}#{num_prefix}#{clean_opt}"
            end

          max_text_width = inner_width - 4
          wrapped_lines = wrap_text(label, max_text_width)

          wrapped_lines
          |> Enum.with_index()
          |> Enum.map(fn {sub_line, sub_idx} ->
            pointer =
              if sub_idx == 0 and is_current do
                "❯ "
              else
                "  "
              end

            styled_sub_line =
              if String.contains?(sub_line, "(Recommended)") do
                [head, tail] = String.split(sub_line, "(Recommended)", parts: 2)

                rec_tag =
                  "#{Formatter.reset()}#{Formatter.gray()}(Recommended)#{Formatter.reset()}"

                if is_current do
                  "#{Formatter.green()}#{Formatter.bold()}#{head}#{rec_tag}#{Formatter.green()}#{Formatter.bold()}#{tail}#{Formatter.reset()}"
                else
                  "#{Formatter.dim()}#{head}#{rec_tag}#{Formatter.dim()}#{tail}#{Formatter.reset()}"
                end
              else
                if is_current do
                  "#{Formatter.green()}#{Formatter.bold()}#{sub_line}#{Formatter.reset()}"
                else
                  "#{Formatter.dim()}#{sub_line}#{Formatter.reset()}"
                end
              end

            len = display_width(sub_line)
            pad = String.duplicate(" ", max(0, max_text_width - len))

            "#{Formatter.cyan()}│#{Formatter.reset()} #{pointer}#{styled_sub_line}#{pad} #{Formatter.cyan()}│#{Formatter.reset()}"
          end)
        end)
      end

    lines =
      [header] ++
        [blank_line] ++
        q_lines ++
        [blank_line] ++
        if(search_lines != [], do: search_lines ++ [blank_line], else: []) ++
        opt_lines ++ [blank_line] ++ [footer]

    IO.write(:user, Enum.join(lines, "\r\n"))
    %{state | rendered_lines: length(lines) - 1}
  end

  defp wrap_text(text, max_len) do
    words = String.split(text, ~r/\s+/)

    Enum.reduce(words, {[], ""}, fn word, {acc, current} ->
      cond do
        current == "" ->
          {acc, word}

        display_width(current) + 1 + display_width(word) <= max_len ->
          {acc, current <> " " <> word}

        true ->
          {acc ++ [current], word}
      end
    end)
    |> then(fn {acc, last} -> if last != "", do: acc ++ [last], else: acc end)
  end

  # ---------------------------------------------------------------------
  # Non-TTY Fallback Prompt
  # ---------------------------------------------------------------------

  defp prompt_non_tty(question, options, is_multi, custom_idx, progress, subagent \\ nil) do
    sub_prefix = if is_binary(subagent) and subagent != "", do: "[#{subagent}] ", else: ""

    label =
      case progress do
        {idx, total} when is_integer(idx) and is_integer(total) and total > 1 ->
          "#{sub_prefix}Question #{idx}/#{total} from AI"

        _ ->
          "#{sub_prefix}Question from AI"
      end

    IO.write(
      :user,
      "\r\n" <>
        Formatter.cyan() <>
        "󰋗 #{label}: " <> Formatter.bold() <> question <> Formatter.reset() <> "\r\n"
    )

    options
    |> Enum.with_index()
    |> Enum.each(fn {opt, idx} ->
      tag = if idx == custom_idx, do: "󰏫  #{opt}", else: opt

      styled_tag =
        if String.contains?(to_string(tag), "(Recommended)") do
          String.replace(
            to_string(tag),
            "(Recommended)",
            Formatter.gray() <> "(Recommended)" <> Formatter.reset()
          )
        else
          tag
        end

      IO.write(:user, "  #{idx + 1}. #{styled_tag}\r\n")
    end)

    input =
      case IO.gets(:user, "Select option number (1-#{length(options)}) or enter response: ") do
        str when is_binary(str) -> String.trim(str)
        _ -> ""
      end

    case Integer.parse(input) do
      {num, ""} when num >= 1 and num <= length(options) ->
        idx = num - 1

        if idx == custom_idx do
          custom_val = IO.gets(:user, "Enter custom response: ") |> to_string() |> String.trim()
          %{selected: [], custom: custom_val}
        else
          %{selected: [Enum.at(options, idx)]}
        end

      _ ->
        if input != "" do
          %{selected: [], custom: input}
        else
          IO.write(
            :user,
            Formatter.yellow() <>
              "Please select a valid option number (1-#{length(options)}) or enter a response.\r\n" <>
              Formatter.reset()
          )

          prompt_non_tty(question, options, is_multi, custom_idx, progress, subagent)
        end
    end
  end

  # ---------------------------------------------------------------------
  # Key Reader (directed to controlling terminal :user)
  # ---------------------------------------------------------------------

  defp read_key do
    case get_raw_input_chunk() do
      :eof -> :eof
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
  defp match_key("\r"), do: :enter
  defp match_key("\n"), do: :enter
  defp match_key("\r\n"), do: :enter
  defp match_key("\t"), do: :tab
  defp match_key(" "), do: :space
  defp match_key("\x08"), do: :backspace
  defp match_key("\x7f"), do: :backspace
  defp match_key("\x0f"), do: :ctrl_o
  defp match_key("\x03"), do: :ctrl_c
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

      true ->
        case String.to_charlist(other) do
          [c | _] -> {:char, c}
          _ -> :other
        end
    end
  end

  # `read_char/0` only ever yields `:eof` or a binary, so those two shapes
  # exhaust the possible input here.
  defp get_raw_input_chunk do
    case read_char() do
      "\e" ->
        seq = read_available_escape_bytes("", 6)
        "\e" <> seq

      :eof ->
        :eof

      char when is_binary(char) ->
        char
    end
  end

  defp drain_stale_input do
    case read_char_with_timeout(5) do
      char when is_binary(char) and char != "" -> drain_stale_input()
      _ -> :ok
    end
  end

  defp read_char_with_timeout(timeout_ms) do
    task = Task.async(fn -> read_char() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp read_available_escape_bytes(acc, count) when count > 0 do
    case read_char_with_timeout(25) do
      char when is_binary(char) and char != "" ->
        new_acc = acc <> char

        if char in ["A", "B", "C", "D", "H", "F", "~"] do
          new_acc
        else
          read_available_escape_bytes(new_acc, count - 1)
        end

      _ ->
        acc
    end
  end

  defp read_available_escape_bytes(acc, _count), do: acc

  defp read_char do
    case IO.getn(:user, "", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
    end
  end
end

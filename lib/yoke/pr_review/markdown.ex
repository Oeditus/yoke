defmodule Yoke.PRReview.Markdown do
  @moduledoc """
  Markdown formatting helpers for GitHub PR code review comments.
  Ensures inline comments, finding summaries, and fix suggestions are formatted
  with proper GitHub-flavored Markdown (backticks for short code pieces,
  code fences for multiline snippets, and preservation of existing formatting).
  """

  @proper_noun_stoplist MapSet.new([
                          "GitHub",
                          "GitLab",
                          "Elixir",
                          "Erlang",
                          "JavaScript",
                          "TypeScript",
                          "Python",
                          "Ruby",
                          "Rust",
                          "PostgreSQL",
                          "MySQL",
                          "SQLite",
                          "GraphQL",
                          "Playwright",
                          "Markdown",
                          "OpenAI",
                          "Anthropic",
                          "DeepMind",
                          "Phoenix",
                          "Ecto",
                          "Oban",
                          "Credo",
                          "Dialyzer",
                          "Docker",
                          "Linux",
                          "macOS",
                          "Windows"
                        ])

  @doc """
  Formats an inline review comment finding for GitHub PR reviews.
  """
  def format_inline_comment_body(finding) when is_map(finding) do
    severity = Map.get(finding, :severity) || Map.get(finding, "severity") || "medium"
    title = Map.get(finding, :title) || Map.get(finding, "title") || ""
    desc = Map.get(finding, :description) || Map.get(finding, "description") || ""
    fix = Map.get(finding, :fix_suggestion) || Map.get(finding, "fix_suggestion") || ""
    file = Map.get(finding, :file) || Map.get(finding, "file")

    lang = infer_language(file)

    formatted_title = format_inline_code(to_string(title))
    formatted_desc = format_markdown_body(to_string(desc), lang: lang)
    suggestion_block = format_fix_block(to_string(fix), lang: lang)

    header = "**[#{String.upcase(to_string(severity))}] #{formatted_title}**"

    body_parts =
      [header, formatted_desc, suggestion_block]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.join(body_parts, "\n\n")
  end

  @doc """
  Formats single-line prose or inline text (such as titles or summary lines),
  wrapping short code pieces in backticks without introducing multiline code fences.
  """
  def format_inline_code(text) when is_binary(text) do
    apply_inline_code_rules(text)
  end

  def format_inline_code(other), do: to_string(other)

  @doc """
  Formats a markdown body, preserving existing code fences, wrapping unfenced
  multiline code snippets in fenced blocks, and wrapping short code pieces in backticks.
  """
  def format_markdown_body(text, opts \\ [])

  def format_markdown_body(text, opts) when is_binary(text) do
    lang = Keyword.get(opts, :lang, "elixir")

    # 1. Split text into existing fenced code blocks and text segments
    segments = split_fenced_blocks(text)

    # 2. For each text segment, detect any unfenced multiline code and fence it
    fenced_segments =
      Enum.flat_map(segments, fn
        {:fence, block} ->
          [{:fence, block}]

        {:text, outside} ->
          detect_and_split_multiline_code(outside, lang)
      end)

    # 3. Only apply inline code formatting to text segments outside any code fences
    fenced_segments
    |> Enum.map_join("", fn
      {:fence, block} ->
        block

      {:text, outside} ->
        apply_inline_code_rules(outside)
    end)
  end

  def format_markdown_body(other, _opts), do: to_string(other)

  # --- Fix block formatting ---

  defp format_fix_block("", _opts), do: ""

  defp format_fix_block(fix, opts) do
    trimmed = String.trim(fix)

    cond do
      trimmed == "" ->
        ""

      String.contains?(trimmed, "```") ->
        # Already has code fences - ensure prose around them is formatted
        format_markdown_body(trimmed, opts)

      pure_prose?(trimmed) ->
        # Pure prose suggestion, format inline code
        format_inline_code(trimmed)

      true ->
        # Code snippet: wrap in ```suggestion
        "\n```suggestion\n#{trimmed}\n```"
    end
  end

  defp pure_prose?(text) do
    lines = String.split(text, "\n", trim: true)

    if length(lines) == 1 do
      line = List.first(lines)

      (String.ends_with?(line, ".") or
         String.match?(line, ~r/^(Wrap|Use|Add|Consider|Ensure|Remove|Replace|Check|Verify|Pass|Guard)\s/)) and
        not String.match?(line, ~r/^\s*(def|defp|if|case|cond|with|@|use|alias|import)\s/) and
        not String.contains?(line, ", do:")
    else
      false
    end
  end

  # --- Fenced blocks splitting ---

  defp split_fenced_blocks(text) do
    regex = ~r/(```[a-zA-Z0-9_\-]*\n[\s\S]*?```)/

    parts = Regex.split(regex, text, include_captures: true, trim: false)

    Enum.map(parts, fn part ->
      if String.starts_with?(part, "```") and String.ends_with?(part, "```") and
           String.length(part) >= 6 do
        {:fence, part}
      else
        {:text, part}
      end
    end)
  end

  # --- Unfenced multiline code detection ---

  defp detect_and_split_multiline_code(text, lang) do
    lines = String.split(text, "\n")
    chunks = chunk_code_and_prose_lines(lines)

    Enum.map(chunks, fn
      {:code, code_lines} ->
        code_body = Enum.join(code_lines, "\n")
        lang_tag = if lang && lang != "", do: lang, else: ""
        {:fence, "\n```#{lang_tag}\n#{code_body}\n```\n"}

      {:prose, prose_lines} ->
        {:text, Enum.join(prose_lines, "\n")}
    end)
  end

  defp chunk_code_and_prose_lines(lines) do
    classified = Enum.map(lines, fn line -> {classify_line(line), line} end)

    classified
    |> Enum.chunk_by(fn {type, _} -> type == :code end)
    |> Enum.flat_map(fn group ->
      case group do
        [{:code, _} | _] ->
          code_lines = Enum.map(group, fn {_, l} -> l end)

          if length(code_lines) >= 2 or strong_code_line?(List.first(code_lines)) do
            [{:code, code_lines}]
          else
            [{:prose, code_lines}]
          end

        _ ->
          [{:prose, Enum.map(group, fn {_, l} -> l end)}]
      end
    end)
  end

  defp classify_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :blank

      strong_code_line?(trimmed) ->
        :code

      indented_code_line?(line, trimmed) ->
        :code

      true ->
        :prose
    end
  end

  defp strong_code_line?(trimmed) do
    cond do
      String.match?(
        trimmed,
        ~r/^(def|defp|defmodule|defmacro|defstruct|defimpl|defprotocol|use|alias|import|require|case|cond|with|receive|try)\s/
      ) ->
        true

      String.match?(trimmed, ~r/^(@impl|@spec|@doc|@moduledoc|@type)\s/) ->
        true

      String.match?(trimmed, ~r/^(end|end\)|end\}|end,)$/) ->
        true

      String.match?(trimmed, ~r/^\s*\|>\s*[a-zA-Z_]/) ->
        true

      String.match?(trimmed, ~r/^(function|const|let|var|return|pub fn|impl|struct|enum)\s/) ->
        true

      String.match?(trimmed, ~r/^(unique:\s*\[|queue:\s*:[a-zA-Z_]|states:\s*\[|keys:\s*\[)/) ->
        true

      true ->
        false
    end
  end

  defp indented_code_line?(line, trimmed) do
    has_indent = String.starts_with?(line, "  ") or String.starts_with?(line, "\t")

    not_md_list =
      not String.match?(trimmed, ~r/^[-*+]\s/) and not String.match?(trimmed, ~r/^\d+\.\s/)

    code_tokens =
      String.contains?(trimmed, ["->", "=>", "|>", "::", "%{", "{:", "}:", "()", "do:"]) or
        String.match?(trimmed, ~r/^[a-zA-Z0-9_]+:\s*[a-zA-Z0-9_:\[{]/) or
        String.match?(trimmed, ~r/^[}\]\)]+[,;]?$/)

    has_indent and not_md_list and code_tokens
  end

  # --- Inline code rules pipeline ---

  defp apply_inline_code_rules(text) do
    # Pipeline of formatting rules applied sequentially.
    # At each step, we split by existing `...` backtick spans so newly created
    # or existing backtick spans are protected and never double-wrapped!
    rules = [
      &format_function_calls/1,
      &format_function_arities/1,
      &format_comparison_expressions/1,
      &format_complex_expressions/1,
      &format_file_paths/1,
      &format_atoms/1,
      &format_dotted_identifiers/1,
      &format_snake_case_identifiers/1,
      &format_pascal_case_identifiers/1,
      &format_hyphen_identifiers/1
    ]

    Enum.reduce(rules, text, fn rule, current_text ->
      parts = Regex.split(~r/(`[^`\n]+`)/, current_text, include_captures: true, trim: false)

      Enum.map_join(parts, "", fn part ->
        if String.starts_with?(part, "`") and String.ends_with?(part, "`") and
             String.length(part) >= 2 do
          part
        else
          rule.(part)
        end
      end)
    end)
  end

  # 1. Function calls with arguments or parens:
  # send(self(), ...), handle_comment_event(socket, %{event: :read}), assign_new(:form, ...), self(), Mix.env()
  defp format_function_calls(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_.])([a-zA-Z_][a-zA-Z0-9_?!]*\.[a-zA-Z_][a-zA-Z0-9_?!]*\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\)|[a-z_][a-zA-Z0-9_?!]*\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\))(?![`a-zA-Z0-9_])/,
      text,
      fn full, call ->
        # Ensure it contains code syntax (empty call like self(), or code args with atoms/commas/braces)
        if String.contains?(call, "(") and
             (String.ends_with?(call, "()") or
                String.contains?(call, [":", ",", ".", "\"", "'", "{", "}", "%", "[", "]"])) do
          "`#{call}`"
        else
          full
        end
      end
    )
  end

  # 2. Function references with arity: mark_read/2, handle_info/2, System.cmd/3, Mod.fun/2
  defp format_function_arities(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_:])((?:[A-Z][a-zA-Z0-9_]*(?:\.[A-Z][a-zA-Z0-9_]*)*\.)?[a-z_][a-zA-Z0-9_?!]*\/\d+)(?![`a-zA-Z0-9_])/,
      text,
      "`\\1`"
    )
  end

  # 3. Comparisons / flow operators: socket.assigns.view == :archived, view == :archived, a != b, foo -> bar
  defp format_comparison_expressions(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_])([a-zA-Z0-9_.\[\]:]+\s*(?:==|!=|===|!==|->|\|>)\s*[a-zA-Z0-9_.\[\]:()]+)(?![`a-zA-Z0-9_])/,
      text,
      fn full, expr ->
        if String.match?(expr, ~r/(==|!=|->|\|>)/) and not String.contains?(expr, "`") do
          "`#{expr}`"
        else
          full
        end
      end
    )
  end

  # 4. Complex expressions: {:error, :unknown_commentable}, %{event: :read}, [:dev, :test]
  defp format_complex_expressions(text) do
    text
    # Tuples: {:error, :unknown_commentable}
    |> String.replace(
      ~r/(?<![`a-zA-Z0-9_])(\{:?[a-zA-Z0-9_]+,\s*[^{}\n]+\})(?![`a-zA-Z0-9_])/,
      "`\\1`"
    )
    # Maps: %{event: :read}
    |> String.replace(~r/(?<![`a-zA-Z0-9_])(%\{[^{}\n]+\})(?![`a-zA-Z0-9_])/, "`\\1`")
    # Lists with atoms: [:available, :scheduled, :retryable] or [:comment_id]
    |> String.replace(
      ~r/(?<![`a-zA-Z0-9_])(\[:[a-zA-Z0-9_]+(?:,\s*:[a-zA-Z0-9_]+)*\])(?![`a-zA-Z0-9_])/,
      "`\\1`"
    )
    # Keyword list syntax: unique: [period: 300, states: [...]] or keys: [:comment_id]
    |> String.replace(
      ~r/(?<![`a-zA-Z0-9_])([a-z_]+:\s*\[[^\]\n]+\])(?![`a-zA-Z0-9_])/,
      "`\\1`"
    )
  end

  # 5. File paths: config/dev.exs, apps/api/lib/drawer.ex, lib/foo.ex:42
  defp format_file_paths(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_])((?:\.?[a-zA-Z0-9_\-]+\/)+[a-zA-Z0-9_\-\.]+\.[a-zA-Z0-9]+(?::\d+)?|[a-zA-Z0-9_\-]+\.(?:ex|exs|erl|hrl|rs|py|js|ts|tsx|jsx|go|rb|json|yml|yaml|toml|sql|sh|heex|eex)(?::\d+)?)(?![`a-zA-Z0-9_])/,
      text,
      "`\\1`"
    )
  end

  # 6. Atoms: :comment_event, :comment_threads, :read, :ok, :error, :archived
  defp format_atoms(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_]):([a-zA-Z_][a-zA-Z0-9_?!]*)(?![`a-zA-Z0-9_])/,
      text,
      "`:\\1`"
    )
  end

  # 7. Dotted identifiers: Oban.Pro, Commentables.Reference, socket.assigns.view, thread.archived_at
  defp format_dotted_identifiers(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_.])([A-Z][a-zA-Z0-9_]*(?:\.[A-Z][a-zA-Z0-9_]*)+|[a-z_][a-zA-Z0-9_]*(?:\.[a-z_][a-zA-Z0-9_?!]*)+)(?![`a-zA-Z0-9_.])/,
      text,
      fn full, ident ->
        cond do
          ident in ["e.g.", "i.e.", "etc.", "vs."] ->
            full

          String.contains?(ident, "`") ->
            full

          true ->
            "`#{ident}`"
        end
      end
    )
  end

  # 8. Snake_case identifiers: comment_commentables, assign_new, fix_suggestion, mark_replies_read?
  defp format_snake_case_identifiers(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_])([a-z][a-z0-9]*_[a-z0-9_?!]*|[a-z][a-z0-9_]*[?!])(?![`a-zA-Z0-9_])/,
      text,
      fn full, ident ->
        if String.contains?(ident, "`") do
          full
        else
          "`#{ident}`"
        end
      end
    )
  end

  # 9. PascalCase code identifiers: StewardshipSyncWorker, NotificationWorker, LiveComponent, LiveView, SurfaceIcon
  defp format_pascal_case_identifiers(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_])([A-Z][a-z0-9]+(?:[A-Z][a-zA-Z0-9]*)+)(?![`a-zA-Z0-9_])/,
      text,
      fn full, ident ->
        cond do
          MapSet.member?(@proper_noun_stoplist, ident) ->
            full

          String.contains?(ident, "`") ->
            full

          true ->
            "`#{ident}`"
        end
      end
    )
  end

  # 10. Hyphenated identifiers with leading dash or angle brackets: -composer, -edit-<id>
  defp format_hyphen_identifiers(text) do
    Regex.replace(
      ~r/(?<![`a-zA-Z0-9_])(-[a-z][a-z0-9\-]*(?:<[^>\n]+>)?)(?![`a-zA-Z0-9_])/,
      text,
      fn full, ident ->
        if String.contains?(ident, "`") do
          full
        else
          "`#{ident}`"
        end
      end
    )
  end

  defp infer_language(file) when is_binary(file) do
    case Path.extname(file) do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ext when ext in [".rs"] -> "rust"
      ext when ext in [".js", ".jsx"] -> "javascript"
      ext when ext in [".ts", ".tsx"] -> "typescript"
      ext when ext in [".py"] -> "python"
      ext when ext in [".rb"] -> "ruby"
      ext when ext in [".go"] -> "go"
      ext when ext in [".json"] -> "json"
      ext when ext in [".sh", ".bash"] -> "bash"
      ext when ext in [".yml", ".yaml"] -> "yaml"
      ext when ext in [".md"] -> "markdown"
      ext when ext in [".sql"] -> "sql"
      ext when ext in [".heex", ".eex"] -> "heex"
      _ -> ""
    end
  end

  defp infer_language(_), do: "elixir"
end

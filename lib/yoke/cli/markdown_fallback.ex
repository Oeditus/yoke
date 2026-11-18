defmodule Yoke.CLI.MarkdownFallback do
  @moduledoc """
  Pure-Elixir Markdown-to-ANSI terminal renderer used when the native
  `mdex_native` NIF is unavailable (for example, when running a Linux-built
  escript on macOS or in an environment without the native library).
  """

  alias Yoke.CLI.Output

  @doc """
  Renders Markdown text into ANSI-styled terminal text using pure Elixir.

  ## Options
  - `:newline` - line ending string (default: `"\\n"`)
  - `:base_color` - ANSI prefix restored after inline resets (default: `""`)
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(markdown, opts \\ []) when is_binary(markdown) do
    nl = Keyword.get(opts, :newline, "\n")
    base_color = Keyword.get(opts, :base_color, "")
    reset_seq = style(IO.ANSI.reset()) <> base_color

    {lines, _in_code?} =
      markdown
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], false}, fn line, {acc, in_code?} ->
        render_line(line, acc, in_code?, reset_seq)
      end)

    lines
    |> Enum.reverse()
    |> Enum.join(nl)
  end

  defp render_line(line, acc, true, reset_seq) do
    if String.match?(line, ~r/^\s*```/) do
      {[style(IO.ANSI.faint()) <> "```" <> reset_seq | acc], false}
    else
      {[style(IO.ANSI.cyan()) <> "  " <> line <> reset_seq | acc], true}
    end
  end

  defp render_line(line, acc, false, reset_seq) do
    cond do
      match = Regex.run(~r/^\s*```(.*)$/, line) ->
        lang = String.trim(Enum.at(match, 1, ""))
        header = if lang == "", do: "```", else: "``` #{lang}"
        {[style(IO.ANSI.faint()) <> header <> reset_seq | acc], true}

      match = Regex.run(~r/^(\#{1,6})\s+(.*)$/, line) ->
        [_, hashes, body] = match
        color = heading_color(String.length(hashes))
        rendered = color <> style(IO.ANSI.bright()) <> format_inline(body, reset_seq) <> reset_seq
        {[rendered | acc], false}

      String.match?(line, ~r/^\s*([-*_])(?:\s*\1){2,}\s*$/) ->
        {[style(IO.ANSI.faint()) <> String.duplicate("─", 40) <> reset_seq | acc], false}

      match = Regex.run(~r/^\s*>\s?(.*)$/, line) ->
        [_, body] = match
        prefix = style(IO.ANSI.faint()) <> "│ " <> reset_seq
        {[prefix <> format_inline(body, reset_seq) | acc], false}

      match = Regex.run(~r/^(\s*)[-*+]\s+\[([xX ])\]\s+(.*)$/, line) ->
        [_, indent, checked, body] = match
        marker = if checked in ["x", "X"], do: "☑ ", else: "☐ "
        {[indent <> marker <> format_inline(body, reset_seq) | acc], false}

      match = Regex.run(~r/^(\s*)[-*+]\s+(.*)$/, line) ->
        [_, indent, body] = match
        bullet = style(IO.ANSI.cyan()) <> "▸ " <> reset_seq
        {[indent <> bullet <> format_inline(body, reset_seq) | acc], false}

      true ->
        {[format_inline(line, reset_seq) | acc], false}
    end
  end

  defp heading_color(1), do: style(IO.ANSI.yellow())
  defp heading_color(2), do: style(IO.ANSI.cyan())
  defp heading_color(_), do: ""

  # Format inline code spans first so markdown delimiters inside backticks stay literal.
  defp format_inline(text, reset_seq) do
    Regex.split(~r/`([^`]+)`/, text, include_captures: true)
    |> Enum.map_join(fn part ->
      case Regex.run(~r/^`([^`]+)`$/, part) do
        [_, code] ->
          style(IO.ANSI.cyan()) <> code <> reset_seq

        nil ->
          part
          |> format_links(reset_seq)
          |> format_emphasis(reset_seq)
      end
    end)
  end

  defp format_links(text, reset_seq) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, fn _, label, url ->
      style(IO.ANSI.blue()) <>
        style(IO.ANSI.underline()) <>
        label <>
        reset_seq <>
        style(IO.ANSI.faint()) <> " (#{url})" <> reset_seq
    end)
  end

  defp format_emphasis(text, reset_seq) do
    text
    |> then(
      &Regex.replace(~r/\*\*([^\*\n]+)\*\*|__([^_\n]+)__/, &1, fn _, a, b ->
        inner = if a != "", do: a, else: b
        style(IO.ANSI.bright()) <> inner <> reset_seq
      end)
    )
    |> then(
      &Regex.replace(~r/~~([^~\n]+)~~/, &1, fn _, inner ->
        style(IO.ANSI.faint()) <> inner <> reset_seq
      end)
    )
    |> then(
      &Regex.replace(~r/(?<!\*)\*([^\*\n]+)\*(?!\*)/, &1, fn _, inner ->
        style(IO.ANSI.italic()) <> inner <> reset_seq
      end)
    )
  end

  defp style(seq), do: Output.style(seq)
end

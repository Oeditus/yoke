defmodule Yoke.Linter.Parser do
  @moduledoc """
  Parses raw textual output from static analysis tools (Credo, oeditus_credo,
  Dialyzer, mix format) into structured finding structs.
  """

  defmodule Finding do
    @moduledoc "Represents a single static analysis finding."
    defstruct [:file, :line, :column, :check, :message, :tool, :priority, :raw]

    @type t :: %__MODULE__{
            file: String.t(),
            line: integer(),
            column: integer() | nil,
            check: String.t() | nil,
            message: String.t(),
            tool: String.t(),
            priority: String.t() | nil,
            raw: String.t()
          }
  end

  @doc """
  Parses raw output from a named linter tool (`credo`, `oeditus_credo`, `dialyzer`, `mix_format`, or `all`)
  into a list of `Finding` structs.
  """
  def parse(output, tool \\ "credo") when is_binary(output) do
    lines = String.split(output, "\n")

    lines
    |> Enum.flat_map(&parse_line(&1, tool))
    |> Enum.filter(&valid_finding?/1)
    |> Enum.uniq_by(fn f -> {f.file, f.line, f.check, f.message} end)
  end

  @doc "Attempts to parse a single line of output based on known linter patterns."
  def parse_line(line, tool) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        []

      # Credo / oeditus_credo oneline style with [C]: lib/foo.ex:12:34 [C] Credo.Check.Name: Message
      match = Regex.named_captures(~r/^(?<file>[a-zA-Z0-9_\/\.\-]+\.exs?):(?<line>\d+)(?::(?<col>\d+))?\s+\[(?<prio>[A-Za-z])\]\s*(?:(?<check>[A-Z][a-zA-Z0-9_\.]+):\s*)?(?<msg>.+)$/, trimmed) ->
        check_or_msg = match["check"]
        msg = match["msg"]

        {check, message} =
          if check_or_msg && check_or_msg != "" && String.contains?(check_or_msg, ".") do
            {check_or_msg, msg}
          else
            {nil, check_or_msg || msg}
          end

        [
          %Finding{
            file: match["file"],
            line: String.to_integer(match["line"]),
            column: parse_int(match["col"]),
            check: check,
            priority: match["prio"],
            message: String.trim(message),
            tool: tool,
            raw: trimmed
          }
        ]

      # Dialyzer / generic style: lib/foo.ex:12:34: Message...
      match = Regex.named_captures(~r/^(?<file>[a-zA-Z0-9_\/\.\-]+\.exs?):(?<line>\d+)(?::(?<col>\d+))?:\s*(?<msg>.+)$/, trimmed) ->
        [
          %Finding{
            file: match["file"],
            line: String.to_integer(match["line"]),
            column: parse_int(match["col"]),
            message: String.trim(match["msg"]),
            tool: tool,
            raw: trimmed
          }
        ]

      # mix format style: "  lib/foo.ex" or "lib/foo.ex"
      match = Regex.named_captures(~r/^(?:Would format|\*|\-)?\s*(?<file>[a-zA-Z0-9_\/\.\-]+\.exs?)$/, trimmed) ->
        [
          %Finding{
            file: match["file"],
            line: 1,
            column: 1,
            check: "Mix.Format",
            message: "File needs formatting with mix format",
            tool: "mix_format",
            raw: trimmed
          }
        ]

      true ->
        []
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(str), do: String.to_integer(str)

  defp valid_finding?(%Finding{file: file, line: line}) when is_binary(file) and is_integer(line) do
    String.ends_with?(file, ".ex") or String.ends_with?(file, ".exs")
  end

  defp valid_finding?(_), do: false
end

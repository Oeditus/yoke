defmodule Yoke.Linter.Fixer do
  @moduledoc """
  Generates proposed code diff fixes for linter findings using a hybrid model:
  1. Fast, deterministic mechanical fixes for formatting, whitespace, and simple AST rules.
  2. LLM-assisted diff generation for non-trivial static analysis warnings.
  """
  alias Yoke.Linter.Parser.Finding

  defmodule ProposedPatch do
    @moduledoc "Represents a proposed fix with a diff for a linter finding."
    defstruct [:finding, :file, :start_line, :end_line, :original_text, :replacement_text, :diff, :fix_type]

    @type t :: %__MODULE__{
            finding: Finding.t(),
            file: String.t(),
            start_line: integer(),
            end_line: integer(),
            original_text: String.t(),
            replacement_text: String.t(),
            diff: String.t(),
            fix_type: :mechanical | :llm
          }
  end

  @doc """
  Generates a proposed patch for a single finding in the given working directory.
  """
  def propose_fix(%Finding{} = finding, cwd \\ ".") do
    full_path = Path.expand(finding.file, cwd)

    if File.exists?(full_path) do
      content = File.read!(full_path)

      case try_mechanical_fix(finding, full_path, content) do
        {:ok, patch} ->
          {:ok, patch}

        :no_mechanical_fix ->
          try_llm_fix(finding, full_path, content)
      end
    else
      {:error, "File does not exist: #{finding.file}"}
    end
  end

  @doc """
  Applies a proposed patch to disk.
  """
  def apply_patch(%ProposedPatch{file: _file, replacement_text: new_text} = patch) do
    full_path = patch.file

    if patch.fix_type == :mechanical and patch.start_line == 1 and patch.end_line == :all do
      File.write!(full_path, new_text)
      :ok
    else
      lines = File.read!(full_path) |> String.split("\n")
      total = length(lines)
      s_idx = max(0, patch.start_line - 1)

      e_idx =
        if patch.end_line == :all do
          total - 1
        else
          min(total - 1, patch.end_line - 1)
        end

      before_lines = Enum.take(lines, s_idx)
      after_lines = Enum.drop(lines, e_idx + 1)
      replacement_lines = String.split(new_text, "\n")

      final_content = Enum.join(before_lines ++ replacement_lines ++ after_lines, "\n")
      File.write!(full_path, final_content)
      :ok
    end
  rescue
    e -> {:error, "Failed to apply patch: #{Exception.message(e)}"}
  end

  # --- Mechanical Fixes ---

  defp try_mechanical_fix(%Finding{check: "Mix.Format"} = finding, full_path, content) do
    formatted =
      try do
        Code.format_string!(content) |> IO.iodata_to_binary()
      rescue
        _ -> content
      end

    if String.trim(formatted) != String.trim(content) do
      diff = build_simple_diff(finding.file, content, formatted)

      {:ok,
       %ProposedPatch{
         finding: finding,
         file: full_path,
         start_line: 1,
         end_line: :all,
         original_text: content,
         replacement_text: formatted <> "\n",
         diff: diff,
         fix_type: :mechanical
       }}
    else
      :no_mechanical_fix
    end
  end

  defp try_mechanical_fix(%Finding{message: msg} = finding, full_path, content)
       when is_binary(msg) do
    cond do
      String.contains?(msg, "formatting") or String.contains?(msg, "mix format") ->
        try_mechanical_fix(%Finding{finding | check: "Mix.Format"}, full_path, content)

      String.contains?(msg, "trailing whitespace") ->
        lines = String.split(content, "\n")
        fixed_lines = Enum.map(lines, &String.trim_trailing/1)
        fixed_content = Enum.join(fixed_lines, "\n")

        if fixed_content != content do
          diff = build_simple_diff(finding.file, content, fixed_content)

          {:ok,
           %ProposedPatch{
             finding: finding,
             file: full_path,
             start_line: 1,
             end_line: :all,
             original_text: content,
             replacement_text: fixed_content,
             diff: diff,
             fix_type: :mechanical
           }}
        else
          :no_mechanical_fix
        end

      true ->
        :no_mechanical_fix
    end
  end

  defp try_mechanical_fix(_finding, _full_path, _content), do: :no_mechanical_fix

  # --- LLM Fixes ---

  defp try_llm_fix(%Finding{} = finding, full_path, content) do
    lines = String.split(content, "\n")
    total_lines = length(lines)
    s_line = max(1, finding.line - 10)
    e_line = min(total_lines, finding.line + 10)

    snippet_lines =
      lines
      |> Enum.slice((s_line - 1)..(e_line - 1))
      |> Enum.with_index(s_line)
      |> Enum.map_join("\n", fn {line, num} -> "#{num}: #{line}" end)

    prompt = """
    You are an expert Elixir refactoring tool. Fix the following linter issue in the snippet below.

    Linter Tool: #{finding.tool}
    Check: #{finding.check || "Linter warning"}
    File: #{finding.file}:#{finding.line}
    Message: #{finding.message}

    Snippet (Lines #{s_line}-#{e_line}):
    ```elixir
    #{snippet_lines}
    ```

    Respond ONLY with the replacement Elixir code snippet for lines #{s_line} to #{e_line} inside standard markdown ```elixir ... ``` block. Do not include line numbers in your response.
    """

    messages = [%{"role" => "user", "content" => prompt}]

    case Yoke.Client.DeepSeekAPI.chat_completion(messages, []) do
      {:ok, %{"content" => reply}} when is_binary(reply) ->
        clean_code = extract_code_block(reply)
        original_snippet = Enum.slice(lines, (s_line - 1)..(e_line - 1)) |> Enum.join("\n")

        if clean_code != "" and clean_code != original_snippet do
          diff = build_simple_diff(finding.file, original_snippet, clean_code, s_line)

          {:ok,
           %ProposedPatch{
             finding: finding,
             file: full_path,
             start_line: s_line,
             end_line: e_line,
             original_text: original_snippet,
             replacement_text: clean_code,
             diff: diff,
             fix_type: :llm
           }}
        else
          {:error, "LLM could not produce a valid code change."}
        end

      _ ->
        {:error, "AI provider unavailable or failed to generate fix."}
    end
  end

  defp extract_code_block(text) do
    case Regex.run(~r/```(?:elixir)?\n(.*?)```/s, text) do
      [_, code] -> String.trim(code)
      _ -> String.trim(text)
    end
  end

  @doc "Renders a unified colored git diff format string."
  def build_simple_diff(file, old_text, new_text, line_offset \\ 1) do
    old_lines = String.split(old_text, "\n")
    new_lines = String.split(new_text, "\n")

    hunk =
      Enum.map(old_lines, fn line -> "- #{line}" end) ++
        Enum.map(new_lines, fn line -> "+ #{line}" end)

    header = "--- a/#{file}\n+++ b/#{file}\n@@ -#{line_offset},#{length(old_lines)} +#{line_offset},#{length(new_lines)} @@\n"
    header <> Enum.join(hunk, "\n")
  end
end

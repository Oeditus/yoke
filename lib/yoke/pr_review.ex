defmodule Yoke.PRReview do
  @moduledoc """
  Semi-automated Pull Request code review module.
  Handles structured finding extraction, interactive accept/decline workflows,
  posting findings to GitHub PRs via the `gh` CLI, and constructing fix prompts.
  """

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.QuestionPrompt

  @type finding :: %{
          id: integer(),
          file: String.t() | nil,
          line: integer() | nil,
          title: String.t(),
          description: String.t(),
          severity: String.t(),
          fix_suggestion: String.t()
        }

  @doc """
  Appends structured findings format instructions to the Code Review prompt.
  """
  def prompt_instructions do
    """

    7. **Structured Findings Payload**:
    At the end of your response, output a ```json findings ... ``` code block containing a JSON array of all discrete code findings/issues identified during this review.
    Each object in the array MUST have the following structure:
    ```json findings
    [
      {
        "id": 1,
        "file": "path/to/file.ex",
        "line": 42,
        "title": "Short title of issue",
        "description": "Clear explanation of the problem.",
        "severity": "high",
        "fix_suggestion": "Proposed code fix or recommendation."
      }
    ]
    ```
    (severity can be "high", "medium", "low", or "info"). If no actionable issues are found, output an empty array `[]`.
    """
  end

  @doc """
  Parses findings from LLM review output. Looks for ```json findings``` or ```json``` blocks
  containing JSON arrays, with fallback heuristic parsing for Markdown sections.
  """
  def parse_findings(review_md) when is_binary(review_md) do
    case extract_json_block(review_md) do
      {:ok, findings} when is_list(findings) and findings != [] ->
        findings
        |> Enum.map(&normalize_finding/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        fallback_parse_findings(review_md)
    end
  end

  def parse_findings(_), do: []

  defp extract_json_block(text) do
    regex_findings = ~r/```json\s*findings\s*\n(.*?)```/s
    regex_generic = ~r/```json\s*\n(.*?)```/s
    regex_tags = ~r/<findings>\s*(.*?)\s*<\/findings>/s

    json_str =
      cond do
        match = Regex.run(regex_findings, text) -> Enum.at(match, 1)
        match = Regex.run(regex_tags, text) -> Enum.at(match, 1)
        match = Regex.run(regex_generic, text) -> Enum.at(match, 1)
        true -> nil
      end

    if json_str do
      case Yoke.Json.decode(String.trim(json_str)) do
        {:ok, list} when is_list(list) -> {:ok, list}
        _ -> :error
      end
    else
      :error
    end
  end

  defp normalize_finding(map) when is_map(map) do
    file = Map.get(map, "file") || Map.get(map, :file)
    line = Map.get(map, "line") || Map.get(map, :line)
    title = Map.get(map, "title") || Map.get(map, :title) || "Unspecified Issue"
    desc = Map.get(map, "description") || Map.get(map, :description) || ""
    severity = Map.get(map, "severity") || Map.get(map, :severity) || "medium"
    fix = Map.get(map, "fix_suggestion") || Map.get(map, :fix_suggestion) || ""
    id = Map.get(map, "id") || Map.get(map, :id) || 1

    line_int =
      cond do
        is_integer(line) -> line
        is_binary(line) -> parse_int(line)
        true -> nil
      end

    %{
      id: id,
      file: if(is_binary(file) and file != "", do: file, else: nil),
      line: line_int,
      title: to_string(title),
      description: to_string(desc),
      severity: to_string(severity),
      fix_suggestion: to_string(fix)
    }
  end

  defp normalize_finding(_), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp fallback_parse_findings(text) do
    lines = String.split(text, "\n")

    # Look for bullet points or numbered lists containing keywords like Risk, Issue, Fix, Recommendation, Error, Warning
    lines
    |> Enum.filter(fn l ->
      String.match?(l, ~r/^\s*[\-\*\d\.]+\s+/) and
        String.match?(
          l,
          ~r/(risk|bug|flaw|issue|recommend|refactor|fix|missing|test|error|uncaught|warning|perf|edge)/i
        )
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      clean = String.replace(line, ~r/^\s*[\-\*\d\.]+\s*/, "")

      # Try parsing file:line if present in brackets or backticks like `lib/foo.ex:42`
      {file, line_num, clean_title} = extract_file_location(clean)

      %{
        id: idx,
        file: file,
        line: line_num,
        title: clean_title,
        description: clean,
        severity: "medium",
        fix_suggestion: ""
      }
    end)
  end

  defp extract_file_location(text) do
    sanitized = String.replace(text, ~r/^[\s\*\`\[]+/, "")

    match =
      Regex.run(
        ~r/([a-zA-Z0-9_\-\.\/]+\.[a-zA-Z0-9]+)(?::(\d+))?[`\]\*]*\s*[\:\-\]\*]*\s*(.*)/,
        sanitized
      )

    case match do
      [_, f, "", rest] -> {f, nil, String.slice(rest, 0, 80)}
      [_, f, l_str, rest] -> {f, parse_int(l_str), String.slice(rest, 0, 80)}
      _ -> {nil, nil, String.slice(text, 0, 80)}
    end
  end

  @doc """
  Runs an interactive session allowing the user to review findings one by one (accept/decline).
  """
  def interactive_review(findings, _opts \\ []) when is_list(findings) do
    if findings == [] do
      {:ok, [], []}
    else
      total = length(findings)

      IO.puts(
        "\n" <>
          Formatter.format_info(
            "Found #{total} actionable code review finding(s). Reviewing interactively…"
          ) <> "\n"
      )

      review_loop(findings, 1, total, [], [])
    end
  end

  defp review_loop([], _idx, _total, accepted, declined) do
    {:ok, Enum.reverse(accepted), Enum.reverse(declined)}
  end

  defp review_loop([f | rest], idx, total, accepted, declined) do
    print_finding_card(f, idx, total)

    question = "Review Finding #{idx}/#{total}: \"#{f.title}\""

    options = [
      "Accept finding (Recommended)",
      "Decline finding",
      "Accept ALL remaining findings",
      "Decline ALL remaining findings"
    ]

    res =
      QuestionPrompt.ask_single_question(question, options, false, true, progress: {idx, total})

    selected =
      case res do
        %{selected: [choice | _]} -> choice
        %{custom: custom} when is_binary(custom) -> custom
        _ -> "Accept"
      end

    cond do
      String.contains?(selected, "Accept ALL") or String.contains?(selected, "Accept All") ->
        all_remaining_accepted = [f | rest]
        {:ok, Enum.reverse(accepted) ++ all_remaining_accepted, Enum.reverse(declined)}

      String.contains?(selected, "Decline ALL") or String.contains?(selected, "Decline All") ->
        all_remaining_declined = [f | rest]
        {:ok, Enum.reverse(accepted), Enum.reverse(declined) ++ all_remaining_declined}

      String.starts_with?(selected, "Accept") or String.contains?(selected, "Accept") ->
        review_loop(rest, idx + 1, total, [f | accepted], declined)

      true ->
        review_loop(rest, idx + 1, total, accepted, [f | declined])
    end
  end

  defp print_finding_card(f, idx, total) do
    severity_colored =
      case String.downcase(to_string(f.severity)) do
        "high" -> Formatter.red() <> "HIGH" <> Formatter.reset()
        "medium" -> Formatter.yellow() <> "MEDIUM" <> Formatter.reset()
        "low" -> Formatter.cyan() <> "LOW" <> Formatter.reset()
        _ -> Formatter.gray() <> String.upcase(to_string(f.severity)) <> Formatter.reset()
      end

    location =
      cond do
        f.file && f.line -> "#{f.file}:#{f.line}"
        f.file -> f.file
        true -> "General / Architectural"
      end

    fix_block =
      if is_binary(f.fix_suggestion) and String.trim(f.fix_suggestion) != "" do
        "\n│ " <>
          Formatter.bold() <> "Fix Suggestion:" <> Formatter.reset() <> " " <> f.fix_suggestion
      else
        ""
      end

    card = """
    #{Formatter.cyan()}╭─ 󰋗 Finding #{idx}/#{total} ───────────────────────────────────────────╮#{Formatter.reset()}
    │ #{Formatter.bold()}Title:#{Formatter.reset()} #{f.title}
    │ #{Formatter.bold()}Location:#{Formatter.reset()} #{location}  [Severity: #{severity_colored}]
    │ #{Formatter.bold()}Description:#{Formatter.reset()} #{f.description}#{fix_block}
    #{Formatter.cyan()}╰─────────────────────────────────────────────────────────────╯#{Formatter.reset()}
    """

    IO.puts(card)
  end

  @doc """
  Builds the fix prompt to be sent back to the LLM agent model.
  Includes standard preamble requested by user:
  "There are some issues found by Yoke, please examine and apply when you see fit"
  """
  def build_fix_prompt(accepted_findings) when is_list(accepted_findings) do
    if accepted_findings == [] do
      ""
    else
      findings_text =
        accepted_findings
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {f, idx} ->
          loc =
            cond do
              f.file && f.line -> "File: #{f.file}:#{f.line}"
              f.file -> "File: #{f.file}"
              true -> "Scope: General"
            end

          fix =
            if is_binary(f.fix_suggestion) and f.fix_suggestion != "",
              do: "\n   Suggested Fix: " <> f.fix_suggestion,
              else: ""

          """
          #{idx}. [#{f.title}]
             #{loc}
             Severity: #{f.severity}
             Description: #{f.description}#{fix}
          """
        end)

      """
      There are some issues found by Yoke, please examine and apply when you see fit:

      #{findings_text}
      """
    end
  end

  @doc """
  Builds the Markdown body for the GitHub PR comment/review.
  """
  def build_pr_comment_body(accepted_findings, fix_prompt) do
    summary_section =
      if accepted_findings == [] do
        "No issues/findings accepted."
      else
        accepted_findings
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {f, idx} ->
          loc = if f.file, do: "`#{f.file}`#{if f.line, do: ":#{f.line}"}", else: "General"

          "- **#{idx}. [#{f.severity |> String.upcase()}]** #{loc} - **#{f.title}**: #{f.description}"
        end)
      end

    """
    ## 🤖 Yoke Code Review

    ### 📋 Findings Summary & Accepted Issues

    #{summary_section}

    ---

    ### 🛠️ Recommended Fix Prompt
    ```
    #{fix_prompt}
    ```
    """
  end

  @doc """
  Posts accepted findings and review summary to GitHub PR using `gh` CLI.
  """
  def post_to_github_pr(target_or_head, pr_body, cwd \\ ".") do
    case System.find_executable("gh") do
      nil ->
        {:error, "GitHub CLI ('gh') is not installed or not found in PATH."}

      _gh_path ->
        case detect_pr(target_or_head, cwd) do
          {:ok, pr_info} ->
            pr_num = to_string(pr_info.number)

            case System.cmd("gh", ["pr", "comment", pr_num, "--body", pr_body],
                   cd: cwd,
                   stderr_to_stdout: true
                 ) do
              {_out, 0} ->
                {:ok, %{number: pr_num, url: pr_info.url}}

              {out, _code} ->
                case System.cmd("gh", ["pr", "review", pr_num, "--comment", "--body", pr_body],
                       cd: cwd,
                       stderr_to_stdout: true
                     ) do
                  {_out2, 0} ->
                    {:ok, %{number: pr_num, url: pr_info.url}}

                  {out2, _code2} ->
                    {:error, "Failed to post PR comment via gh: #{out} / #{out2}"}
                end
            end

          {:error, err} ->
            {:error, err}
        end
    end
  end

  @doc """
  Detects PR info (number, url, head, base) using `gh` CLI.
  `target` can be a numeric string ("123"), branch name ("feature-x"), or nil (current branch).
  """
  def detect_pr(target \\ nil, cwd \\ ".") do
    target_str = if is_binary(target), do: String.trim(target), else: ""

    args =
      cond do
        Regex.match?(~r/^\d+$/, target_str) ->
          ["pr", "view", target_str, "--json", "number,url,headRefName,baseRefName"]

        target_str != "" and target_str != "HEAD" ->
          ["pr", "view", target_str, "--json", "number,url,headRefName,baseRefName"]

        true ->
          ["pr", "view", "--json", "number,url,headRefName,baseRefName"]
      end

    case System.cmd("gh", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        case Yoke.Json.decode(out) do
          {:ok, %{"number" => num, "url" => url} = map} ->
            {:ok,
             %{
               number: num,
               url: url,
               head: Map.get(map, "headRefName"),
               base: Map.get(map, "baseRefName")
             }}

          _ ->
            {:error, "Could not parse gh pr view JSON output."}
        end

      {out, _code} ->
        {:error, "gh pr view failed: #{String.trim(out)}"}
    end
  end
end

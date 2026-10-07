defmodule Yoke.PRReview do
  @moduledoc """
  Semi-automated Pull Request code review module.
  Handles structured finding extraction, interactive accept/edit/decline workflows,
  posting atomic reviews with inline comments to GitHub PRs via the `gh` CLI,
  managing living review patterns memory, and constructing fix prompts.
  """

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.QuestionPrompt
  alias Yoke.Json
  alias Yoke.PRReview.Patterns

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
  Appends structured findings format instructions and self-critique rules to the Code Review prompt.
  Optionally includes historical patterns from `.yoke/review_patterns.md`.
  """
  def prompt_instructions(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    patterns_section = Patterns.format_patterns_for_prompt(cwd)

    """

    ### 7. Structured Findings Payload
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
        "fix_suggestion": "Proposed code fix or recommendation (can be committable code)."
      }
    ]
    ```
    (severity can be "high", "medium", "low", or "info"). If no actionable issues are found, output an empty array `[]`.

    ### 8. Self-Critique Checklist (Drop the suggestion if any apply):
    1. Another PR in the branch stack already addresses it.
    2. A feature flag or supervisor already gates the risk.
    3. It is speculative about an unconfirmed future or consumers that do not exist.
    4. It is naming/formatting bikeshedding on clear code.
    5. It is latent: it only bites if a currently-guaranteed condition changes with no concrete reason to expect that change.
    6. It flags duplication in tests or UI code; reserve DRY comments strictly for business logic.
    7. Another reviewer or existing PR comment already raised it.
    8. A blocking CI check (compiler, credo, dialyzer, formatter) already flags it.
    9. It claims the code contradicts a ticket without quoting the verbatim ticket text.
    10. It flags code as unused when a subsequent part of the system consumes it.

    ### 9. Tone & Comment Phrasing Rules:
    - **Technical issues only**: Never raise process, organizational, or interpersonal concerns.
    - **Enforce proper typography**:
      - Use real em dashes (—) for parenthetical clauses or abrupt breaks—never double hyphens (--) or loose hyphens.
      - Use proper curly typographic quotes (“ ” and ‘ ’) in prose explanations and commentary instead of plain straight quotes (" '). Straight quotes and backticks must still be used inside code snippets and JSON.
    - **No rhetorical fillers**: Strip AI filler phrases (“it’s worth noting”, “this is a classic”, “let’s dive into”).
    - **Ask rather than assert** when a difference could be deliberate (e.g., “The ticket specifies X, but the code does Y. Is this intentional?”).
    - **Actionable & Committable**: Provide concrete replacement code in `fix_suggestion` whenever possible.
    #{patterns_section}
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
      case Json.decode(String.trim(json_str)) do
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
  Runs an interactive session allowing the user to review findings one by one.
  Supports Accept [i], Edit [e], Decline [d], Accept ALL, and Decline ALL.
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
      "Edit finding",
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

      String.contains?(selected, "Edit") ->
        edited_f = edit_finding_interactively(f)
        review_loop(rest, idx + 1, total, [edited_f | accepted], declined)

      String.starts_with?(selected, "Accept") or String.contains?(selected, "Accept") ->
        review_loop(rest, idx + 1, total, [f | accepted], declined)

      true ->
        review_loop(rest, idx + 1, total, accepted, [f | declined])
    end
  end

  defp edit_finding_interactively(f) do
    IO.puts("\n" <> Formatter.cyan() <> "✎ Editing finding ##{f.id}:" <> Formatter.reset())

    IO.puts(Formatter.dim() <> "Current title: " <> f.title <> Formatter.reset())
    new_title = prompt_line("New title (press Enter to keep): ", f.title)

    IO.puts(Formatter.dim() <> "Current description: " <> f.description <> Formatter.reset())
    new_desc = prompt_line("New description (press Enter to keep): ", f.description)

    IO.puts(Formatter.dim() <> "Current fix suggestion: " <> f.fix_suggestion <> Formatter.reset())
    new_fix = prompt_line("New fix suggestion (press Enter to keep): ", f.fix_suggestion)

    %{
      f
      | title: new_title,
        description: new_desc,
        fix_suggestion: new_fix
    }
  end

  defp prompt_line(prompt_text, default_val) do
    case IO.gets(prompt_text) do
      :eof -> default_val
      {:error, _} -> default_val
      input ->
        trimmed = String.trim(input)
        if trimmed == "", do: default_val, else: trimmed
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
  def build_pr_comment_body(accepted_findings, fix_prompt \\ "") do
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

    fix_block =
      if fix_prompt != "" do
        """

        ---

        ### 🛠️ Recommended Fix Prompt
        ```
        #{fix_prompt}
        ```
        """
      else
        ""
      end

    """
    ## 🤖 Yoke Code Review

    ### 📋 Findings Summary & Accepted Issues

    #{summary_section}#{fix_block}
    """
  end

  @doc """
  Parses git unified diff text and extracts the MapSet of `{file_path, line_number}`
  locations present on the RIGHT (added/context) side of hunks.
  """
  def parse_diff_right_lines(diff_text) when is_binary(diff_text) do
    lines = String.split(diff_text, "\n")

    {set, _cur_file, _cur_line} =
      Enum.reduce(lines, {MapSet.new(), nil, nil}, fn line, {set_acc, cur_file, cur_line} ->
        cond do
          String.starts_with?(line, "+++ b/") ->
            file = String.replace_prefix(line, "+++ b/", "") |> String.trim()
            {set_acc, file, nil}

          String.starts_with?(line, "+++ ") ->
            # e.g. +++ /dev/null
            {set_acc, nil, nil}

          String.starts_with?(line, "@@ ") ->
            case Regex.run(~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
              [_, start_line_str] ->
                start_line = String.to_integer(start_line_str)
                {set_acc, cur_file, start_line}

              _ ->
                {set_acc, cur_file, nil}
            end

          is_binary(cur_file) and is_integer(cur_line) ->
            cond do
              String.starts_with?(line, "+") ->
                new_set = MapSet.put(set_acc, {cur_file, cur_line})
                {new_set, cur_file, cur_line + 1}

              String.starts_with?(line, " ") ->
                new_set = MapSet.put(set_acc, {cur_file, cur_line})
                {new_set, cur_file, cur_line + 1}

              String.starts_with?(line, "-") ->
                # Deletions do not advance right-side line number
                {set_acc, cur_file, cur_line}

              true ->
                {set_acc, cur_file, cur_line}
            end

          true ->
            {set_acc, cur_file, cur_line}
        end
      end)

    set
  end

  @doc """
  Builds an atomic GitHub review payload.
  Sorts findings into valid inline comments (lines on the right side of diff)
  and top-level body sidenotes (lines outside diff or general architectural findings).
  `event` can be "APPROVE", "COMMENT", or "REQUEST_CHANGES".
  """
  def build_atomic_review_payload(accepted_findings, review_body, event \\ "COMMENT", valid_diff_lines \\ nil) do
    event_str = normalize_review_event(event)

    {inline_comments, body_sidenotes} =
      Enum.split_with(accepted_findings, fn f ->
        if f.file && f.line do
          if is_nil(valid_diff_lines) do
            true
          else
            MapSet.member?(valid_diff_lines, {f.file, f.line})
          end
        else
          false
        end
      end)

    comments_payload =
      Enum.map(inline_comments, fn f ->
        %{
          "path" => f.file,
          "line" => f.line,
          "side" => "RIGHT",
          "body" => format_inline_comment_body(f)
        }
      end)

    full_body =
      if body_sidenotes == [] do
        review_body
      else
        sidenotes_text =
          Enum.map_join(body_sidenotes, "\n", fn f ->
            loc = if f.file, do: "`#{f.file}`#{if f.line, do: ":#{f.line}"}", else: "General"
            "- **[#{f.severity |> String.upcase()}]** #{loc} - **#{f.title}**: #{f.description}"
          end)

        review_body <> "\n\n### 📝 General Observations & Out-of-Diff Notes\n" <> sidenotes_text
      end

    %{
      "event" => event_str,
      "body" => full_body,
      "comments" => comments_payload
    }
  end

  defp normalize_review_event(event) do
    case String.upcase(to_string(event)) do
      "APPROVE" -> "APPROVE"
      "REQUEST_CHANGES" -> "REQUEST_CHANGES"
      "CHANGES_REQUESTED" -> "REQUEST_CHANGES"
      _ -> "COMMENT"
    end
  end

  defp format_inline_comment_body(f) do
    suggestion_block =
      if is_binary(f.fix_suggestion) and String.trim(f.fix_suggestion) != "" do
        fix = String.trim(f.fix_suggestion)

        if String.contains?(fix, "```") do
          "\n\n" <> fix
        else
          "\n\n```suggestion\n#{fix}\n```"
        end
      else
        ""
      end

    "**[#{String.upcase(to_string(f.severity))}] #{f.title}**\n\n#{f.description}#{suggestion_block}"
  end

  @doc """
  Posts an atomic review (body + inline comments) to a GitHub PR using `gh api`.
  Falls back to standard PR comment if the API call fails or inline comments are rejected.
  """
  def post_atomic_review(target_or_head, payload, cwd \\ ".") do
    case System.find_executable("gh") do
      nil ->
        {:error, "GitHub CLI ('gh') is not installed or not found in PATH."}

      _gh_path ->
        with {:ok, pr_info} <- detect_pr(target_or_head, cwd),
             {:ok, repo_name} <- get_repo_name(cwd) do
          pr_num = to_string(pr_info.number)
          temp_file = Path.join(System.tmp_dir!(), "yoke_review_#{pr_num}_#{System.unique_integer([:positive])}.json")

          File.write!(temp_file, Json.encode!(payload))

          api_path = "repos/#{repo_name}/pulls/#{pr_num}/reviews"
          args = ["api", "-X", "POST", api_path, "--input", temp_file]

          case System.cmd("gh", args, cd: cwd, stderr_to_stdout: true) do
            {_out, 0} ->
              File.rm(temp_file)
              {:ok, %{number: pr_num, url: pr_info.url, event: payload["event"]}}

            {err, _code} ->
              File.rm(temp_file)
              # If atomic reviews fail (e.g. invalid line number rejection), fall back to top-level PR comment
              case post_to_github_pr(target_or_head, payload["body"], cwd) do
                {:ok, res} ->
                  {:ok, Map.put(res, :fallback_comment, true)}

                {:error, fallback_err} ->
                  {:error, "Atomic review failed: #{String.trim(err)}; fallback comment failed: #{fallback_err}"}
              end
          end
        end
    end
  end

  defp get_repo_name(cwd) do
    case System.cmd("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, _} -> {:error, "Could not determine GitHub repository: #{String.trim(err)}"}
    end
  end

  @doc """
  Fetches the raw diff for a PR using `gh pr diff <n>`.
  """
  def fetch_pr_diff(pr_num, cwd \\ ".") do
    case System.cmd("gh", ["pr", "diff", to_string(pr_num)], cd: cwd, stderr_to_stdout: true) do
      {diff, 0} -> {:ok, diff}
      {err, _} -> {:error, "Failed to fetch PR diff: #{String.trim(err)}"}
    end
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
        case Json.decode(out) do
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

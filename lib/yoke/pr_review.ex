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
  alias Yoke.PRReview.Markdown
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
        "title": "Short title with `inline_code` in backticks",
        "description": "Clear explanation of the problem with `short_code_pieces` in backticks and multiline code snippets in code fences.",
        "severity": "high",
        "fix_suggestion": "Proposed code fix or recommendation (can be committable code or fenced block)."
      }
    ]
    ```
    (severity can be "high", "medium", "low", or "info"). For codepieces that are outstandingly good, clean, nifty, or clever, you may also include a comment with a heart (❤) or thumbs-up emoji (:+1:) (with severity "info" and an empty fix_suggestion). If no actionable issues are found, output an empty array `[]`.

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
    - **Praise outstanding code**: For codepieces that are outstandingly good, clean, nifty, or clever, please also add a comment with a heart (❤) or thumbs-up emoji (:+1:) highlighting and appreciating the clean, clever craftsmanship.
    - **Markdown formatting for GitHub PR comments**:
      - Findings payload fields (`title`, `description`, `fix_suggestion`) are posted directly as GitHub Pull Request inline review comments and summary items. They MUST be formatted in rich GitHub-flavored Markdown, NEVER plain text.
      - **Backticks for code pieces**: Enclose all short code pieces—function/macro calls and arities (e.g. `mark_read/2`), expressions (e.g. `send(self(), ...)`), module/type names (e.g. `LiveView`), atoms/keys (e.g. `:comment_event`), variables/assigns (e.g. `socket.assigns.view`), and file paths (e.g. `config/dev.exs`)—in single backticks (`...`).
      - **Code fences for multiline snippets**: Enclose all multiline code blocks in fenced code blocks with language identifiers (e.g. ```elixir ... ```) or ```suggestion ... ``` for direct replacement code. Never emit raw unfenced multiline code.
    - **Enforce proper typography**:
      - Use real em dashes (—) for parenthetical clauses or abrupt breaks—never double hyphens (--) or loose hyphens.
      - Use proper curly typographic quotes (“ ” and ‘ ’) in prose explanations and commentary instead of plain straight quotes (" '). Straight quotes and backticks must still be used inside code snippets and JSON.
    - **No rhetorical fillers**: Strip AI filler phrases (“it’s worth noting”, “this is a classic”, “let’s dive into”).
    - **Subtitles must match their content**: Every section heading and sub-label (e.g. “File: Scanner.scan”, “Risk: …”, “Recommendation: …”) MUST accurately describe the content that follows it. Never emit a subtitle that names a file, symbol, or topic the section does not actually discuss. Triple-check each subtitle against its body before finalizing; if they do not correspond, fix the subtitle (or move the content) so they do.
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
      [_, f, "", rest] -> {f, nil, String.trim(rest)}
      [_, f, l_str, rest] -> {f, parse_int(l_str), String.trim(rest)}
      _ -> {nil, nil, String.trim(text)}
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

    IO.puts(
      Formatter.dim() <> "Current fix suggestion: " <> f.fix_suggestion <> Formatter.reset()
    )

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
      :eof ->
        default_val

      {:error, _} ->
        default_val

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
          loc = fix_prompt_location(f)

          fix =
            if is_binary(f.fix_suggestion) and f.fix_suggestion != "",
              do: "\n   Suggested Fix: " <> f.fix_suggestion,
              else: ""

          # The title is emitted verbatim on the first line (in square brackets)
          # and MUST NOT be truncated, regardless of its length.
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

  # Renders the location line for a finding in the fix prompt.
  #
  # Every finding MUST carry both a file name and a line number so the model
  # can apply the fix precisely. When a line number is unavailable we still
  # emit the file name plus an explicit placeholder, and when the file itself
  # is unknown we emit a clearly-scoped general marker.
  defp fix_prompt_location(f) do
    file = if is_binary(f.file) and f.file != "", do: f.file, else: nil

    cond do
      file && f.line -> "File: #{file}:#{f.line}"
      file -> "File: #{file} (line number unavailable — locate the relevant site in this file)"
      true -> "Scope: General (no specific file or line number was identified)"
    end
  end

  @doc """
  Builds the Markdown body for the GitHub PR comment/review.
  """
  def build_pr_comment_body(accepted_findings, fix_prompt \\ "", opts \\ []) do
    summary_section =
      if accepted_findings == [] do
        "No issues/findings accepted."
      else
        accepted_findings
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {f, idx} ->
          loc = if f.file, do: "`#{f.file}`#{if f.line, do: ":#{f.line}"}", else: "General"
          title = Markdown.format_inline_code(f.title)
          desc = Markdown.format_inline_code(f.description)

          "- **#{idx}. [#{f.severity |> String.upcase()}]** #{loc} - **#{title}**: #{desc}"
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

    assistant_name =
      Keyword.get(opts, :assistant_name) ||
        Yoke.Config.assistant_name(Keyword.get(opts, :cwd, "."))

    """
    ## 🪢 Review from #{assistant_name}

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
  def build_atomic_review_payload(
        accepted_findings,
        review_body,
        event \\ "COMMENT",
        valid_diff_lines \\ nil
      ) do
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

    # The review body already contains a "Findings Summary & Accepted Issues"
    # section that lists every accepted finding. Only surface an off-diff
    # sidenote in the "General Observations & Out-of-Diff Notes" section when
    # it is NOT already mentioned in that summary, otherwise the section would
    # be an exact duplicate of the summary. If nothing new remains, omit the
    # section entirely.
    novel_sidenotes =
      Enum.reject(body_sidenotes, fn f ->
        title = to_string(f.title)
        formatted_title = Markdown.format_inline_code(title)

        title != "" and
          (String.contains?(review_body, title) or String.contains?(review_body, formatted_title))
      end)

    full_body =
      if novel_sidenotes == [] do
        review_body
      else
        sidenotes_text =
          Enum.map_join(novel_sidenotes, "\n", fn f ->
            loc = if f.file, do: "`#{f.file}`#{if f.line, do: ":#{f.line}"}", else: "General"
            title = Markdown.format_inline_code(f.title)
            desc = Markdown.format_inline_code(f.description)
            "- **[#{f.severity |> String.upcase()}]** #{loc} - **#{title}**: #{desc}"
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
    Markdown.format_inline_comment_body(f)
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

          temp_file =
            Path.join(
              System.tmp_dir!(),
              "yoke_review_#{pr_num}_#{System.unique_integer([:positive])}.json"
            )

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
                  {:error,
                   "Atomic review failed: #{String.trim(err)}; fallback comment failed: #{fallback_err}"}
              end
          end
        end
    end
  end

  @doc """
  Determines the GitHub repository (`owner/repo`) using `gh repo view`.
  """
  def get_repo_name(cwd \\ ".") do
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
  Detects PR info (number, url, head, base, author) using `gh` CLI.
  `target` can be a numeric string ("123"), integer (123), branch name ("feature-x"), or nil (current branch).
  """
  def detect_pr(target \\ nil, cwd \\ ".") do
    target_str =
      cond do
        is_integer(target) -> to_string(target)
        is_binary(target) -> String.trim(target)
        true -> ""
      end

    args =
      cond do
        Regex.match?(~r/^\d+$/, target_str) ->
          ["pr", "view", target_str, "--json", "number,url,headRefName,baseRefName,author"]

        target_str != "" and target_str != "HEAD" ->
          ["pr", "view", target_str, "--json", "number,url,headRefName,baseRefName,author"]

        true ->
          ["pr", "view", "--json", "number,url,headRefName,baseRefName,author"]
      end

    case System.cmd("gh", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, %{"number" => num, "url" => url} = map} ->
            author_login =
              case Map.get(map, "author") do
                %{"login" => l} when is_binary(l) -> l
                l when is_binary(l) -> l
                _ -> nil
              end

            {:ok,
             %{
               number: num,
               url: url,
               head: Map.get(map, "headRefName"),
               base: Map.get(map, "baseRefName"),
               author: author_login
             }}

          _ ->
            {:error, "Could not parse gh pr view JSON output."}
        end

      {out, _code} ->
        {:error, "gh pr view failed: #{String.trim(out)}"}
    end
  end

  @doc """
  Fetches all peer review comments (inline review comments, review summaries, and conversation comments)
  on the GitHub Pull Request page, excluding comments made by the PR author.
  Returns `{:ok, comments_list}` on success or `{:error, reason}` on failure.
  """
  def fetch_peer_comments(target_or_pr_num, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    explicit_author = Keyword.get(opts, :pr_author)

    with {:ok, pr_info} <- resolve_pr_info(target_or_pr_num, cwd),
         {:ok, repo_name} <- get_repo_name(cwd) do
      pr_num = to_string(pr_info.number)
      pr_author = explicit_author || pr_info.author

      inline_comments = fetch_inline_review_comments(repo_name, pr_num, cwd)
      pr_view_comments = fetch_pr_view_comments(pr_num, cwd)

      all_comments = inline_comments ++ pr_view_comments

      peer_comments =
        all_comments
        |> Enum.reject(fn c ->
          pr_author?(c, pr_author) or String.trim(c.body) == ""
        end)
        |> deduplicate_comments()

      {:ok, peer_comments}
    else
      {:error, err} -> {:error, err}
    end
  end

  defp resolve_pr_info(pr_num, cwd) when is_integer(pr_num) do
    detect_pr(to_string(pr_num), cwd)
  end

  defp resolve_pr_info(target, cwd) do
    detect_pr(target, cwd)
  end

  defp fetch_inline_review_comments(repo_name, pr_num, cwd) do
    case System.cmd("gh", ["api", "repos/#{repo_name}/pulls/#{pr_num}/comments?per_page=100"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, list} when is_list(list) ->
            Enum.map(list, fn item ->
              line =
                Map.get(item, "line") ||
                  Map.get(item, "original_line") ||
                  Map.get(item, "start_line") ||
                  Map.get(item, "original_start_line")

              line_int =
                cond do
                  is_integer(line) -> line
                  is_binary(line) -> parse_int(line)
                  true -> nil
                end

              %{
                type: :inline,
                file: Map.get(item, "path"),
                line: line_int,
                author: get_in(item, ["user", "login"]) || "unknown",
                body: Map.get(item, "body") || "",
                diff_hunk: Map.get(item, "diff_hunk")
              }
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp fetch_pr_view_comments(pr_num, cwd) do
    case System.cmd("gh", ["pr", "view", pr_num, "--json", "comments,reviews"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, map} when is_map(map) ->
            raw_reviews = Map.get(map, "reviews") || []
            raw_comments = Map.get(map, "comments") || []

            reviews =
              Enum.map(raw_reviews, fn r ->
                %{
                  type: :review,
                  file: nil,
                  line: nil,
                  author: get_in(r, ["author", "login"]) || "unknown",
                  body: Map.get(r, "body") || "",
                  diff_hunk: nil
                }
              end)

            comments =
              Enum.map(raw_comments, fn c ->
                %{
                  type: :issue,
                  file: nil,
                  line: nil,
                  author: get_in(c, ["author", "login"]) || "unknown",
                  body: Map.get(c, "body") || "",
                  diff_hunk: nil
                }
              end)

            reviews ++ comments

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp pr_author?(_comment, nil), do: false

  defp pr_author?(comment, pr_author) when is_binary(pr_author) do
    author = to_string(comment.author || "")
    String.downcase(author) == String.downcase(pr_author)
  end

  defp deduplicate_comments(comments) do
    Enum.uniq_by(comments, fn c ->
      {c.author, c.file, c.line, String.trim(c.body)}
    end)
  end

  @doc """
  Formats peer comments for inclusion in the code review LLM prompt so the model
  is aware of issues already raised on the PR page.
  """
  def format_peer_comments_for_prompt(peer_comments) when is_list(peer_comments) do
    meaningful_comments =
      peer_comments
      |> Enum.reject(&(String.trim(&1.body) == ""))

    if meaningful_comments == [] do
      ""
    else
      formatted =
        meaningful_comments
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {c, idx} ->
          loc =
            cond do
              c.file && c.line -> "`#{c.file}:#{c.line}`"
              c.file -> "`#{c.file}`"
              true -> "General / PR Summary"
            end

          author_label = if c.author && c.author != "unknown", do: " by @#{c.author}", else: ""
          type_label = Atom.to_string(c.type) |> String.capitalize()

          """
          #{idx}. [#{type_label} on #{loc}#{author_label}]
             #{indent_text(c.body, 3)}
          """
        end)

      """

      ### 6.1 Existing Peer Review Comments on PR Page (Already Reported — Do NOT Re-report)
      The following findings and observations have ALREADY been reported by other peer reviewers on the PR page.
      CRITICAL REQUIREMENT: Do NOT duplicate, repeat, or re-report any issue already presented below. You must SILENTLY DROP them from your review and your structured findings JSON array. Focus strictly on fresh, unreported problems:

      #{formatted}
      """
    end
  end

  def format_peer_comments_for_prompt(_), do: ""

  defp indent_text(text, spaces) do
    padding = String.duplicate(" ", spaces)
    text |> String.split("\n") |> Enum.map_join("\n", &"#{padding}#{&1}")
  end

  @doc """
  Filters findings, silently dropping those already reported by peer reviewers on the PR page.
  """
  def drop_already_reported(findings, peer_comments)
      when is_list(findings) and is_list(peer_comments) do
    if peer_comments == [] do
      findings
    else
      Enum.reject(findings, fn finding ->
        finding_already_reported?(finding, peer_comments)
      end)
    end
  end

  def drop_already_reported(findings, _), do: findings

  @doc """
  Checks if a discrete finding has already been reported by any of the peer comments on the PR page.
  """
  def finding_already_reported?(finding, peer_comments)
      when is_map(finding) and is_list(peer_comments) do
    Enum.any?(peer_comments, fn comment ->
      comment_reports_finding?(comment, finding)
    end)
  end

  def finding_already_reported?(_, _), do: false

  @common_stop_words MapSet.new([
                       "a",
                       "about",
                       "above",
                       "after",
                       "again",
                       "against",
                       "all",
                       "also",
                       "an",
                       "and",
                       "any",
                       "are",
                       "aren't",
                       "as",
                       "at",
                       "be",
                       "because",
                       "been",
                       "before",
                       "being",
                       "below",
                       "between",
                       "both",
                       "but",
                       "by",
                       "can",
                       "cannot",
                       "could",
                       "couldn't",
                       "did",
                       "didn't",
                       "do",
                       "does",
                       "doesn't",
                       "doing",
                       "don't",
                       "down",
                       "during",
                       "each",
                       "else",
                       "few",
                       "for",
                       "from",
                       "further",
                       "had",
                       "hadn't",
                       "has",
                       "hasn't",
                       "have",
                       "haven't",
                       "having",
                       "he",
                       "her",
                       "here",
                       "hers",
                       "herself",
                       "him",
                       "himself",
                       "his",
                       "how",
                       "if",
                       "in",
                       "into",
                       "is",
                       "isn't",
                       "it",
                       "it's",
                       "its",
                       "itself",
                       "just",
                       "me",
                       "more",
                       "most",
                       "must",
                       "my",
                       "myself",
                       "no",
                       "nor",
                       "not",
                       "of",
                       "off",
                       "on",
                       "once",
                       "only",
                       "or",
                       "other",
                       "ought",
                       "our",
                       "ours",
                       "ourselves",
                       "out",
                       "over",
                       "own",
                       "please",
                       "same",
                       "should",
                       "shouldn't",
                       "so",
                       "some",
                       "such",
                       "than",
                       "that",
                       "the",
                       "their",
                       "theirs",
                       "them",
                       "themselves",
                       "then",
                       "there",
                       "these",
                       "they",
                       "this",
                       "those",
                       "through",
                       "to",
                       "too",
                       "under",
                       "until",
                       "up",
                       "very",
                       "was",
                       "wasn't",
                       "we",
                       "were",
                       "weren't",
                       "what",
                       "when",
                       "where",
                       "which",
                       "while",
                       "who",
                       "whom",
                       "why",
                       "with",
                       "won't",
                       "would",
                       "wouldn't",
                       "you",
                       "your",
                       "yours",
                       "yourself",
                       "yourselves"
                     ])

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.replace_prefix("./", "")
    |> String.downcase()
  end

  defp same_file?(path_a, path_b) do
    a = normalize_path(path_a)
    b = normalize_path(path_b)
    is_binary(a) and is_binary(b) and a != "" and a == b
  end

  defp extract_code_identifiers(text) when is_binary(text) do
    backticked =
      Regex.scan(~r/`([^`]+)`/, text)
      |> Enum.map(fn [_, m] -> String.trim(m) |> String.downcase() end)
      |> Enum.reject(&(&1 == "" or String.length(&1) < 3))

    snake_case =
      Regex.scan(~r/\b[a-z0-9]+_[a-z0-9_]+\b/i, text)
      |> Enum.map(fn [m] -> String.trim(m) |> String.downcase() end)
      |> Enum.reject(&(String.length(&1) < 4))

    camel_case =
      Regex.scan(~r/\b[A-Z][a-zA-Z0-9]{2,}\b/, text)
      |> Enum.map(fn [m] -> String.trim(m) |> String.downcase() end)

    dotted =
      Regex.scan(~r/\b[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+\b/, text)
      |> Enum.map(fn [m] -> String.trim(m) |> String.downcase() end)

    (backticked ++ snake_case ++ camel_case ++ dotted)
    |> MapSet.new()
  end

  defp extract_code_identifiers(_), do: MapSet.new()

  defp extract_significant_words(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn w ->
      String.length(w) < 4 or
        MapSet.member?(@common_stop_words, w) or
        Regex.match?(~r/^\d+$/, w)
    end)
    |> MapSet.new()
  end

  defp extract_significant_words(_), do: MapSet.new()

  defp extract_suggestion_code(body) when is_binary(body) do
    case Regex.run(~r/```suggestion\s*\n(.*?)```/s, body) do
      [_, code] -> String.trim(code)
      _ -> nil
    end
  end

  defp comment_reports_finding?(comment, finding) do
    c_body = comment.body || ""
    c_body_trimmed = String.trim(c_body)

    if c_body_trimmed == "" or praise_only?(c_body_trimmed) do
      false
    else
      f_text = "#{finding.title} #{finding.description} #{finding.fix_suggestion}"
      f_id_tokens = extract_code_identifiers(f_text)
      c_id_tokens = extract_code_identifiers(c_body)
      shared_id_tokens = MapSet.intersection(f_id_tokens, c_id_tokens)

      f_words = extract_significant_words("#{finding.title} #{finding.description}")
      c_words = extract_significant_words(c_body)
      shared_words = MapSet.intersection(f_words, c_words)

      c_suggestion = extract_suggestion_code(c_body)

      cond do
        # 1. Exact or near line in the same file
        same_file?(comment.file, finding.file) and is_integer(comment.line) and
          is_integer(finding.line) and abs(comment.line - finding.line) <= 5 ->
          line_diff = abs(comment.line - finding.line)

          cond do
            c_suggestion != nil ->
              true

            line_diff == 0 ->
              MapSet.size(shared_id_tokens) > 0 or MapSet.size(shared_words) > 0

            true ->
              MapSet.size(shared_id_tokens) > 0 or MapSet.size(shared_words) >= 2
          end

        # 2. Same file with shared code identifiers or high word overlap
        same_file?(comment.file, finding.file) ->
          cond do
            c_suggestion != nil and is_binary(finding.fix_suggestion) and
              finding.fix_suggestion != "" and
                suggestion_matches?(c_suggestion, finding.fix_suggestion) ->
              true

            MapSet.size(shared_id_tokens) >= 1 and MapSet.size(shared_words) >= 1 ->
              true

            MapSet.size(shared_id_tokens) >= 2 ->
              true

            MapSet.size(shared_words) >= 3 ->
              true

            jaccard_similarity(f_words, c_words) >= 0.25 and MapSet.size(shared_words) >= 2 ->
              true

            true ->
              false
          end

        # 3. Comment mentions the file (e.g. top-level review or issue comment)
        comment_mentions_file?(c_body, finding.file) ->
          cond do
            MapSet.size(shared_id_tokens) >= 1 ->
              true

            MapSet.size(shared_words) >= 2 ->
              true

            true ->
              false
          end

        # 4. Across files or general finding: title or strong identifiers match
        true ->
          title_clean =
            finding.title
            |> String.downcase()
            |> String.replace("`", "")
            |> String.trim()

          cond do
            title_clean != "" and String.length(title_clean) >= 12 and
                String.contains?(String.downcase(c_body), title_clean) ->
              true

            MapSet.size(shared_id_tokens) >= 2 and MapSet.size(shared_words) >= 2 ->
              true

            MapSet.size(shared_words) >= 4 and jaccard_similarity(f_words, c_words) >= 0.35 ->
              true

            true ->
              false
          end
      end
    end
  end

  @praise_words MapSet.new([
                  "lgtm",
                  "looks",
                  "good",
                  "nice",
                  "great",
                  "thanks",
                  "thank",
                  "you",
                  "approved",
                  "perfect",
                  "awesome",
                  "cool",
                  "fine",
                  "plus",
                  "one",
                  "to",
                  "me"
                ])

  defp praise_only?(body) do
    words =
      body
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, " ")
      |> String.split(~r/\s+/, trim: true)

    words != [] and Enum.all?(words, &MapSet.member?(@praise_words, &1))
  end

  defp comment_mentions_file?(_body, nil), do: false

  defp comment_mentions_file?(body, file) when is_binary(body) and is_binary(file) do
    file_norm = normalize_path(file)
    base = Path.basename(file_norm)
    body_down = String.downcase(body)

    (file_norm != "" and String.contains?(body_down, file_norm)) or
      (String.length(base) >= 5 and String.contains?(body_down, base))
  end

  defp suggestion_matches?(suggestion, fix) do
    s_words = extract_significant_words(suggestion)
    f_words = extract_significant_words(fix)
    shared = MapSet.intersection(s_words, f_words)
    MapSet.size(shared) >= 2 or jaccard_similarity(s_words, f_words) >= 0.3
  end

  defp jaccard_similarity(set_a, set_b) do
    union = MapSet.union(set_a, set_b)
    union_size = MapSet.size(union)

    if union_size == 0 do
      0.0
    else
      intersection = MapSet.intersection(set_a, set_b)
      MapSet.size(intersection) / union_size
    end
  end
end

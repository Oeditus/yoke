defmodule Yoke.PRReviewTest do
  use ExUnit.Case, async: true

  alias Yoke.PRReview

  describe "prompt_instructions/0" do
    test "returns prompt instructions containing structured findings format" do
      instructions = PRReview.prompt_instructions()
      assert is_binary(instructions)
      assert String.contains?(instructions, "Structured Findings Payload")
      assert String.contains?(instructions, "```json findings")
      assert String.contains?(instructions, "fix_suggestion")
    end
  end

  describe "parse_findings/1" do
    test "parses findings from ```json findings``` block" do
      review_md = """
      # Executive Summary
      Great PR with minor issues.

      ```json findings
      [
        {
          "id": 1,
          "file": "lib/yoke/git.ex",
          "line": 42,
          "title": "Unhandled System.cmd error",
          "description": "System.cmd might raise if git is missing.",
          "severity": "medium",
          "fix_suggestion": "Wrap in try/rescue block."
        },
        {
          "id": 2,
          "file": "lib/yoke/cli/repl.ex",
          "line": 700,
          "title": "Missing nil check",
          "description": "Variable could be nil.",
          "severity": "high",
          "fix_suggestion": "Add guard clause."
        }
      ]
      ```
      """

      findings = PRReview.parse_findings(review_md)
      assert length(findings) == 2

      [f1, f2] = findings
      assert f1.id == 1
      assert f1.file == "lib/yoke/git.ex"
      assert f1.line == 42
      assert f1.title == "Unhandled System.cmd error"
      assert f1.severity == "medium"
      assert f1.fix_suggestion == "Wrap in try/rescue block."

      assert f2.id == 2
      assert f2.file == "lib/yoke/cli/repl.ex"
      assert f2.line == 700
      assert f2.severity == "high"
    end

    test "parses findings from <findings> tags" do
      review_md = """
      <findings>
      [
        {
          "id": 1,
          "file": "lib/foo.ex",
          "line": 10,
          "title": "Syntax warning",
          "description": "Deprecated function call.",
          "severity": "low",
          "fix_suggestion": "Use new_fn/0 instead."
        }
      ]
      </findings>
      """

      findings = PRReview.parse_findings(review_md)
      assert length(findings) == 1
      assert Enum.at(findings, 0).file == "lib/foo.ex"
    end

    test "fallback parsing extracts bullet points when json block is missing" do
      review_md = """
      # Risk & Edge Case Assessment
      - **`lib/yoke/git.ex:42`** Uncaught error: System.cmd might fail without rescue
      - **`lib/yoke/cli.ex:10`** Refactor recommendation: simplify pattern match
      """

      findings = PRReview.parse_findings(review_md)
      assert length(findings) == 2
      assert Enum.at(findings, 0).file == "lib/yoke/git.ex"
      assert Enum.at(findings, 0).line == 42
    end
  end

  describe "build_fix_prompt/1" do
    test "constructs prompt with preamble and accepted findings list" do
      accepted = [
        %{
          id: 1,
          file: "lib/yoke/git.ex",
          line: 42,
          title: "Unhandled System.cmd error",
          description: "System.cmd might raise if git is missing.",
          severity: "medium",
          fix_suggestion: "Wrap in try/rescue block."
        }
      ]

      prompt = PRReview.build_fix_prompt(accepted)

      assert String.contains?(
               prompt,
               "There are some issues found by Yoke, please examine and apply when you see fit:"
             )

      assert String.contains?(prompt, "1. [Unhandled System.cmd error]")
      assert String.contains?(prompt, "File: lib/yoke/git.ex:42")
      assert String.contains?(prompt, "Suggested Fix: Wrap in try/rescue block.")
    end

    test "returns empty string when accepted findings list is empty" do
      assert PRReview.build_fix_prompt([]) == ""
    end

    test "includes both file name and line number for every finding" do
      accepted = [
        %{
          id: 1,
          file: "lib/yoke/git.ex",
          line: 42,
          title: "With line",
          description: "d",
          severity: "medium",
          fix_suggestion: ""
        },
        %{
          id: 2,
          file: "lib/yoke/cli.ex",
          line: nil,
          title: "Without line",
          description: "d",
          severity: "low",
          fix_suggestion: ""
        }
      ]

      prompt = PRReview.build_fix_prompt(accepted)

      assert String.contains?(prompt, "File: lib/yoke/git.ex:42")
      # A file with no line still names the file and flags the missing line.
      assert String.contains?(prompt, "File: lib/yoke/cli.ex")
      assert String.contains?(prompt, "line number unavailable")
    end

    test "never truncates finding titles, however long" do
      long_title =
        "This is an extremely long finding title that far exceeds any reasonable " <>
          "single-line width and must therefore be preserved verbatim in full"

      accepted = [
        %{
          id: 1,
          file: "lib/yoke/git.ex",
          line: 42,
          title: long_title,
          description: "d",
          severity: "medium",
          fix_suggestion: ""
        }
      ]

      prompt = PRReview.build_fix_prompt(accepted)

      assert String.contains?(prompt, "1. [#{long_title}]")
    end
  end

  describe "build_pr_comment_body/3" do
    test "constructs markdown PR review comment with assistant name" do
      accepted = [
        %{
          id: 1,
          file: "lib/yoke/git.ex",
          line: 42,
          title: "Unhandled System.cmd error",
          description: "System.cmd might raise if git is missing.",
          severity: "medium",
          fix_suggestion: "Wrap in try/rescue block."
        }
      ]

      fix_prompt = PRReview.build_fix_prompt(accepted)
      pr_body = PRReview.build_pr_comment_body(accepted, fix_prompt)

      assert String.contains?(pr_body, "## 🪢 Review from Robby Ott")
      assert String.contains?(pr_body, "### 📋 Findings Summary & Accepted Issues")
      assert String.contains?(pr_body, "- **1. [MEDIUM]** `lib/yoke/git.ex`:42")
      assert String.contains?(pr_body, "### 🛠️ Recommended Fix Prompt")

      custom_body = PRReview.build_pr_comment_body(accepted, fix_prompt, assistant_name: "Alice")
      assert String.contains?(custom_body, "## 🪢 Review from Alice")
    end
  end

  describe "interactive_review/2" do
    test "returns empty lists when findings list is empty" do
      assert {:ok, [], []} = PRReview.interactive_review([])
    end

    test "auto-answers in non-interactive / god mode" do
      findings = [
        %{
          id: 1,
          file: "lib/test.ex",
          line: 1,
          title: "Test Issue",
          description: "Desc",
          severity: "high",
          fix_suggestion: "Fix"
        }
      ]

      assert {:ok, accepted, declined} = PRReview.interactive_review(findings)
      assert length(accepted) + length(declined) == 1
    end
  end

  describe "detect_pr/2" do
    test "runs gh pr view command safely" do
      res = PRReview.detect_pr("HEAD")
      assert match?({:ok, _}, res) or match?({:error, _}, res)
    end
  end

  describe "parse_diff_right_lines/1" do
    test "correctly parses right-side lines from unified diff" do
      diff =
        """
        diff --git a/lib/test.ex b/lib/test.ex
        index 1234567..89abcdef 100644
        --- a/lib/test.ex
        +++ b/lib/test.ex
        @@ -10,4 +10,5 @@ defmodule Test do
         context_line_10
        - deleted_line
        + added_line_11
        + added_line_12
         context_line_13
        """

      lines = PRReview.parse_diff_right_lines(diff)

      assert MapSet.member?(lines, {"lib/test.ex", 10})
      assert MapSet.member?(lines, {"lib/test.ex", 11})
      assert MapSet.member?(lines, {"lib/test.ex", 12})
      assert MapSet.member?(lines, {"lib/test.ex", 13})
      refute MapSet.member?(lines, {"lib/test.ex", 9})
      refute MapSet.member?(lines, {"lib/test.ex", 14})
    end
  end

  describe "build_atomic_review_payload/4" do
    test "constructs review JSON payload with inline comments on valid diff lines" do
      findings = [
        %{
          id: 1,
          file: "lib/test.ex",
          line: 11,
          title: "Style issue",
          description: "Use pattern matching",
          severity: "medium",
          fix_suggestion: "def foo(:bar), do: :ok"
        },
        %{
          id: 2,
          file: "lib/other.ex",
          line: 99,
          title: "Outside diff issue",
          description: "Old code has a bug",
          severity: "low",
          fix_suggestion: ""
        }
      ]

      valid_lines = MapSet.new([{"lib/test.ex", 11}])

      payload =
        PRReview.build_atomic_review_payload(
          findings,
          "## Summary",
          "APPROVE",
          valid_lines
        )

      assert payload["event"] == "APPROVE"
      assert length(payload["comments"]) == 1

      [c] = payload["comments"]
      assert c["path"] == "lib/test.ex"
      assert c["line"] == 11
      assert c["side"] == "RIGHT"
      assert String.contains?(c["body"], "```suggestion")
      assert String.contains?(c["body"], "def foo(:bar), do: :ok")

      # Finding 2 should be in body sidenotes
      assert String.contains?(payload["body"], "Outside diff issue")
    end

    test "omits the General Observations section when sidenotes duplicate the summary" do
      findings = [
        %{
          id: 1,
          file: "lib/other.ex",
          line: 99,
          title: "Outside diff issue",
          description: "Old code has a bug",
          severity: "low",
          fix_suggestion: ""
        }
      ]

      # The summary body already mentions this finding by title, so the
      # off-diff sidenotes section would be an exact duplicate and must be
      # suppressed entirely.
      review_body =
        "### 📋 Findings Summary & Accepted Issues\n" <>
          "- **1. [LOW]** `lib/other.ex`:99 - **Outside diff issue**: Old code has a bug"

      payload =
        PRReview.build_atomic_review_payload(
          findings,
          review_body,
          "COMMENT",
          MapSet.new()
        )

      refute String.contains?(payload["body"], "General Observations & Out-of-Diff Notes")
      assert payload["body"] == review_body
    end

    test "publishes the General Observations section only for novel sidenotes" do
      findings = [
        %{
          id: 1,
          file: "lib/other.ex",
          line: 99,
          title: "Outside diff issue",
          description: "Old code has a bug",
          severity: "low",
          fix_suggestion: ""
        }
      ]

      payload =
        PRReview.build_atomic_review_payload(
          findings,
          "## Summary with no findings listed",
          "COMMENT",
          MapSet.new()
        )

      assert String.contains?(payload["body"], "General Observations & Out-of-Diff Notes")
      assert String.contains?(payload["body"], "Outside diff issue")
    end
  end

  describe "prompt_instructions self-critique and tone" do
    test "contains self-critique rules, typography enforcement, and tone guidelines" do
      prompt = PRReview.prompt_instructions()
      assert String.contains?(prompt, "Self-Critique Checklist")
      assert String.contains?(prompt, "em dashes (—)")
      assert String.contains?(prompt, "typographic quotes (“ ” and ‘ ’)")
      assert String.contains?(prompt, "Ask rather than assert")
      assert String.contains?(prompt, "Tone & Comment Phrasing Rules")
      assert String.contains?(prompt, "Subtitles must match their content")
      assert String.contains?(prompt, "Markdown formatting for GitHub PR comments")
      assert String.contains?(prompt, "Backticks for code pieces")
      assert String.contains?(prompt, "Code fences for multiline snippets")
    end
  end

  describe "markdown formatting of inline comments and summaries" do
    test "formats short code pieces in backticks and multiline code in fences" do
      findings = [
        %{
          id: 1,
          file: "apps/api/lib/drawer.ex",
          line: 930,
          title: "Drawer sends itself a :comment_event message with no handle_info/2",
          description:
            "mark_read/2 calls send(self(), {:comment_event, %{event: :read, ...}}). self() inside a LiveComponent is the LiveView process, and Drawer defines no handle_info/2.",
          severity: "high",
          fix_suggestion: """
          @impl true
          def handle_info({:comment_event, event}, socket) do
            {:ok, handle_comment_event(socket, event)}
          end
          """
        }
      ]

      valid_lines = MapSet.new([{"apps/api/lib/drawer.ex", 930}])
      pr_body = PRReview.build_pr_comment_body(findings)
      payload = PRReview.build_atomic_review_payload(findings, pr_body, "COMMENT", valid_lines)

      # Summary body formatting
      assert String.contains?(pr_body, "`:comment_event`")
      assert String.contains?(pr_body, "`handle_info/2`")

      # Inline comment formatting
      [c] = payload["comments"]
      assert String.contains?(c["body"], "`:comment_event`")
      assert String.contains?(c["body"], "`handle_info/2`")
      assert String.contains?(c["body"], "`mark_read/2`")
      assert String.contains?(c["body"], "`LiveComponent`")
      assert String.contains?(c["body"], "`LiveView`")
      assert String.contains?(c["body"], "```")
      assert String.contains?(c["body"], "def handle_info")
    end
  end
end

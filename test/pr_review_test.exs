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
  end

  describe "build_pr_comment_body/2" do
    test "constructs markdown PR review comment" do
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

      assert String.contains?(pr_body, "## 🤖 Yoke Code Review")
      assert String.contains?(pr_body, "### 📋 Findings Summary & Accepted Issues")
      assert String.contains?(pr_body, "- **1. [MEDIUM]** `lib/yoke/git.ex`:42")
      assert String.contains?(pr_body, "### 🛠️ Recommended Fix Prompt")
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
  end

  describe "prompt_instructions self-critique and tone" do
    test "contains self-critique rules, typography enforcement, and tone guidelines" do
      prompt = PRReview.prompt_instructions()
      assert String.contains?(prompt, "Self-Critique Checklist")
      assert String.contains?(prompt, "em dashes (—)")
      assert String.contains?(prompt, "typographic quotes (“ ” and ‘ ’)")
      assert String.contains?(prompt, "Ask rather than assert")
      assert String.contains?(prompt, "Tone & Comment Phrasing Rules")
    end
  end
end

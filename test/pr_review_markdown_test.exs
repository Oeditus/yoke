defmodule Yoke.PRReview.MarkdownTest do
  use ExUnit.Case, async: true

  alias Yoke.PRReview.Markdown

  describe "format_inline_code/1" do
    test "wraps function arities in backticks" do
      input = "Drawer defines no handle_info/2 and calls mark_read/2 or System.cmd/3"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`handle_info/2`")
      assert String.contains?(output, "`mark_read/2`")
      assert String.contains?(output, "`System.cmd/3`")
    end

    test "wraps atoms in backticks" do
      input = "Sends a :comment_event or :error with :ok status"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`:comment_event`")
      assert String.contains?(output, "`:error`")
      assert String.contains?(output, "`:ok`")
    end

    test "wraps PascalCase component and module names in backticks" do
      input = "Inside a LiveComponent or LiveView, StewardshipSyncWorker calls SurfaceIcon"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`LiveComponent`")
      assert String.contains?(output, "`LiveView`")
      assert String.contains?(output, "`StewardshipSyncWorker`")
      assert String.contains?(output, "`SurfaceIcon`")
    end

    test "does not wrap common proper nouns in backticks" do
      input = "Publishing to GitHub using Elixir and GraphQL"
      output = Markdown.format_inline_code(input)

      refute String.contains?(output, "`GitHub`")
      refute String.contains?(output, "`Elixir`")
      refute String.contains?(output, "`GraphQL`")
      assert String.contains?(output, "GitHub")
      assert String.contains?(output, "Elixir")
    end

    test "wraps complex expressions, tuples, and function calls in backticks" do
      input = "mark_read/2 calls send(self(), {:comment_event, %{event: :read, ...}})."
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`mark_read/2`")
      assert String.contains?(output, "send(self(),")
      assert String.contains?(output, "`")
    end

    test "wraps file paths and dotted variables in backticks" do
      input = "Configured in config/dev.exs for socket.assigns.view and drawer.ex:930"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`config/dev.exs`")
      assert String.contains?(output, "`drawer.ex:930`")
      assert String.contains?(output, "`socket.assigns.view`")
    end

    test "wraps snake_case identifiers in backticks" do
      input = "Check comment_commentables or assign_new with mark_replies_read?"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`comment_commentables`")
      assert String.contains?(output, "`assign_new`")
      assert String.contains?(output, "`mark_replies_read?`")
    end

    test "wraps comparison expressions in backticks" do
      input = "When view == :archived or a != b"
      output = Markdown.format_inline_code(input)

      assert String.contains?(output, "`view == :archived`") or
               (String.contains?(output, "`view`") and String.contains?(output, "`:archived`"))
    end

    test "preserves existing backticks without double-wrapping" do
      input = "Already has `mark_read/2` and `:ok` in backticks"
      output = Markdown.format_inline_code(input)

      assert output == "Already has `mark_read/2` and `:ok` in backticks"
      refute String.contains?(output, "``")
    end
  end

  describe "format_markdown_body/2" do
    test "preserves existing fenced code blocks intact" do
      input = """
      Here is the fix:

      ```elixir
      def foo(:bar) do
        :ok
      end
      ```

      And explanation with mark_read/2.
      """

      output = Markdown.format_markdown_body(input, lang: "elixir")

      assert String.contains?(output, "```elixir\ndef foo(:bar) do\n  :ok\nend\n```")
      assert String.contains?(output, "`mark_read/2`")
    end

    test "detects and fences unfenced multiline code blocks" do
      input = """
      Calling System.cmd without handling the error:
      case System.cmd("gh", args) do
        {out, 0} -> {:ok, out}
        {err, _} -> {:error, err}
      end
      This causes a crash.
      """

      output = Markdown.format_markdown_body(input, lang: "elixir")

      assert String.contains?(output, "```elixir\ncase System.cmd(\"gh\", args) do")
      assert String.contains?(output, "end\n```")
    end
  end

  describe "format_inline_comment_body/1" do
    test "formats finding with markdown in title, description, and fix suggestion" do
      finding = %{
        file: "apps/api/lib/drawer.ex",
        line: 930,
        severity: "high",
        title: "Drawer sends itself a :comment_event message with no handle_info/2",
        description: "mark_read/2 calls send(self(), {:comment_event, %{event: :read, ...}}). self() inside a LiveComponent is the LiveView process, and Drawer defines no handle_info/2.",
        fix_suggestion: """
        @impl true
        def handle_info({:comment_event, event}, socket) do
          {:ok, handle_comment_event(socket, event)}
        end
        """
      }

      body = Markdown.format_inline_comment_body(finding)

      # Header has severity and formatted title with backticks
      assert String.contains?(body, "**[HIGH]")
      assert String.contains?(body, "`:comment_event`")
      assert String.contains?(body, "`handle_info/2`")

      # Description has backticks
      assert String.contains?(body, "`mark_read/2`")
      assert String.contains?(body, "`LiveComponent`")
      assert String.contains?(body, "`LiveView`")

      # Fix suggestion is fenced
      assert String.contains?(body, "```")
      assert String.contains?(body, "def handle_info")
    end

    test "wraps single-line code fix suggestion in suggestion code fence" do
      finding = %{
        file: "lib/test.ex",
        line: 11,
        severity: "medium",
        title: "Style issue",
        description: "Use pattern matching",
        fix_suggestion: "def foo(:bar), do: :ok"
      }

      body = Markdown.format_inline_comment_body(finding)

      assert String.contains?(body, "```suggestion\ndef foo(:bar), do: :ok\n```")
    end
  end
end

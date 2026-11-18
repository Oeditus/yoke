defmodule Yoke.Brain.ConfirmationSummaryTest do
  @moduledoc """
  The permission modal is the one place a user must actually read what they are
  approving, so its renderer is tested directly rather than through a live
  session actor.
  """
  use ExUnit.Case, async: true

  alias Yoke.Brain.ConfirmationSummary

  describe "render/2 for known tool shapes" do
    test "renders a replace as a two-line diff with the target file" do
      summary =
        ConfirmationSummary.render("replace_file", %{
          "path" => "lib/foo.ex",
          "target" => "old_text",
          "replacement" => "new_text"
        })

      assert summary =~ "Tool: replace_file"
      assert summary =~ "File: lib/foo.ex"
      assert summary =~ "- old_text"
      assert summary =~ "+ new_text"
    end

    test "renders a write with the line count and a preview" do
      summary =
        ConfirmationSummary.render("write_file", %{
          "path" => "lib/new.ex",
          "content" => "line one\nline two\nline three"
        })

      assert summary =~ "File: lib/new.ex (3 lines)"
      assert summary =~ "line one"
    end

    test "renders a shell command" do
      summary = ConfirmationSummary.render("bash", %{"command" => "mix test"})

      assert summary =~ "Tool: bash"
      assert summary =~ "Command: $ mix test"
    end

    test "renders a single-file read with a line range" do
      summary =
        ConfirmationSummary.render("read_file", %{
          "path" => "lib/foo.ex",
          "StartLine" => 10,
          "EndLine" => 20
        })

      assert summary =~ "File: lib/foo.ex (lines 10-20)"
    end

    test "renders a multi-file read with every path" do
      summary = ConfirmationSummary.render("read_files", %{"paths" => ["a.ex", "b.ex"]})

      assert summary =~ "Files (2):"
      assert summary =~ "a.ex"
      assert summary =~ "b.ex"
    end

    test "reports an empty multi-file read rather than a blank list" do
      summary = ConfirmationSummary.render("read_files", %{"paths" => []})

      assert summary =~ "Files (0):"
      assert summary =~ "(none specified)"
    end
  end

  describe "render/2 bounds the generic renderer" do
    test "caps the number of keys and reports how many were hidden" do
      args = Map.new(1..30, fn n -> {"key_#{n}", "value"} end)

      summary = ConfirmationSummary.render("some_mcp_tool", args)

      assert summary =~ "Tool: some_mcp_tool"
      assert summary =~ "18 more argument(s)"
      # Only the first 12 keys are rendered.
      assert summary =~ "key_1:"
      refute summary =~ "key_20:"
    end

    test "truncates a long value" do
      summary = ConfirmationSummary.render("tool", %{"a" => String.duplicate("x", 500)})

      refute summary =~ String.duplicate("x", 100)
      assert String.length(summary) < 200
    end

    test "renders a non-map argument payload without dumping it verbatim" do
      summary = ConfirmationSummary.render("tool", "a" <> String.duplicate("b", 500))

      assert summary =~ "Tool: tool"
      assert String.length(summary) < 200
    end

    test "escapes newlines in a generic value so the modal stays one line per key" do
      summary = ConfirmationSummary.render("tool", %{"a" => "line1\nline2"})

      assert summary =~ "a: line1\\nline2"
    end
  end

  describe "render/2 is total" do
    test "never raises for any argument shape" do
      for args <- [%{}, nil, 42, :atom, [1, 2], "string", %{a: 1}] do
        assert is_binary(ConfirmationSummary.render("tool", args))
      end
    end
  end
end

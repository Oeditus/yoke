defmodule Yoke.ContextExpanderTest do
  use ExUnit.Case, async: true
  # Expands `@error` references against a live session's message history.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.CLI.ContextExpander

  test "expands local relative path file reference" do
    tmp_path = Path.join(System.tmp_dir!(), "test_ref_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "Hello reference context!")

    prompt = "Please inspect @#{tmp_path} and summarize it."
    assert {:ok, expanded, attachments} = ContextExpander.expand(prompt)

    assert String.contains?(expanded, "[Ref: #{tmp_path}]") and
             String.contains?(expanded, "Hello reference context!")

    assert tmp_path in attachments

    File.rm(tmp_path)
  end

  test "expands relative path with parent dir (@../foo)" do
    tmp_dir = Path.join(System.tmp_dir!(), "sub_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    tmp_file = Path.join(tmp_dir, "file.txt")
    File.write!(tmp_file, "Parent relative test")

    assert {:ok, expanded, _attachments} = ContextExpander.expand("Check @#{tmp_file}")
    assert String.contains?(expanded, "Parent relative test")

    File.rm_rf!(tmp_dir)
  end

  test "expands file URI reference (@file://...)" do
    tmp_path = Path.join(System.tmp_dir!(), "file_uri_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "File URI content")

    assert {:ok, expanded, _attachments} = ContextExpander.expand("Check @file://#{tmp_path}")
    assert String.contains?(expanded, "File URI content")

    File.rm(tmp_path)
  end

  test "enforces workspace sandbox bounds when enabled" do
    workspace = Path.join(System.tmp_dir!(), "workspace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    inside_file = Path.join(workspace, "inside.txt")

    outside_file =
      Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.txt")

    File.write!(inside_file, "Inside workspace")
    File.write!(outside_file, "Outside workspace")

    # Allowed inside workspace
    assert {:ok, exp1, _att1} =
             ContextExpander.expand("Read @#{inside_file}", workspace, sandbox_workspace: true)

    assert String.contains?(exp1, "Inside workspace")

    # Denied outside workspace sandbox
    assert {:ok, exp2, att2} =
             ContextExpander.expand("Read @#{outside_file}", workspace, sandbox_workspace: true)

    refute String.contains?(exp2, "Outside workspace")
    assert att2 == []

    File.rm_rf!(workspace)
    File.rm(outside_file)
  end

  test "retains original token if target file does not exist" do
    assert {:ok, expanded, attachments} =
             ContextExpander.expand("Check @/tmp/non_existent_file_xyz_123.txt")

    assert String.contains?(expanded, "@/tmp/non_existent_file_xyz_123.txt")
    assert attachments == []
  end

  test "resolves URL references (@https://...)" do
    assert {:ok, _content, label} =
             ContextExpander.resolve_reference("https://example.com", ".", [])

    assert label == "https://example.com"
  end

  test "expands ambiguous error reference ('error above') with resolution status" do
    messages = [
      %{"role" => "tool", "content" => "Tool execution failed: syntax_error in mix.exs"}
    ]

    tracker = [
      %{
        id: 1,
        turn: 2,
        error: "mix.exs syntax_error",
        status: :resolved,
        resolved_at: 3,
        resolution: "Resolved via successful replace_file execution"
      }
    ]

    opts = [session_messages: messages, issue_tracker: tracker]

    assert {:ok, expanded, attachments} =
             ContextExpander.expand("Why did the error above happen?", ".", opts)

    assert String.contains?(expanded, "RESOLVED in Turn 3")
    assert String.contains?(expanded, "syntax_error")
    assert "error_context" in attachments
  end

  test "image reference produces a structured image attachment (not inlined text)" do
    # Minimal valid 1x1 transparent PNG (base64-encoded)
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      )

    tmp_path =
      Path.join(System.tmp_dir!(), "img_#{System.unique_integer([:positive])}.png")

    File.write!(tmp_path, png)

    assert {:ok, expanded, attachments} = ContextExpander.expand("Describe @#{tmp_path}")

    # The base64 payload must NOT be inlined into the prompt text
    refute String.contains?(expanded, "iVBORw0KG")
    assert String.contains?(expanded, "[Image: #{tmp_path}]")
    assert String.contains?(expanded, "Ragex Image Analysis")
    assert String.contains?(expanded, "Format: png")

    [img] = Enum.filter(attachments, &(is_map(&1) and &1.type == "image"))
    assert img.label == tmp_path
    assert img.mime == "image/png"
    assert img.filename == Path.basename(tmp_path)
    assert img.bytes == png
    assert String.starts_with?(img.data_uri, "data:image/png;base64,")

    File.rm(tmp_path)
  end

  test "oversized image reference is rejected with an error" do
    path = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.png")
    # 11MB of junk, exceeding the 10MB vision limit
    File.write!(path, :binary.copy(<<0>>, 11_000_000))

    assert {:ok, expanded, attachments} = ContextExpander.expand("Look at @#{path}")
    assert attachments == []
    refute String.contains?(expanded, "[Image:")

    File.rm(path)
  end
end

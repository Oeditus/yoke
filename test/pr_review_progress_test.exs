defmodule Yoke.PRReview.ProgressTest do
  use ExUnit.Case, async: true

  alias Yoke.PRReview.Progress

  test "equivalent sources and changing arguments cannot disguise identical results" do
    progress = Progress.new()
    assert {:ok, progress} = observe(progress, "read_file", %{"path" => "lib/a.ex"}, "same")
    assert {:ok, progress} = observe(progress, "read_file", %{"path" => "./lib/a.ex"}, "same")

    assert {:ok, progress} =
             observe(progress, "read_file", %{"path" => "lib/a.ex", "start_line" => 10}, "same")

    assert {:stalled, _} =
             observe(progress, "read_file", %{"path" => "lib/a.ex", "end_line" => 100}, "same")
  end

  test "different files, revisions, and contents count as new evidence" do
    progress = Progress.new()

    for args <- [
          %{"path" => "a.ex"},
          %{"path" => "b.ex"},
          %{"path" => "a.ex", "revision" => "base"}
        ],
        reduce: progress do
      acc ->
        assert {:ok, next} = observe(acc, "read_file", args, "same")
        assert next.stalled_steps == 0
        next
    end
  end

  test "alternating old results is still a stall" do
    a = %{"path" => "a.ex"}
    b = %{"path" => "b.ex"}
    assert {:ok, progress} = observe(Progress.new(), "read_file", a, "a")
    assert {:ok, progress} = observe(progress, "read_file", b, "b")
    assert {:ok, progress} = observe(progress, "read_file", a, "a")
    assert {:ok, progress} = observe(progress, "read_file", b, "b")
    assert {:stalled, _} = observe(progress, "read_file", a, "a")
  end

  test "new evidence and other tools reset the consecutive stall counter" do
    args = %{"path" => "a.ex"}
    assert {:ok, progress} = observe(Progress.new(), "read_file", args, "old")
    assert {:ok, progress} = observe(progress, "read_file", args, "old")
    assert progress.stalled_steps == 1
    assert {:ok, progress} = observe(progress, "grep_search", %{"query" => "new"}, "match")
    assert progress.stalled_steps == 0
    assert {:ok, progress} = observe(progress, "read_file", args, "new")
    assert progress.stalled_steps == 0
  end

  test "read_files batches also track repeated evidence" do
    args = %{"paths" => ["a.ex", "b.ex"]}
    assert {:ok, progress} = observe(Progress.new(), "read_files", args, "a and b")
    assert {:ok, progress} = observe(progress, "read_files", args, "a and b")
    assert {:ok, progress} = observe(progress, "read_files", args, "a and b")
    assert {:stalled, _} = observe(progress, "read_files", args, "a and b")
  end

  test "malformed path lists still track error results without crashing" do
    for paths <- [nil, "not-a-list", 42] do
      args = %{"paths" => paths}

      assert {:ok, progress} =
               observe(Progress.new(), "read_files", args, "Tool execution failed")

      assert {:ok, _} = observe(progress, "read_files", args, "Tool execution failed")
    end
  end

  test "duplicate tool call ids and nil do not crash progress observation" do
    progress = Progress.new()
    calls = [%{id: "call", name: "read_file", arguments: %{"path" => "lib/a.ex"}}]

    messages = [
      %{"tool_call_id" => "call", "content" => "first"},
      %{"tool_call_id" => "call", "content" => "second"},
      %{"tool_call_id" => nil, "content" => "synthetic"}
    ]

    assert {:ok, _} = Progress.observe(progress, calls, messages, "/repo")
  end

  defp observe(progress, name, args, content) do
    Progress.observe(
      progress,
      [%{id: "call", name: name, arguments: args}],
      [%{"tool_call_id" => "call", "content" => content}],
      "/repo"
    )
  end
end

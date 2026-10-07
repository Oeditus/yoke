defmodule Yoke.PRReview.PatternsTest do
  use ExUnit.Case, async: false

  alias Yoke.PRReview.Patterns

  @test_dir "test/tmp/patterns_test_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "ensure_patterns_file/1 and load_patterns/1" do
    test "creates template file if missing and parses patterns" do
      path = Patterns.ensure_patterns_file(@test_dir)
      assert File.exists?(path)

      patterns = Patterns.load_patterns(@test_dir)
      assert length(patterns) >= 5

      shared_helper = Enum.find(patterns, &(&1.name == "Shared Helper Contract Drift"))
      assert shared_helper != nil
      assert shared_helper.category == "Correctness"
      assert shared_helper.seen == 1
    end
  end

  describe "format_patterns_for_prompt/1" do
    test "formats mandatory checks (seen: 3+) and candidates into prompt" do
      Patterns.ensure_patterns_file(@test_dir)

      # Record a pattern 3 times to make it mandatory
      finding = %{
        title: "Repeated Auth Bug",
        description: "Missing tenant check",
        severity: "high",
        file: "lib/auth.ex",
        line: 10
      }

      Patterns.record_finding(finding, "PR #1", @test_dir)
      Patterns.record_finding(finding, "PR #2", @test_dir)
      Patterns.record_finding(finding, "PR #3", @test_dir)

      prompt = Patterns.format_patterns_for_prompt(@test_dir)

      assert String.contains?(prompt, "Mandatory Historical Tripwires (Seen: 3+)")
      assert String.contains?(prompt, "Repeated Auth Bug")
      assert String.contains?(prompt, "Known Codebase Patterns")
    end
  end

  describe "record_finding/3" do
    test "increments seen count for existing pattern and appends new pattern" do
      Patterns.ensure_patterns_file(@test_dir)

      # Record new pattern
      f1 = %{
        title: "Unindexed Foreign Key in Posts",
        description: "Adding user_id without index",
        severity: "medium",
        file: "priv/repo/migrations/123.exs",
        line: 5
      }

      :ok = Patterns.record_finding(f1, "PR #42", @test_dir)

      patterns_after_f1 = Patterns.load_patterns(@test_dir)
      p1 = Enum.find(patterns_after_f1, &String.contains?(&1.name, "Unindexed Foreign Key"))
      assert p1 != nil
      assert p1.seen == 1

      # Record same pattern again
      :ok = Patterns.record_finding(f1, "PR #43", @test_dir)

      patterns_after_f2 = Patterns.load_patterns(@test_dir)
      p2 = Enum.find(patterns_after_f2, &String.contains?(&1.name, "Unindexed Foreign Key"))
      assert p2 != nil
      assert p2.seen == 2
    end
  end
end

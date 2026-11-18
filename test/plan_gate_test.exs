defmodule Yoke.PlanGateTest do
  use ExUnit.Case, async: true

  alias Yoke.PlanGate

  describe "modifier_tool?/2" do
    test "returns true for file-modifying tools regardless of args" do
      for tool <- ~w(write_file replace_file edit_file git_commit) do
        assert PlanGate.modifier_tool?(tool, %{}) == true
        assert PlanGate.modifier_tool?(tool) == true
      end
    end

    test "accepts atom tool names" do
      assert PlanGate.modifier_tool?(:write_file, %{}) == true
      assert PlanGate.modifier_tool?(:edit_file, %{}) == true
    end

    test "returns true for Ragex file modifying and refactoring tools" do
      for tool <-
            ~w(mcp_ragex_edit_file mcp_ragex_edit_files mcp_ragex_refactor_code mcp_ragex_advanced_refactor mcp_ragex_rollback_edit) do
        assert PlanGate.modifier_tool?(tool, %{}) == true
        assert PlanGate.modifier_tool?(tool) == true
      end
    end

    test "returns false for read-only tools" do
      for tool <- ~w(read_file read_files list_dir glob_search) do
        assert PlanGate.modifier_tool?(tool, %{}) == false
      end

      assert PlanGate.modifier_tool?("mcp_ragex_analyze_file", %{}) == false
      assert PlanGate.modifier_tool?("ragex_grep", %{}) == false
    end

    test "bash with write-ish command returns true" do
      for cmd <- ["rm -rf build", "> out.txt", "sed -i s/a/b/ f", "git commit -m x"] do
        assert PlanGate.modifier_tool?("bash", %{"command" => cmd}) == true,
               "expected bash '#{cmd}' to be flagged"
      end
    end

    test "bash with read-only command returns false" do
      for cmd <- ["ls -la", "git status", "cat file", "mix test", "grep foo bar"] do
        assert PlanGate.modifier_tool?("bash", %{"command" => cmd}) == false,
               "expected bash '#{cmd}' not to be flagged"
      end
    end

    test "bash with -> or => only returns false (no real redirection)" do
      for cmd <- ["echo a -> b", "x => y", "lambda -> :ok", "fn a -> a end"] do
        assert PlanGate.modifier_tool?("bash", %{"command" => cmd}) == false,
               "expected bash '#{cmd}' not to be flagged"
      end
    end

    test "bash with real redirection token returns true" do
      assert PlanGate.modifier_tool?("bash", %{"command" => "echo hi > out.txt"}) == true
      assert PlanGate.modifier_tool?("bash", %{"command" => "cat a >> b"}) == true
    end
  end

  describe "write_ish_bash?/1 token classification" do
    test "catches redirection without surrounding whitespace" do
      assert PlanGate.write_ish_bash?(%{"command" => "echo hi>out.txt"})
      assert PlanGate.write_ish_bash?(%{"command" => "cmd 2>&1 >log"})
    end

    test "catches in-place edit and destructive file commands by first word" do
      for cmd <- [
            "truncate -s0 f",
            "ln -sf /etc/passwd f",
            "shred f",
            "chmod 777 f",
            "patch -p1 < d",
            "install -m 755 a b"
          ] do
        assert PlanGate.write_ish_bash?(%{"command" => cmd}),
               "expected '#{cmd}' to be flagged"
      end
    end

    test "catches git subcommands that mutate the tree" do
      for cmd <- [
            "git checkout -- .",
            "git restore f",
            "git clean -fdx",
            "git stash",
            "git rebase main"
          ] do
        assert PlanGate.write_ish_bash?(%{"command" => cmd}),
               "expected '#{cmd}' to be flagged"
      end
    end

    test "catches an interpreter with an inline program" do
      for cmd <- [
            "python3 -c \"open('f','w').write('x')\"",
            "/usr/bin/python -c pass",
            "perl -pi -e 's/a/b/' f"
          ] do
        assert PlanGate.write_ish_bash?(%{"command" => cmd}),
               "expected '#{cmd}' to be flagged"
      end
    end

    test "classifies by the command after a shell separator" do
      assert PlanGate.write_ish_bash?(%{"command" => "cd lib && rm -rf build"})
      assert PlanGate.write_ish_bash?(%{"command" => "ls; touch f"})
    end

    test "does not flag a quoted destructive word inside a read-only command" do
      refute PlanGate.write_ish_bash?(%{"command" => "git log --grep 'rm -rf'"})
      refute PlanGate.write_ish_bash?(%{"command" => "grep -r 'touch' lib"})
    end

    test "does not flag scp or rsync as a cp" do
      refute PlanGate.write_ish_bash?(%{"command" => "scp host:a b"})
      refute PlanGate.write_ish_bash?(%{"command" => "rsync -a a b"})
    end

    test "keeps plain sed and plain git reads read-only" do
      refute PlanGate.write_ish_bash?(%{"command" => "sed 's/a/b/' f"})
      refute PlanGate.write_ish_bash?(%{"command" => "git status"})
      refute PlanGate.write_ish_bash?(%{"command" => "git diff HEAD"})
    end

    test "does not mistake arrow tokens for shell redirection" do
      refute PlanGate.write_ish_bash?(%{"command" => "echo 'a -> b'"})
      refute PlanGate.write_ish_bash?(%{"command" => "grep 'x => y' lib"})
    end

    test "an empty command is read-only" do
      refute PlanGate.write_ish_bash?(%{"command" => ""})
      refute PlanGate.write_ish_bash?(%{})
      refute PlanGate.write_ish_bash?(nil)
    end
  end

  describe "count_modifiers/1" do
    test "counts modifiers over a mixed batch with string keys" do
      calls = [
        %{"name" => "write_file", "arguments" => %{"path" => "a.ex"}},
        %{"name" => "read_file", "arguments" => %{"path" => "b.ex"}},
        %{"name" => "bash", "arguments" => %{"command" => "git status"}},
        %{"name" => "bash", "arguments" => %{"command" => "rm -rf build"}},
        %{"name" => "git_commit", "arguments" => %{}}
      ]

      assert PlanGate.count_modifiers(calls) == 3
    end

    test "counts modifiers over a mixed batch with atom keys" do
      calls = [
        %{name: "edit_file", arguments: %{"path" => "a.ex"}},
        %{name: "list_dir", arguments: %{}},
        %{name: "bash", command: "sed -i s/x/y/ f"}
      ]

      assert PlanGate.count_modifiers(calls) == 2
    end

    test "handles empty and nil input" do
      assert PlanGate.count_modifiers([]) == 0
      assert PlanGate.count_modifiers(nil) == 0
    end
  end

  describe "needs_plan?/2" do
    test "returns true when modifiers meet the threshold" do
      calls = [
        %{"name" => "write_file", "arguments" => %{}},
        %{"name" => "edit_file", "arguments" => %{}}
      ]

      assert PlanGate.needs_plan?(calls) == true
    end

    test "returns false when below the threshold" do
      one = [%{"name" => "write_file", "arguments" => %{}}]
      zero = [%{"name" => "read_file", "arguments" => %{}}]

      assert PlanGate.needs_plan?(one) == false
      assert PlanGate.needs_plan?(zero) == false
    end

    test "returns false for empty list and nil" do
      assert PlanGate.needs_plan?([]) == false
      assert PlanGate.needs_plan?(nil) == false
    end

    test "respects a custom threshold" do
      one = [%{"name" => "write_file", "arguments" => %{}}]
      assert PlanGate.needs_plan?(one, 1) == true
      assert PlanGate.needs_plan?(one, 2) == false
    end
  end

  describe "render_plan/1" do
    test "renders summary and steps" do
      plan = %{
        "summary" => "Refactor the module",
        "steps" => ["Add PlanGate", "Write tests"],
        "files" => ["lib/yoke/plan_gate.ex"]
      }

      rendered = PlanGate.render_plan(plan)

      assert rendered =~ "Refactor the module"
      assert rendered =~ "Add PlanGate"
      assert rendered =~ "Write tests"
      assert rendered =~ "plan_gate.ex"
    end

    test "handles steps as maps with description" do
      plan = %{
        "summary" => "S",
        "steps" => [%{"description" => "step one"}, %{description: "step two"}]
      }

      rendered = PlanGate.render_plan(plan)
      assert rendered =~ "step one"
      assert rendered =~ "step two"
    end

    test "returns fallback for nil or empty plan" do
      assert PlanGate.render_plan(nil) == "(no plan structure provided)"
      assert PlanGate.render_plan(%{}) == "(no plan structure provided)"
    end
  end

  describe "decision_from_selection/1" do
    test "maps the three modal options" do
      assert PlanGate.decision_from_selection("Approve & execute") == :approve
      assert PlanGate.decision_from_selection("Request changes") == :request_changes
      assert PlanGate.decision_from_selection("Deny") == :deny
    end

    test "matches case-insensitively by substring" do
      assert PlanGate.decision_from_selection("approve") == :approve
      assert PlanGate.decision_from_selection("APPROVE & EXECUTE NOW") == :approve
      assert PlanGate.decision_from_selection("Request Changes Please") == :request_changes
      assert PlanGate.decision_from_selection("deny everything") == :deny
    end

    test "returns :unknown for garbage" do
      assert PlanGate.decision_from_selection("maybe") == :unknown
      assert PlanGate.decision_from_selection("") == :unknown
      assert PlanGate.decision_from_selection(nil) == :unknown
    end
  end
end

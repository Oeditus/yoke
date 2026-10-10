defmodule Yoke.CLI.ConfigExplorerTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.ConfigExplorer

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "explorer_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".yoke/sessions"))
    File.mkdir_p!(Path.join(tmp_dir, ".yoke/practices"))
    File.mkdir_p!(Path.join(tmp_dir, ".yoke/jobs"))
    File.mkdir_p!(Path.join(tmp_dir, ".yoke/skills/custom_skill"))

    # Seed test files
    File.write!(
      Path.join(tmp_dir, ".yoke/config.json"),
      "{\"model\": \"deepseek-chat\", \"god_mode\": false}"
    )

    File.write!(
      Path.join(tmp_dir, ".yoke/sessions/test_sess.lmml"),
      "@@@manifest.json\n{\"session_id\":\"test_sess\",\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Fix async worker task engine\"}]}\n@@@\n\n# User\nFix async worker task engine"
    )

    File.write!(Path.join(tmp_dir, ".yoke/practices/elixir.lmml"), "# Elixir Practice Guidelines")
    File.write!(Path.join(tmp_dir, ".yoke/jobs/job_101.log"), "Starting job output log...")

    File.write!(
      Path.join(tmp_dir, ".yoke/skills/custom_skill/SKILL.md"),
      """
      ---
      name: custom_skill
      description: A custom project test skill
      ---
      # Custom Skill Instructions
      """
    )

    File.write!(
      Path.join(tmp_dir, ".yoke/review_patterns.md"),
      """
      # Living Review Patterns

      ## code_search

      ### No Raw Bash for Grep
      - **What**: Used raw bash grep instead of mcp_ragex_grep
      - **How to check**: Call mcp_ragex_grep tool
      - **Seen**: 4
      """
    )

    File.write!(
      Path.join(tmp_dir, ".yoke/bash_analytics.json"),
      """
      {
        "total_calls": 5,
        "unique_commands": 2,
        "ineffective_calls": 1,
        "ineffective_percentage": 20.0,
        "root_commands": {
          "echo": {
            "name": "echo",
            "count": 4,
            "ineffective": false,
            "frequency": 0.8,
            "percentage": 80.0
          },
          "grep": {
            "name": "grep",
            "count": 1,
            "ineffective": true,
            "suggested_analog": "mcp_ragex_grep",
            "frequency": 0.2,
            "percentage": 20.0
          }
        },
        "command_details": {},
        "recent_calls": []
      }
      """
    )

    File.write!(
      Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml"),
      "<!-- error_entry -->\n## Test Error Report"
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "directory scanning & summary" do
    test "scans directory tree correctly", %{tmp_dir: tmp_dir} do
      tree = ConfigExplorer.scan_directory_tree(tmp_dir)

      assert is_map(tree.config)
      assert tree.config["model"] == "deepseek-chat"

      assert length(tree.sessions) == 1
      assert hd(tree.sessions).id == "test_sess"
      assert hd(tree.sessions).model == "deepseek-chat"
      assert hd(tree.sessions).preview == "Fix async worker task engine"

      assert length(tree.jobs) == 1
      assert hd(tree.jobs).id == "job_101"

      assert is_list(tree.skills)
      assert Enum.any?(tree.skills, &(&1.name == "custom_skill"))

      assert is_list(tree.patterns)
      assert Enum.any?(tree.patterns, &(&1.name == "No Raw Bash for Grep"))

      assert is_map(tree.analytics)
      assert tree.analytics.total_calls == 5
      assert tree.analytics.ineffective_calls == 1

      assert tree.errors.count == 1
      assert hd(tree.errors.entries).title == "Test Error Report"
    end

    test "parses descriptive error titles from complex error entries", %{tmp_dir: tmp_dir} do
      err_content = """

      <!-- error_entry -->
      ## [2026-09-10T06:46:02.500400Z] Level: error
      ```
      Task.Supervisor worker process terminating:
        ● Function: Yoke.TaskEngine.JobManager.-start_job/2-fun-3-/0
        ● Reason:   {%ArgumentError{message: "task %Task{...} must be queried from owner"}, []}
      ```
      """

      File.write!(Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml"), err_content)

      log = ConfigExplorer.read_error_log(tmp_dir)
      assert log.count == 1
      entry = hd(log.entries)
      assert String.contains?(entry.title, "Task.Supervisor worker process terminating")
      assert String.contains?(entry.title, "ArgumentError")
    end

    test "formats non-TTY summary cleanly", %{tmp_dir: tmp_dir} do
      tree = ConfigExplorer.scan_directory_tree(tmp_dir)
      summary = ConfigExplorer.format_non_tty_summary(tree)

      assert String.contains?(summary, "Yoke Config Directory Explorer Summary")
      assert String.contains?(summary, "deepseek-chat")
      assert String.contains?(summary, "Saved Sessions/Conversations (1 files)")
      assert String.contains?(summary, "Custom & Discovered Skills")
      assert String.contains?(summary, "Living Review Patterns")
      assert String.contains?(summary, "Bash Command Analytics (5 calls, 1 ineffective)")
    end
  end

  describe "state navigation & tab switching" do
    test "initializes state and switches tabs", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      assert state.active_tab == :settings
      assert state.tab_index == 0

      state = ConfigExplorer.switch_tab(state, 1)
      assert state.active_tab == :rules
      assert state.tab_index == 1

      state = ConfigExplorer.switch_tab(state, 1)
      assert state.active_tab == :sessions
    end

    test "moves cursor within tab boundaries", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = ConfigExplorer.move_cursor(state, 1)
      assert state.cursor == 1

      state = ConfigExplorer.move_cursor(state, -1)
      assert state.cursor == 0
    end
  end

  describe "expandable detail views" do
    test "toggles into detail view mode on select", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      # :sessions tab
      state = ConfigExplorer.switch_tab(state, 2)

      assert state.view_mode == :list
      detailed_state = ConfigExplorer.handle_select(state)
      assert detailed_state.view_mode == :detail

      back_state = ConfigExplorer.handle_select(detailed_state)
      assert back_state.view_mode == :list
    end

    test "provides detail view for skills", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = %{state | active_tab: :skills, tab_index: 5}

      assert state.view_mode == :list
      detailed_state = ConfigExplorer.handle_select(state)
      assert detailed_state.view_mode == :detail
    end

    test "provides distinct color themes per tab" do
      t_settings = ConfigExplorer.tab_theme(:settings)
      t_rules = ConfigExplorer.tab_theme(:rules)
      t_sessions = ConfigExplorer.tab_theme(:sessions)
      t_skills = ConfigExplorer.tab_theme(:skills)
      t_analytics = ConfigExplorer.tab_theme(:analytics)

      assert String.contains?(t_settings.border, "39m")
      assert String.contains?(t_rules.border, "220m")
      assert String.contains?(t_sessions.border, "177m")
      assert String.contains?(t_skills.border, "51m")
      assert String.contains?(t_analytics.border, "141m")
    end
  end

  describe "toggles and deletions" do
    test "toggles boolean setting in config tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      keys = Enum.sort(Map.keys(state.tree.config))
      god_idx = Enum.find_index(keys, &(&1 == "god_mode"))

      state = %{state | cursor: god_idx}
      updated_state = ConfigExplorer.handle_toggle(state)

      assert updated_state.tree.config["god_mode"] == true
    end

    test "clears errors in diagnostics tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = %{state | active_tab: :diagnostics}

      updated_state = ConfigExplorer.handle_delete(state)
      assert updated_state.tree.errors.count == 0
      assert File.read!(Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml")) == ""
    end

    test "deletes job log in jobs tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = %{state | active_tab: :jobs, tab_index: 4, cursor: 0}

      assert [_] = state.tree.jobs
      updated_state = ConfigExplorer.handle_delete(state)
      assert updated_state.tree.jobs == []
      refute File.exists?(Path.join(tmp_dir, ".yoke/jobs/job_101.log"))
    end

    test "deletes project skill in skills tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      skill_idx = Enum.find_index(state.tree.skills, &(&1.name == "custom_skill")) || 0
      state = %{state | active_tab: :skills, tab_index: 5, cursor: skill_idx}

      skill_dir = Path.join(tmp_dir, ".yoke/skills/custom_skill")
      assert File.exists?(skill_dir)

      updated_state = ConfigExplorer.handle_delete(state)
      refute File.exists?(skill_dir)
      assert updated_state.status_notice =~ "Deleted project skill"
    end

    test "clears bash analytics in analytics tab", %{tmp_dir: tmp_dir} do
      state = ConfigExplorer.new_state(tmp_dir)
      state = %{state | active_tab: :analytics, tab_index: 7, cursor: 0}

      updated_state = ConfigExplorer.handle_delete(state)
      assert updated_state.status_notice =~ "Cleared bash command analytics"
    end
  end

  describe "UTF-8 tolerance in diagnostics" do
    test "safely handles and renders ERRORS_TO_FIX.lmml containing invalid UTF-8 bytes", %{
      tmp_dir: tmp_dir
    } do
      # Write an invalid UTF-8 byte sequence like <<152>> (0x98) into ERRORS_TO_FIX.lmml
      invalid_entry =
        "<!-- error_entry -->\n## [2026-10-10 07:00:00] Level: error\nReason: invalid encoding starting at " <>
          <<152>> <> "\n```\n** (UnicodeConversionError) " <> <<152>> <> "\n```\n"

      File.write!(Path.join(tmp_dir, ".yoke/ERRORS_TO_FIX.lmml"), invalid_entry)

      # Rescan tree and load state
      state = ConfigExplorer.new_state(tmp_dir)
      assert state.tree.errors.count == 1
      entry = hd(state.tree.errors.entries)
      assert String.valid?(entry.title)
      assert String.valid?(entry.raw_entry)

      # Switch to Diagnostics tab (tab index 6)
      diag_state = %{state | active_tab: :diagnostics, tab_index: 6, cursor: 0}

      # Rendering full screen must not raise UnicodeConversionError
      output =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          ConfigExplorer.render_full_screen(diag_state)
        end)

      assert is_binary(output)
      assert String.valid?(output)
      assert output =~ "Diagnostics"

      # Also test detail view rendering
      detail_state = %{diag_state | view_mode: :detail}

      detail_output =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          ConfigExplorer.render_full_screen(detail_state)
        end)

      assert is_binary(detail_output)
      assert String.valid?(detail_output)
    end
  end
end

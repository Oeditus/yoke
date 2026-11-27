defmodule Yoke.BashTrackerTest do
  use ExUnit.Case, async: false

  alias Yoke.BashTracker

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "yoke_bash_tracker_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  test "normalizes simple, compound, and wrapped commands" do
    assert BashTracker.normalize_command("cat mix.exs") == {"cat", "cat"}
    assert BashTracker.normalize_command("grep -rn 'def' lib/") == {"grep", "grep"}
    assert BashTracker.normalize_command("git status") == {"git", "git status"}
    assert BashTracker.normalize_command("git diff HEAD~1") == {"git", "git diff"}
    assert BashTracker.normalize_command("mix test test/foo_test.exs") == {"mix", "mix test"}
    assert BashTracker.normalize_command("cargo build --release") == {"cargo", "cargo build"}
    assert BashTracker.normalize_command("sudo cat /etc/hosts") == {"cat", "cat"}
    assert BashTracker.normalize_command("MIX_ENV=test mix test") == {"mix", "mix test"}
  end

  test "identifies ineffective commands and pairs them with Ragex / tool analogs" do
    assert {:ok, grep_analog} = BashTracker.suggest_analog("grep -rn 'def' lib/")
    assert grep_analog.analog =~ "mcp_ragex_grep"
    assert grep_analog.category == :code_search

    assert {:ok, cat_analog} = BashTracker.suggest_analog("cat mix.exs")
    assert cat_analog.analog =~ "read_file" or cat_analog.analog =~ "mcp_ragex_view"

    assert {:ok, find_analog} = BashTracker.suggest_analog("find . -name '*.ex'")
    assert find_analog.analog =~ "list_dir" or find_analog.analog =~ "mcp_ragex_structure"

    assert {:ok, git_diff_analog} = BashTracker.suggest_analog("git diff HEAD~1")
    assert git_diff_analog.analog == "git_diff"

    # Legitimate fallback build/test commands have no analog
    assert BashTracker.suggest_analog("mix test") == nil
    assert BashTracker.suggest_analog("cargo build") == nil
    assert BashTracker.suggest_analog("echo 'hello'") == nil
  end

  test "records bash calls, calculates counts and frequencies, and persists to disk", %{
    tmp_dir: tmp_dir
  } do
    # Initial state
    initial_stats = BashTracker.stats(cwd: tmp_dir)
    assert initial_stats.total_calls == 0
    assert initial_stats.ineffective_calls == 0

    # Record 4 calls: 2 grep, 1 cat, 1 mix test
    {:ok, _} = BashTracker.record("grep -rn 'def' lib/", cwd: tmp_dir)
    {:ok, _} = BashTracker.record("grep -i 'foo' web/", cwd: tmp_dir)
    {:ok, _} = BashTracker.record("cat mix.exs", cwd: tmp_dir)
    {:ok, _} = BashTracker.record("mix test", cwd: tmp_dir)

    stats = BashTracker.stats(cwd: tmp_dir)

    assert stats.total_calls == 4
    assert stats.ineffective_calls == 3
    assert stats.ineffective_percentage == 75.0

    # Verify root command frequency calculations
    grep_entry = Enum.find(stats.root_commands, &(&1["name"] == "grep"))
    assert grep_entry["count"] == 2
    assert grep_entry["frequency"] == 0.5
    assert grep_entry["percentage"] == 50.0
    assert grep_entry["ineffective"] == true
    assert grep_entry["suggested_analog"] =~ "mcp_ragex_grep"

    mix_entry = Enum.find(stats.root_commands, &(&1["name"] == "mix test"))
    assert mix_entry["count"] == 1
    assert mix_entry["frequency"] == 0.25
    assert mix_entry["percentage"] == 25.0
    assert mix_entry["ineffective"] == false

    cat_entry = Enum.find(stats.root_commands, &(&1["name"] == "cat"))
    assert cat_entry["count"] == 1
    assert cat_entry["frequency"] == 0.25
    assert cat_entry["percentage"] == 25.0
    assert cat_entry["ineffective"] == true

    # Verify top ineffective list
    assert [_, _] = stats.top_ineffective
    assert hd(stats.top_ineffective)["name"] == "grep"

    # Verify file was written to disk
    store_file = Path.join(tmp_dir, ".yoke/bash_analytics.json")
    assert File.exists?(store_file)
    {:ok, content} = File.read(store_file)
    assert content =~ "grep"
    assert content =~ "mix test"
  end

  test "exports analytics report to .yoke/exports/", %{tmp_dir: tmp_dir} do
    {:ok, _} = BashTracker.record("grep -rn 'hello' .", cwd: tmp_dir)
    {:ok, _} = BashTracker.record("cat README.md", cwd: tmp_dir)

    {:ok, export_path} = BashTracker.export_analytics(cwd: tmp_dir)
    assert File.exists?(export_path)
    assert export_path =~ "bash_calls_"

    {:ok, json_str} = File.read(export_path)
    {:ok, data} = Yoke.Json.decode(json_str)

    assert data["total_calls"] == 2
    assert data["ineffective_calls"] == 2
    assert is_list(data["most_used_ineffective_calls"])
    assert is_list(data["root_commands_by_frequency"])
  end

  test "formats summary and clears analytics", %{tmp_dir: tmp_dir} do
    {:ok, _} = BashTracker.record("grep -rn 'hello' .", cwd: tmp_dir)

    summary = BashTracker.format_summary(cwd: tmp_dir)
    assert summary =~ "Total Bash Calls: 1"
    assert summary =~ "Better Ragex / Yoke Analog"

    assert :ok = BashTracker.clear(cwd: tmp_dir)
    cleared_stats = BashTracker.stats(cwd: tmp_dir)
    assert cleared_stats.total_calls == 0
  end

  describe "nil cwd tolerance" do
    # Callers pass `cwd: Map.get(args, "_session_cwd")`, which is `nil` when the
    # key is absent. `Keyword.get(opts, :cwd, default)` returns `nil` in that
    # case (the key *is* present), and `Path.join/2` then raised
    # `FunctionClauseError` inside the `BashTracker` GenServer. Because
    # `Yoke.Supervisor` uses `:one_for_all`, that crash tore down the entire
    # supervision tree -- including `Yoke.Brain.SessionSupervisor` -- so an
    # unrelated test running afterwards failed with `(EXIT) shutdown`.
    test "store_file_path/1 falls back to the process cwd for nil" do
      assert BashTracker.store_file_path(nil) == BashTracker.store_file_path(File.cwd!())
    end

    test "load/1 does not raise for nil" do
      assert is_map(BashTracker.load(nil))
    end

    test "record/2 does not crash the tracker when cwd is nil", %{tmp_dir: tmp_dir} do
      # Route through the GenServer (the crashing path) rather than the
      # direct helper, and assert the server survives. Under `--no-start` the
      # tracker is not running, so start it here; the point of the test is the
      # crash, not the supervision wiring.
      tracker = Process.whereis(BashTracker) || start_supervised!({BashTracker, cwd: tmp_dir})
      original = :sys.get_state(tracker)

      :sys.replace_state(tracker, fn _ ->
        %{analytics: BashTracker.load(tmp_dir), cwd: tmp_dir}
      end)

      on_exit(fn ->
        if Process.alive?(tracker), do: :sys.replace_state(tracker, fn _ -> original end)
      end)

      assert {:ok, _} = BashTracker.record("sleep 1", cwd: nil, session_id: nil, async: false)
      assert Process.whereis(BashTracker) == tracker
      assert BashTracker.stats(cwd: tmp_dir).total_calls == 1
    end
  end

  describe "cd-prefixed normalization and check_bash_policy/2" do
    test "normalize_command/1 unwraps leading cd && prefix" do
      assert BashTracker.normalize_command(
               "cd /home/am/Proyectos/cure-lang && sed -n '7868,7930p' lib/cure/compiler/parser.ex"
             ) == {"sed", "sed"}

      assert BashTracker.normalize_command("cd /tmp && mix test") == {"mix", "mix test"}
    end

    test "blocks sed -n with cd prefix and suggests exact read_file line range" do
      cmd = "cd /home/am/Proyectos/cure-lang && sed -n '7868,7930p' lib/cure/compiler/parser.ex"

      assert {:block, info} = BashTracker.check_bash_policy(cmd)
      assert info.command == "sed"
      assert info.category == :file_read
      assert info.message =~ "[Bash Guard] Refused shell command 'sed'"
      assert info.message =~ "read_file"
      assert info.message =~ "/home/am/Proyectos/cure-lang/lib/cure/compiler/parser.ex"
      assert info.message =~ "start_line: 7868"
      assert info.message =~ "end_line: 7930"
    end

    test "blocks raw file-exploration commands (cat, grep, rg, find, ls, head, tail, awk)" do
      for cmd <- [
            "cat mix.exs",
            "head -n 20 lib/yoke.ex",
            "tail -n 20 lib/yoke.ex",
            "grep -rn 'def ' lib/",
            "rg 'foo|bar' lib/",
            "find . -name '*.ex'",
            "ls -la lib/",
            "cd /proj && awk '{print $1}' mix.exs"
          ] do
        assert {:block, info} = BashTracker.check_bash_policy(cmd),
               "expected #{inspect(cmd)} to be blocked"

        assert info.message =~ "[Bash Guard]"
      end
    end

    test "allows legitimate build/test commands including pipelines into grep/tail/head" do
      for cmd <- [
            "mix test",
            "cd /home/am/Proyectos/cure-lang && mix test",
            "mix test 2>&1 | tail -n 30",
            "mix compile 2>&1 | grep -i warning",
            "cargo build --release | head -n 50",
            "git log -n 5 --oneline",
            "echo 'hello'"
          ] do
        assert :allow == BashTracker.check_bash_policy(cmd),
               "expected #{inspect(cmd)} to be allowed"
      end
    end

    test "DefaultTools.execute_bash/1 enforces the guard by default and respects opt-out", %{
      tmp_dir: tmp_dir
    } do
      cmd = "cd /home/am/Proyectos/cure-lang && sed -n '7868,7930p' lib/cure/compiler/parser.ex"

      assert {:error, msg} =
               Yoke.Plugin.DefaultTools.execute_bash(%{
                 "command" => cmd,
                 "_session_cwd" => tmp_dir
               })

      assert msg =~ "[Bash Guard] Refused shell command 'sed'"
      assert msg =~ "start_line: 7868"

      # Opt-out via application env allows execution (using a harmless command)
      Application.put_env(:yoke, :enforce_bash_analogs, false)

      on_exit(fn -> Application.delete_env(:yoke, :enforce_bash_analogs) end)

      assert {:ok, _} =
               Yoke.Plugin.DefaultTools.execute_bash(%{
                 "command" => "ls #{tmp_dir}",
                 "_session_cwd" => tmp_dir
               })
    end
  end
end

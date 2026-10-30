defmodule Yoke.TaskEngine.JobManagerTest do
  use ExUnit.Case, async: false

  alias Yoke.Plugin.DefaultTools
  alias Yoke.TaskEngine.JobManager

  setup do
    JobManager.ensure_started()
    JobManager.kill_all_jobs()
    on_exit(fn -> JobManager.kill_all_jobs() end)
    :ok
  end

  test "starts background job, checks status, and reads output log" do
    assert {:ok, job_id, log_file} = JobManager.start_job("echo 'hello world'")
    assert is_binary(job_id)
    assert File.exists?(log_file)

    # Wait briefly for process completion
    Process.sleep(200)

    assert {:ok, output} = JobManager.get_job_status(job_id)
    assert output =~ "Job '#{job_id}'"
    assert output =~ "hello world"
  end

  test "sends completion notification to notify_pid when job finishes" do
    assert {:ok, job_id, _log_file} =
             JobManager.start_job("echo 'notified completion'", notify_pid: self())

    assert_receive {:job_completed, ^job_id, "echo 'notified completion'", {:exited, 0},
                    log_tail},
                   2000

    assert log_tail =~ "notified completion"
  end

  test "sends completion notification to session_id via Yoke.Registry when job finishes" do
    fake_sid = "test_sess_#{System.unique_integer([:positive])}"
    Registry.register(Yoke.Registry, "session_" <> fake_sid, nil)

    assert {:ok, job_id, _log_file} =
             JobManager.start_job("echo 'session notified'", session_id: fake_sid)

    assert_receive {:job_completed, ^job_id, "echo 'session notified'", {:exited, 0}, log_tail},
                   2000

    assert log_tail =~ "session notified"
  end

  test "bash tool executes asynchronously when async: true is passed" do
    assert {:ok, msg} =
             DefaultTools.execute_bash(%{"command" => "echo 'async job test'", "async" => true})

    assert msg =~ "Started background job"
    assert msg =~ "job_"

    # Extract job_id
    [[job_id | _] | _] = Regex.scan(~r/job_\d+/, msg)

    Process.sleep(200)

    assert {:ok, status_out} = DefaultTools.job_status_tool(%{"job_id" => job_id})
    assert status_out =~ "async job test"
  end

  test "can terminate background job via job_kill" do
    assert {:ok, job_id, _log} = JobManager.start_job("sleep 10")

    assert {:ok, kill_msg} = DefaultTools.job_kill_tool(%{"job_id" => job_id})
    assert kill_msg =~ "Killed background job"

    assert {:ok, status_out} = JobManager.get_job_status(job_id)
    assert status_out =~ "KILLED"
  end

  test "await_all/1 returns promptly once a running job finishes on its own" do
    assert {:ok, job_id, _log} = JobManager.start_job("sleep 0.2")

    assert JobManager.running_jobs() |> Enum.any?(&(&1.id == job_id))

    assert :ok = JobManager.await_all(5_000)
    refute JobManager.running_jobs() |> Enum.any?(&(&1.id == job_id))
  end

  test "kill_all_jobs/0 kills all currently running background jobs" do
    assert {:ok, job_1, _} = JobManager.start_job("sleep 10")
    assert {:ok, job_2, _} = JobManager.start_job("sleep 10")

    running_ids = JobManager.running_jobs() |> Enum.map(& &1.id)
    assert job_1 in running_ids
    assert job_2 in running_ids

    assert {:ok, count} = JobManager.kill_all_jobs()
    assert count >= 2

    assert {:ok, s1} = JobManager.get_job_status(job_1)
    assert {:ok, s2} = JobManager.get_job_status(job_2)
    assert s1 =~ "KILLED"
    assert s2 =~ "KILLED"

    running_after = JobManager.running_jobs() |> Enum.map(& &1.id)
    refute job_1 in running_after
    refute job_2 in running_after
  end

  @tag tmp_dir: true
  test "status line ruler updates and properly redraws showing 1 job less when a job finishes", %{
    tmp_dir: tmp_dir
  } do
    alias Yoke.CLI.LineEditor
    alias Yoke.CLI.TerminalOwner
    on_exit(fn -> TerminalOwner.clear() end)
    JobManager.kill_all_jobs()

    # Keep both jobs running until the test explicitly releases each FIFO.
    gate_1 = Path.join(tmp_dir, "job_1.fifo")
    gate_2 = Path.join(tmp_dir, "job_2.fifo")
    assert {_, 0} = System.cmd("mkfifo", [gate_1, gate_2])

    assert {:ok, job_1, _} =
             JobManager.start_job("read line < #{inspect(gate_1)}",
               notify_pid: self(),
               cwd: tmp_dir
             )

    assert {:ok, job_2, _} =
             JobManager.start_job("read line < #{inspect(gate_2)}",
               notify_pid: self(),
               cwd: tmp_dir
             )

    # Verify ruler shows 2 running jobs
    ruler_2 = LineEditor.ruler_line()
    assert ruler_2 =~ "2 running"

    # Register a mock foreground surface in TerminalOwner to track redrawing
    test_pid = self()

    TerminalOwner.set(
      fn state -> send(test_pid, {:erased, state}) end,
      fn state -> send(test_pid, {:redrawn, state, LineEditor.ruler_line()}) end,
      %{custom: :state}
    )

    File.write!(gate_1, "finish\n")
    assert_receive {:job_completed, ^job_1, _command, {:exited, 0}, _log_tail}, 2_000

    # Validate that TerminalOwner was triggered to redraw upon job completion
    assert_receive {:redrawn, %{custom: :state}, redrawn_ruler}, 2_000
    assert redrawn_ruler =~ "1 running"
    refute redrawn_ruler =~ "2 running"

    # Check live ruler_line now shows 1 running job (1 job less!)
    ruler_1 = LineEditor.ruler_line()
    assert ruler_1 =~ "1 running"
    refute ruler_1 =~ "2 running"

    File.write!(gate_2, "finish\n")
    assert_receive {:job_completed, ^job_2, _command, {:exited, 0}, _log_tail}, 2_000

    # Live ruler should now show 0 running jobs (idle status bar, no running badge)
    ruler_0 = LineEditor.ruler_line()
    refute ruler_0 =~ "running"
  end

  test "read_file supports start_line and end_line parameters" do
    tmp_path = Path.join(System.tmp_dir!(), "line_test_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "line 1\nline 2\nline 3\nline 4\nline 5\n")

    assert {:ok, content} =
             DefaultTools.read_file(%{"path" => tmp_path, "start_line" => 2, "end_line" => 4})

    assert content =~ "=== Lines 2-4 of"
    assert content =~ "2: line 2"
    assert content =~ "3: line 3"
    assert content =~ "4: line 4"
    refute content =~ "1: line 1"
    refute content =~ "5: line 5"
  end

  test "grep_search tool searches files for matching pattern" do
    tmp_dir = Path.join(System.tmp_dir!(), "grep_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    file_a = Path.join(tmp_dir, "a.txt")
    File.write!(file_a, "apple\nbanana\ncherry\n")

    assert {:ok, result} =
             DefaultTools.grep_search_tool(%{"path" => tmp_dir, "query" => "banana"})

    assert result =~ "banana"
    assert result =~ "a.txt:2:"
  end

  test "prepare_environment auto-loads user toolchain paths and VIPS_UNBLOCK" do
    {env, _cmd} = JobManager.prepare_environment("mix compile")
    env_map = Enum.into(env, %{})
    assert is_binary(env_map["PATH"])
    assert env_map["VIPS_UNBLOCK"] == "svgload,svgload_buffer,svgload_stream"

    user_home = Yoke.Hands.Environment.user_home()
    asdf_shims = Path.join(user_home, ".asdf/shims")

    if File.dir?(asdf_shims) do
      assert String.contains?(env_map["PATH"], asdf_shims)
    end
  end
end

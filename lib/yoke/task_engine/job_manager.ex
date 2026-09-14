defmodule Yoke.TaskEngine.JobManager do
  @moduledoc """
  Manages asynchronous background jobs started via `bash(command: "...", async: true)`.

  Executes background shell processes without blocking the agent turn loop,
  captures stdout/stderr to disk (`.yoke/jobs/<id>.log`), surfaces active jobs in
  `PackageTracker` (status bar & spinner), and allows `job_status` / `job_kill`
  tool calls to check output logs, exit codes, and terminate running jobs.
  """
  use Agent

  alias Yoke.TaskEngine.PackageTracker

  @doc "Starts the singleton JobManager agent."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Ensures the JobManager process is running."
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          _ -> nil
        end

      pid ->
        pid
    end
  end

  @doc """
  Starts a bash command in the background, logging stdout/stderr to `.yoke/jobs/<id>.log`.
  """
  def start_job(command, opts \\ []) when is_binary(command) do
    ensure_started()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    id = "job_#{System.unique_integer([:positive])}"
    jobs_dir = Path.join(cwd, ".yoke/jobs")
    File.mkdir_p!(jobs_dir)
    log_file = Path.join(jobs_dir, "#{id}.log")

    # Clear previous log file if exists
    File.write!(log_file, "")

    started_at = System.system_time(:second)
    label = PackageTracker.derive_label(command)

    {env, exec_cmd} = prepare_environment(command)

    # Monitor task completion asynchronously to record exit status.
    # Spawning Task.Supervisor.async_nolink INSIDE the Task.start process ensures
    # the monitor process is the owner of `task`, avoiding Task ownership ArgumentErrors
    # when calling Task.yield/2.
    {:ok, monitor_pid} =
      Task.start(fn ->
        task =
          Task.Supervisor.async_nolink(
            Yoke.TaskEngine.TaskSupervisor,
            fn ->
              # Register in PackageTracker under worker task
              PackageTracker.register("[job] #{label}", :job, id: id)

              try do
                case System.cmd("sh", ["-c", exec_cmd],
                       cd: cwd,
                       env: env,
                       stderr_to_stdout: true,
                       into: File.stream!(log_file, [:append])
                     ) do
                  {_, 0} -> :ok
                  {_, code} -> {:error, code}
                end
              rescue
                e -> {:error, Exception.message(e)}
              after
                PackageTracker.unregister()
              end
            end
          )

        # Update job entry with worker pid and task
        Agent.update(__MODULE__, fn state ->
          case Map.get(state, id) do
            nil -> state
            info -> Map.put(state, id, %{info | task: task, worker_pid: task.pid})
          end
        end)

        res =
          case Task.yield(task, :infinity) do
            {:ok, :ok} -> {:exited, 0}
            {:ok, {:error, code}} when is_integer(code) -> {:exited, code}
            {:ok, {:error, msg}} -> {:failed, msg}
            {:exit, _reason} -> {:exited, -1}
            nil -> {:exited, -1}
          end

        finished_at = System.system_time(:second)

        Agent.update(__MODULE__, fn state ->
          case Map.get(state, id) do
            nil ->
              state

            info ->
              if info.status == :running do
                updated =
                  case res do
                    {:exited, code} ->
                      %{info | status: :finished, exit_code: code, finished_at: finished_at}

                    {:failed, msg} ->
                      %{info | status: :failed, exit_code: msg, finished_at: finished_at}
                  end

                Map.put(state, id, updated)
              else
                state
              end
          end
        end)
      end)

    job_info = %{
      id: id,
      command: command,
      started_at: started_at,
      finished_at: nil,
      status: :running,
      exit_code: nil,
      log_file: log_file,
      task: nil,
      worker_pid: nil,
      monitor_pid: monitor_pid
    }

    Agent.update(__MODULE__, &Map.put(&1, id, job_info))

    {:ok, id, log_file}
  end

  @doc "Retrieves job info and recent log output for a given job ID."
  def get_job_status(job_id, opts \\ []) when is_binary(job_id) do
    ensure_started()
    tail = Keyword.get(opts, :tail, 30)

    case Agent.get(__MODULE__, &Map.get(&1, job_id)) do
      nil ->
        {:error, "No job found with ID '#{job_id}'."}

      info ->
        now = System.system_time(:second)

        elapsed =
          if info.finished_at do
            info.finished_at - info.started_at
          else
            now - info.started_at
          end

        status_str =
          case info.status do
            :running -> "RUNNING (#{elapsed}s elapsed)"
            :finished when info.exit_code == 0 -> "FINISHED (exit code 0, took #{elapsed}s)"
            :finished -> "FAILED (exit code #{info.exit_code}, took #{elapsed}s)"
            :failed -> "FAILED (#{info.exit_code}, took #{elapsed}s)"
            :killed -> "KILLED (took #{elapsed}s)"
          end

        log_lines =
          if File.exists?(info.log_file) do
            info.log_file
            |> File.read!()
            |> String.split(~r/\r?\n/)
            |> Enum.reject(&(&1 == ""))
            |> Enum.take(-tail)
            |> Enum.join("\n")
          else
            "(no output yet)"
          end

        output = """
        === Background Job '#{job_id}' [#{status_str}] ===
        Command: #{info.command}
        Log file: #{info.log_file}

        Recent log output (last #{tail} lines):
        #{if log_lines == "", do: "(empty)", else: log_lines}
        """

        {:ok, output}
    end
  end

  @doc "Kills a running background job."
  def kill_job(job_id) when is_binary(job_id) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, job_id)) do
      nil ->
        {:error, "No job found with ID '#{job_id}'."}

      %{status: :running} = info ->
        if info.worker_pid do
          Task.Supervisor.terminate_child(Yoke.TaskEngine.TaskSupervisor, info.worker_pid)
        end

        now = System.system_time(:second)

        Agent.update(__MODULE__, fn state ->
          Map.put(state, job_id, %{info | status: :killed, finished_at: now})
        end)

        {:ok, "Killed background job '#{job_id}'."}

      _ ->
        {:ok, "Job '#{job_id}' is not currently running."}
    end
  end

  @doc "Lists all tracked background jobs."
  def list_jobs do
    ensure_started()
    Agent.get(__MODULE__, &Map.values/1)
  end

  # Automatically injects user toolchain paths into PATH / env if present
  def prepare_environment(command) do
    user_home = System.user_home() || System.get_env("HOME") || "/home/am"

    asdf_shims = Path.join(user_home, ".asdf/shims")
    asdf_bin = Path.join(user_home, ".asdf/bin")
    cargo_bin = Path.join(user_home, ".cargo/bin")
    local_bin = Path.join(user_home, ".local/bin")

    current_path = System.get_env("PATH") || "/usr/bin:/bin"

    extra_paths =
      [asdf_shims, asdf_bin, cargo_bin, local_bin]
      |> Enum.filter(&File.dir?/1)

    updated_path = Enum.join(extra_paths ++ [current_path], ":")

    extra_env = %{
      "PATH" => updated_path,
      "VIPS_UNBLOCK" => "svgload,svgload_buffer,svgload_stream"
    }

    extra_env =
      if System.get_env("ERL_HOME") == nil do
        erl_dir = Path.join(user_home, ".asdf/installs/erlang")

        case File.ls(erl_dir) do
          {:ok, versions} when is_list(versions) and versions != [] ->
            first = Enum.sort(versions) |> List.last()
            Map.put(extra_env, "ERL_HOME", Path.join(erl_dir, first))

          _ ->
            extra_env
        end
      else
        extra_env
      end

    scrubbed_env = Yoke.Hands.Environment.build(File.cwd!(), extra_env)

    {scrubbed_env, command}
  end
end

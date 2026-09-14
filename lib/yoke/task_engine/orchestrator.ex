defmodule Yoke.TaskEngine.Orchestrator do
  @moduledoc """
  Main orchestrator process for executing tool call batches concurrently.
  Spawns worker subprocesses under TaskEngine.TaskSupervisor, manages resource locking
  via TaskEngine.LockRegistry, handles timeouts, and aggregates results.
  """
  alias Yoke.Hands.Executor, as: HandsExecutor
  alias Yoke.TaskEngine.TaskSupervisor

  @doc """
  Executes a list of tool call structs concurrently in separate processes.
  Returns a list of tuples `{tool_call, execution_result}` in original order.
  """
  def execute_batch(tool_calls, session_state, opts \\ []) when is_list(tool_calls) do
    timeout = opts[:timeout] || 60_000

    # Pair each tool call with an index to preserve original order
    indexed_calls = Enum.with_index(tool_calls)

    tasks =
      Enum.map(indexed_calls, fn {tc, idx} ->
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            result = run_single_tool(tc, session_state)
            {idx, tc, result}
          end)

        {task, idx, tc}
      end)

    # Interactive tools (currently just `ask_question`) block on a live
    # human answering a TTY modal, which can legitimately take far longer
    # than the batch's tool-execution timeout -- there is no "too slow"
    # for a person reading and deciding. Cutting them off with the same
    # timeout as `bash`/`read_file`/etc. would silently discard the
    # question and fabricate a timeout error the model never asked for.
    # Splitting them out and awaiting them with `:infinity` guarantees the
    # *only* way such a call ever resolves is the user's own answer (or an
    # explicit in-modal cancel via Ctrl+C) -- never a wall-clock expiry.
    {interactive, timed} =
      Enum.split_with(tasks, fn {_task, _idx, tc} -> interactive_tool?(tc.name) end)

    timed_structs = Enum.map(timed, fn {task, _idx, _tc} -> task end)

    yielded_map =
      timed_structs
      |> Task.yield_many(timeout)
      |> Enum.into(%{})

    timed_results =
      Enum.map(timed, fn {task, idx, tc} ->
        res =
          case Map.get(yielded_map, task) do
            {:ok, {_idx, _tc, exec_result}} ->
              exec_result

            nil ->
              Task.shutdown(task, :brutal_kill)
              {:error, "Tool execution timed out after #{timeout}ms"}

            {:exit, reason} ->
              {:error, "Tool process crashed: #{inspect(reason)}"}
          end

        {idx, tc, res}
      end)

    interactive_results =
      Enum.map(interactive, fn {task, idx, tc} ->
        res =
          case Task.yield(task, :infinity) || Task.shutdown(task, :brutal_kill) do
            {:ok, {_idx, _tc, exec_result}} -> exec_result
            {:exit, reason} -> {:error, "Tool process crashed: #{inspect(reason)}"}
            nil -> {:error, "Tool execution failed unexpectedly"}
          end

        {idx, tc, res}
      end)

    (timed_results ++ interactive_results)
    |> Enum.sort_by(fn {idx, _tc, _res} -> idx end)
    |> Enum.map(fn {_idx, tc, res} -> {tc, res} end)
  end

  @doc false
  def interactive_tool?("ask_question"), do: true
  def interactive_tool?("run_workflow"), do: true
  # `spawn_subagent(async: false)` blocks on a full nested agentic turn
  # (its own multi-step tool-calling loop), which can easily run past the
  # standard tool-execution timeout -- give it the same unbounded await as
  # the other long-running tools rather than risk `Task.shutdown/2`
  # brutally killing a subagent that is still legitimately working.
  # `spawn_subagent(async: true)` (the default) returns almost immediately
  # regardless, so this is harmless in that case.
  def interactive_tool?("spawn_subagent"), do: true
  def interactive_tool?(_), do: false

  defp run_single_tool(tc, session_state) do
    summary = format_short_summary(tc.name, tc.arguments)

    task_info = %{
      id: tc.id,
      name: tc.name,
      summary: summary,
      started_at: System.system_time(:second)
    }

    # Register task for real-time tracking while process is alive
    Registry.register(Yoke.TaskEngine.TaskRegistry, "active_task", task_info)

    lock_key = get_lock_resource(tc.name, tc.arguments)

    if lock_key do
      acquire_lock(lock_key)
    end

    try do
      HandsExecutor.execute(session_state.hands, tc.name, effective_arguments(tc, session_state))
    after
      if lock_key do
        release_lock(lock_key)
      end
    end
  end

  # `spawn_subagent` needs to identify and report back to the session it
  # was invoked from, without the model ever having to know or supply that
  # PID/id itself (it isn't declared in the tool's own parameter schema in
  # `DefaultTools.tools/0`). Inject it here, server-side, as underscore-
  # prefixed "private" arguments -- `HandsExecutor.format_tool_call/2`
  # hides any such key from the tool-call summary line so this never leaks
  # into what the user sees echoed for the call.
  defp effective_arguments(%{name: "spawn_subagent", arguments: args}, session_state) do
    sid = if is_map(session_state), do: Map.get(session_state, :session_id)
    model = if is_map(session_state), do: Map.get(session_state, :model)
    cwd = if is_map(session_state), do: Map.get(session_state, :cwd)

    args
    |> Map.put("_session_id", sid)
    |> Map.put("_session_model", model)
    |> Map.put("_session_cwd", cwd)
  end

  defp effective_arguments(%{arguments: args}, session_state) do
    sid = if is_map(session_state), do: Map.get(session_state, :session_id)
    cwd = if is_map(session_state), do: Map.get(session_state, :cwd)

    args
    |> Map.put("_session_id", sid)
    |> Map.put("_session_cwd", cwd)
  end

  @doc "Formats a short human-readable summary of a tool call for real-time status display."
  def format_short_summary(tool_name, args) when is_map(args) do
    target =
      Map.get(args, "target_file") ||
        Map.get(args, "path") ||
        Map.get(args, "TargetFile") ||
        Map.get(args, "query") ||
        Map.get(args, "command") ||
        ""

    # `read_files` takes a list of paths; summarize the first few so the
    # status badge doesn't balloon to the full list.
    target =
      if target == "" and is_list(args["paths"]) do
        case args["paths"] do
          [] -> ""
          [single] -> single
          [first | rest] -> "#{first} (+#{length(rest)})"
        end
      else
        target
      end

    cleaned_target =
      target
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.trim()

    truncated =
      if String.length(cleaned_target) > 25 do
        String.slice(cleaned_target, 0, 22) <> "..."
      else
        cleaned_target
      end

    if truncated != "" do
      "#{tool_name}(\"#{truncated}\")"
    else
      tool_name
    end
  end

  def format_short_summary(tool_name, _), do: tool_name

  # The model can emit more than one `ask_question` tool call in a single
  # turn (e.g. one per question, instead of batching them into a single
  # call's `questions` list). Since `Yoke.CLI.QuestionPrompt`
  # reads raw keystrokes directly from `:user`, running two of its modals
  # concurrently would let a keystroke intended for one resolve the other
  # instead. A fixed lock key -- shared across every `ask_question` call
  # regardless of arguments -- guarantees only one such modal ever holds
  # the terminal at a time; additional calls simply wait (before ever
  # touching the TTY) until the current one fully returns.
  @doc false
  def get_lock_resource("ask_question", _args), do: "tty_interactive"

  # `run_workflow` runs a full multi-step workflow, which can itself pause
  # for interactive `ask_question`-style confirmations (branch warnings,
  # split-plan approval) -- give it the same exclusive TTY lock as
  # `ask_question` so it can never race a concurrently-dispatched
  # `ask_question` tool call for the terminal.
  def get_lock_resource("run_workflow", _args), do: "tty_interactive"

  def get_lock_resource(tool_name, args) when is_map(args) do
    if tool_name in ["write_file", "replace_file", "write_to_file", "replace_file_content"] do
      path = Map.get(args, "target_file") || Map.get(args, "path") || Map.get(args, "TargetFile")
      if is_binary(path), do: "file_lock:" <> Path.expand(path)
    else
      nil
    end
  end

  def get_lock_resource(_, _), do: nil

  defp acquire_lock(resource_key) when is_binary(resource_key) do
    case Registry.register(Yoke.TaskEngine.LockRegistry, resource_key, :locked) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        Process.sleep(10)
        acquire_lock(resource_key)
    end
  end

  defp release_lock(resource_key) when is_binary(resource_key) do
    Registry.unregister(Yoke.TaskEngine.LockRegistry, resource_key)
  rescue
    _ -> :ok
  end
end

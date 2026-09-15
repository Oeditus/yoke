defmodule Yoke.Brain.Session do
  @moduledoc """
  The "Brain" actor of Yoke.
  Manages agentic session state, temporal context checkpoints, conversation memory,
  subagent spawning, project rules, context expansion, permission authorization gates,
  and execution loops.
  """
  use GenServer
  require Logger

  alias Yoke.Brain.AgentLoop
  alias Yoke.Brain.ContextCompressor
  alias Yoke.Brain.SessionStore
  alias Yoke.CLI.ContextExpander
  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Config
  alias Yoke.Hands.Executor, as: HandsExecutor
  alias Yoke.PlanGate
  alias Yoke.Plugin.Loader, as: PluginLoader
  alias Yoke.TaskEngine.TaskSupervisor
  alias Yoke.Workflow.Plan, as: WorkflowPlan

  @default_system_prompt """
  You are an expert agentic AI coding assistant powered by DeepSeek.
  You have access to tools for file operations, bash execution, skills, MCP servers (including Ragex code intelligence), Elixir evaluation, and interactive user questions (ask_question tool).

  PARALLEL EXECUTION IS OUR VIRTUE & CORE STRENGTH:
  - You can and MUST spawn processes and execute tasks and tools in parallel whenever possible!
  - When inspecting, searching, reading, or editing multiple files, ALWAYS emit multiple tool calls in parallel in a single response turn rather than sequentially across multiple turns.
  - To read several files at once, use the `read_files` tool (pass a `paths` list) instead of issuing multiple `read_file` calls -- it reads them all concurrently in a single tool call.
  - When breaking down complex or multi-step work, use `spawn_subagent` (with `async: true`) to spawn independent sub-agent worker processes that execute concurrently in parallel. NEVER use `sleep` or polling loops (`sleep 60 && ...`) -- spawned tasks and subagents run as asynchronous OTP worker processes and notify this session via native Erlang messages when complete.
  - Parallel process execution is fully backed by the Erlang/Elixir BEAM actor model for maximum speed and concurrent throughput. Always leverage maximum parallelism!
  - Always report how many BEAM processes are currently serving when summarizing system status or turn execution.

  Tool Selection Guidelines:
  - EFFICIENT COMMAND EXECUTION & DEDICATED TOOLS:
    - For long-running build or test commands (`mix compile`, `mix test`, `cargo build`), use `bash(command: "...", async: true)` to run the command asynchronously in the background. The job runs as an OTP background worker process and will automatically send a completion message to this session when finished. NEVER poll `job_status` or execute bash polling commands (`pgrep`, `sleep`, `tail` loops) to wait for completion -- continue with other work or end your turn.
    - User environment toolchains (`~/.asdf/shims`, `~/.cargo/bin`, `ERL_HOME`) are automatically loaded into `bash` -- NEVER issue exploratory bash loops (`which erl`, `env | grep ...`, `cat ~/.asdf/...`) to locate binaries.
    - NEVER use raw `bash` commands (`cat`, `head`, `tail`, `sed`, `grep`) for file reading or code searching. Use `read_file` (with `start_line`/`end_line` for line ranges), `read_files`, `grep_search`, or Ragex tools instead.
    - Use dedicated git tools (`git_status`, `git_diff`, `git_commit`, `git_root`) instead of executing raw shell git commands.
  - STRICT TOOL PREFERENCE (RAGEX CODE INTELLIGENCE FIRST):
    - You MUST ALWAYS prefer and use Ragex MCP tools (`mcp_ragex_grep`, `mcp_ragex_search_code`, `mcp_ragex_symbol_definition`, `mcp_ragex_symbol_references`, `mcp_ragex_metaast_search`, `mcp_ragex_ast_search`, `mcp_ragex_structure`, `mcp_ragex_view`, `mcp_ragex_analyze_file`) for code searching, symbol lookup, reference tracking, AST pattern queries, directory structure analysis, and file viewing.
    - Use `bash` ONLY for executing build/test commands, running local binaries/scripts, or system operations where no suitable dedicated tool exists.
  - ALWAYS use Ragex image tools (`mcp_ragex_image_info`, `mcp_ragex_image_resize`, `mcp_ragex_image_crop`, `mcp_ragex_image_rotate`, `mcp_ragex_image_convert`, `mcp_ragex_image_apply_filter`, `mcp_ragex_image_composite`, `mcp_ragex_image_avatar`, `mcp_ragex_image_draw_text`, `mcp_ragex_image_compare`) whenever you need to inspect, resize, crop, convert, filter, composite, or compare images, instead of writing custom scripts or executing raw shell commands.
  - When calling Ragex's `mcp_ragex_edit_file` / `mcp_ragex_edit_files` tools, ALWAYS include `old_content` on every change entry, even though the schema marks it optional: the exact original text of the lines at `line_start`..`line_end` as you last observed them (from a prior `read_file`/view of that file). Ragex uses `old_content` to verify and, if line numbers drifted since your last read, auto-relocate the correct target lines before applying the edit. Omitting it means a stale or off-by-a-few-lines guess can silently clip or duplicate block keywords (e.g. `def`, `do`, `end`) and break the file's syntax. Never fabricate `old_content` from guessed line numbers -- only supply text you actually saw.
  - Break down tasks systematically, reason carefully, and invoke tools in parallel when needed.
  - If requirements are underspecified, design choices need feedback, or confirmation is helpful, use the `ask_question` tool to present structured choices to the user.
  """

  # Client API

  def start_link(opts \\ []) do
    session_id = opts[:session_id] || "default"
    name = via_tuple(session_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def via_tuple(session_id) do
    {:via, Registry, {Yoke.Registry, "session_" <> session_id}}
  end

  @doc "Sends a user prompt to the session actor, expanding @ references."
  def send_user_message(pid, text) do
    GenServer.call(pid, {:send_user_message, text}, :infinity)
  end

  @doc """
  Cancels the session's currently in-flight agent turn (started by
  `send_user_message/2` or `generate_code_review/3`), if any.

  Forcibly stops the turn's background Task -- aborting the in-progress
  DeepSeek API request or tool execution wherever it happens to be -- and
  makes whichever caller is *currently blocked inside that original call*
  receive `{:error, "Turn cancelled by user (Ctrl+Q)."}` immediately. The
  session actor itself is never killed: conversation history up to (but
  not including) the interrupted turn's own messages is preserved intact,
  so the user can simply try again.

  This is a fast, always-responsive call -- bounded by the session actor's
  own mailbox, not by however long the turn being cancelled might
  otherwise run -- because this actor no longer blocks its own mailbox
  while a turn's agent loop is running. See `start_agent_turn/2`.
  """
  def cancel_current_turn(pid) do
    GenServer.call(pid, :cancel_current_turn, 5_000)
  catch
    :exit, _ -> {:error, "Session process unavailable; nothing to cancel."}
  end

  @doc "Gets the active model for the session."
  def get_model(pid) do
    GenServer.call(pid, :get_model, :infinity)
  end

  @doc "Gets the API endpoint URL for the session."
  def get_endpoint(pid) do
    GenServer.call(pid, :get_endpoint, :infinity)
  end

  @doc "Sets the DeepSeek model ('deepseek-chat' or 'deepseek-reasoner')."
  def set_model(pid, model) do
    GenServer.call(pid, {:set_model, model}, :infinity)
  end

  @doc "Sets the API endpoint URL for the session."
  def set_endpoint(pid, endpoint) do
    GenServer.call(pid, {:set_endpoint, endpoint}, :infinity)
  end

  @doc "Sets permission mode (:auto_approve | :ask_confirm)."
  def set_permission_mode(pid, mode) do
    GenServer.call(pid, {:set_permission_mode, mode}, :infinity)
  end

  @doc "Configures the Hands execution mode (:local, :remote, :docker)."
  def set_hands_mode(pid, mode, target \\ nil) do
    GenServer.call(pid, {:set_hands_mode, mode, target}, :infinity)
  end

  @doc "Compresses context history (/compact)."
  def compact_context(pid) do
    GenServer.call(pid, :compact_context, :infinity)
  end

  @doc "Resets session state, clearing conversation history, context tokens, checkpoints, and persisted state."
  def reset(pid) do
    GenServer.call(pid, :reset, :infinity)
  end

  @doc "Creates a temporal state snapshot (checkpoint)."
  def checkpoint(pid, label \\ nil) do
    GenServer.call(pid, {:checkpoint, label}, :infinity)
  end

  @doc "Rolls back session state to previous checkpoint."
  def undo(pid) do
    GenServer.call(pid, :undo, :infinity)
  end

  @doc "Spawns a subagent session actor for sub-task execution."
  def spawn_subagent(pid, prompt, opts \\ []) do
    GenServer.call(pid, {:spawn_subagent, prompt, opts}, :infinity)
  end

  @doc "Generates a comprehensive Code Review comparing two git branches."
  def generate_code_review(pid, base_branch, head_branch \\ "HEAD") do
    GenServer.call(pid, {:generate_code_review, base_branch, head_branch}, :infinity)
  end

  @doc "Returns token stats and session cost estimate."
  def get_token_stats(pid) do
    GenServer.call(pid, :get_token_stats, :infinity)
  end

  @doc "Returns current session summary and statistics."
  def get_info(pid) do
    GenServer.call(pid, :get_info, :infinity)
  end

  @doc "Returns content of the latest assistant message response in session."
  def get_latest_response(pid) do
    GenServer.call(pid, :get_latest_response, :infinity)
  end

  @doc "Toggles workspace sandbox bounds mode."
  def set_sandbox_mode(pid, enabled) do
    GenServer.call(pid, {:set_sandbox_mode, enabled}, :infinity)
  end

  @doc "Returns comprehensive session analytics and statistics dashboard metrics."
  def get_stats(pid) do
    GenServer.call(pid, :get_stats, :infinity)
  end

  @doc "Returns per-turn token usage breakdown."
  def get_turn_tokens(pid) do
    GenServer.call(pid, :get_turn_tokens, :infinity)
  end

  @doc "Exports session conversation history into JSON or Markdown file."
  def export_session(pid, format \\ :markdown) do
    GenServer.call(pid, {:export_session, format}, :infinity)
  end

  @doc "Returns full list of conversation messages in session."
  def get_messages(pid) do
    GenServer.call(pid, :get_messages, :infinity)
  end

  @doc """
  Records an error message (including stacktrace/harness failure details)
  into the session's message log and immediately persists it to disk (.lmml / .lmmlz).
  """
  def record_error(pid, error_text) do
    GenServer.call(pid, {:record_error, error_text}, :infinity)
  catch
    :exit, _ -> {:error, "Session process unavailable"}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = opts[:session_id] || "default"
    base_sys_prompt = opts[:system_prompt] || @default_system_prompt

    # Inject workspace project rules if available (.yokerules, .yoke/rules.md)
    rules = Config.discover_project_rules(opts[:cwd] || ".")

    system_prompt =
      if rules != "" do
        base_sys_prompt <> "\n\n" <> rules
      else
        base_sys_prompt
      end

    # Register in PubSub registry "sessions" group for hot-code tool reload broadcasts
    Registry.register(Yoke.PubSubRegistry, "sessions", session_id)

    tools = PluginLoader.list_tools()
    initial_messages = [%{"role" => "system", "content" => system_prompt}]
    cwd = opts[:cwd] || "."

    state = %{
      session_id: session_id,
      model: opts[:model] || System.get_env("DEEPSEEK_MODEL") || "deepseek-chat",
      endpoint:
        opts[:endpoint] ||
          System.get_env("DEEPSEEK_ENDPOINT") ||
          System.get_env("OPENROUTER_BASE_URL") ||
          System.get_env("OLLAMA_HOST") ||
          Map.get(
            Config.load_config(cwd),
            "endpoint",
            "https://api.deepseek.com/chat/completions"
          ),
      permission_mode: opts[:permission_mode] || :ask_confirm,
      sandbox_workspace: opts[:sandbox_workspace] || false,
      session_tool_permissions: %{},
      api_key:
        opts[:api_key] ||
          System.get_env("DEEPSEEK_API_KEY") ||
          System.get_env("OPENROUTER_API_KEY") ||
          System.get_env("LLM_API_KEY") ||
          Map.get(Config.load_config(cwd), "api_key"),
      hands: %HandsExecutor{mode: :local},
      messages: initial_messages,
      tools: tools,
      tool_failure_counts: %{},
      snapshots: [],
      step_count: 0,
      max_tool_depth:
        opts[:max_tool_depth] || Map.get(Config.load_config(cwd), "max_tool_depth", 1000),
      # Hardcoded "plan -> approve -> execute" gate for non-trivial tasks. The
      # gate is default-ON and read from config (`plan_gate_enabled`,
      # `plan_gate_threshold`). `plan_approved_for_turn` is set true once the
      # user approves a plan for the current agent turn, so later tool-call
      # batches in the SAME turn don't re-prompt. Subagent and workflow
      # sessions keep their own behavior (they never arm the gate).
      plan_gate_enabled:
        opts[:plan_gate_enabled] || Map.get(Config.load_config(cwd), "plan_gate_enabled", true),
      plan_gate_threshold:
        opts[:plan_gate_threshold] || Map.get(Config.load_config(cwd), "plan_gate_threshold", 2),
      plan_approved_for_turn: false,
      # Optional per-request completion-token cap, read from config
      # ("max_tokens") and forwarded to the DeepSeek API on each call.
      # `nil` means "not set" and the field is omitted from requests.
      max_tokens: opts[:max_tokens] || Map.get(Config.load_config(cwd), "max_tokens"),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      turn_history: [],
      cwd: cwd,
      status: :idle,
      # `%{task: %Task{}, from: GenServer.from()}` while an agent turn
      # (started by `send_user_message/2` or `generate_code_review/3`) is
      # running in its own background Task -- see `start_agent_turn/2` --
      # or `nil` when idle. Lets `cancel_current_turn/1` (Ctrl+Q) abort the
      # turn and reply to its still-waiting caller without this GenServer
      # ever blocking its own mailbox for the turn's duration.
      active_turn: nil,
      images: %{}
    }

    # Attempt to restore session state if persisted
    state =
      case SessionStore.load_session(session_id, state.cwd) do
        {:ok, saved_data} ->
          Logger.info("[Brain.Session] Restored persisted session state for '#{session_id}'")

          %{
            state
            | messages: saved_data["messages"] || initial_messages,
              images: saved_data["images"] || saved_data[:images] || %{}
          }

        _ ->
          state
      end

    Logger.info(
      "[Brain.Session] Session actor initialized: #{session_id} (model: #{state.model})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send_user_message, raw_text}, from, state) do
    # Expand @filename, @relative_path, @file://..., @https://... and ambiguous error references ("error above")
    opts = [
      sandbox_workspace: state.sandbox_workspace,
      session_messages: state.messages,
      issue_tracker: Map.get(state, :issue_tracker, [])
    ]

    {:ok, expanded_text, attachments} = ContextExpander.expand(raw_text, state.cwd, opts)

    rules_preamble = Yoke.Rules.build_preamble("all", state.cwd)

    final_user_text =
      if rules_preamble != "", do: rules_preamble <> expanded_text, else: expanded_text

    SessionStore.append_transcript(state.session_id, "USER_INPUT", final_user_text, state.cwd)

    # When the user attached one or more images (@screenshot.png), build the
    # structured `content` array the vision API expects (image_url + text parts)
    # instead of a plain string.
    image_parts =
      Enum.flat_map(attachments, fn
        %{type: "image"} = img ->
          [%{"type" => "image_url", "image_url" => %{"url" => img.data_uri}}]

        _ ->
          []
      end)

    user_msg =
      if image_parts != [] do
        %{
          "role" => "user",
          "content" => image_parts ++ [%{"type" => "text", "text" => final_user_text}]
        }
      else
        %{"role" => "user", "content" => final_user_text}
      end

    new_images =
      Enum.reduce(attachments, Map.get(state, :images, %{}), fn
        %{type: "image", filename: name, bytes: bytes}, acc
        when is_binary(name) and is_binary(bytes) ->
          Map.put(acc, name, bytes)

        _, acc ->
          acc
      end)

    state = %{
      state
      | messages: state.messages ++ [user_msg],
        images: new_images,
        status: :thinking
    }

    # A fresh user turn starts with no approved plan; the plan gate may arm
    # once this turn's tool calls look non-trivial.
    state = %{state | plan_approved_for_turn: false}

    state = auto_checkpoint(state, "Pre-turn ##{state.step_count + 1}")

    start_agent_turn(state, from)
  end

  @impl true
  def handle_call(
        :cancel_current_turn,
        _from,
        %{active_turn: %{task: task, from: waiting_from}} = state
      ) do
    Task.shutdown(task, :brutal_kill)
    GenServer.reply(waiting_from, {:error, "Turn cancelled by user (Ctrl+Q)."})
    Logger.info("[Brain.Session] In-flight agent turn cancelled by user (Ctrl+Q).")
    {:reply, :ok, %{state | active_turn: nil, status: :idle}}
  end

  @impl true
  def handle_call(:cancel_current_turn, _from, state) do
    {:reply, {:error, "No turn currently in progress to cancel."}, state}
  end

  @impl true
  def handle_call(:get_model, _from, state) do
    {:reply, {:ok, state.model}, state}
  end

  @impl true
  def handle_call(:get_endpoint, _from, state) do
    {:reply, {:ok, state.endpoint}, state}
  end

  @impl true
  def handle_call({:set_model, model}, _from, state) do
    new_state = %{state | model: model}
    {:reply, {:ok, model}, new_state}
  end

  @impl true
  def handle_call({:set_endpoint, endpoint}, _from, state) do
    new_state = %{state | endpoint: endpoint}
    {:reply, {:ok, endpoint}, new_state}
  end

  @impl true
  def handle_call({:set_permission_mode, mode}, _from, state) do
    new_state = %{state | permission_mode: mode}
    {:reply, {:ok, mode}, new_state}
  end

  @impl true
  def handle_call({:set_hands_mode, mode, target}, _from, state) do
    hands =
      case mode do
        :remote -> %HandsExecutor{mode: :remote, remote_node: target}
        :docker -> %HandsExecutor{mode: :docker, docker_container: target}
        _ -> %HandsExecutor{mode: :local}
      end

    new_state = %{state | hands: hands}
    {:reply, {:ok, hands}, new_state}
  end

  @impl true
  def handle_call(:compact_context, _from, state) do
    opts = [model: state.model, api_key: state.api_key, endpoint: state.endpoint]

    opts =
      if is_integer(state.max_tokens) and state.max_tokens > 0 do
        Keyword.put(opts, :max_tokens, state.max_tokens)
      else
        opts
      end

    case ContextCompressor.compress_messages(state.messages, opts) do
      {:ok, new_messages, summary} ->
        new_state = %{state | messages: new_messages}
        SessionStore.save_session(new_state, state.cwd)
        {:reply, {:ok, summary}, new_state}

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    system_msg =
      Enum.find(state.messages, fn m -> m["role"] == "system" end) ||
        %{"role" => "system", "content" => @default_system_prompt}

    new_messages = [system_msg]

    new_state = %{
      state
      | messages: new_messages,
        snapshots: [],
        tool_failure_counts: %{},
        session_tool_permissions: %{},
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        step_count: 0,
        plan_approved_for_turn: false,
        turn_history: []
    }

    SessionStore.save_session(new_state, state.cwd)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:checkpoint, label}, _from, state) do
    label = label || "Manual Checkpoint ##{length(state.snapshots) + 1}"

    snapshot = %{
      id: "cp_#{System.unique_integer([:positive])}",
      label: label,
      timestamp: DateTime.utc_now(),
      messages: state.messages,
      model: state.model
    }

    new_state = %{state | snapshots: [snapshot | state.snapshots]}
    SessionStore.save_session(new_state, state.cwd)
    {:reply, {:ok, snapshot}, new_state}
  end

  @impl true
  def handle_call(:undo, _from, state) do
    case state.snapshots do
      [latest | rest] ->
        Logger.info("[Brain.Session] Rolling back state to snapshot: #{latest.label}")

        new_state = %{
          state
          | messages: latest.messages,
            model: latest.model,
            snapshots: rest
        }

        SessionStore.save_session(new_state, state.cwd)
        {:reply, {:ok, "Rolled back to checkpoint: '#{latest.label}'"}, new_state}

      [] ->
        {:reply, {:error, "No checkpoints available to undo."}, state}
    end
  end

  @impl true
  def handle_call({:spawn_subagent, prompt, opts}, _from, state) do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    async? = Keyword.get(opts, :async, true)

    Logger.info("[Brain.Session] Spawning subagent session '#{sub_id}' (async: #{async?})")

    if async? do
      parent_pid = self()

      Task.start(fn ->
        Yoke.TaskEngine.PackageTracker.register(
          "sub: " <> Yoke.TaskEngine.PackageTracker.derive_label(prompt),
          :subagent,
          id: sub_id
        )

        try do
          case Yoke.Brain.SessionSupervisor.start_session(
                 session_id: sub_id,
                 model: state.model,
                 cwd: state.cwd
               ) do
            {:ok, sub_pid} ->
              res = send_user_message(sub_pid, prompt)
              send(parent_pid, {:subagent_completed, sub_id, res})
              Yoke.Brain.SessionSupervisor.stop_session(sub_pid)

            {:error, err} ->
              send(parent_pid, {:subagent_completed, sub_id, {:error, err}})
          end
        after
          Yoke.TaskEngine.PackageTracker.unregister()
        end
      end)

      {:reply, {:ok, "Subagent '#{sub_id}' spawned asynchronously."}, state}
    else
      Yoke.TaskEngine.PackageTracker.register(
        "sub: " <> Yoke.TaskEngine.PackageTracker.derive_label(prompt),
        :subagent,
        id: sub_id
      )

      try do
        case Yoke.Brain.SessionSupervisor.start_session(
               session_id: sub_id,
               model: state.model,
               cwd: state.cwd
             ) do
          {:ok, sub_pid} ->
            case send_user_message(sub_pid, prompt) do
              {:ok, response} ->
                Yoke.Brain.SessionSupervisor.stop_session(sub_pid)
                {:reply, {:ok, response.content}, state}

              {:error, err} ->
                Yoke.Brain.SessionSupervisor.stop_session(sub_pid)
                {:reply, {:error, err}, state}
            end

          {:error, err} ->
            {:reply, {:error, "Failed to spawn subagent: #{inspect(err)}"}, state}
        end
      after
        Yoke.TaskEngine.PackageTracker.unregister()
      end
    end
  end

  @impl true
  def handle_call({:generate_code_review, base_branch, head_branch}, from, state) do
    case Yoke.Git.diff_branches(base_branch, head_branch, state.cwd) do
      {:ok, data} ->
        prompt = """
        Perform a thorough, expert production Code Review comparing base branch '#{data.base}' against head branch '#{data.head}'.

        ### Branch Comparison Data
        - Base Branch: #{data.base}
        - Head Branch: #{data.head}

        ### Commits Included in Branch Range
        #{data.log}

        ### Diff Summary (--stat)
        #{data.stat}

        ### Code Diff Payload
        ```diff
        #{data.raw_diff}
        ```

        Please generate a detailed, structured Code Review in GitHub-flavored Markdown:
        1. **Executive Summary**: Architectural purpose & high-level review summary.
        2. **Key Modifications & Feature Breakdown**: File-by-file analysis of major changes.
        3. **Risk & Edge Case Assessment**: Potential bugs, security flaws, breaking changes, or performance risks.
        4. **Actionable Recommendations**: Specific code refactoring snippets & improvements.
        5. **Test & Verification Coverage**: Assessment of missing test cases.
        6. **GitHub PR Review Formatted Block**: A ready-to-post Markdown comment block formatted for GitHub Pull Request review.
        #{Yoke.PRReview.prompt_instructions()}
        """

        rules_preamble = Yoke.Rules.build_preamble("cr", state.cwd)
        final_prompt = if rules_preamble != "", do: rules_preamble <> prompt, else: prompt

        user_msg = %{"role" => "user", "content" => final_prompt}
        state_with_msg = %{state | messages: state.messages ++ [user_msg], status: :thinking}

        start_agent_turn(state_with_msg, from)

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call(:get_token_stats, _from, state) do
    prompt_tokens = state.total_prompt_tokens
    completion_tokens = state.total_completion_tokens
    total = prompt_tokens + completion_tokens

    total_cost = estimate_cost(state, prompt_tokens, completion_tokens)

    proc_status = Yoke.process_status()

    stats = %{
      model: state.model,
      hands_mode: state.hands.mode,
      permission_mode: state.permission_mode,
      sandbox_workspace: state.sandbox_workspace,
      tracked_prompt_tokens: prompt_tokens,
      tracked_completion_tokens: completion_tokens,
      total_tokens: total,
      estimated_cost_usd: Float.round(total_cost, 6),
      serving_processes: proc_status.total_serving_processes,
      active_task_workers: proc_status.active_task_workers,
      serving_report: Yoke.report_serving_processes()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    proc_status = Yoke.process_status()

    info = %{
      session_id: state.session_id,
      model: state.model,
      permission_mode: state.permission_mode,
      message_count: length(state.messages),
      snapshot_count: length(state.snapshots),
      hands_mode: state.hands.mode,
      hands_target: state.hands.remote_node || state.hands.docker_container || "local",
      tools_count: length(state.tools),
      status: state.status,
      plan_gate_enabled: state.plan_gate_enabled,
      plan_gate_threshold: state.plan_gate_threshold,
      serving_processes: proc_status.total_serving_processes,
      active_task_workers: proc_status.active_task_workers,
      serving_report: Yoke.report_serving_processes(),
      pid: self()
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_latest_response, _from, state) do
    last_assistant_msg =
      state.messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m["role"] == "assistant" end)

    case last_assistant_msg do
      %{"content" => content} when is_binary(content) and content != "" ->
        {:reply, {:ok, content}, state}

      _ ->
        {:reply, {:error, "No assistant response found in active session history."}, state}
    end
  end

  @impl true
  def handle_call({:set_sandbox_mode, enabled}, _from, state) do
    new_state = %{state | sandbox_workspace: enabled}
    {:reply, {:ok, enabled}, new_state}
  end

  @impl true
  def handle_call(:get_turn_tokens, _from, state) do
    {:reply, state.turn_history, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    prompt_tokens = state.total_prompt_tokens
    completion_tokens = state.total_completion_tokens
    total = prompt_tokens + completion_tokens

    total_cost = estimate_cost(state, prompt_tokens, completion_tokens)

    mcp_servers = Yoke.MCP.ServerManager.list_servers()

    stats = %{
      session_id: state.session_id,
      model: state.model,
      permission_mode: state.permission_mode,
      sandbox_workspace: state.sandbox_workspace,
      message_count: length(state.messages),
      snapshot_count: length(state.snapshots),
      hands_mode: state.hands.mode,
      step_count: state.step_count,
      tracked_prompt_tokens: prompt_tokens,
      tracked_completion_tokens: completion_tokens,
      total_tokens: total,
      estimated_cost_usd: Float.round(total_cost, 6),
      tools_count: length(state.tools),
      mcp_servers_count: Enum.count(mcp_servers),
      turns_count: length(state.turn_history),
      max_tool_depth: state.max_tool_depth
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:export_session, format}, _from, state) do
    export_dir = Path.join(state.cwd, ".yoke/exports")
    File.mkdir_p!(export_dir)

    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")

    fmt_atom =
      case format do
        f when f in [:json, "json"] -> :json
        f when f in [:lmml, "lmml"] -> :lmml
        f when f in [:lmmlz, "lmmlz"] -> :lmmlz
        _ -> :markdown
      end

    ext = to_string(fmt_atom)
    ext = if ext == "markdown", do: "md", else: ext
    filename = "session_#{state.session_id}_#{timestamp}.#{ext}"
    export_path = Path.join(export_dir, filename)

    case export_session_content(fmt_atom, state, export_path) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      {:error, err} -> {:reply, {:error, "Failed to write export file: #{inspect(err)}"}, state}
    end
  end

  @impl true
  def handle_call({:record_error, error_text}, _from, state) do
    clean_text =
      error_text
      |> to_string()
      |> String.replace_invalid()

    error_msg = %{
      "role" => "system",
      "content" => "[HARNESS ERROR]\n" <> clean_text
    }

    new_state = %{state | messages: state.messages ++ [error_msg], status: :idle}
    SessionStore.save_session(new_state, state.cwd)
    SessionStore.append_transcript(state.session_id, "ERROR", clean_text, state.cwd)
    {:reply, :ok, new_state}
  end

  defp export_session_content(:json, state, export_path) do
    content =
      Yoke.Json.encode!(
        %{
          "session_id" => state.session_id,
          "model" => state.model,
          "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "total_tokens" => state.total_prompt_tokens + state.total_completion_tokens,
          "messages" => state.messages
        },
        pretty: true
      )

    case File.write(export_path, content) do
      :ok -> {:ok, export_path}
      err -> err
    end
  end

  defp export_session_content(:lmml, state, export_path) do
    with {:ok, narrative} <- Yoke.Brain.SessionLmml.encode(state, state.session_id),
         :ok <- File.write(export_path, narrative) do
      {:ok, export_path}
    end
  end

  defp export_session_content(:lmmlz, state, export_path) do
    images = Map.get(state, :images) || Map.get(state, "images") || %{}

    with {:ok, narrative} <- Yoke.Brain.SessionLmml.encode(state, state.session_id),
         {:ok, bundle} <- Lmml.Bundle.new_zip("#{state.session_id}.lmml", narrative, images),
         :ok <- Lmml.Bundle.write!(bundle, export_path) do
      {:ok, export_path}
    end
  end

  defp export_session_content(:markdown, state, export_path) do
    case Yoke.Brain.SessionLmml.encode(state, state.session_id) do
      {:ok, narrative} ->
        case Yoke.Brain.SessionLmml.to_markdown(narrative) do
          {:ok, md_content} ->
            case File.write(export_path, md_content) do
              :ok -> {:ok, export_path}
              err -> err
            end

          _ ->
            fallback_markdown_export(state, export_path)
        end

      _ ->
        fallback_markdown_export(state, export_path)
    end
  end

  defp fallback_markdown_export(state, export_path) do
    formatted_messages =
      Enum.map_join(state.messages, "\n\n", fn m ->
        role = String.upcase(m["role"] || "unknown")
        text = message_content_text(m["content"])
        "### #{role}\n#{text}"
      end)

    content = """
    # Session Export: #{state.session_id}
    - **Model**: `#{state.model}`
    - **Exported At**: `#{DateTime.to_iso8601(DateTime.utc_now())}`
    - **Total Tokens**: `#{state.total_prompt_tokens + state.total_completion_tokens}`

    ---

    #{formatted_messages}
    """

    case File.write(export_path, content) do
      :ok -> {:ok, export_path}
      err -> err
    end
  end

  @impl true
  def handle_info({:hot_reload_tools, new_tools}, state) do
    Logger.debug(
      "[Brain.Session] Hot-reloaded tools dynamically without dropping conversation state! (Tools: #{length(new_tools)})"
    )

    {:noreply, %{state | tools: new_tools}}
  end

  @impl true
  def handle_info({:tools_reloaded, new_tools}, state) do
    Logger.debug(
      "[Brain.Session] Dynamic tools updated without dropping conversation state (#{length(new_tools)} tools active)."
    )

    {:noreply, %{state | tools: new_tools}}
  end

  @impl true
  def handle_info({ref, result}, %{active_turn: %{task: %Task{ref: ref}, from: from}})
      when is_reference(ref) do
    # The agent-loop Task started by `start_agent_turn/2` finished on its
    # own (as opposed to being cut short by `cancel_current_turn/1`).
    # Demonitor+flush so the matching `:DOWN` message this same Task also
    # sends right after doesn't fall through to the catch-all clause below.
    Process.demonitor(ref, [:flush])
    {final_response, new_turn_state} = result
    GenServer.reply(from, final_response)
    {:noreply, %{new_turn_state | active_turn: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active_turn: %{task: %Task{ref: ref}, from: from}} = state
      ) do
    # The agent-loop Task crashed outright (an uncaught exception) rather
    # than returning a `{final_response, new_state}` result -- reply with
    # an error instead of leaving the original caller hanging forever.
    Logger.error("[Brain.Session] Agent turn task crashed: #{inspect(reason)}")
    err_str = "Agent turn crashed unexpectedly: #{inspect(reason)}"
    error_msg = %{"role" => "system", "content" => "[HARNESS ERROR]\n" <> err_str}

    new_state = %{
      state
      | messages: state.messages ++ [error_msg],
        active_turn: nil,
        status: :idle
    }

    SessionStore.save_session(new_state, state.cwd)
    SessionStore.append_transcript(state.session_id, "ERROR", err_str, state.cwd)

    GenServer.reply(from, {:error, err_str})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:subagent_completed, sub_id, result}, state) do
    Logger.info("[Brain.Session] Async subagent '#{sub_id}' completed with result.")

    notice_content =
      case result do
        {:ok, %{content: content}} -> "=== Async Subagent Result (#{sub_id}) ===\n#{content}\n"
        {:ok, text} when is_binary(text) -> "=== Async Subagent Result (#{sub_id}) ===\n#{text}\n"
        {:ok, other} -> "=== Async Subagent Result (#{sub_id}) ===\n#{inspect(other)}\n"
        {:error, err} -> "=== Async Subagent Failure (#{sub_id}) ===\n#{inspect(err)}\n"
      end

    notice = %{"role" => "user", "content" => notice_content}
    {:noreply, %{state | messages: state.messages ++ [notice]}}
  end

  @impl true
  def handle_info({:job_completed, job_id, command, result, log_tail}, state) do
    Logger.info("[Brain.Session] Async background job '#{job_id}' completed.")

    status_str =
      case result do
        {:exited, 0} -> "COMPLETED SUCCESSFULLY (exit code 0)"
        {:exited, code} -> "FAILED with exit code #{code}"
        {:failed, msg} -> "FAILED (#{msg})"
      end

    notice_content = """
    === Async Background Job Finished (#{job_id}) ===
    Command: `#{command}`
    Status: #{status_str}
    Log output (tail):
    ```
    #{log_tail}
    ```
    """

    notice = %{"role" => "user", "content" => notice_content}
    {:noreply, %{state | messages: state.messages ++ [notice]}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Brain.Session] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  # Agent Execution Loop

  # Runs `run_agent_loop/2` in its own supervised Task instead of blocking
  # this GenServer's own mailbox -- keeping this session actor responsive
  # to `cancel_current_turn/1` (Ctrl+Q) and any other call for the entire
  # duration of what can otherwise be a very long-running turn (an LLM
  # round-trip plus however many tool-calling iterations it takes).
  # `from` (the caller's own `GenServer.call` tag) is stashed in
  # `active_turn` and only replied to once `handle_info/2` above receives
  # this Task's result or crash -- or once `cancel_current_turn/1` cuts it
  # short and replies early itself.
  defp start_agent_turn(state, from) do
    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        run_agent_loop(state, state.max_tool_depth)
      end)

    {:noreply, %{state | active_turn: %{task: task, from: from}}}
  end

  defp run_agent_loop(state, depth) when depth <= 0 do
    question =
      "Max tool iteration depth reached (#{state.max_tool_depth} turns). Would you like to continue running?"

    choices = [
      "Continue execution (#{state.max_tool_depth} more iterations)",
      "Stop turn here"
    ]

    ans =
      Yoke.CLI.Spinner.with_paused(fn ->
        Yoke.CLI.QuestionPrompt.ask_single_question(question, choices, false)
      end)

    case ans do
      %{selected: [sel]} ->
        if String.contains?(sel, "Continue") do
          Logger.info(
            "[Brain.Session] User authorized #{state.max_tool_depth} additional tool iterations."
          )

          run_agent_loop(state, state.max_tool_depth)
        else
          {{:error, "Turn stopped by user at max tool iteration depth."}, state}
        end

      _ ->
        {{:error, "Turn stopped by user at max tool iteration depth."}, state}
    end
  end

  defp run_agent_loop(state, depth, retries \\ 0) do
    opts = [model: state.model, api_key: state.api_key, endpoint: state.endpoint]

    opts =
      if is_integer(state.max_tokens) and state.max_tokens > 0 do
        Keyword.put(opts, :max_tokens, state.max_tokens)
      else
        opts
      end

    sanitized_messages = sanitize_messages(state.messages)

    case DeepSeekAPI.chat_completion(sanitized_messages, state.tools, opts) do
      {:ok, %{tool_calls: tool_calls} = response} when is_list(tool_calls) and tool_calls != [] ->
        handle_tool_calls_turn(state, response, tool_calls, depth)

      {:ok, response} ->
        handle_text_response_turn(state, response)

      {:error, reason} ->
        if retries < 2 and api_request_error?(reason) do
          Logger.warning(
            "[Brain.Session] DeepSeek API returned request error: #{reason}. Attempting harness recovery (retry #{retries + 1})..."
          )

          repaired_messages =
            if retries == 0 do
              repair_tool_messages(state.messages)
            else
              convert_all_tool_roles_to_user_messages(state.messages)
            end

          repaired_state = %{state | messages: repaired_messages}
          run_agent_loop(repaired_state, depth, retries + 1)
        else
          {{:error, "Error communicating with DeepSeek API: #{reason}"}, %{state | status: :idle}}
        end
    end
  end

  defp api_request_error?(reason) when is_binary(reason) do
    c = String.downcase(reason)

    String.contains?(c, "invalid_request_error") or
      String.contains?(c, "role 'tool'") or
      String.contains?(c, "tool_calls") or
      String.contains?(c, "http status 400") or
      String.contains?(c, "400")
  end

  defp api_request_error?(_), do: false

  defp handle_tool_calls_turn(state, response, tool_calls, depth) do
    state = accumulate_usage(state, response[:usage])

    if response[:reasoning_content] do
      Logger.info("[DeepSeek-R1 Reasoning]\n#{response.reasoning_content}")
    end

    assistant_msg = build_assistant_tool_msg(response, tool_calls)
    state_after_assistant = %{state | messages: state.messages ++ [assistant_msg]}

    if AgentLoop.duplicate_tool_calls?(state.messages, tool_calls) do
      Logger.warning(
        "[Brain.Session] Detected duplicate tool call loop. Instructing model to finalize response."
      )

      tool_cancel_messages =
        Enum.map(tool_calls, fn tc ->
          %{
            "role" => "tool",
            "tool_call_id" => tc.id,
            "content" => "SYSTEM NOTICE: Duplicate tool call ignored."
          }
        end)

      system_feedback = %{
        "role" => "user",
        "content" =>
          "SYSTEM NOTICE: The tool call(s) #{inspect(Enum.map(tool_calls, & &1.name))} with the exact same arguments were already executed in the previous turn. Do NOT call the tool again. Synthesize your final answer using the results already provided."
      }

      state_with_feedback = %{
        state_after_assistant
        | messages: state_after_assistant.messages ++ tool_cancel_messages ++ [system_feedback]
      }

      run_agent_loop(state_with_feedback, depth - 1)
    else
      state_after_gate =
        maybe_run_plan_gate(tool_calls, state_after_assistant)

      case state_after_gate do
        {:denied, denied_state} ->
          {{:error, "Turn stopped by user: plan was not approved for a non-trivial task."},
           %{denied_state | status: :idle}}

        {:ok, gated_state} ->
          {tool_messages, updated_hands_state} = execute_tool_calls(tool_calls, gated_state)

          state_after_tools = %{
            updated_hands_state
            | messages: updated_hands_state.messages ++ tool_messages,
              step_count: updated_hands_state.step_count + 1
          }

          run_agent_loop(state_after_tools, depth - 1)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Hardcoded "plan -> approve -> execute" gate for non-trivial tasks
  # ---------------------------------------------------------------------

  # Returns `{:ok, state}` to continue executing (either the gate did not
  # fire, or the user approved the plan), or `{:denied, state}` to stop the
  # turn because the user denied the plan for a non-trivial batch of tool
  # calls.
  defp maybe_run_plan_gate(tool_calls, state) do
    if plan_gate_active?(state) and PlanGate.needs_plan?(tool_calls, state.plan_gate_threshold) do
      case request_plan_approval(state) do
        {:approved, approved_state} -> {:ok, approved_state}
        {:denied, denied_state} -> {:denied, denied_state}
      end
    else
      {:ok, state}
    end
  end

  # The gate is armed only for the main interactive session's own user turns:
  # it must be enabled in config, the session must be a top-level session (not
  # a `sub_*` subagent or `workflow-*` workflow Brain), and no plan may yet
  # have been approved for the current turn.
  defp plan_gate_active?(state) do
    state.plan_gate_enabled and not state.plan_approved_for_turn and
      top_level_session?(state.session_id)
  end

  defp top_level_session?(session_id) when is_binary(session_id) do
    not (String.starts_with?(session_id, "sub_") or
           String.starts_with?(session_id, "workflow-"))
  end

  defp top_level_session?(_), do: false

  # Drafts a plan from the user's own most recent request, shows it for
  # approval via the paused question modal, and returns `{:approved, state}`
  # (with the approved plan injected into the conversation so the model
  # executes against it) or `{:denied, state}`.
  defp request_plan_approval(state) do
    task_text = latest_user_request(state)

    plan =
      case WorkflowPlan.draft(task_text, model: state.model, api_key: state.api_key) do
        {:ok, plan} -> plan
        {:error, reason} -> %{"summary" => "(plan drafting failed: #{reason})", "steps" => []}
      end

    rendered = PlanGate.render_plan(plan)

    question =
      "This task looks non-trivial (several file-modifying actions). " <>
        "Here is the proposed plan -- approve it before I proceed:\n\n#{rendered}"

    options = ["Approve & execute", "Request changes", "Deny"]

    answer =
      Yoke.CLI.Spinner.with_paused(fn ->
        Yoke.CLI.QuestionPrompt.ask_single_question(question, options, false)
      end)

    decision =
      case answer do
        %{selected: [sel]} -> PlanGate.decision_from_selection(sel)
        %{custom: custom} when is_binary(custom) and custom != "" -> :request_changes
        _ -> :deny
      end

    case decision do
      :approve ->
        approved_state = inject_approved_plan(state, rendered)
        {:approved, %{approved_state | plan_approved_for_turn: true}}

      :request_changes ->
        handle_plan_revisions(state, plan, rendered)

      _ ->
        {:denied, state}
    end
  end

  # When the user asks for changes, prompt for their concrete feedback and
  # fold it into the plan (asking again). If they cancel or give nothing,
  # treat as denied.
  defp handle_plan_revisions(state, _plan, rendered) do
    feedback =
      Yoke.CLI.Spinner.with_paused(fn ->
        Yoke.CLI.QuestionPrompt.ask_single_question(
          "Approved plan needs changes. What should change? (type your feedback)",
          ["Approve as-is anyway", "Deny"],
          false
        )
      end)

    custom =
      case feedback do
        %{custom: text} when is_binary(text) and text != "" -> text
        _ -> ""
      end

    if custom != "" do
      # Fold the user's feedback into the conversation so the model revises
      # its approach accordingly, then treat the plan as approved with the
      # requested changes noted.
      amended = rendered <> "\n\n### User amendments\n#{custom}"
      approved_state = inject_approved_plan(state, amended)
      {:approved, %{approved_state | plan_approved_for_turn: true}}
    else
      {:denied, state}
    end
  end

  # Appends the approved/amended plan as a user-role message so the model is
  # instructed to execute against it (rather than improvising).
  defp inject_approved_plan(state, rendered) do
    notice = %{
      "role" => "user",
      "content" =>
        "PLAN APPROVED. Execute this plan now. Do not improvise beyond it:\n\n#{rendered}"
    }

    %{state | messages: state.messages ++ [notice]}
  end

  # The user's own most recent plain request, used as the seed for planning.
  defp latest_user_request(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _ -> nil
    end)
    |> String.replace_prefix("=== Prompt & Execution Rules ===", "")
    |> String.trim()
  end

  @doc "Sanitizes message history to ensure all assistant tool_calls are followed by matching tool response messages."
  def sanitize_messages(messages) when is_list(messages) do
    repair_tool_messages(messages)
  end

  def sanitize_messages(_), do: []

  @doc "Repairs malformed tool sequences in message history."
  def repair_tool_messages(messages) when is_list(messages) do
    {acc, pending} =
      Enum.reduce(messages, {[], []}, fn msg, {acc_messages, pending_ids} ->
        role = Map.get(msg, "role") || Map.get(msg, :role)
        calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)

        cond do
          role == "tool" ->
            call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id)

            if call_id != nil and call_id in pending_ids do
              new_pending = List.delete(pending_ids, call_id)
              {acc_messages ++ [msg], new_pending}
            else
              content = Map.get(msg, "content") || Map.get(msg, :content, "")

              converted = %{
                "role" => "user",
                "content" => "[Tool Output #{call_id || "unknown"}]: #{content}"
              }

              {acc_messages ++ [converted], pending_ids}
            end

          role == "assistant" and is_list(calls) and calls != [] ->
            acc_messages = fill_pending_tool_responses(acc_messages, pending_ids)

            new_ids =
              calls
              |> Enum.map(fn tc -> Map.get(tc, "id") || Map.get(tc, :id) end)
              |> Enum.reject(&is_nil/1)

            {acc_messages ++ [msg], new_ids}

          true ->
            acc_messages = fill_pending_tool_responses(acc_messages, pending_ids)
            {acc_messages ++ [msg], []}
        end
      end)

    fill_pending_tool_responses(acc, pending)
  end

  def repair_tool_messages(_), do: []

  defp fill_pending_tool_responses(messages, []) do
    messages
  end

  defp fill_pending_tool_responses(messages, pending_ids) when is_list(pending_ids) do
    tool_responses =
      Enum.map(pending_ids, fn id ->
        %{
          "role" => "tool",
          "tool_call_id" => id,
          "content" => "SYSTEM NOTICE: Tool execution result unavailable."
        }
      end)

    messages ++ tool_responses
  end

  @doc "Aggressively converts all tool-role messages into user messages to recover from strict API 400 validation failures."
  def convert_all_tool_roles_to_user_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      role = Map.get(msg, "role") || Map.get(msg, :role)
      calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)

      cond do
        role == "tool" ->
          call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id) || "unknown"
          content = Map.get(msg, "content") || Map.get(msg, :content, "")

          %{
            "role" => "user",
            "content" => "[Tool Output #{call_id}]: #{content}"
          }

        role == "assistant" and is_list(calls) ->
          content = Map.get(msg, "content") || ""
          msg |> Map.drop(["tool_calls", :tool_calls]) |> Map.put("content", content)

        true ->
          msg
      end
    end)
  end

  def convert_all_tool_roles_to_user_messages(_), do: []

  defp handle_text_response_turn(state, response) do
    state = accumulate_usage(state, response[:usage])

    if response[:reasoning_content] do
      Logger.info("[DeepSeek-R1 Reasoning]\n#{response.reasoning_content}")
    end

    final_msg = %{"role" => "assistant", "content" => response.content}
    final_state = %{state | messages: state.messages ++ [final_msg], status: :idle}
    SessionStore.save_session(final_state, state.cwd)
    {{:ok, response}, final_state}
  end

  defp build_assistant_tool_msg(response, tool_calls) do
    %{
      "role" => "assistant",
      "content" => response.content || "",
      "tool_calls" =>
        Enum.map(tool_calls, fn tc ->
          %{
            "id" => tc.id,
            "type" => "function",
            "function" => %{
              "name" => tc.name,
              "arguments" => Yoke.Json.encode!(tc.arguments)
            }
          }
        end)
    }
    |> maybe_put_reasoning(response[:reasoning_content])
  end

  defp accumulate_usage(state, nil), do: state

  defp accumulate_usage(state, usage) when is_map(usage) do
    p = Map.get(usage, :prompt_tokens, 0)
    c = Map.get(usage, :completion_tokens, 0)

    turn_entry = %{
      turn: length(state.turn_history) + 1,
      prompt_tokens: p,
      completion_tokens: c,
      total_tokens: p + c
    }

    %{
      state
      | total_prompt_tokens: state.total_prompt_tokens + p,
        total_completion_tokens: state.total_completion_tokens + c,
        turn_history: state.turn_history ++ [turn_entry]
    }
  end

  defp maybe_put_reasoning(msg, reasoning) when is_binary(reasoning) and reasoning != "" do
    Map.put(msg, "reasoning_content", reasoning)
  end

  defp maybe_put_reasoning(msg, _), do: msg

  @doc """
  Extracts a plain-text representation of a message's `content` field.

  Handles both the legacy plain-string form and the multimodal array form
  (list of `image_url` / `text` content parts used by vision models), so
  exports and summaries never crash on image-bearing messages.
  """
  def message_content_text(content) when is_binary(content), do: content

  def message_content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"image_url" => %{"url" => url}} when is_binary(url) -> "[Image: #{url}]"
      _ -> ""
    end)
  end

  def message_content_text(_), do: ""

  # Computes the estimated session cost in USD from the cumulative prompt
  # and completion token counts, using the per-million-token prices from
  # system-global config (~/.yoke/config.json) or a workspace override
  # (.yoke/config.json). Falls back to DeepSeek's published V3 rates
  # (prompt $0.14/1M, completion $0.28/1M) when unset, so existing
  # installations without the new keys keep their previous estimates.
  defp estimate_cost(state, prompt_tokens, completion_tokens) do
    config = Config.load_config(state.cwd)

    prompt_per_million =
      Map.get(config, "price_per_million_prompt_tokens", 0.14) / 1_000_000

    completion_per_million =
      Map.get(config, "price_per_million_completion_tokens", 0.28) / 1_000_000

    prompt_tokens * prompt_per_million + completion_tokens * completion_per_million
  end

  defp execute_tool_calls(tool_calls, state) do
    alias Yoke.TaskEngine.Orchestrator

    # Step 1: Check permissions and log TOOL_CALL transcripts for all tool calls
    {permitted_calls, denied_results, state_after_permissions} =
      Enum.reduce(tool_calls, {[], [], state}, fn tc, {allowed_acc, denied_acc, current_state} ->
        SessionStore.append_transcript(
          current_state.session_id,
          "TOOL_CALL",
          %{name: tc.name, args: tc.arguments},
          current_state.cwd
        )

        case tool_permitted?(tc.name, tc.arguments, current_state) do
          {:allow, updated_state} ->
            {allowed_acc ++ [tc], denied_acc, updated_state}

          {:deny, reason, updated_state} ->
            tool_msg = %{
              "role" => "tool",
              "tool_call_id" => tc.id,
              "content" => "Tool execution denied: #{reason}"
            }

            SessionStore.append_transcript(
              updated_state.session_id,
              "TOOL_DENIED",
              tool_msg,
              updated_state.cwd
            )

            {allowed_acc, denied_acc ++ [{tc, tool_msg}], updated_state}
        end
      end)

    # Step 2: Execute permitted tools concurrently off the main loop via TaskEngine
    executed_batch = Orchestrator.execute_batch(permitted_calls, state_after_permissions)

    # Step 3: Collate results in original order, update transcripts, failure handles, & issue tracking
    {tool_messages, system_notices, final_state} =
      Enum.reduce(
        tool_calls,
        {[], [], state_after_permissions},
        fn tc, {msg_acc, notice_acc, curr_state} ->
          case Enum.find(denied_results, fn {denied_tc, _} -> denied_tc.id == tc.id end) do
            {_denied_tc, tool_msg} ->
              {msg_acc ++ [tool_msg], notice_acc, curr_state}

            nil ->
              case Enum.find(executed_batch, fn {exec_tc, _} -> exec_tc.id == tc.id end) do
                {_exec_tc, exec_res} ->
                  tool_msg =
                    case exec_res do
                      {:ok, result} ->
                        %{"role" => "tool", "tool_call_id" => tc.id, "content" => result}

                      {:error, err} ->
                        %{
                          "role" => "tool",
                          "tool_call_id" => tc.id,
                          "content" => "Tool execution failed: #{err}"
                        }
                    end

                  SessionStore.append_transcript(
                    curr_state.session_id,
                    "TOOL_RESULT",
                    tool_msg,
                    curr_state.cwd
                  )

                  {curr_state_after, maybe_notice} =
                    AgentLoop.handle_tool_failure(tc.name, exec_res, curr_state)

                  state_with_issues = update_issue_tracker(curr_state_after, tc, exec_res)

                  new_notices =
                    if maybe_notice, do: notice_acc ++ [maybe_notice], else: notice_acc

                  {msg_acc ++ [tool_msg], new_notices, state_with_issues}

                nil ->
                  {msg_acc, notice_acc, curr_state}
              end
          end
        end
      )

    all_messages = tool_messages ++ system_notices
    {all_messages, final_state}
  end

  defp update_issue_tracker(state, tc, exec_res) do
    current_tracker = Map.get(state, :issue_tracker, [])

    case exec_res do
      {:error, err} ->
        new_issue = %{
          id: length(current_tracker) + 1,
          turn: state.step_count + 1,
          error: "#{tc.name}: #{err}",
          status: :open,
          resolved_at: nil,
          resolution: nil
        }

        Map.put(state, :issue_tracker, current_tracker ++ [new_issue])

      {:ok, _result} ->
        target_file = tc.arguments["path"] || tc.arguments["TargetFile"] || ""

        updated_tracker =
          Enum.map(current_tracker, fn issue ->
            if issue.status == :open and
                 (target_file == "" or String.contains?(issue.error, target_file)) do
              %{
                issue
                | status: :resolved,
                  resolved_at: state.step_count + 1,
                  resolution: "Resolved via successful #{tc.name} execution"
              }
            else
              issue
            end
          end)

        Map.put(state, :issue_tracker, updated_tracker)
    end
  end

  # Permission Authorization Gate (Item 1, 4, 18)
  @doc false
  def tool_permitted?(tool_name, args, state) do
    config = Config.load_config(state.cwd)
    tool_perms = Map.get(config, "tool_permissions", %{})
    config_policy = Map.get(tool_perms, tool_name)
    session_perms = Map.get(state, :session_tool_permissions, %{})
    session_policy = Map.get(session_perms, tool_name)

    policy = session_policy || config_policy

    target_file = args["path"] || args["TargetFile"] || args["AbsolutePath"] || args["file"]

    # `read_files` takes a list of paths, so the sandbox must validate every
    # one of them (a single out-of-bounds path is enough to deny the call).
    sandbox_violation =
      state.sandbox_workspace and
        cond do
          is_binary(target_file) ->
            not in_workspace?(target_file, state.cwd)

          is_list(args["paths"]) ->
            Enum.any?(args["paths"], &(is_binary(&1) and not in_workspace?(&1, state.cwd)))

          true ->
            false
        end

    cond do
      sandbox_violation ->
        {:deny, "Access denied: one or more file paths are outside active sandbox bounds.", state}

      policy == "deny" ->
        {:deny, "Tool '#{tool_name}' execution denied by configuration policy.", state}

      policy == "allow" or ragex_tool?(tool_name) or read_only_tool?(tool_name) ->
        {:allow, state}

      destructive_bash_command?(tool_name, args) ->
        confirm_tool_with_user(
          tool_name,
          args,
          "Warning: Destructive shell command detected!",
          state
        )

      state.permission_mode == :ask_confirm or policy == "confirm" ->
        confirm_tool_with_user(tool_name, args, "Confirmation required for tool execution", state)

      true ->
        {:allow, state}
    end
  end

  @doc "Returns true if tool is a read-only tool allowed by default."
  def read_only_tool?(tool_name) when is_binary(tool_name) do
    tool_name in ~w(read_file read_files glob_search grep_search list_dir job_status view_file find_by_name search_web read_url_content inspect_file get_file) or
      String.starts_with?(tool_name, "read_") or
      String.starts_with?(tool_name, "glob_") or
      String.starts_with?(tool_name, "grep_") or
      String.starts_with?(tool_name, "list_") or
      String.starts_with?(tool_name, "search_") or
      String.starts_with?(tool_name, "find_") or
      String.starts_with?(tool_name, "view_") or
      String.starts_with?(tool_name, "inspect_") or
      String.ends_with?(tool_name, "_search") or
      String.ends_with?(tool_name, "_read") or
      String.ends_with?(tool_name, "_list") or
      String.ends_with?(tool_name, "_status")
  end

  def read_only_tool?(_), do: false

  defp ragex_tool?(tool_name) when is_binary(tool_name) do
    String.starts_with?(tool_name, "mcp_ragex_") or
      String.starts_with?(tool_name, "ragex_") or
      tool_name == "ragex"
  end

  defp ragex_tool?(_), do: false

  defp in_workspace?(path, cwd) do
    abs_path = Path.expand(path, cwd)
    abs_cwd = Path.expand(cwd)
    # `String.starts_with?/2` alone is a classic prefix bug: a workspace root
    # of "/home/u/project" would incorrectly accept "/home/u/project-evil"
    # since the latter's text starts with the former. Requiring an exact
    # match OR a match followed by a path separator closes that sibling-
    # directory escape.
    abs_path == abs_cwd or String.starts_with?(abs_path, abs_cwd <> "/")
  end

  # Tool names that execute an arbitrary shell command string, whether
  # registered directly by `Yoke.Plugin.DefaultTools` ("bash") or exposed
  # under an alias by another plugin/MCP server -- see
  # `format_tool_confirmation_summary/2` below, which already treats all of
  # these as shell-execution tools for confirmation-summary purposes.
  @shell_exec_tool_names ~w(bash cmd run_command shell exec)

  defp destructive_bash_command?(tool_name, %{"command" => cmd})
       when tool_name in @shell_exec_tool_names and is_binary(cmd) do
    c = String.downcase(cmd)

    String.contains?(c, "rm -rf") or String.contains?(c, "git push --force") or
      String.contains?(c, "git reset --hard") or String.contains?(c, "drop database") or
      String.contains?(c, "mkfs")
  end

  defp destructive_bash_command?(_, _), do: false

  defp confirm_tool_with_user(tool_name, args, reason, state) do
    # Never ask for ask_question or ragex tools
    if tool_name == "ask_question" or ragex_tool?(tool_name) do
      {:allow, state}
    else
      summary = format_tool_confirmation_summary(tool_name, args)
      q = "#{reason}:\n#{summary}"

      opts = [
        "Allow once",
        "Allow always for this session",
        "Allow always (save to project config)",
        "Allow always (save to global config)",
        "Deny tool execution",
        "Deny always (save to project config)",
        "Deny always (save to global config)"
      ]

      ans =
        Yoke.CLI.Spinner.with_paused(fn ->
          Yoke.CLI.QuestionPrompt.ask_single_question(q, opts, false)
        end)

      case ans do
        %{selected: [sel]} ->
          cond do
            String.contains?(sel, "save to global config") and
                String.contains?(String.downcase(sel), "allow") ->
              Config.set_global_tool_permission(tool_name, "allow")
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "allow")
              {:allow, %{state | session_tool_permissions: perms}}

            String.contains?(sel, "save to global config") and
                String.contains?(String.downcase(sel), "deny") ->
              Config.set_global_tool_permission(tool_name, "deny")
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "deny")

              {:deny, "Tool execution denied by user (saved globally).",
               %{state | session_tool_permissions: perms}}

            String.contains?(sel, "save to project config") and
                String.contains?(String.downcase(sel), "allow") ->
              Config.set_tool_permission(tool_name, "allow", state.cwd)
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "allow")
              {:allow, %{state | session_tool_permissions: perms}}

            String.contains?(sel, "save to project config") and
                String.contains?(String.downcase(sel), "deny") ->
              Config.set_tool_permission(tool_name, "deny", state.cwd)
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "deny")

              {:deny, "Tool execution denied by user (saved to project).",
               %{state | session_tool_permissions: perms}}

            String.contains?(sel, "this session") ->
              perms = Map.put(Map.get(state, :session_tool_permissions, %{}), tool_name, "allow")
              {:allow, %{state | session_tool_permissions: perms}}

            String.contains?(String.downcase(sel), "allow") ->
              {:allow, state}

            true ->
              {:deny, "Tool execution denied by user.", state}
          end

        _ ->
          {:deny, "Tool execution denied by user.", state}
      end
    end
  end

  def format_tool_confirmation_summary(tool_name, args) when is_map(args) do
    case tool_name do
      name when name in ["replace_file_content", "replace_file", "edit_file"] ->
        format_replace_summary(tool_name, args)

      name when name in ["write_file", "write_to_file", "create_file"] ->
        format_write_summary(tool_name, args)

      name when name in ["bash", "cmd", "run_command", "shell", "exec"] ->
        format_bash_summary(tool_name, args)

      name when name in ["read_file", "view_file", "file_read"] ->
        format_read_file_summary(tool_name, args)

      name when name in ["read_files", "read_multiple_files"] ->
        format_read_files_summary(tool_name, args)

      _ ->
        summary =
          args
          |> Enum.map_join("\n", fn {k, v} ->
            str_v = if is_binary(v), do: truncate_str(v, 60), else: inspect(v)
            "  #{k}: #{str_v}"
          end)

        """
        Tool: #{tool_name}
        #{summary}
        """
        |> String.trim()
    end
  end

  def format_tool_confirmation_summary(tool_name, args) do
    "Tool: #{tool_name}\nArgs: #{inspect(args)}"
  end

  defp format_replace_summary(tool_name, args) do
    file = args["TargetFile"] || args["path"] || args["AbsolutePath"] || args["file"] || "file"
    target = args["TargetContent"] || args["target"] || ""
    replacement = args["ReplacementContent"] || args["replacement"] || ""
    start_line = args["StartLine"] || args["line_start"]
    end_line = args["EndLine"] || args["line_end"]

    lines_info = if start_line, do: " (lines #{start_line}-#{end_line})", else: ""

    diff_summary =
      cond do
        target != "" and replacement != "" ->
          t_preview = truncate_lines(target, 2)
          r_preview = truncate_lines(replacement, 2)

          """
          Target:
          - #{t_preview}
          Replacement:
          + #{r_preview}
          """

        replacement != "" ->
          r_preview = truncate_lines(replacement, 3)

          """
          Replacement:
          + #{r_preview}
          """

        true ->
          ""
      end

    """
    Tool: #{tool_name}
    File: #{file}#{lines_info}
    #{diff_summary}
    """
    |> String.trim()
  end

  defp format_write_summary(tool_name, args) do
    file = args["TargetFile"] || args["path"] || args["AbsolutePath"] || "file"
    content = args["CodeContent"] || args["content"] || ""
    line_count = length(String.split(content, "\n"))
    preview = truncate_lines(content, 3)

    """
    Tool: #{tool_name}
    File: #{file} (#{line_count} lines)
    Preview:
    #{preview}
    """
    |> String.trim()
  end

  defp format_bash_summary(tool_name, args) do
    cmd = args["CommandLine"] || args["command"] || args["cmd"] || ""

    """
    Tool: #{tool_name}
    Command: $ #{cmd}
    """
    |> String.trim()
  end

  defp format_read_file_summary(tool_name, args) do
    file = args["AbsolutePath"] || args["path"] || args["file"] || "file"
    start_line = args["StartLine"]
    end_line = args["EndLine"]
    range = if start_line, do: " (lines #{start_line}-#{end_line})", else: ""

    """
    Tool: #{tool_name}
    File: #{file}#{range}
    """
    |> String.trim()
  end

  defp format_read_files_summary(tool_name, args) do
    files = args["paths"] || []

    file_list =
      if is_list(files) and files != [] do
        Enum.map_join(files, "\n", fn f -> "  - #{f}" end)
      else
        "  (none specified)"
      end

    """
    Tool: #{tool_name}
    Files (#{if is_list(files), do: length(files), else: 0}):
    #{file_list}
    """
    |> String.trim()
  end

  defp truncate_lines(text, max_lines) when is_binary(text) do
    lines = String.split(text, "\n")

    if length(lines) <= max_lines do
      text
    else
      preview = Enum.take(lines, max_lines) |> Enum.join("\n")
      "#{preview}\n  ... [#{length(lines)} lines total]"
    end
  end

  defp truncate_str(str, max_len) when is_binary(str) do
    clean = String.replace(str, "\n", "\\n")

    if String.length(clean) <= max_len do
      clean
    else
      String.slice(clean, 0, max_len) <> "..."
    end
  end

  defp auto_checkpoint(state, label) do
    snapshot = %{
      id: "auto_#{System.unique_integer([:positive])}",
      label: label,
      timestamp: DateTime.utc_now(),
      messages: state.messages,
      model: state.model
    }

    snapshots = Enum.take([snapshot | state.snapshots], 20)
    new_state = %{state | snapshots: snapshots}
    SessionStore.save_session(new_state, state.cwd)
    new_state
  end
end

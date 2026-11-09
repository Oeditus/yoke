defmodule Yoke.CLI.FixRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionStore
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.CLI.Fix

  @moduletag :app
  @moduletag :tmp_dir

  # Only the provider turn is replaced: cancellation, checkpointing,
  # SessionStore persistence, and resumed Session initialization are real.
  defmodule StalledSession do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.put(:test_owner, opts[:test_owner])
      Session.init(opts)
    end

    @impl true
    def handle_call({:send_user_message, prompt}, from, state) do
      owner = Process.get(:test_owner)

      task =
        Task.Supervisor.async_nolink(Yoke.TaskEngine.TaskSupervisor, fn ->
          send(owner, {:active_worker, self()})

          receive do
            :mutate -> send(owner, :unexpected_mutation)
          end
        end)

      messages = state.messages ++ [%{"role" => "user", "content" => prompt}]

      {:noreply,
       %{state | active_turn: %{task: task, from: from}, status: :thinking, messages: messages}}
    end

    def handle_call(request, from, state), do: Session.handle_call(request, from, state)

    @impl true
    def handle_info(message, state), do: Session.handle_info(message, state)
  end

  setup %{tmp_dir: dir} do
    id = "fix-recovery-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {StalledSession, session_id: id, cwd: dir, provider: "local", test_owner: self()}
      )

    %{id: id, pid: pid}
  end

  test "timeout kills the active turn, persists triage and resumes context without provider calls",
       %{tmp_dir: dir, id: id, pid: pid} do
    prompt = prompt()
    output = capture_io(fn -> assert Fix.run_turn(pid, prompt, 30) == 1 end)

    assert_receive {:active_worker, worker}
    refute Process.alive?(worker)
    send(worker, :mutate)
    refute_receive :unexpected_mutation
    assert %{active_turn: nil, status: :idle} = :sys.get_state(pid)
    assert output =~ "Recovery persisted in session #{id}"
    assert output =~ "yoke -c '#{id}'"
    assert output =~ "new turn"
    assert output =~ "does not resurrect"

    assert {:ok, saved} = SessionStore.load_session(id, dir)
    assert [%{"role" => "system"}, %{"role" => "user", "content" => ^prompt}] = saved["messages"]

    stop_supervised!(StalledSession)

    assert {:ok, resumed} =
             SessionSupervisor.start_session(session_id: id, cwd: dir, provider: "local")

    on_exit(fn -> SessionSupervisor.stop_session(resumed) end)
    assert {:ok, messages} = Session.get_messages(resumed)
    assert messages == saved["messages"]
  end

  test "recovery preserves apply permission in the original triage prompt",
       %{tmp_dir: dir, id: id, pid: pid} do
    prompt = prompt(apply: true)
    output = capture_io(fn -> assert Fix.run_turn(pid, prompt, 30) == 1 end)
    assert output =~ "Recovery persisted"
    assert {:ok, saved} = SessionStore.load_session(id, dir)
    assert List.last(saved["messages"])["content"] == prompt
    assert prompt =~ "You MAY now apply the fix"
  end

  @tag capture_log: true
  test "save failure never advertises a session continuation", %{tmp_dir: dir, pid: pid} do
    File.mkdir_p!(Path.join(dir, ".yoke"))
    File.write!(Path.join(dir, ".yoke/sessions"), "not a directory")
    output = capture_io(fn -> assert Fix.run_turn(pid, prompt(), 30) == 1 end)

    assert_receive {:active_worker, worker}
    refute Process.alive?(worker)
    assert output =~ "Could not persist"
    refute output =~ "Recovery persisted"
    refute output =~ "yoke -c"
  end

  test "stale on-disk history is not sufficient proof of recovery",
       %{tmp_dir: dir, id: id, pid: pid} do
    state = :sys.get_state(pid)
    assert {:ok, _} = SessionStore.save_session(state, dir)
    # A stale higher-precedence container must not hide the fresh narrative
    # and produce a false claim that the saved context can be resumed.
    File.mkdir!(Path.join(dir, ".yoke/sessions/#{id}.lmmlz"))
    output = capture_io(fn -> assert Fix.run_turn(pid, prompt(), 30) == 1 end)
    assert output =~ "Could not persist"
    refute output =~ "yoke -c"
  end

  test "invalid provider returns usage error before replaying any command" do
    output = capture_io(fn -> assert Fix.fix(["--provider", "unknown", "never-execute"]) == 2 end)
    assert output =~ "Unknown provider"
    refute output =~ "Command source"
  end

  defp prompt(opts \\ []) do
    Fix.build_prompt("mix test", %{status: nil, output: "", ran?: false, duration_ms: 0}, opts)
  end
end

defmodule Yoke.SessionCheckpointMetadataTest do
  use ExUnit.Case, async: false
  @moduletag :app
  @moduletag :tmp_dir

  import ExUnit.CaptureIO
  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionLmml
  alias Yoke.Brain.SessionStore
  alias Yoke.Brain.SessionSupervisor

  defp session(cwd, opts \\ []) do
    id = Keyword.get(opts, :session_id, "metadata-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      SessionSupervisor.start_session(
        Keyword.merge([session_id: id, cwd: cwd, provider: "local", mock: true], opts)
      )

    on_exit(fn ->
      Session.cancel_current_turn(pid)
      SessionSupervisor.stop_session(pid)
    end)

    pid
  end

  @tag skip_in_gha: true
  test "listing is read-only metadata; snapshots survive save/load and restore provider state", %{
    tmp_dir: cwd
  } do
    pid = session(cwd)
    id = Session.get_info(pid).session_id
    assert [] = Session.list_checkpoints(pid)
    refute File.exists?(Path.join(cwd, ".yoke/sessions/#{id}.lmml"))
    assert {:ok, _} = Session.send_user_message(pid, "Say hello without tools.")
    assert {:ok, cp} = Session.checkpoint(pid, "before switching")
    assert cp.turn == 1
    assert [meta, automatic] = Session.list_checkpoints(pid)
    assert meta == Map.take(cp, [:id, :label, :turn, :timestamp])
    assert automatic.turn == 1
    assert automatic.label == "Pre-turn #1"
    refute Map.has_key?(meta, :messages)
    refute Map.has_key?(meta, :provider_options)

    assert {:ok, stored} = SessionStore.load_session(id, cwd)
    assert [saved, _] = stored["snapshots"]
    assert saved["turn"] == 1
    assert stored["turn_count"] == 1
    assert :ok = SessionSupervisor.stop_session(pid)

    resumed = session(cwd, session_id: id)
    assert [resumed_meta, _] = Session.list_checkpoints(resumed)
    assert resumed_meta.id == cp.id
    assert resumed_meta.turn == 1
    assert {:ok, _} = Session.set_provider(resumed, "deepseek")
    assert {:ok, message} = Session.undo(resumed)
    assert message =~ cp.id
    assert message =~ "before switching"
    assert message =~ "turn: 1"
    assert message =~ "Working-tree files are unchanged"
    assert Session.provider_options(resumed)[:provider] == "local"
    assert [remaining] = Session.list_checkpoints(resumed)
    assert remaining.id == automatic.id
  end

  test "legacy string-keyed JSON snapshots without turn or provider metadata remain restorable",
       %{
         tmp_dir: cwd
       } do
    id = "legacy-#{System.unique_integer([:positive])}"

    messages = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "old"}
    ]

    dir = Path.join(cwd, ".yoke/sessions")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{id}.json"),
      Yoke.Json.encode!(%{
        "session_id" => id,
        "messages" => messages,
        "snapshots" => [
          %{
            "id" => "legacy-cp",
            "label" => "legacy label",
            "model" => "old-model",
            "messages" => messages
          }
        ]
      })
    )

    pid = session(cwd, session_id: id)
    assert [%{id: "legacy-cp", label: "legacy label", turn: 1}] = Session.list_checkpoints(pid)
    assert {:ok, message} = Session.undo(pid)
    assert message =~ "legacy-cp"
    assert message =~ "turn: 1"
    assert {:ok, "old-model"} = Session.get_model(pid)
    assert {:ok, ^messages} = Session.get_messages(pid)
    assert [] = Session.list_checkpoints(pid)
  end

  test "new and legacy LMML snapshot turn metadata round-trips", %{tmp_dir: cwd} do
    pid = session(cwd)
    {:ok, cp} = Session.checkpoint(pid, "zero")
    state = :sys.get_state(pid)
    legacy = Map.drop(cp, [:turn, :provider_options])

    assert {:ok, narrative} =
             SessionLmml.encode(%{state | snapshots: [cp, legacy]}, state.session_id)

    assert {:ok, decoded} = SessionLmml.decode(narrative)
    assert [%{"turn" => 0}, legacy_decoded] = decoded["snapshots"]
    assert legacy_decoded["turn"] in [nil, :null]

    assert {:ok, _} = SessionStore.save_session(%{state | snapshots: [legacy]}, cwd)
    assert :ok = SessionSupervisor.stop_session(pid)
    resumed = session(cwd, session_id: state.session_id)
    assert [%{turn: 0}] = Session.list_checkpoints(resumed)
    assert {:ok, message} = Session.undo(resumed)
    assert message =~ "turn: 0"
  end

  test "manual checkpoint persistence failures retain prior snapshots", %{tmp_dir: cwd} do
    pid = session(cwd)
    assert {:ok, cp} = Session.checkpoint(pid, "saved")
    blocker = Path.join(cwd, "not-a-directory")
    File.write!(blocker, "block persistence")
    :sys.replace_state(pid, &%{&1 | cwd: blocker})
    assert {:error, reason} = Session.checkpoint(pid, "not saved")
    assert reason =~ "Could not save checkpoint"
    assert [%{id: id}] = Session.list_checkpoints(pid)
    assert id == cp.id
  end

  test "undo without checkpoints provides save/list guidance", %{tmp_dir: cwd} do
    pid = session(cwd)
    assert {:error, reason} = Session.undo(pid)
    assert reason =~ "No checkpoints"
    assert reason =~ "/checkpoint <label>"
    assert reason =~ "/checkpoint lists"
  end

  test "current context estimate changes with messages and compression but not billing", %{
    tmp_dir: cwd
  } do
    pid = session(cwd)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | messages: [%{"role" => "user", "content" => String.duplicate("history ", 2000)}],
          tools: [],
          turn_count: 7,
          total_prompt_tokens: 70_000,
          total_completion_tokens: 20_000,
          turn_history: [
            %{turn: 1, prompt_tokens: 70_000, completion_tokens: 20_000, total_tokens: 90_000}
          ]
      }
    end)

    before_stats = Session.get_token_stats(pid)
    assert before_stats.context_tokens < before_stats.total_tokens
    assert {:ok, _} = Session.compact_context(pid)
    after_stats = Session.get_token_stats(pid)
    assert after_stats.context_tokens != before_stats.context_tokens
    assert {:ok, compressed_messages} = Session.get_messages(pid)

    expected =
      div(
        String.length(Yoke.Json.encode!(%{"messages" => compressed_messages, "tools" => []})) + 3,
        4
      )

    assert after_stats.context_tokens == expected
    assert after_stats.total_tokens == 90_000
    assert after_stats.estimated_cost_usd == before_stats.estimated_cost_usd
    assert {:ok, %{turn: 7}} = Session.checkpoint(pid, "after compression")
  end

  test "runtime status excludes non-session registry entries while retaining diagnostic counts",
       %{
         tmp_dir: cwd
       } do
    before_status = Yoke.process_status()
    session(cwd)
    assert Yoke.process_status().active_sessions == before_status.active_sessions + 1
    key = {:unrelated, make_ref()}
    assert {:ok, _} = Registry.register(Yoke.Registry, key, nil)
    assert {:ok, _} = Registry.register(Yoke.Registry, "mcp_metadata_test", nil)
    assert Yoke.process_status().active_sessions == before_status.active_sessions + 1

    {:ok, worker} =
      Task.Supervisor.start_child(Yoke.TaskEngine.TaskSupervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Task.Supervisor.terminate_child(Yoke.TaskEngine.TaskSupervisor, worker) end)
    assert Yoke.process_status().active_task_workers == before_status.active_task_workers + 1
    assert is_integer(Yoke.serving_process_count())
    assert is_integer(Yoke.process_status().total_serving_processes)

    assert Yoke.report_serving_processes() =~
             "#{before_status.active_task_workers + 1} active task workers"

    refute Yoke.report_serving_processes() =~ "BEAM processes"
    refute Session.default_system_prompt() =~ "Always report how many BEAM processes"
  end

  test "invalid session list arguments warn before the recent-session fallback" do
    for arg <- ["0", "-2", "oops", "2 extra"] do
      output =
        capture_io(fn ->
          assert :continue = Yoke.CLI.Repl.handle_input("/session list " <> arg, nil, nil)
        end)

      assert output =~ "Invalid /session list argument '#{arg}'"
      assert output =~ "recent 20 sessions"
    end
  end
end

defmodule Yoke.CLI.ConfigExplorerLoadingTest do
  use ExUnit.Case, async: false

  alias Yoke.CLI.ConfigExplorer

  test "initial state does not load files and renders immediately" do
    state =
      ConfigExplorer.new_state("/not/a/workspace",
        loader: fn _, _, _ -> flunk("initial state must not call a loader") end
      )

    assert state.tree.config == %{}
    assert state.tree.sessions == []
    assert state.loader_pid == nil
    assert ConfigExplorer.switch_tab(state, 2).active_tab == :sessions

    output =
      ExUnit.CaptureIO.capture_io(:user, fn ->
        ConfigExplorer.render_full_screen(state)
      end)

    assert output =~ "Loading Settings"
  end

  test "session category lists files without reading or decoding their content" do
    cwd = Path.join(System.tmp_dir!(), "explorer_listing_#{System.unique_integer([:positive])}")
    directory = Path.join(cwd, ".yoke/sessions")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(cwd) end)
    path = Path.join(directory, "unreadable_content.lmml")
    File.write!(path, <<255, 254, 0, 1>>)

    state =
      ConfigExplorer.new_state(cwd, include_global?: false) |> ConfigExplorer.start_loading()

    on_exit(fn -> ConfigExplorer.cancel_loading(state) end)
    ref = state.load_ref
    assert_receive {:explorer_load, ^ref, :sessions, {:ok, values}}
    assert [session] = values.sessions
    assert session.path == path
    assert session.model == "not loaded"
    assert session.preview == "(open to inspect)"
  end

  test "categories complete independently and refresh rejects late results" do
    owner = self()

    loader = fn tab, _, _ ->
      send(owner, {:worker, tab, self()})
      receive do: ({:finish, value} -> value)
    end

    state = ConfigExplorer.new_state(".", loader: loader) |> ConfigExplorer.start_loading()
    workers = for _ <- 1..8, into: %{}, do: receive_worker()
    send(workers.settings, {:finish, %{config: %{"ready" => true}}})
    ref = state.load_ref
    assert_receive {:explorer_load, ^ref, :settings, {:ok, _}} = result
    state = %{ConfigExplorer.switch_tab(state, 2) | cursor: 4, detail_scroll: 7}
    state = ConfigExplorer.apply_load_result(state, result)
    assert state.loading.settings == :ready
    assert state.loading.sessions == :loading
    assert state.tree.config == %{"ready" => true}
    assert state.active_tab == :sessions
    assert state.cursor == 4
    assert state.detail_scroll == 7

    monitors = for {_tab, pid} <- workers, do: {pid, Process.monitor(pid)}
    refreshed = ConfigExplorer.refresh_state(state)
    on_exit(fn -> ConfigExplorer.cancel_loading(refreshed) end)
    assert refreshed.load_ref != ref
    assert refreshed.active_tab == :sessions
    assert refreshed.cursor == 4
    assert refreshed.detail_scroll == 7

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    end

    late = {:explorer_load, ref, :sessions, {:ok, %{sessions: [%{id: "obsolete"}]}}}
    assert ConfigExplorer.apply_load_result(refreshed, late) == refreshed
    assert refreshed.loading.settings == :loading
    assert ConfigExplorer.handle_toggle(refreshed) == refreshed
    assert ConfigExplorer.handle_delete(refreshed) == refreshed
    assert ConfigExplorer.handle_edit(refreshed) == refreshed
    assert ConfigExplorer.handle_add_rule(refreshed) == refreshed
    assert ConfigExplorer.handle_select(refreshed) == refreshed
  end

  test "timeouts and exceptions are visible and cannot be overwritten" do
    loader = fn
      :settings, _, _ -> raise "broken settings"
      _, _, _ -> Process.sleep(:infinity)
    end

    state = ConfigExplorer.new_state(".", loader: loader, load_timeout: 30)
    state = ConfigExplorer.start_loading(state)
    ref = state.load_ref

    state =
      Enum.reduce(1..8, state, fn _, acc ->
        assert_receive {:explorer_load, ^ref, _, _} = message
        ConfigExplorer.apply_load_result(acc, message)
      end)

    assert {:error, "broken settings"} = state.loading.settings
    assert {:error, "Loading timed out"} = state.loading.sessions
    late = {:explorer_load, ref, :sessions, {:ok, %{sessions: [:late]}}}
    assert ConfigExplorer.apply_load_result(state, late) == state

    output =
      ExUnit.CaptureIO.capture_io(:user, fn ->
        ConfigExplorer.render_full_screen(state)
      end)

    assert output =~ "broken settings"
    assert output =~ "Press r to retry"
  end

  test "loading workers terminate when their owner exits" do
    test = self()

    owner =
      spawn(fn ->
        loader = fn tab, _, _ ->
          send(test, {:worker, tab, self()})
          Process.sleep(:infinity)
        end

        ConfigExplorer.new_state(".", loader: loader) |> ConfigExplorer.start_loading()
        receive do: (:stop -> :ok)
      end)

    workers = for _ <- 1..8, do: receive_worker()
    monitors = for {_tab, pid} <- workers, do: {pid, Process.monitor(pid)}
    send(owner, :stop)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    end
  end

  test "TTY navigates, refreshes, and exits on EOF while every category is blocked" do
    test = self()

    loader = fn tab, _, _ ->
      send(test, {:worker, tab, self()})
      Process.sleep(:infinity)
    end

    reader = fn ->
      send(test, {:reader, self()})
      receive do: ({:key, key} -> key)
    end

    task =
      Task.async(fn ->
        ExUnit.CaptureIO.capture_io(:user, fn ->
          assert :ok = ConfigExplorer.run_tty(".", loader: loader, read_key: reader)
        end)
      end)

    workers = for _ <- 1..8, do: receive_worker()
    monitors = for {_tab, pid} <- workers, do: {pid, Process.monitor(pid)}
    assert_receive {:reader, input}
    send(input, {:key, :tab})
    assert_receive {:reader, next_input}
    send(next_input, {:key, {:char, ?r}})
    refreshed_workers = for _ <- 1..8, do: receive_worker()
    refreshed_monitors = for {_tab, pid} <- refreshed_workers, do: {pid, Process.monitor(pid)}
    assert_receive {:reader, last_input}
    input_monitor = Process.monitor(last_input)
    send(last_input, {:key, :eof})
    output = Task.await(task, 1_000)
    assert output =~ "Loading Settings"
    assert output =~ "Loading Rules"
    assert output =~ "Refreshed configuration tree"
    assert output =~ "\e[?1049l"
    assert_receive {:DOWN, ^input_monitor, :process, ^last_input, _}

    for {pid, monitor} <- monitors ++ refreshed_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    end
  end

  defp receive_worker do
    receive do
      {:worker, tab, pid} -> {tab, pid}
    after
      1_000 -> flunk("Explorer worker did not start")
    end
  end
end

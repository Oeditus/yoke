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

  test "session category loads files and populates their metadata" do
    cwd = Path.join(System.tmp_dir!(), "explorer_listing_#{System.unique_integer([:positive])}")
    directory = Path.join(cwd, ".yoke/sessions")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(cwd) end)
    path = Path.join(directory, "example_session.lmml")

    File.write!(path, """
    @@@manifest.json
    {"session_id":"example_session","model":"claude-3-opus","messages":[{"role":"user","content":"Fix the build"}]}
    @@@

    # User
    Fix the build
    """)

    assert [placeholder] =
             ConfigExplorer.list_session_files(cwd, include_global?: false, metadata?: false)

    assert placeholder.model == "not loaded"
    assert placeholder.preview == "(open to inspect)"

    state =
      ConfigExplorer.new_state(cwd, include_global?: false) |> ConfigExplorer.start_loading()

    on_exit(fn -> ConfigExplorer.cancel_loading(state) end)
    ref = state.load_ref
    assert_receive {:explorer_load, ^ref, :sessions, {:ok, values}}
    assert [session] = values.sessions
    assert session.path == path
    assert session.model == "claude-3-opus"
    assert session.preview == "Fix the build"
    assert session.msg_count == 1
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

  test "TTY automatically updates and renders loaded category on idle timeout without user keystrokes" do
    test = self()

    loader = fn
      :settings, _, _ ->
        send(test, {:settings_worker, self()})

        receive do
          :proceed -> %{config: %{"auto_update_feature" => true}}
        end

      tab, _, _ ->
        send(test, {:worker, tab, self()})
        Process.sleep(:infinity)
    end

    reader = fn _timeout ->
      send(test, {:reader_polled, self()})

      receive do
        {:key, key} -> key
      end
    end

    task =
      Task.async(fn ->
        ExUnit.CaptureIO.capture_io(:user, fn ->
          assert :ok = ConfigExplorer.run_tty(".", loader: loader, read_key: reader)
        end)
      end)

    assert_receive {:settings_worker, worker_pid}
    assert_receive {:reader_polled, reader_pid}

    # Worker finishes loading settings
    worker_monitor = Process.monitor(worker_pid)
    send(worker_pid, :proceed)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, _}
    wait_for_explorer_load(task.pid, :settings)

    # Reader returns :timeout (simulating idle timeout, no key pressed by user)
    send(reader_pid, {:key, :timeout})

    # Reader is polled again; now send :eof to cleanly exit
    assert_receive {:reader_polled, next_reader_pid}
    send(next_reader_pid, {:key, :eof})

    output = Task.await(task, 1_000)
    assert output =~ "Loading Settings"
    assert output =~ "auto_update_feature"
  end

  test "sessions tab lazily loads one screen page and supports paging next/prev" do
    cwd = Path.join(System.tmp_dir!(), "explorer_pager_#{System.unique_integer([:positive])}")
    directory = Path.join(cwd, ".yoke/sessions")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(cwd) end)

    for i <- 1..7 do
      path = Path.join(directory, "sess_#{String.pad_leading(Integer.to_string(i), 2, "0")}.lmml")

      File.write!(path, """
      @@@manifest.json
      {"session_id":"sess_#{i}","model":"deepseek-flash","messages":[{"role":"user","content":"Prompt #{i}"}]}
      @@@

      # User
      Prompt #{i}
      """)

      # Distinct mtime so ordering is deterministic
      File.touch!(path, {{2026, 11, 1}, {10, 0, i}})
    end

    state =
      ConfigExplorer.new_state(cwd, include_global?: false, sessions_page_size: 3)
      |> ConfigExplorer.switch_tab(2)
      |> ConfigExplorer.start_loading()

    on_exit(fn -> ConfigExplorer.cancel_loading(state) end)
    ref = state.load_ref

    assert_receive {:explorer_load, ^ref, :sessions, {:ok, page1}}
    assert length(page1.sessions) == 3
    assert page1.sessions_total == 7
    assert page1.sessions_offset == 0
    assert Enum.map(page1.sessions, & &1.id) == ["sess_07", "sess_06", "sess_05"]

    state =
      ConfigExplorer.apply_load_result(state, {:explorer_load, ref, :sessions, {:ok, page1}})

    page1_out =
      ExUnit.CaptureIO.capture_io(:user, fn ->
        ConfigExplorer.render_full_screen(state)
      end)

    assert page1_out =~ "Conversations: 1-3 of 7 (Page 1/3)"
    assert page1_out =~ "PgUp/PgDn or p/n: Page"

    state = ConfigExplorer.load_sessions_page(state, 3)
    assert_receive {:explorer_load, ^ref, :sessions, {:ok, page2}}
    assert length(page2.sessions) == 3
    assert page2.sessions_offset == 3
    assert Enum.map(page2.sessions, & &1.id) == ["sess_04", "sess_03", "sess_02"]

    state =
      ConfigExplorer.apply_load_result(state, {:explorer_load, ref, :sessions, {:ok, page2}})

    page2_out =
      ExUnit.CaptureIO.capture_io(:user, fn ->
        ConfigExplorer.render_full_screen(state)
      end)

    assert page2_out =~ "Conversations: 4-6 of 7 (Page 2/3)"
  end

  defp receive_worker do
    receive do
      {:worker, tab, pid} -> {tab, pid}
    after
      1_000 -> flunk("Explorer worker did not start")
    end
  end

  defp wait_for_explorer_load(pid, tab, attempts \\ 500)

  defp wait_for_explorer_load(_pid, tab, 0),
    do: flunk("Timed out waiting for #{tab} load message")

  defp wait_for_explorer_load(pid, tab, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, &match?({:explorer_load, _, ^tab, _}, &1)) do
      :ok
    else
      Process.sleep(1)
      wait_for_explorer_load(pid, tab, attempts - 1)
    end
  end
end

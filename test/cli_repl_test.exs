defmodule Yoke.CLIReplTest do
  use ExUnit.Case, async: false

  alias Yoke.Brain.SessionSupervisor
  alias Yoke.CLI.Repl

  setup do
    session_id = "repl_test_#{System.unique_integer([:positive])}"
    {:ok, session_pid} = SessionSupervisor.start_session(session_id: session_id)
    prior_god = Application.get_env(:yoke, :god_mode)

    on_exit(fn ->
      if prior_god != nil do
        Application.put_env(:yoke, :god_mode, prior_god)
      else
        Application.delete_env(:yoke, :god_mode)
      end

      cfg_path = ".yoke/config.json"

      if File.exists?(cfg_path) do
        case File.read(cfg_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, map} ->
                cleaned = Map.drop(map, ["god_mode"])
                File.write!(cfg_path, Jason.encode!(cleaned, pretty: true))

              _ ->
                :ok
            end

          _ ->
            :ok
        end
      end
    end)

    {:ok, session_pid: session_pid, session_id: session_id}
  end

  test "handles standard slash commands", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/help", pid, id)
    assert :continue = Repl.handle_input("/guide", pid, id)
    assert :continue = Repl.handle_input("/docs", pid, id)
    assert :continue = Repl.handle_input("/getting-started", pid, id)
    assert :continue = Repl.handle_input("/clear", pid, id)
    assert :continue = Repl.handle_input("/reset", pid, id)
    assert :continue = Repl.handle_input("/cost", pid, id)
    assert :continue = Repl.handle_input("/session", pid, id)
    assert :continue = Repl.handle_input("/nodes", pid, id)
    assert :continue = Repl.handle_input("/skills", pid, id)
    assert :continue = Repl.handle_input("/plugins", pid, id)
    assert :continue = Repl.handle_input("/mcp", pid, id)
    assert :continue = Repl.handle_input("/mcp list", pid, id)
    assert :continue = Repl.handle_input("/mcp ls", pid, id)
  end

  describe "/skills command surface" do
    setup do
      # Scaffold a real skill in the workspace so list/show/path have something
      # to resolve, then clean it up afterwards.
      root = Path.join(File.cwd!(), ".yoke/skills")
      name = "repl-test-skill-#{System.unique_integer([:positive])}"
      dir = Path.join(root, name)
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: #{name}
      description: A skill used by the REPL tests
      ---
      Repl test body for {{arg}}.
      """)

      Yoke.Skill.Manager.invalidate_cache()

      on_exit(fn ->
        File.rm_rf!(dir)
        Yoke.Skill.Manager.invalidate_cache()
      end)

      {:ok, skill_name: name}
    end

    test "lists, shows, and resolves paths for skills", %{
      session_pid: pid,
      session_id: id,
      skill_name: name
    } do
      assert :continue = Repl.handle_input("/skills", pid, id)
      assert :continue = Repl.handle_input("/skills show #{name}", pid, id)
      assert :continue = Repl.handle_input("/skills path #{name}", pid, id)
    end

    test "scaffolds a new skill via /skills new", %{session_pid: pid, session_id: id} do
      name = "repl-scaffold-#{System.unique_integer([:positive])}"
      path = Path.join([File.cwd!(), ".yoke/skills", name, "SKILL.md"])

      on_exit(fn ->
        File.rm_rf!(Path.dirname(path))
        Yoke.Skill.Manager.invalidate_cache()
      end)

      assert :continue = Repl.handle_input("/skills new #{name}", pid, id)
      assert File.exists?(path)
    end

    test "suggests close matches for an unknown skill", %{
      session_pid: pid,
      session_id: id,
      skill_name: name
    } do
      # Truncate the name slightly so it becomes a near-miss suggestion target.
      misspelled = String.slice(name, 0..-2//1)
      assert :continue = Repl.handle_input("/skills #{misspelled}", pid, id)
    end

    test "reports unknown skills without crashing", %{session_pid: pid, session_id: id} do
      assert :continue = Repl.handle_input("/skills definitely-not-a-skill", pid, id)
      assert :continue = Repl.handle_input("/skills show definitely-not-a-skill", pid, id)
      assert :continue = Repl.handle_input("/skills --global definitely-not-a-skill", pid, id)
    end

    test "prints usage for bare subcommand keywords", %{session_pid: pid, session_id: id} do
      assert :continue = Repl.handle_input("/skills show", pid, id)
      assert :continue = Repl.handle_input("/skills path", pid, id)
      assert :continue = Repl.handle_input("/skills edit", pid, id)
      assert :continue = Repl.handle_input("/skills new", pid, id)
    end
  end

  test "handles permission and model switching", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/permissions auto", pid, id)
    assert :continue = Repl.handle_input("/permissions ask", pid, id)
    assert :continue = Repl.handle_input("/model reasoner", pid, id)
    assert :continue = Repl.handle_input("/model chat", pid, id)
    assert :continue = Repl.handle_input("/model vision", pid, id)
    assert :continue = Repl.handle_input("/model v4", pid, id)
  end

  test "handles hands execution mode settings", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/mode local", pid, id)
    assert :continue = Repl.handle_input("/mode remote hands@127.0.0.1", pid, id)
    assert :continue = Repl.handle_input("/mode docker yoke_box", pid, id)
  end

  test "handles checkpoint and undo operations", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/checkpoint test_snap", pid, id)
    assert :continue = Repl.handle_input("/undo", pid, id)
  end

  test "handles shell command shortcut and unknown commands", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("!echo 'test_shell'", pid, id)
    assert :continue = Repl.handle_input("/unknown_command", pid, id)
  end

  test "handles the !! pure console mode flip-flop", %{session_pid: pid, session_id: id} do
    assert :toggle_console = Repl.handle_input("!!", pid, id)
    assert :toggle_console = Repl.handle_input("!!", pid, id)
  end

  test "handles exit and quit commands", %{session_pid: pid, session_id: id} do
    assert :exit = Repl.handle_input("/exit", pid, id)
    assert :exit = Repl.handle_input("/quit", pid, id)
  end

  test "handles session switch and resume commands", %{session_pid: pid, session_id: id} do
    target_id = "target_test_session"

    assert {:switch_session, ^target_id, new_pid} =
             Repl.handle_input("/session switch " <> target_id, pid, id)

    assert is_pid(new_pid)

    assert {:switch_session, ^target_id, _} = Repl.handle_input("/resume " <> target_id, pid, id)

    assert {:switch_session, ^target_id, _} =
             Repl.handle_input("/session resume " <> target_id, pid, id)
  end

  test "handles /plan slash commands without writing to the repo config", %{
    session_pid: pid,
    session_id: id
  } do
    # The /plan on|off handlers persist to the workspace .yoke/config.json
    # (cwd "."), which would pollute the repo. Back up any existing file and
    # restore it afterwards to keep the workspace clean.
    cfg_path = Path.join(File.cwd!(), ".yoke/config.json")
    backup_path = cfg_path <> ".repl_test_backup"

    existed? = File.exists?(cfg_path)

    if existed? do
      File.cp!(cfg_path, backup_path)
    end

    on_exit(fn ->
      if existed? do
        if File.exists?(backup_path) do
          File.rm(cfg_path)
          File.rename!(backup_path, cfg_path)
        end
      else
        File.rm(cfg_path)
      end
    end)

    assert :continue = Repl.handle_input("/plan status", pid, id)
    assert :continue = Repl.handle_input("/plan", pid, id)
    assert :continue = Repl.handle_input("/plan on", pid, id)
    assert :continue = Repl.handle_input("/plan off", pid, id)
    assert :continue = Repl.handle_input("/plan foo", pid, id)

    assert :continue = Repl.handle_input("/god status", pid, id)
    assert :continue = Repl.handle_input("/god", pid, id)
    assert :continue = Repl.handle_input("/god on", pid, id)
    assert Yoke.Config.god_mode?() == true
    assert :continue = Repl.handle_input("/god off", pid, id)
    assert Yoke.Config.god_mode?() == false
    assert :continue = Repl.handle_input("/god foo", pid, id)
    assert :continue = Repl.handle_input("/god on", pid, id)
  end

  test "handles review conversation commands", %{session_pid: pid, session_id: id} do
    assert :continue = Repl.handle_input("/review_conversation " <> id, pid, id)
  end

  test "survives handle_input errors and stores error in .lmml session file", %{
    session_pid: pid,
    session_id: id
  } do
    err =
      try do
        raise ArgumentError, "simulated io.put_chars failure"
      rescue
        e -> e
      end

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        # Send a private call to handle_repl_error to verify recovery & persistence
        # or simulate loop error handling
        send(self(), :test)
        # We invoke handle_repl_error via loop error path
        Repl.handle_repl_error(:error, err, [], pid, id, [])
      end)

    # Harness reported the error without crashing
    assert output =~ "REPL error caught by harness"
    assert output =~ "simulated io.put_chars failure"

    # Verify stored in session .lmml file
    {:ok, messages} = Yoke.Brain.Session.get_messages(pid)
    last_msg = List.last(messages)
    assert last_msg["role"] == "system"
    assert last_msg["content"] =~ "[HARNESS ERROR]"
    assert last_msg["content"] =~ "simulated io.put_chars failure"

    lmml_path = Path.join(".yoke/sessions", "#{id}.lmml")
    assert File.exists?(lmml_path)
    lmml_content = File.read!(lmml_path)
    assert lmml_content =~ "simulated io.put_chars failure"
  end
end

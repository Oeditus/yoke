defmodule Yoke.MCPDllbShutdownTest do
  use ExUnit.Case, async: false
  # Drives `Yoke.MCP.ServerManager`, a supervised process.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Ragex.Dllb.ProjectManager, as: DllbPM
  alias Yoke.CLI.Main
  alias Yoke.MCP.ServerManager

  setup do
    root =
      Path.join(System.tmp_dir!(), "yoke_dllb_shutdown_#{System.unique_integer([:positive])}")

    manager_state = :sys.get_state(ServerManager)
    dllb_state = :sys.get_state(DllbPM)
    mode = Application.fetch_env!(:ragex, :dllb_mode)
    Application.put_env(:ragex, :dllb_mode, :per_project)

    :sys.replace_state(
      ServerManager,
      &%{&1 | dllb_projects: MapSet.new(), ragex_status: :ready, ragex_task: nil}
    )

    on_exit(fn ->
      :sys.replace_state(ServerManager, fn _ -> manager_state end)
      :sys.replace_state(DllbPM, fn _ -> dllb_state end)
      Application.put_env(:ragex, :dllb_mode, mode)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "stops activated projects but leaves unrelated managed instances running", %{root: root} do
    {first, first_proc, first_file} = register_instance(root, "first")
    {second, second_proc, second_file} = register_instance(root, "second")
    {other, other_proc, other_file} = register_instance(root, "other")

    assert :ok = activate(first)
    assert :ok = activate(Path.join(first, "."))
    assert :ok = activate(second)
    assert MapSet.new([first, second]) == :sys.get_state(ServerManager).dllb_projects

    assert :ok = ServerManager.stop_ragex()
    assert Port.info(first_proc) == nil
    assert Port.info(second_proc) == nil
    refute File.exists?(first_file)
    refute File.exists?(second_file)
    assert Port.info(other_proc) != nil
    assert File.exists?(other_file)
    assert Map.has_key?(:sys.get_state(DllbPM).instances, other)
    assert :sys.get_state(ServerManager).dllb_projects == MapSet.new()

    assert :ok = ServerManager.stop_ragex()
    assert Port.info(other_proc) != nil
  end

  test "disconnects a borrowed instance without killing it or removing its state file", %{
    root: root
  } do
    {project, proc, instance_file} = register_instance(root, "borrowed", false)

    assert :ok = activate(project)
    assert :ok = ServerManager.stop_ragex()

    assert Port.info(proc) != nil
    assert File.exists?(instance_file)
    refute Map.has_key?(:sys.get_state(DllbPM).instances, project)
  end

  test "shutdown before any activation leaves all managed instances alone", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "other")

    assert :ok = ServerManager.stop_ragex()

    assert Port.info(proc) != nil
    assert File.exists?(instance_file)
    assert Map.has_key?(:sys.get_state(DllbPM).instances, project)
  end

  test "keeps cleanup scope when indexing fails after activation", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "failed")

    assert :ok = activate(project)
    GenServer.cast(ServerManager, {:ragex_failed, :indexing_failed})
    assert :ok = ServerManager.await_ragex()
    assert MapSet.member?(:sys.get_state(ServerManager).dllb_projects, project)

    assert :ok = ServerManager.stop_ragex()
    assert Port.info(proc) == nil
    refute File.exists?(instance_file)
  end

  for args <- [
        ["--help"],
        ["review", "--help"],
        ["lint", "--help"],
        ["rag", "--help"],
        ["fix", "--help"],
        ["review", "--unknown-option"]
      ] do
    test "CLI #{Enum.join(args, " ")} cleans up activated instances", %{root: root} do
      {project, proc, instance_file} = register_instance(root, "cli")
      assert :ok = activate(project)

      ExUnit.CaptureIO.capture_io(fn -> assert :ok = Main.main(unquote(args)) end)

      assert Port.info(proc) == nil
      refute File.exists?(instance_file)
    end
  end

  for {args, status} <- [{["lint", "--help"], 0}, {["review", "--unknown-option"], 2}] do
    test "real CLI halt preserves exit #{status} and removes instance metadata", %{root: root} do
      project = Path.join(root, "subprocess")
      instance_file = Path.join(project, ".ragex/dllb.instance.json")

      script = """
      Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test))
      Application.put_env(:ragex, :ai, providers: [])
      {:ok, _} = Application.ensure_all_started(:yoke)
      project = #{inspect(project)}
      instance_file = #{inspect(instance_file)}
      File.mkdir_p!(Path.dirname(instance_file))
      File.write!(instance_file, "{}")
      proc = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
      info = %{project_path: project, owned?: true, proc: proc, pool_pid: nil}
      :sys.replace_state(Ragex.Dllb.ProjectManager, fn state ->
        %{state | instances: Map.put(state.instances, project, info)}
      end)
      :ok = GenServer.call(Yoke.MCP.ServerManager, {:activate_dllb_project, project})
      Yoke.CLI.Main.main(#{inspect(unquote(args))})
      """

      paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

      {output, status} =
        System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
          env: [{"ERL_FLAGS", "+S 2:2"}],
          stderr_to_stdout: true
        )

      assert status == unquote(status), output
      refute File.exists?(instance_file)
    end
  end

  test "CLI exceptions clean up activated instances", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "exception")
    assert :ok = activate(project)

    assert_raise Protocol.UndefinedError, fn -> Main.main(nil) end

    assert Port.info(proc) == nil
    refute File.exists?(instance_file)
  end

  test "shutdown cancels startup and replies to pending callers", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "starting")
    assert :ok = activate(project)
    task = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(task)
    reply_tag = make_ref()
    caller = self()

    :sys.replace_state(ServerManager, fn state ->
      %{
        state
        | ragex_status: :starting,
          ragex_task: task,
          waiting_callers: [{:await, {caller, reply_tag}}]
      }
    end)

    assert :ok = ServerManager.stop_ragex()

    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert_receive {^reply_tag, {:error, :shutting_down}}
    assert Port.info(proc) == nil
    refute File.exists?(instance_file)

    assert %{ragex_status: :stopped, ragex_task: nil, waiting_callers: []} =
             :sys.get_state(ServerManager)
  end

  test "shutdown settles an in-flight activation without blocking manager queries", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "in_flight")
    {_other, other_proc, other_file} = register_instance(root, "unrelated")
    manager = Process.whereis(ServerManager)
    activation_tag = make_ref()
    shutdown_tag = make_ref()
    :sys.suspend(DllbPM)

    try do
      send(manager, {:"$gen_call", {self(), activation_tag}, {:activate_dllb_project, project}})

      assert [{_ref, %{project: ^project}}] =
               Map.to_list(:sys.get_state(manager).dllb_activations)

      assert is_list(ServerManager.list_servers())

      send(manager, {:"$gen_call", {self(), shutdown_tag}, :stop_ragex})
      assert :sys.get_state(manager).ragex_status == :stopped
      refute_receive {^shutdown_tag, :ok}, 20
      assert is_list(ServerManager.list_servers())
    after
      :sys.resume(DllbPM)
    end

    assert_receive {^activation_tag, {:error, :shutting_down}}, 3_000
    assert_receive {^shutdown_tag, :ok}, 3_000
    assert Port.info(proc) == nil
    refute File.exists?(instance_file)
    assert Port.info(other_proc) != nil
    assert File.exists?(other_file)
    assert :sys.get_state(manager).dllb_activations == %{}
    assert :sys.get_state(manager).dllb_projects == MapSet.new()
  end

  test "late startup messages cannot recreate a stopped instance", %{root: root} do
    assert :ok = ServerManager.stop_ragex()

    send(ServerManager, :auto_start_ragex)
    GenServer.cast(ServerManager, {:ragex_started, root, []})
    GenServer.cast(ServerManager, {:ragex_failed, :late_failure})

    assert {:error, :shutting_down} = activate(root)

    assert %{ragex_status: :stopped, ragex_task: nil, dllb_projects: projects} =
             :sys.get_state(ServerManager)

    assert projects == MapSet.new()
    refute Map.has_key?(:sys.get_state(DllbPM).instances, root)
    refute File.exists?(Path.join(root, ".ragex/dllb.instance.json"))
    refute Enum.any?(ServerManager.list_servers(), &(&1.name == "ragex"))
  end

  test "supervised termination cleans up activated instances", %{root: root} do
    {project, proc, instance_file} = register_instance(root, "terminate")
    assert :ok = activate(project)

    assert :ok = ServerManager.terminate(:shutdown, :sys.get_state(ServerManager))

    assert Port.info(proc) == nil
    refute File.exists?(instance_file)
  end

  defp activate(project) do
    GenServer.call(ServerManager, {:activate_dllb_project, project})
  end

  defp register_instance(root, name, owned? \\ true) do
    project = Path.join(root, name)
    instance_file = Path.join(project, ".ragex/dllb.instance.json")
    File.mkdir_p!(Path.dirname(instance_file))
    File.write!(instance_file, "{}")

    # A harmless OS process exercises real port shutdown without a database,
    # network listener, or interaction with the user's running dllb daemons.
    proc = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])

    info = %{
      project_path: project,
      owned?: owned?,
      proc: if(owned?, do: proc),
      pool_pid: nil
    }

    :sys.replace_state(DllbPM, fn state ->
      %{state | instances: Map.put(state.instances, project, info)}
    end)

    {project, proc, instance_file}
  end
end

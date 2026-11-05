defmodule Yoke.MCPDllbShutdownTest do
  use ExUnit.Case, async: false

  alias Ragex.Dllb.ProjectManager, as: DllbPM
  alias Yoke.MCP.ServerManager

  setup do
    root =
      Path.join(System.tmp_dir!(), "yoke_dllb_shutdown_#{System.unique_integer([:positive])}")

    manager_state = :sys.get_state(ServerManager)
    dllb_state = :sys.get_state(DllbPM)
    mode = Application.fetch_env!(:ragex, :dllb_mode)
    Application.put_env(:ragex, :dllb_mode, :per_project)
    :sys.replace_state(ServerManager, &%{&1 | dllb_projects: MapSet.new()})

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

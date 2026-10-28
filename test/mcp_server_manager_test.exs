defmodule Yoke.MCPServerManagerTest do
  use ExUnit.Case, async: false

  alias Yoke.MCP.ServerManager, as: MCPServerManager

  @tag ragex: true
  test "discovers ragex directory path" do
    assert {:ok, dir} = MCPServerManager.discover_ragex_dir(".")
    assert String.contains?(dir, "ragex")
    assert File.exists?(Path.join(dir, "mix.exs"))
  end

  test "lists registered mcp servers" do
    servers = MCPServerManager.list_servers()
    assert is_list(servers)
  end

  test "loads configured servers from config" do
    assert {:ok, results} = MCPServerManager.load_from_config()
    assert is_list(results) or is_map(results)
  end

  test "handles removing connected MCP server gracefully" do
    assert {:error, msg} = MCPServerManager.remove_server("non_existent_server")
    assert msg =~ "not connected"
  end

  test "reanalyzes directory with ragex on each subsequent run when branch files change" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yoke_ragex_reanalyze_test_#{System.unique_integer([:positive])}"
      )

    lib_dir = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    shared_file = Path.join(lib_dir, "shared.ex")
    branch_a_file = Path.join(lib_dir, "branch_a_only.ex")
    branch_b_file = Path.join(lib_dir, "branch_b_only.ex")
    unchanged_file = Path.join(lib_dir, "unchanged.ex")

    File.write!(unchanged_file, """
    defmodule YokeRagexTest.Unchanged do
      def stable, do: :stable
    end
    """)

    # Simulate Run 1 on Branch A
    File.write!(shared_file, """
    defmodule YokeRagexTest.Shared do
      def common_fn, do: :ok
      def branch_a_fn, do: :from_a
    end
    """)

    File.write!(branch_a_file, """
    defmodule YokeRagexTest.BranchAOnly do
      def only_a, do: :a
    end
    """)

    assert {:ok, ^tmp_dir, tools} =
             start_ragex_once(target_dir: tmp_dir, watch: false, notify: false)

    assert is_list(tools) and tools != []
    Ragex.Graph.Store.sync()

    assert Ragex.Graph.Store.get_module(YokeRagexTest.Shared) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.Shared, :common_fn, 0) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.Shared, :branch_a_fn, 0) != nil
    assert Ragex.Graph.Store.get_module(YokeRagexTest.BranchAOnly) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.BranchAOnly, :only_a, 0) != nil
    assert Ragex.Graph.Store.get_module(YokeRagexTest.BranchBOnly) == nil

    # A warm restart must neither reload the project twice nor reanalyze files.
    tracked_before = Ragex.Embeddings.FileTracker.export()

    assert {:ok, ^tmp_dir, _tools} =
             start_ragex_once(target_dir: tmp_dir, watch: false, notify: false)

    assert Ragex.Embeddings.FileTracker.export() == tracked_before
    unchanged_id = Ragex.Embeddings.FileTracker.normalize_file_id(unchanged_file)
    unchanged_metadata = tracked_before.tracked_files[unchanged_id]

    # Simulate switching to Branch B in the same directory and restarting Ragex (Run 2):
    # - shared.ex is modified (branch_a_fn removed, branch_b_fn added)
    # - branch_a_only.ex is deleted
    # - branch_b_only.ex is added
    File.rm!(branch_a_file)

    File.write!(shared_file, """
    defmodule YokeRagexTest.Shared do
      def common_fn, do: :ok
      def branch_b_fn, do: :from_b
    end
    """)

    File.write!(branch_b_file, """
    defmodule YokeRagexTest.BranchBOnly do
      def only_b, do: :b
    end
    """)

    # Existing nodes are > 0 before second run
    assert Ragex.Graph.Store.stats().nodes > 0

    assert {:ok, ^tmp_dir, _tools} =
             start_ragex_once(target_dir: tmp_dir, watch: false, notify: false)

    Ragex.Graph.Store.sync()

    # Verify new & modified symbols from Branch B are indexed
    assert Ragex.Graph.Store.get_module(YokeRagexTest.Shared) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.Shared, :common_fn, 0) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.Shared, :branch_b_fn, 0) != nil
    assert Ragex.Graph.Store.get_module(YokeRagexTest.BranchBOnly) != nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.BranchBOnly, :only_b, 0) != nil

    # Verify removed symbols from Branch A are pruned
    assert Ragex.Graph.Store.get_function(YokeRagexTest.Shared, :branch_a_fn, 0) == nil
    assert Ragex.Graph.Store.get_module(YokeRagexTest.BranchAOnly) == nil
    assert Ragex.Graph.Store.get_function(YokeRagexTest.BranchAOnly, :only_a, 0) == nil
    assert Ragex.Embeddings.FileTracker.export().tracked_files[unchanged_id] == unchanged_metadata
  end

  defp start_ragex_once(opts) do
    store = Process.whereis(Ragex.Graph.Store)
    pattern = [{[{:load_project, :_}, :_, :_], [], []}]
    :erlang.trace_pattern({Ragex.Graph.Store, :handle_call, 3}, pattern, [:local])
    :erlang.trace(store, true, [:call])

    try do
      result = MCPServerManager.start_ragex(opts)
      delivery = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^delivery}

      assert_receive {:trace, ^store, :call,
                      {Ragex.Graph.Store, :handle_call, [{:load_project, _}, _, _]}}

      refute_received {:trace, ^store, :call,
                       {Ragex.Graph.Store, :handle_call, [{:load_project, _}, _, _]}}

      result
    after
      :erlang.trace(store, false, [:call])
      :erlang.trace_pattern({Ragex.Graph.Store, :handle_call, 3}, false, [:local])
    end
  end

  test "formats validation errors with dynamic language (JS/TS support)" do
    err_atom = %{
      type: :validation_error,
      language: :javascript,
      errors: [%{line: 12, message: "Unexpected token"}]
    }

    # Verify via private format_mcp_content or through validation error payload:
    formatted_atom_str = :erlang.apply(MCPServerManager, :format_mcp_content, [err_atom])

    assert formatted_atom_str =~
             "Validation Error: Code changes produced invalid javascript syntax:"

    assert formatted_atom_str =~ "● Line 12: Unexpected token"

    err_string_keys = %{
      "type" => "validation_error",
      "language" => "typescript",
      "errors" => [%{"line" => 42, "message" => "Type mismatch"}]
    }

    formatted_str = :erlang.apply(MCPServerManager, :format_mcp_content, [err_string_keys])

    assert formatted_str =~ "Validation Error: Code changes produced invalid typescript syntax:"
    assert formatted_str =~ "● Line 42: Type mismatch"
  end
end

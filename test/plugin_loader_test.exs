defmodule Yoke.PluginLoaderTest do
  use ExUnit.Case, async: false

  alias Yoke.Plugin.Loader, as: PluginLoader

  test "lists built-in default tools" do
    tools = PluginLoader.list_tools()
    tool_names = Enum.map(tools, & &1.name)

    assert "read_file" in tool_names
    assert "read_files" in tool_names
    assert "write_file" in tool_names
    assert "replace_file" in tool_names
    assert "list_dir" in tool_names
    assert "bash" in tool_names
    assert "elixir_eval" in tool_names
    assert "ask_question" in tool_names
  end

  test "read_files reads several files in parallel and returns delimited content" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "yoke_read_files_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "a.txt"), "content of A")
    File.write!(Path.join(tmp_dir, "b.txt"), "content of B")

    {:ok, result} =
      PluginLoader.execute_tool("read_files", %{
        "paths" => [Path.join(tmp_dir, "a.txt"), Path.join(tmp_dir, "b.txt")]
      })

    assert result =~ "=== File: #{Path.join(tmp_dir, "a.txt")} ==="
    assert result =~ "content of A"
    assert result =~ "=== File: #{Path.join(tmp_dir, "b.txt")} ==="
    assert result =~ "content of B"
  end

  test "read_files reports a missing file inline without failing the others" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yoke_read_files_missing_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    good = Path.join(tmp_dir, "good.txt")
    File.write!(good, "readable")
    missing = Path.join(tmp_dir, "does_not_exist.txt")

    {:ok, result} = PluginLoader.execute_tool("read_files", %{"paths" => [good, missing]})

    assert result =~ "=== File: #{good} ==="
    assert result =~ "readable"
    assert result =~ "=== File: #{missing} ==="
    assert result =~ "[ERROR]"
  end

  test "read_files validates its paths argument" do
    assert {:error, msg} = PluginLoader.execute_tool("read_files", %{"paths" => "not_a_list"})
    assert msg =~ "Invalid 'paths'"

    assert {:error, msg} = PluginLoader.execute_tool("read_files", %{})
    assert msg =~ "Invalid arguments"
  end

  test "executes built-in elixir_eval tool" do
    {:ok, result} = PluginLoader.execute_tool("elixir_eval", %{"code" => "21 * 2"})
    assert result =~ "42"
  end

  test "dynamic plugin file compilation and hot reloading" do
    tmp_plugin_path =
      Path.join(System.tmp_dir!(), "custom_math_plugin_#{System.unique_integer([:positive])}.exs")

    code = """
    defmodule CustomMathPlugin do
      @behaviour Yoke.Plugin.Behaviour

      def name, do: "CustomMathPlugin"
      def description, do: "Custom math tools plugin"

      def tools do
        [
          %{
            name: "square",
            description: "Calculates the square of a number",
            parameters: %{
              type: "object",
              properties: %{n: %{type: "number"}},
              required: ["n"]
            },
            execute: fn %{"n" => n} -> {:ok, "\#{n * n}"} end
          }
        ]
      end
    end
    """

    File.write!(tmp_plugin_path, code)

    assert {:ok, names} = PluginLoader.load_file(tmp_plugin_path)
    assert "CustomMathPlugin" in names

    # Verify custom tool is immediately registered and executable
    {:ok, res} = PluginLoader.execute_tool("square", %{"n" => 9})
    assert res == "81"

    File.rm(tmp_plugin_path)
  end

  test "unregisters plugin modules and tool names live" do
    assert :ok = PluginLoader.unregister_plugins(["non_existent_tool_xyz"])
    tools = PluginLoader.list_tools()
    refute Enum.any?(tools, fn t -> t.name == "non_existent_tool_xyz" end)
  end

  test "grep_search and its ragex aliases work with query, pattern, and flexible arguments" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "yoke_grep_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    sub_dir = Path.join(tmp_dir, "lib/cure")
    File.mkdir_p!(sub_dir)
    target_file = Path.join(sub_dir, "repl.ex")

    File.write!(
      target_file,
      "def cmd_check(state) do\n  :ok\nend\ndef hole_goals(state), do: []\n"
    )

    # Primary query argument
    {:ok, res1} =
      PluginLoader.execute_tool("grep_search", %{"path" => sub_dir, "query" => "def cmd_check"})

    assert res1 =~ "repl.ex:1: def cmd_check(state) do"

    # Pattern alias argument (the one DeepSeek sent)
    {:ok, res2} =
      PluginLoader.execute_tool("grep_search", %{"path" => sub_dir, "pattern" => "def hole_goals"})

    assert res2 =~ "repl.ex:4: def hole_goals(state), do: []"

    # mcp_ragex_grep alias
    {:ok, res3} =
      PluginLoader.execute_tool("mcp_ragex_grep", %{
        "path" => sub_dir,
        "query" => "def cmd_check"
      })

    assert res3 =~ "repl.ex:1: def cmd_check"

    # mcp_ragex_search_code alias
    {:ok, res4} =
      PluginLoader.execute_tool("mcp_ragex_search_code", %{
        "path" => sub_dir,
        "query" => "def hole_goals"
      })

    assert res4 =~ "repl.ex:4: def hole_goals"

    # mcp_ragex_view alias to read_file
    {:ok, res5} = PluginLoader.execute_tool("mcp_ragex_view", %{"path" => target_file})
    assert res5 =~ "def cmd_check(state) do"

    # mcp_ragex_structure alias to list_dir
    {:ok, res6} = PluginLoader.execute_tool("mcp_ragex_structure", %{"path" => sub_dir})
    assert res6 =~ "repl.ex"

    # Bare ragex_grep fallback resolution
    {:ok, res7} =
      PluginLoader.execute_tool("ragex_grep", %{
        "path" => sub_dir,
        "pattern" => "cmd_check"
      })

    assert res7 =~ "repl.ex:1"
  end
end

defmodule Yoke.HandsExecutorTest do
  use ExUnit.Case, async: true

  alias Yoke.Hands.Executor

  test "executes local tool call" do
    config = %Executor{mode: :local}
    assert {:ok, _} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
  end

  test "handles remote mode with bad node" do
    config = %Executor{mode: :remote, remote_node: :bad_node@local}
    assert {:error, msg} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
    assert String.contains?(msg, "Remote node unreachable")
  end

  test "handles docker mode execution" do
    config = %Executor{mode: :docker, docker_container: "non_existent_container"}
    assert {:error, msg} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
    assert String.contains?(msg, "Docker exec exited")
  end

  test "fallbacks unhandled docker tools to local" do
    config = %Executor{mode: :docker, docker_container: "non_existent_container"}
    assert {:ok, _} = Executor.execute(config, "read_file", %{"path" => "mix.exs"})
  end

  test "returns correct tool icon for known tools" do
    assert Executor.tool_icon("read_file") == "󰈔"
    assert Executor.tool_icon("write_file") == "󰏫"
    assert Executor.tool_icon("bash") == "⚙"
    assert Executor.tool_icon("grep_search") == "󰍉"
    assert Executor.tool_icon("list_dir") == "󰉋"
    assert Executor.tool_icon("git_status") == "󰘬"
    assert Executor.tool_icon("unknown_tool") == "󰒓"
  end

  test "formats tool calls user-friendly" do
    assert Executor.format_tool_call("read_file", %{"path" => "test/git_test.exs"}) ==
             "read_file(path: \"test/git_test.exs\")"

    assert Executor.format_tool_call("bash", %{"command" => "mix test"}) ==
             "bash(command: \"mix test\")"

    assert Executor.format_tool_call("list_dir", %{}) == "list_dir()"
  end

  test "toggles tool call argument expansion mode" do
    Application.put_env(:yoke, :expand_tool_calls, false)

    collapsed =
      Executor.format_tool_call(
        "write_file",
        %{
          "path" => "test.txt",
          "content" => String.duplicate("a", 100)
        },
        max_width: 80
      )

    assert String.contains?(collapsed, "…") or String.contains?(collapsed, "payload")

    Application.put_env(:yoke, :expand_tool_calls, true)

    expanded =
      Executor.format_tool_call("write_file", %{
        "path" => "test.txt",
        "content" => String.duplicate("a", 100)
      })

    refute String.contains?(expanded, "payload")
    assert String.contains?(expanded, String.duplicate("a", 100))

    Application.put_env(:yoke, :expand_tool_calls, false)
  end

  test "smart trimming Rule 1: does not trim if tool call fits screen" do
    Application.put_env(:yoke, :expand_tool_calls, false)

    args = %{
      "path" => "lib/cure/elab/resolve.ex",
      "target" => "foo",
      "replacement" => "bar"
    }

    formatted = Executor.format_tool_call("replace_file", args, max_width: 120)

    # Fits screen (width ~73 <= 120), so no argument should be trimmed
    assert formatted ==
             "replace_file(path: \"lib/cure/elab/resolve.ex\", replacement: \"bar\", target: \"foo\")" or
             formatted ==
               "replace_file(path: \"lib/cure/elab/resolve.ex\", target: \"foo\", replacement: \"bar\")"

    refute String.contains?(formatted, "payload")
  end

  test "smart trimming Rule 2: shows shortest parts and trims longest argument when line is too long" do
    Application.put_env(:yoke, :expand_tool_calls, false)

    long_change = String.duplicate("def resolve(a, b, c) do\n  :ok\nend\n", 10)

    args = %{
      "path" => "lib/cure/elab/resolve.ex",
      "replacement" => long_change
    }

    # Set max_width = 80 so full call (~320 width) exceeds max_width
    formatted = Executor.format_tool_call("replace_file", args, max_width: 80)

    # Shortest part ("path") must be shown in full
    assert String.contains?(formatted, "path: \"lib/cure/elab/resolve.ex\"")

    # Longest part ("replacement") must be trimmed out
    refute String.contains?(formatted, long_change)
    assert String.contains?(formatted, "replacement:")
  end
end

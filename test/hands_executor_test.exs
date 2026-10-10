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

  test "bash command log displays full command when it fits max_width" do
    Application.put_env(:yoke, :expand_tool_calls, false)

    cmd = "mix test test/hands_executor_test.exs"
    formatted = Executor.format_tool_call("bash", %{"command" => cmd}, max_width: 80)

    assert formatted == ~s|bash(command: "mix test test/hands_executor_test.exs")|
    refute String.contains?(formatted, "…")
  end

  test "bash command log shows maximum possible symbols when command exceeds max_width" do
    Application.put_env(:yoke, :expand_tool_calls, false)

    long_cmd =
      "git commit -m 'feat: implement single line terminal width truncation for bash command logs in yoke CLI'"

    formatted = Executor.format_tool_call("bash", %{"command" => long_cmd}, max_width: 60)

    # Command symbols should be partially visible, not fully collapsed to `bash(command: …)`
    assert String.contains?(formatted, "git commit -m 'feat:")
    assert String.contains?(formatted, "…")
    assert Yoke.CLI.Formatter.display_width(formatted) <= 60
  end

  describe "tool categories and Unicode bullets" do
    test "classifies tools into ToolCall, ShellOut, and Other" do
      assert Executor.tool_category("read_file") == :tool_call
      assert Executor.tool_category("grep_search") == :tool_call
      assert Executor.tool_category("replace_file") == :tool_call
      assert Executor.tool_category("list_dir") == :tool_call

      assert Executor.tool_category("bash") == :shell_out
      assert Executor.tool_category("cmd") == :shell_out
      assert Executor.tool_category("run_command") == :shell_out

      assert Executor.tool_category("job_status") == :other
      assert Executor.tool_category("spawn_subagent") == :other
      assert Executor.tool_category("ask_question") == :other
      assert Executor.tool_category("run_workflow") == :other
    end

    test "returns distinct Unicode bullets for each category" do
      # ToolCall: ◈ (cyan)
      assert Executor.category_badge(:tool_call) =~ "◈"
      # ShellOut: ❯ (yellow)
      assert Executor.category_badge(:shell_out) =~ "❯"
      # Other: ⟡ (magenta)
      assert Executor.category_badge(:other) =~ "⟡"
    end

    test "humanize_action produces succinct, professional summaries" do
      assert Executor.humanize_action("read_file", %{
               "path" => "lib/cure/core/kernel.ex",
               "start_line" => 120,
               "end_line" => 180
             }) == "Read   lib/cure/core/kernel.ex:120-180"

      assert Executor.humanize_action("read_file", %{"path" => "lib/cure/core/meta_check.ex"}) ==
               "Read   lib/cure/core/meta_check.ex"

      assert Executor.humanize_action("grep_search", %{
               "path" => "lib/cure/core/kernel.ex",
               "query" => "def check\\(|def infer\\("
             }) == "Grep   /def check(|def infer(/ in lib/cure/core/kernel.ex"

      assert Executor.humanize_action("bash", %{"command" => "mix test"}) ==
               "Bash   $ mix test"

      assert Executor.humanize_action("job_status", %{"job_id" => "job_3138", "tail" => 40}) ==
               "Job    #job_3138 (tail 40)"

      assert Executor.humanize_action("list_dir", %{"path" => "lib/cure"}) ==
               "List   lib/cure"
    end

    test "format_execution_log bundles bullet and semantic text" do
      Application.put_env(:yoke, :expand_tool_calls, false)

      line_tool = Executor.format_execution_log("read_file", %{"path" => "lib/app.ex"})
      assert line_tool =~ "◈"
      assert line_tool =~ "Read   lib/app.ex"

      line_shell = Executor.format_execution_log("bash", %{"command" => "git status"})
      assert line_shell =~ "❯"
      assert line_shell =~ "Bash   $ git status"

      line_other = Executor.format_execution_log("job_status", %{"job_id" => "job_123"})
      assert line_other =~ "⟡"
      assert line_other =~ "Job    #job_123"
    end
  end
end

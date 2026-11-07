defmodule Yoke.ShellHistoryTest do
  use ExUnit.Case, async: true

  alias Yoke.ShellHistory

  setup do
    dir = Path.join(System.tmp_dir!(), "yoke_shell_history_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_history(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "last_command/1 with an explicit history file" do
    test "reads the most recent plain (bash) command", %{dir: dir} do
      path = write_history(dir, "bash_history", "mix compile\nmix test\nmix format\n")

      assert {:ok, "mix format"} = ShellHistory.last_command(history_file: path)
    end

    test "parses zsh extended history format", %{dir: dir} do
      path =
        write_history(
          dir,
          "zsh_history",
          ": 1700000000:0;mix deps.get\n: 1700000001:0;mix test --trace\n"
        )

      assert {:ok, "mix test --trace"} = ShellHistory.last_command(history_file: path)
    end

    test "skips bash HISTTIMEFORMAT timestamp marker lines", %{dir: dir} do
      path =
        write_history(dir, "bash_history", "#1700000000\nmix compile\n#1700000001\nmix test\n")

      assert {:ok, "mix test"} = ShellHistory.last_command(history_file: path)
    end

    test "parses fish history format", %{dir: dir} do
      path =
        write_history(
          dir,
          "fish_history",
          "- cmd: mix compile\n  when: 1700000000\n- cmd: mix test\n  when: 1700000001\n"
        )

      assert {:ok, "mix test"} = ShellHistory.last_command(history_file: path)
    end

    test "joins a command continued with a trailing backslash", %{dir: dir} do
      path = write_history(dir, "zsh_history", "mix test \\\n  --trace\n")

      assert {:ok, "mix test\n  --trace"} = ShellHistory.last_command(history_file: path)
    end

    test "skips Yoke's own invocations", %{dir: dir} do
      path = write_history(dir, "zsh_history", "mix test\nyoke fix\n./yoke\n")

      assert {:ok, "mix test"} = ShellHistory.last_command(history_file: path)
    end

    test "skip: 1 returns the command before the last one", %{dir: dir} do
      path = write_history(dir, "zsh_history", "mix compile\nmix test\n")

      assert {:ok, "mix compile"} = ShellHistory.last_command(history_file: path, skip: 1)
    end

    test "returns an error when the history holds only Yoke invocations", %{dir: dir} do
      path = write_history(dir, "zsh_history", "yoke\nyoke fix\n")

      assert {:error, reason} = ShellHistory.last_command(history_file: path)
      assert reason =~ "No usable command"
    end

    test "returns an error when skipping past the start of history", %{dir: dir} do
      path = write_history(dir, "zsh_history", "mix test\n")

      assert {:error, reason} = ShellHistory.last_command(history_file: path, skip: 5)
      assert reason =~ "No usable command"
    end

    test "returns an error for an unreadable history file", %{dir: dir} do
      missing = Path.join(dir, "does_not_exist")

      assert {:error, reason} = ShellHistory.last_command(history_file: missing)
      assert reason =~ "Could not read shell history"
    end

    test "an empty history file yields an error, not a crash", %{dir: dir} do
      path = write_history(dir, "empty_history", "")

      assert {:error, _reason} = ShellHistory.last_command(history_file: path)
    end
  end

  describe "yoke_invocation?/1" do
    test "recognises Yoke invocations" do
      for cmd <- ["yoke", "yoke fix", "./yoke", "./yoke_escript", "  yoke audit  "] do
        assert ShellHistory.yoke_invocation?(cmd),
               "expected #{inspect(cmd)} to be a yoke invocation"
      end
    end

    test "does not treat real commands as Yoke invocations" do
      for cmd <- ["mix test", "cargo build", "yokel --help", "git status"] do
        refute ShellHistory.yoke_invocation?(cmd)
      end
    end

    test "treats blank input as an invocation to skip" do
      assert ShellHistory.yoke_invocation?("")
      assert ShellHistory.yoke_invocation?("   ")
    end
  end

  test "candidate_files/0 always includes a zsh and a bash path" do
    files = ShellHistory.candidate_files()
    assert Enum.any?(files, &String.ends_with?(&1, ".zsh_history"))
    assert Enum.any?(files, &String.ends_with?(&1, ".bash_history"))
  end

  test "commands/1 returns every non-Yoke command, most recent first", %{dir: dir} do
    path = write_history(dir, "zsh_history", "mix compile\nyoke\nmix test\n")

    assert {:ok, commands} = ShellHistory.commands(history_file: path)
    assert commands == ["mix test", "mix compile"]
  end
end

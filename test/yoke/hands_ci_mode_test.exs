defmodule Yoke.Hands.CIModeTest do
  @moduledoc """
  Tests for the fourth Hands target, `mode: :ci` (`docs/CI_PLAN.md` §2.3).

  The property under test is a safety property, not a preference: a CI run
  must be unable to mutate the checkout unless the policy explicitly opts in.
  """
  use ExUnit.Case, async: true
  # Executes tools through `Yoke.Plugin.Loader`, a supervised process.
  # See `test/test_helper.exs`.
  @moduletag :app
  @moduletag :tmp_dir

  alias Yoke.Hands.Executor
  alias Yoke.Interaction.Policy

  describe "write_tool?/2" do
    test "flags every file-mutating tool" do
      for tool <- ~w(
            write_file write_to_file create_file save_file replace_file
            replace_file_content edit_file edit_files patch_file apply_diff
            git_commit git_push git_merge git_reset
            mcp_ragex_edit_file mcp_ragex_edit_files mcp_ragex_refactor_code
            mcp_ragex_advanced_refactor mcp_ragex_rollback_edit
          ) do
        assert Executor.write_tool?(tool), "expected #{tool} to be write-capable"
      end
    end

    test "treats read-only tools as safe" do
      for tool <- ~w(read_file read_files list_dir grep_search glob_search git_diff git_root) do
        refute Executor.write_tool?(tool), "expected #{tool} to be read-only"
      end
    end

    test "refuses every shell tool regardless of the command string" do
      # A read-only CI target cannot decide whether an arbitrary shell command
      # writes, so it refuses the shell outright. Each of these slipped past the
      # substring classifier this used to delegate to.
      for command <- [
            "ls -la",
            "git status",
            "mix test",
            "grep -rn foo lib",
            "rm -rf build",
            "sed -i 's/a/b/' file.ex",
            "git commit -m wip",
            "echo hi > out.txt",
            "echo hi>out.txt",
            "tee out.txt",
            "python3 -c \"open('f','w').write('x')\"",
            "perl -pi -e 's/a/b/' f",
            "git checkout -- .",
            "truncate -s0 f",
            "ln -sf /etc/passwd f",
            "find . -delete"
          ] do
        assert Executor.write_tool?("bash", %{"command" => command}),
               "expected bash '#{command}' to be refused in :ci mode"
      end
    end

    test "refuses every shell tool alias" do
      for tool <- ~w(bash cmd run_command shell exec) do
        assert Executor.write_tool?(tool, %{"command" => "ls"}),
               "expected #{tool} to be refused in :ci mode"
      end
    end

    test "tolerates non-string and missing arguments" do
      # The tool name alone is enough: a shell tool is write-capable without
      # inspecting its arguments at all.
      assert Executor.write_tool?("bash")
      assert Executor.write_tool?("bash", %{})
      refute Executor.write_tool?(:read_file, %{})
      refute Executor.write_tool?(nil, %{})
    end
  end

  describe "authorize_ci_write/3" do
    test "refuses writes by default", %{tmp_dir: dir} do
      executor = %Executor{mode: :ci, cwd: dir}

      assert {:error, reason} = Executor.authorize_ci_write("write_file", %{}, executor)
      assert reason =~ "read-only"
      assert reason =~ "allow_writes"
    end

    test "permits read-only calls by default", %{tmp_dir: dir} do
      executor = %Executor{mode: :ci, cwd: dir}
      assert :ok = Executor.authorize_ci_write("read_file", %{"path" => "mix.exs"}, executor)
    end

    test "an explicit struct override wins over the policy file", %{tmp_dir: dir} do
      Policy.write(dir, %{"allow_writes" => true})

      locked = %Executor{mode: :ci, cwd: dir, allow_writes: false}
      assert {:error, _} = Executor.authorize_ci_write("write_file", %{}, locked)

      Policy.write(dir, %{"allow_writes" => false})
      unlocked = %Executor{mode: :ci, cwd: dir, allow_writes: true}
      assert :ok = Executor.authorize_ci_write("write_file", %{}, unlocked)
    end

    test "the policy file can opt in to writes", %{tmp_dir: dir} do
      Policy.write(dir, %{"allow_writes" => true})
      executor = %Executor{mode: :ci, cwd: dir}
      assert :ok = Executor.authorize_ci_write("write_file", %{}, executor)
    end
  end

  describe "execute/3 in :ci mode" do
    test "a write is refused before the tool ever runs", %{tmp_dir: dir} do
      target = Path.join(dir, "should-not-exist.txt")
      executor = %Executor{mode: :ci, cwd: dir}

      assert {:error, reason} =
               Executor.execute(executor, "write_file", %{
                 "path" => target,
                 "content" => "mutated"
               })

      assert reason =~ "read-only"
      refute File.exists?(target)
    end

    test "a read-only tool executes normally", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hi there")
      executor = %Executor{mode: :ci, cwd: dir}

      # Tools resolve paths against the process working directory, not the
      # executor's `cwd` field (which is only used to locate the policy file),
      # so this uses an absolute path.
      assert {:ok, output} = Executor.execute(executor, "read_file", %{"path" => path})
      assert output =~ "hi there"
    end

    test "a per-call timeout is enforced", %{tmp_dir: dir} do
      executor = %Executor{mode: :ci, cwd: dir, timeout_ms: 1}

      # `bash` is refused outright in `:ci` mode (a read-only target cannot
      # decide whether an arbitrary shell command writes), so the timeout is
      # exercised through a write-allowed executor instead.
      allowed = %Executor{mode: :ci, cwd: dir, timeout_ms: 1, allow_writes: true}

      assert {:error, reason} = Executor.execute(allowed, "bash", %{"command" => "sleep 5"})
      assert reason =~ "budget"

      # The refusal is still the default answer for the same call.
      assert {:error, refused} = Executor.execute(executor, "bash", %{"command" => "sleep 5"})
      assert refused =~ "read-only"
    end

    test "the default executor mode is unchanged (:local)", %{tmp_dir: dir} do
      assert %Executor{}.mode == :local

      # A `:local` executor is not subject to the CI write refusal.
      target = Path.join(dir, "local-ok.txt")
      File.write!(target, "original")

      assert {:ok, _} =
               Executor.execute(%Executor{mode: :local}, "read_file", %{"path" => target})
    end
  end
end

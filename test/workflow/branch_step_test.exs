defmodule Yoke.Workflow.BranchStepTest do
  # Not async: `Branch.run/2` consults `Yoke.Interaction.ask/2` on non-base
  # branches, which reads global `:yoke, :interaction` / `:yoke, :god_mode`
  # application env, and this module installs `Yoke.Test.StubInteraction`.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Workflow.Steps.Branch

  setup do
    prior = Application.get_env(:yoke, :interaction)
    Application.put_env(:yoke, :interaction, Yoke.Test.StubInteraction)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:yoke, :interaction),
        else: Application.put_env(:yoke, :interaction, prior)
    end)

    :ok
  end

  defp git!(dir, args) do
    {out, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp init_repo!(dir) do
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "a.txt"), "one\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "first"])
  end

  defp context(dir) do
    {:ok, definition} = Yoke.Workflow.Definition.load("elixir")
    %{workflow: definition, run_id: "run-#{System.unique_integer([:positive])}", cwd: dir}
  end

  describe "Steps.Branch.run/2 checkout states" do
    # The step used to branch from `Git.current_branch/1`, which collapses both
    # "detached HEAD" and "not a repository" to `""`. The user was then asked to
    # confirm branching off `''` -- a dead end with no actionable information.
    test "halts with an actionable message on a detached HEAD", %{tmp_dir: dir} do
      init_repo!(dir)
      git!(dir, ["checkout", "-q", "--detach"])
      sha = String.trim(git!(dir, ["rev-parse", "--short", "HEAD"]))

      assert {:halt, reason} = Branch.run(context(dir), %{})

      assert reason =~ "detached HEAD"
      assert reason =~ sha
      assert reason =~ "Check out a branch first"
      # The old message named an empty branch.
      refute reason =~ "''"
    end

    test "halts with an actionable message outside a Git repository" do
      # `@moduletag :tmp_dir` puts the directory inside this repository, which
      # *is* a working tree, so use a path that is guaranteed to be outside one.
      dir = Path.join(System.tmp_dir!(), "yoke-norepo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:halt, reason} = Branch.run(context(dir), %{})

      assert reason =~ "not a Git working tree"
      assert reason =~ "Git repository"
      refute reason =~ "fatal:"
      refute reason =~ "''"
    end

    test "creates the workflow branch when on a base branch", %{tmp_dir: dir} do
      init_repo!(dir)
      ctx = context(dir)

      assert {:ok, new_ctx} = Branch.run(ctx, %{})
      assert new_ctx.original_branch == "main"
      assert new_ctx.branch == "yoke/elixir/#{ctx.run_id}"

      assert String.trim(git!(dir, ["branch", "--show-current"])) == new_ctx.branch
    end
  end
end

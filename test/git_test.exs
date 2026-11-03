defmodule Yoke.GitTest do
  use ExUnit.Case, async: true

  alias Yoke.Git

  test "returns git status and diff" do
    assert {:ok, _status} = Git.status()
    assert {:ok, _diff} = Git.diff()
    assert {:ok, _diff_head} = Git.diff("HEAD")
    assert {:ok, root} = Git.root_dir()
    assert is_binary(root) and root != ""
  end

  test "diff_branches compares HEAD against HEAD" do
    assert {:ok, data} = Git.diff_branches("HEAD", "HEAD")
    assert data.base == "HEAD"
    assert data.head == "HEAD"
    assert is_binary(data.stat)
  end

  # The functions below mutate branch/worktree state, so every test below
  # operates on a throwaway tmp repo instead of this project's own working
  # tree, and cleans it up afterwards.
  describe "create_branch/2 and branch_exists?/2" do
    setup [:tmp_repo]

    test "creates and checks out a new branch", %{repo: repo} do
      assert {:ok, _} = Git.create_branch("feature/one", repo)
      assert Git.current_branch(repo) == "feature/one"
    end

    test "fails when the branch already exists", %{repo: repo} do
      assert {:ok, _} = Git.create_branch("feature/dup", repo)
      assert {:ok, _} = Git.checkout("main", repo)
      assert {:error, _reason} = Git.create_branch("feature/dup", repo)
    end

    test "reports existence of a branch accurately", %{repo: repo} do
      assert Git.branch_exists?("main", repo)
      refute Git.branch_exists?("does-not-exist", repo)
    end

    test "default_base_branch/1 resolves 'main' when main exists", %{repo: repo} do
      assert Git.default_base_branch(repo) == "main"
    end

    test "default_base_branch/1 resolves 'master' when main does not exist" do
      master_repo =
        Path.join(System.tmp_dir!(), "yoke_git_master_#{System.unique_integer([:positive])}")

      File.mkdir_p!(master_repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "master"], cd: master_repo)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: master_repo)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: master_repo)
      File.write!(Path.join(master_repo, "README.md"), "hello master\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: master_repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial master"], cd: master_repo)

      on_exit(fn -> File.rm_rf(master_repo) end)

      refute Git.branch_exists?("main", master_repo)
      assert Git.branch_exists?("master", master_repo)
      assert Git.default_base_branch(master_repo) == "master"

      # diff_branches with nil or "main" automatically uses master
      assert {:ok, diff1} = Git.diff_branches(nil, "HEAD", master_repo)
      assert diff1.base == "master"

      assert {:ok, diff2} = Git.diff_branches("main", "HEAD", master_repo)
      assert diff2.base == "master"
    end

    test "default_base_branch/1 honors configured default_branch", %{repo: repo} do
      {:ok, _} = Git.create_branch("develop", repo)

      cfg = %{"default_branch" => "develop"}
      assert :ok = Yoke.Config.save_config(cfg, repo)

      assert Git.default_base_branch(repo) == "develop"

      # When configured branch does not exist, it falls back to main
      cfg_bad = %{"default_branch" => "nonexistent"}
      assert :ok = Yoke.Config.save_config(cfg_bad, repo)

      assert Git.default_base_branch(repo) == "main"
    end
  end

  describe "add_worktree/3 and remove_worktree/2" do
    setup [:tmp_repo]

    test "creates an isolated worktree on a new branch", %{repo: repo} do
      worktree_path =
        Path.join(System.tmp_dir!(), "yoke_worktree_#{System.unique_integer([:positive])}")

      assert {:ok, _} = Git.add_worktree(worktree_path, "subtask/a", repo)
      assert File.dir?(worktree_path)
      assert Git.current_branch(worktree_path) == "subtask/a"

      # Writing a file in the worktree must never appear in the main repo's
      # working tree -- that's the whole point of filesystem isolation.
      File.write!(Path.join(worktree_path, "isolated.txt"), "only here\n")
      refute File.exists?(Path.join(repo, "isolated.txt"))

      assert {:ok, _} = Git.remove_worktree(worktree_path, repo)
      refute File.dir?(worktree_path)
    end

    test "reuses an existing branch instead of failing when it already exists", %{repo: repo} do
      assert {:ok, _} = Git.create_branch("subtask/existing", repo)
      assert {:ok, _} = Git.checkout("main", repo)

      worktree_path =
        Path.join(
          System.tmp_dir!(),
          "yoke_worktree_existing_#{System.unique_integer([:positive])}"
        )

      assert {:ok, _} = Git.add_worktree(worktree_path, "subtask/existing", repo)
      assert Git.current_branch(worktree_path) == "subtask/existing"

      Git.remove_worktree(worktree_path, repo)
    end
  end

  describe "merge/3 and abort_merge/1" do
    setup [:tmp_repo]

    test "merges a clean branch back in", %{repo: repo} do
      {:ok, _} = Git.create_branch("feature/clean", repo)
      File.write!(Path.join(repo, "new_file.txt"), "content\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "add file"], cd: repo)

      {:ok, _} = Git.checkout("main", repo)
      assert {:ok, _out} = Git.merge("feature/clean", repo)
      assert File.exists?(Path.join(repo, "new_file.txt"))
    end

    test "reports a conflict instead of a generic error", %{repo: repo} do
      {:ok, _} = Git.create_branch("feature/conflict", repo)
      File.write!(Path.join(repo, "README.md"), "from feature\n")
      {_, 0} = System.cmd("git", ["commit", "-q", "-am", "feature change"], cd: repo)

      {:ok, _} = Git.checkout("main", repo)
      File.write!(Path.join(repo, "README.md"), "from main\n")
      {_, 0} = System.cmd("git", ["commit", "-q", "-am", "main change"], cd: repo)

      assert {:conflict, out} = Git.merge("feature/conflict", repo)
      assert out =~ "CONFLICT"

      assert {:ok, _} = Git.abort_merge(repo)
    end
  end

  defp tmp_repo(_context) do
    repo = Path.join(System.tmp_dir!(), "yoke_git_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: repo)

    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial"], cd: repo)

    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo}
  end
end

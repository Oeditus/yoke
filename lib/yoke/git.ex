defmodule Yoke.Git do
  @moduledoc """
  Git awareness module. Provides repository status, formatted ANSI diffs,
  and structured commit generation for Yoke.
  """

  @doc "Returns git status output."
  def status(cwd \\ ".") do
    case System.cmd("git", ["status", "--short"], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git status exited with status #{code}: #{out}"}
    end
  rescue
    e -> {:error, "Git not available: #{Exception.message(e)}"}
  end

  @doc "Returns true when the workspace has uncommitted changes (staged, unstaged, or untracked)."
  def dirty?(cwd \\ ".") do
    case status(cwd) do
      {:ok, ""} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc "Returns absolute path to the top-level root of the git repository (git rev-parse --show-toplevel)."
  def root_dir(cwd \\ ".") do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git rev-parse --show-toplevel exited with status #{code}: #{out}"}
    end
  rescue
    e -> {:error, "Git not available: #{Exception.message(e)}"}
  end

  @doc "Returns current git branch name or empty string."
  def current_branch(cwd \\ ".") do
    case System.cmd("git", ["branch", "--show-current"], cd: cwd, stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @doc """
  Runs an arbitrary git subcommand with its arguments, returning the raw
  stdout. This is the generic passthrough backing the `/git <subcommand>`
  REPL command. The `args` string is split on whitespace and passed directly
  to `git`; no shell is involved, so no shell injection risk.
  """
  def run(args, cwd \\ ".") when is_binary(args) do
    argv = String.split(args, " ", trim: true)

    case System.cmd("git", argv, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git #{args} exited with status #{code}:\n#{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git command failed: #{Exception.message(e)}"}
  end

  @doc "Returns formatted git diff output against working tree or target branch/commit."
  def diff(target_or_cwd \\ nil, cwd \\ ".")

  def diff(target, cwd) when is_binary(target) and target != "." and not is_nil(target) do
    target_str = String.trim(target)

    if target_str == "" or target_str == "." do
      diff(nil, cwd)
    else
      case System.cmd("git", ["diff", target_str], cd: cwd, stderr_to_stdout: true) do
        {out, 0} ->
          clean_out = Yoke.Json.sanitize_utf8(out)

          if String.trim(clean_out) == "" do
            {:ok, "No diff changes against '#{target_str}'."}
          else
            {:ok, colorize_diff(clean_out)}
          end

        {out, code} ->
          {:error,
           "git diff #{target_str} exited with status #{code}: #{Yoke.Json.sanitize_utf8(out)}"}
      end
    end
  rescue
    e -> {:error, "Git diff failed: #{Exception.message(e)}"}
  end

  def diff(_, cwd) do
    case System.cmd("git", ["diff"], cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        clean_out = Yoke.Json.sanitize_utf8(out)

        if String.trim(clean_out) == "" do
          {:ok, "No unstaged changes in git repository."}
        else
          {:ok, colorize_diff(clean_out)}
        end

      {out, code} ->
        {:error, "git diff exited with status #{code}: #{Yoke.Json.sanitize_utf8(out)}"}
    end
  rescue
    e -> {:error, "Git diff failed: #{Exception.message(e)}"}
  end

  @doc "Stages all changes and creates a git commit."
  def commit(message, cwd \\ ".") do
    with {_, 0} <- System.cmd("git", ["add", "."], cd: cwd, stderr_to_stdout: true),
         {out, 0} <- System.cmd("git", ["commit", "-m", message], cd: cwd, stderr_to_stdout: true) do
      {:ok, String.trim(out)}
    else
      {out, code} -> {:error, "Git commit failed (code #{code}): #{out}"}
    end
  rescue
    e -> {:error, "Git commit exception: #{Exception.message(e)}"}
  end

  @doc "Compares two git branches and returns stat, commit log, and diff payload."
  def diff_branches(base_branch, head_branch \\ "HEAD", cwd \\ ".") do
    range = "#{base_branch}...#{head_branch}"
    log_range = "#{base_branch}..#{head_branch}"

    with {stat, 0} <-
           System.cmd("git", ["diff", "--stat", range], cd: cwd, stderr_to_stdout: true),
         {log, 0} <-
           System.cmd("git", ["log", "--oneline", log_range], cd: cwd, stderr_to_stdout: true),
         {raw_diff, 0} <- System.cmd("git", ["diff", range], cd: cwd, stderr_to_stdout: true) do
      diff_payload =
        if byte_size(raw_diff) > 300_000 do
          binary_part(raw_diff, 0, 300_000)
          |> Yoke.Json.sanitize_utf8()
          |> Kernel.<>("\n... [Diff truncated at 300KB]")
        else
          Yoke.Json.sanitize_utf8(raw_diff)
        end

      {:ok,
       %{
         base: base_branch,
         head: head_branch,
         stat: String.trim(stat),
         log: String.trim(log),
         raw_diff: diff_payload,
         color_diff: colorize_diff(diff_payload)
       }}
    else
      {err, code} ->
        {:error,
         "Failed to compare branches (#{base_branch} vs #{head_branch}, code #{code}): #{err}"}
    end
  rescue
    e -> {:error, "Branch comparison exception: #{Exception.message(e)}"}
  end

  @doc """
  Creates and checks out a new local branch from the current HEAD.
  Fails if a branch with that name already exists.
  """
  def create_branch(name, cwd \\ ".") when is_binary(name) do
    case System.cmd("git", ["checkout", "-b", name], cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, code} ->
        {:error, "git checkout -b #{name} exited with status #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git branch creation failed: #{Exception.message(e)}"}
  end

  @doc "Checks out an existing local branch (does not create one)."
  def checkout(name, cwd \\ ".") when is_binary(name) do
    case System.cmd("git", ["checkout", name], cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, code} ->
        {:error, "git checkout #{name} exited with status #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git checkout failed: #{Exception.message(e)}"}
  end

  @doc "Returns whether a local branch with the given name exists."
  def branch_exists?(name, cwd \\ ".") when is_binary(name) do
    case System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/#{name}"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Adds a git worktree at `path`, creating a new branch `branch` from the
  current HEAD (or checking out `branch` in the new worktree if it
  already exists). Used to give each parallel workflow subtask its own
  isolated working tree, so concurrent agent processes can never write to
  the same files on disk even when their task split wasn't perfectly
  non-overlapping.
  """
  def add_worktree(path, branch, cwd \\ ".") do
    args =
      if branch_exists?(branch, cwd) do
        ["worktree", "add", path, branch]
      else
        ["worktree", "add", path, "-b", branch]
      end

    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git worktree add failed (status #{code}): #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git worktree creation failed: #{Exception.message(e)}"}
  end

  @doc "Removes a previously created git worktree, discarding any local changes within it."
  def remove_worktree(path, cwd \\ ".") do
    case System.cmd("git", ["worktree", "remove", path, "--force"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git worktree remove failed (status #{code}): #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git worktree removal failed: #{Exception.message(e)}"}
  end

  @doc """
  Merges `branch` into the current branch. Distinguishes a merge conflict
  (`{:conflict, output}`) from any other failure (`{:error, reason}`) so
  callers can decide whether to pause for manual resolution instead of
  treating every non-zero exit the same way.
  """
  def merge(branch, cwd \\ ".", opts \\ []) do
    strategy_flags = if Keyword.get(opts, :no_ff, true), do: ["--no-ff"], else: []

    case System.cmd("git", ["merge" | strategy_flags ++ [branch]],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _code} ->
        if String.contains?(out, "CONFLICT") or String.contains?(out, "Automatic merge failed") do
          {:conflict, String.trim(out)}
        else
          {:error, String.trim(out)}
        end
    end
  rescue
    e -> {:error, "Git merge failed: #{Exception.message(e)}"}
  end

  @doc "Aborts an in-progress merge, e.g. after a `{:conflict, _}` result the user chooses not to resolve."
  def abort_merge(cwd \\ ".") do
    case System.cmd("git", ["merge", "--abort"], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git merge --abort failed (status #{code}): #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git merge abort failed: #{Exception.message(e)}"}
  end

  defp colorize_diff(raw_diff) do
    raw_diff
    |> String.split("\n")
    |> Enum.map_join("\n", &colorize_line/1)
  end

  defp colorize_line("+++" <> _ = line), do: line
  defp colorize_line("---" <> _ = line), do: line
  defp colorize_line("+" <> _ = line), do: IO.ANSI.green() <> line <> IO.ANSI.reset()
  defp colorize_line("-" <> _ = line), do: IO.ANSI.red() <> line <> IO.ANSI.reset()
  defp colorize_line("@@" <> _ = line), do: IO.ANSI.cyan() <> line <> IO.ANSI.reset()
  defp colorize_line(line), do: line
end

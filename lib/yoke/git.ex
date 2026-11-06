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

  @doc "Lists changed paths with the same configuration-independent semantics as review diffs."
  def review_changed_paths(merge_base, head_sha, cwd) do
    case System.cmd("git", review_diff_args("#{merge_base}..#{head_sha}", ["--name-only", "-z"]),
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {paths, 0} -> {:ok, MapSet.new(String.split(paths, <<0>>, trim: true))}
      {_error, _} -> {:error, "Cannot list files in the reviewed diff."}
    end
  end

  @doc "Resolves a revision once, without allowing revision arguments to become Git options."
  def resolve_revision(ref, cwd \\ ".") when is_binary(ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _} -> {:error, "Cannot resolve review revision #{inspect(ref)} in #{cwd}."}
    end
  rescue
    e -> {:error, "Cannot resolve review revision: #{Exception.message(e)}"}
  end

  # Default cap on the size of a review diff, in bytes.
  #
  # 300 KB is a good default: it bounds both the model's context cost and the
  # CI job's runtime. Repositories can tighten it with `max_diff_bytes` in
  # `.yoke/policy.json`.
  @default_max_diff_bytes 300_000

  @doc "Returns the effective review-diff cap in bytes for `cwd`."
  @spec max_diff_bytes(String.t()) :: non_neg_integer()
  def max_diff_bytes(cwd \\ ".") do
    case Yoke.Interaction.Policy.load(cwd)["max_diff_bytes"] do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_max_diff_bytes
    end
  end

  defp complete_review_diff(diff, cwd) do
    limit = max_diff_bytes(cwd)

    if byte_size(diff) > limit do
      {:error,
       "Review diff exceeds #{div(limit, 1000)} KB. Review a smaller commit range; " <>
         "no partial review was generated."}
    else
      :ok
    end
  end

  defp review_diff_args(range, extra \\ []) do
    [
      "--no-pager",
      "-c",
      "core.quotePath=false",
      "-c",
      "diff.noprefix=false",
      "-c",
      "diff.mnemonicPrefix=false",
      "diff",
      "--no-ext-diff",
      "--no-textconv",
      "--no-color",
      "--no-relative",
      "--ignore-submodules=none",
      "--src-prefix=a/",
      "--dst-prefix=b/",
      "--unified=3"
    ] ++ extra ++ [range, "--"]
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
    base_branch =
      cond do
        is_nil(base_branch) or base_branch == "" ->
          default_base_branch(cwd)

        base_branch == "main" and not branch_exists?("main", cwd) and
            branch_exists?("master", cwd) ->
          "master"

        true ->
          base_branch
      end

    with {:ok, base_sha} <- resolve_revision(base_branch, cwd),
         {:ok, head_sha} <- resolve_revision(head_branch, cwd),
         {merge_base, 0} <-
           System.cmd("git", ["merge-base", base_sha, head_sha], cd: cwd, stderr_to_stdout: true),
         range = "#{String.trim(merge_base)}..#{head_sha}",
         {stat, 0} <-
           System.cmd("git", review_diff_args(range, ["--stat"]), cd: cwd, stderr_to_stdout: true),
         {log, 0} <-
           System.cmd("git", ["--no-pager", "log", "--oneline", range, "--"],
             cd: cwd,
             stderr_to_stdout: true
           ),
         {raw_diff, 0} <-
           System.cmd(
             "git",
             review_diff_args(range),
             cd: cwd,
             stderr_to_stdout: true
           ),
         :ok <- complete_review_diff(raw_diff, cwd) do
      diff_payload = Yoke.Json.sanitize_utf8(raw_diff)

      {:ok,
       %{
         base: base_branch,
         head: head_branch,
         base_sha: base_sha,
         head_sha: head_sha,
         merge_base: String.trim(merge_base),
         stat: String.trim(stat),
         log: String.trim(log),
         raw_diff: diff_payload,
         color_diff: colorize_diff(diff_payload)
       }}
    else
      {:error, reason} ->
        {:error, reason}

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

  @doc """
  Returns whether a branch or revision reference with the given name exists.
  Checks local branches (refs/heads/), remote branches (refs/remotes/), and commit objects.
  """
  def branch_exists?(name, cwd \\ ".") when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      false
    else
      cond do
        match?(
          {_, 0},
          System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/#{name}"],
            cd: cwd,
            stderr_to_stdout: true
          )
        ) ->
          true

        match?(
          {_, 0},
          System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/remotes/#{name}"],
            cd: cwd,
            stderr_to_stdout: true
          )
        ) ->
          true

        match?(
          {_, 0},
          System.cmd("git", ["rev-parse", "--verify", "--quiet", "#{name}^{commit}"],
            cd: cwd,
            stderr_to_stdout: true
          )
        ) ->
          true

        true ->
          false
      end
    end
  rescue
    _ -> false
  end

  @doc """
  Determines the default base branch to compare against for code reviews and branch diffs.

  Checks configured `default_branch` in `Yoke.Config` first.
  If not configured (or if the configured branch does not exist), probes:
  1. `main` (local or remote reference)
  2. `master` (local or remote reference)
  3. `origin/main`
  4. `origin/master`
  5. Falls back to configured branch (if set) or `"main"`.
  """
  def default_base_branch(cwd \\ ".") do
    configured =
      case Yoke.Config.default_branch(cwd) do
        branch when is_binary(branch) ->
          trimmed = String.trim(branch)
          if trimmed in ["", "auto", "default"], do: nil, else: trimmed

        _ ->
          nil
      end

    if configured &&
         (branch_exists?(configured, cwd) or branch_exists?("origin/#{configured}", cwd)) do
      if branch_exists?(configured, cwd), do: configured, else: "origin/#{configured}"
    else
      cond do
        branch_exists?("main", cwd) ->
          "main"

        branch_exists?("master", cwd) ->
          "master"

        branch_exists?("origin/main", cwd) ->
          "origin/main"

        branch_exists?("origin/master", cwd) ->
          "origin/master"

        configured != nil ->
          configured

        true ->
          "main"
      end
    end
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

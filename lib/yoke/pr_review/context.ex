defmodule Yoke.PRReview.Context do
  @moduledoc """
  Immutable evidence and identity shared by review generation and submission.
  Branch reviews inspect committed changes only. PR reviews fetch verified objects
  without checking out branches or modifying the user's index or working tree.
  """
  alias Yoke.Git
  alias Yoke.PRReview

  @doc "Resolves command arguments into an authoritative review context."
  def resolve(args, cwd \\ ".") do
    case String.split(String.trim(args), ~r/\s+/, trim: true) do
      [] ->
        from_branches(Git.default_base_branch(cwd), "HEAD", cwd)

      [target] ->
        if Regex.match?(~r/^\d+$/, target),
          do: from_pr(target, cwd),
          else: from_branches(target, "HEAD", cwd)

      [base, head] ->
        from_branches(base, head, cwd)

      _ ->
        {:error, "Usage: /review [<base> [<head>] | <pr_number>]"}
    end
  end

  defp matching_remote(repository, host, cwd) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: cwd, stderr_to_stdout: true) do
      {url, 0} ->
        normalized =
          Regex.replace(~r/^([^@\/]+)@([^:\/]+):(.+)$/, String.trim(url), "ssh://\\1@\\2/\\3")

        uri = URI.parse(normalized)
        path = (uri.path || "") |> String.trim_leading("/") |> String.trim_trailing(".git")

        if String.downcase(uri.host || "") == String.downcase(host) and
             String.downcase(path) == String.downcase(repository),
           do: "origin"

      _ ->
        nil
    end
  end

  @doc "Builds complete evidence from two pinned commit objects."
  def from_branches(base, head, cwd \\ ".") do
    with {:ok, root} <- Git.root_dir(cwd),
         {:ok, data} <- Git.diff_branches(base, head, root),
         :ok <- nonempty(data.raw_diff),
         {:ok, paths} <- Git.review_changed_paths(data.merge_base, data.head_sha, root) do
      {:ok,
       Map.merge(data, %{
         cwd: root,
         pr_number: nil,
         pr_url: nil,
         repository: nil,
         peer_comments: [],
         changed_paths: paths,
         valid_lines: PRReview.parse_diff_right_lines(data.raw_diff)
       })}
    end
  end

  @doc "Obtains PR identity and exact object IDs, never substituting the current branch."
  def from_pr(number, cwd \\ ".") do
    with {:ok, info} <- PRReview.detect_pr(number, cwd),
         :ok <- valid_pr_revisions(info),
         {:ok, repository} <- PRReview.get_repo_name(cwd),
         {:ok, root} <- Git.root_dir(cwd),
         :ok <- fetch_pr_objects(repository, info, root),
         {:ok, context} <- from_branches(info.base_sha, info.head_sha, root) do
      comments =
        case PRReview.fetch_peer_comments(number, cwd: root, pr_author: info.author) do
          {:ok, comments} -> comments
          _ -> []
        end

      {:ok,
       %{
         context
         | base: info.base,
           head: info.head,
           pr_number: to_string(info.number),
           pr_url: info.url,
           repository: repository,
           peer_comments: comments
       }}
    end
  rescue
    e -> {:error, "Cannot prepare PR review: #{Exception.message(e)}"}
  end

  @doc "Rejects findings without an anchor in the actual reviewed diff."
  def validate_findings(findings, context) do
    invalid =
      Enum.reject(findings, fn finding ->
        cond do
          PRReview.endorsement?(finding) and is_nil(finding.file) ->
            true

          not MapSet.member?(context.changed_paths, finding.file) ->
            false

          is_integer(finding.line) ->
            MapSet.member?(context.valid_lines, {finding.file, finding.line})

          true ->
            not Enum.any?(context.valid_lines, fn {file, _} -> file == finding.file end)
        end
      end)

    if invalid == [] do
      :ok
    else
      {:error,
       "Review findings are not anchored to the reviewed diff: " <>
         Enum.map_join(invalid, ", ", &inspect(&1.title)) <>
         ". No findings were accepted or posted."}
    end
  end

  @doc "Allows fixes only from the clean reviewed process working directory."
  def verify_fix_checkout(context, execution_cwd \\ File.cwd!()) do
    with true <- Path.expand(execution_cwd) == context.cwd,
         {:ok, head} <- Git.resolve_revision("HEAD", context.cwd),
         true <- head == context.head_sha,
         {:ok, ""} <- Git.status(context.cwd) do
      :ok
    else
      _ ->
        {:error,
         "Fixes were not applied. Start Yoke at the repository root in a clean checkout of reviewed commit #{context.head_sha}, then review again."}
    end
  end

  @doc "Checks that a reviewed PR still identifies the same repository and head."
  def verify_current(context) do
    with {:ok, repository} <- PRReview.get_repo_name(context.cwd),
         true <- repository == context.repository,
         {:ok, info} <- PRReview.detect_pr(context.pr_number, context.cwd),
         true <-
           info.url == context.pr_url and info.head_sha == context.head_sha and
             info.base_sha == context.base_sha do
      :ok
    else
      _ ->
        {:error,
         "The PR repository, base, or head changed since review. Run /review again before posting."}
    end
  end

  defp nonempty(diff) do
    if String.trim(diff) == "",
      do:
        {:error,
         "No committed changes in the selected review range. Staged, unstaged, and untracked edits are not included; choose a nonempty commit range."},
      else: :ok
  end

  defp valid_pr_revisions(info) do
    if Enum.all?(
         [info.base_sha, info.head_sha],
         &(is_binary(&1) and Regex.match?(~r/^[0-9a-f]{40,64}$/, &1))
       ),
       do: :ok,
       else: {:error, "GitHub did not return valid base/head commit IDs for this PR."}
  end

  defp fetch_pr_objects(repository, info, cwd) do
    host = URI.parse(info.url).host || "github.com"
    remote = matching_remote(repository, host, cwd) || "https://#{host}/#{repository}.git"

    args = [
      "fetch",
      "--no-tags",
      "--no-write-fetch-head",
      "--",
      remote,
      info.base_sha,
      info.head_sha
    ]

    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {_, _} ->
        {:error,
         "Cannot fetch the exact PR commits. Check GitHub Git authentication and retry; no local branch was substituted."}
    end
  end
end

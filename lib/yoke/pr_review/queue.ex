defmodule Yoke.PRReview.Queue do
  @moduledoc """
  Multi-PR Queue & Triage management.
  Polls open pull requests for the active repository, correlates approval states,
  CI status, and author activity, and classifies PRs into visible actionable queues
  vs hidden waiting states. Supports commit-pinned skips.
  """

  alias Yoke.Json

  @skips_file ".yoke/skips.json"

  @graphql_query """
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          number title url isDraft baseRefName headRefOid additions deletions
          author { login }
          reviews(last: 50) { nodes { author { login } state submittedAt } }
          commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
          files(first: 50) { pageInfo { hasNextPage } nodes { path } }
        }
      }
    }
  }
  """

  @doc """
  Fetches and classifies all reviewable PRs for the current repository.
  Options:
  - `:cwd` - directory of the git repo (default: ".")
  - `:approvals_needed` - integer number of approvals needed (default: 2)
  - `:hide_drafts` - boolean (default: true)
  - `:hide_mine` - boolean (default: true)
  """
  def fetch_queue(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    approvals_needed = Keyword.get(opts, :approvals_needed, 2)
    hide_drafts = Keyword.get(opts, :hide_drafts, true)
    hide_mine = Keyword.get(opts, :hide_mine, true)

    with {:ok, repo_name} <- get_repo_name(cwd),
         {:ok, me} <- get_current_user(cwd),
         [owner, name] <- String.split(repo_name, "/"),
         {:ok, nodes} <- run_graphql_query(owner, name, cwd) do
      skips = load_skips(cwd)
      prs = Enum.map(nodes, &shape_pr(&1, me))
      pruned_skips = prune_skips(skips, prs)

      if map_size(pruned_skips) != map_size(skips) do
        save_skips(pruned_skips, cwd)
      end

      classified =
        classify_prs(prs, %{
          me: me,
          approvals_needed: approvals_needed,
          hide_drafts: hide_drafts,
          hide_mine: hide_mine,
          skips: pruned_skips
        })

      {:ok,
       Map.merge(classified, %{
         repo: repo_name,
         me: me,
         skips: pruned_skips
       })}
    end
  end

  @doc """
  Picks the next recommended PR to review from the visible queue.
  """
  def pick_next(visible_prs, current_num \\ nil) when is_list(visible_prs) do
    Enum.find(visible_prs, fn pr -> pr.number != current_num end)
  end

  @doc """
  Skips a PR at its current HEAD commit.
  The PR remains hidden until a new commit is pushed by its author.
  """
  def skip_pr(pr_num, cwd \\ ".") do
    pr_num_int = if is_binary(pr_num), do: String.to_integer(pr_num), else: pr_num

    case get_pr_head(pr_num_int, cwd) do
      {:ok, head_sha} ->
        skips = load_skips(cwd)
        updated = Map.put(skips, to_string(pr_num_int), head_sha)
        save_skips(updated, cwd)
        {:ok, head_sha}

      {:error, err} ->
        {:error, err}
    end
  end

  @doc """
  Unskips a PR, removing it from the skips store.
  """
  def unskip_pr(pr_num, cwd \\ ".") do
    pr_str = to_string(pr_num)
    skips = load_skips(cwd)
    updated = Map.delete(skips, pr_str)
    save_skips(updated, cwd)
    :ok
  end

  @doc """
  Loads the skips map from `.yoke/skips.json`.
  """
  def load_skips(cwd \\ ".") do
    path = Path.join(cwd, @skips_file)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Json.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp save_skips(skips, cwd) do
    path = Path.join(cwd, @skips_file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Json.encode!(skips))
  end

  defp prune_skips(skips, prs) do
    heads = Map.new(prs, fn pr -> {to_string(pr.number), pr.head} end)

    Map.filter(skips, fn {pr_str, skipped_head} ->
      Map.get(heads, pr_str) == skipped_head
    end)
  end

  defp get_repo_name(cwd) do
    case System.cmd("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, _} -> {:error, "Could not determine GitHub repo: #{String.trim(err)}"}
    end
  end

  defp get_current_user(cwd) do
    case System.cmd("gh", ["api", "user", "--jq", ".login"], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, _} -> {:error, "Could not fetch current GitHub user: #{String.trim(err)}"}
    end
  end

  defp get_pr_head(pr_num, cwd) do
    case System.cmd(
           "gh",
           ["pr", "view", to_string(pr_num), "--json", "headRefOid", "-q", ".headRefOid"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {err, _} -> {:error, "Failed to get head commit for PR ##{pr_num}: #{String.trim(err)}"}
    end
  end

  defp run_graphql_query(owner, name, cwd) do
    args = [
      "api",
      "graphql",
      "-f",
      "query=#{@graphql_query}",
      "-F",
      "owner=#{owner}",
      "-F",
      "name=#{name}"
    ]

    case System.cmd("gh", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => nodes}}}}} ->
            {:ok, nodes}

          _ ->
            {:error, "Invalid GraphQL response from gh api"}
        end

      {err, _} ->
        {:error, "GraphQL query failed: #{String.trim(err)}"}
    end
  end

  defp shape_pr(node, me) do
    raw_reviews =
      get_in(node, ["reviews", "nodes"]) || []

    reviews =
      raw_reviews
      |> Enum.reject(&(Map.get(&1, "state") == "PENDING"))
      |> Enum.map(fn r ->
        %{
          author: get_in(r, ["author", "login"]),
          state: Map.get(r, "state"),
          submitted_at: Map.get(r, "submittedAt", "")
        }
      end)

    commits = get_in(node, ["commits", "nodes"]) || []
    last_commit = List.first(commits)
    last_commit_at = get_in(last_commit, ["commit", "committedDate"]) || ""
    ci_state = get_in(last_commit, ["commit", "statusCheckRollup", "state"]) || "NONE"

    approver_list = extract_approvers(reviews)

    changes_requested_by =
      reviews
      |> Enum.filter(&(&1.state == "CHANGES_REQUESTED"))
      |> Enum.map(& &1.author)
      |> Enum.uniq()

    my_reviews =
      reviews
      |> Enum.filter(&(&1.author == me))
      |> Enum.sort_by(& &1.submitted_at)

    my_last_review = List.last(my_reviews)

    my_state =
      cond do
        me in approver_list ->
          "approved"

        my_last_review != nil ->
          if last_commit_at > my_last_review.submitted_at, do: "re-review", else: "waiting"

        true ->
          "new"
      end

    %{
      number: Map.get(node, "number"),
      title: Map.get(node, "title"),
      url: Map.get(node, "url"),
      head: Map.get(node, "headRefOid"),
      author: get_in(node, ["author", "login"]) || "unknown",
      is_draft: Map.get(node, "isDraft", false),
      base: Map.get(node, "baseRefName"),
      additions: Map.get(node, "additions", 0),
      deletions: Map.get(node, "deletions", 0),
      ci: ci_state,
      approvers: approver_list,
      changes_requested_by: changes_requested_by,
      my_state: my_state,
      my_last_review_at: if(my_last_review, do: my_last_review.submitted_at, else: nil),
      files: Enum.map(get_in(node, ["files", "nodes"]) || [], &Map.get(&1, "path"))
    }
  end

  defp extract_approvers(reviews) do
    reviews
    |> Enum.filter(&(&1.state in ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]))
    |> Enum.reduce(%{}, fn r, acc ->
      prev = Map.get(acc, r.author)

      if is_nil(prev) or prev.submitted_at <= r.submitted_at do
        Map.put(acc, r.author, r)
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.filter(&(&1.state == "APPROVED"))
    |> Enum.map(& &1.author)
  end

  defp classify_prs(prs, %{
         me: me,
         approvals_needed: approvals_needed,
         hide_drafts: hide_drafts,
         hide_mine: hide_mine,
         skips: skips
       }) do
    {visible, hidden} =
      Enum.reduce(prs, {[], []}, fn pr, {vis, hid} ->
        pr_str = to_string(pr.number)
        skipped_head = Map.get(skips, pr_str)

        hide_reason =
          cond do
            hide_drafts and pr.is_draft -> "draft"
            hide_mine and pr.author == me -> "yours"
            length(pr.approvers) >= approvals_needed -> "#{length(pr.approvers)} approvals"
            pr.my_state == "approved" -> "you approved"
            pr.my_state == "waiting" -> "waiting on author"
            skipped_head != nil and skipped_head == pr.head -> "skipped (no new commits)"
            true -> nil
          end

        if hide_reason do
          {vis, [{pr, hide_reason} | hid]}
        else
          {[pr | vis], hid}
        end
      end)

    # Rank visible: re-reviews first (0), then new (1), then by PR number
    sorted_visible =
      Enum.sort_by(visible, fn pr ->
        rank = if pr.my_state == "re-review", do: 0, else: 1
        {rank, pr.number}
      end)

    %{visible: sorted_visible, hidden: Enum.reverse(hidden)}
  end
end

# Phase 0 exit test for docs/YAAS.md.
#
# Computes review precision on a real repository: for every Yoke review comment
# ever posted, did the reviewed line subsequently change? That single number is
# what the whole "precision over time" thesis rests on, so it is measured before
# any backend is built.
#
# Run with:
#
#     mix run --no-start scripts/precision_report.exs
#     mix run --no-start scripts/precision_report.exs --limit 50 --repo owner/name
#
# Requires the GitHub CLI (`gh`) authenticated against the target repository.
# This script makes network calls by design: it is an operator tool, not a test.
#
# Exit codes:
#   0  measurement produced
#   2  usage error
#   3  the repository or review history could not be read

alias Yoke.Cloud.Outcome

alias Yoke.Json

defmodule PrecisionReport do
  @moduledoc false

  @default_limit 20
  @yoke_marker "Review from"

  @doc "Returns the default number of merged PRs to scan."
  def default_limit, do: @default_limit
  @doc "Parses argv into options, or returns a usage error."
  def parse_args(argv) do
    {opts, extra, invalid} =
      OptionParser.parse(argv,
        strict: [repo: :string, limit: :integer, json: :boolean, help: :boolean],
        aliases: [h: :help, n: :limit]
      )

    cond do
      opts[:help] -> {:help, opts}
      invalid != [] -> {:error, "Unknown or malformed option(s): #{inspect(invalid)}"}
      extra != [] -> {:error, "Unexpected argument(s): #{inspect(extra)}"}
      true -> {:ok, opts}
    end
  end

  @doc """
  Resolves the target repository as `{owner, name}`.

  An explicit `--repo` wins; otherwise the origin remote of the current
  directory is used, so the script runs correctly from a checkout.
  """
  def resolve_repo(opts) do
    case opts[:repo] do
      nil ->
        with {:ok, name} <- gh_json(["repo", "view", "--json", "nameWithOwner"]),
             %{"nameWithOwner" => full} <- name,
             [owner, repo] <- String.split(full, "/") do
          {:ok, {owner, repo}}
        else
          _ -> {:error, "Cannot determine the repository. Pass --repo <owner/name>."}
        end

      full ->
        case String.split(full, "/") do
          [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
          _ -> {:error, "--repo must be <owner/name>, got #{inspect(full)}."}
        end
    end
  end

  @doc """
  Fetches merged pull requests that carry a Yoke review, newest first.

  Only merged PRs are considered: an open PR has not finished, so a finding on
  it cannot yet be called ignored.
  """
  def fetch_reviewed_prs({owner, repo}, limit) do
    query = """
    query($owner: String!, $name: String!, $limit: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: MERGED, first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number
            url
            mergeCommit { oid }
            baseRefName
            headRefOid
            reviews(last: 50) { nodes { body author { login } } }
          }
        }
      }
    }
    """

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{query}",
      "-F",
      "owner=#{owner}",
      "-F",
      "name=#{repo}",
      "-F",
      "limit=#{limit}"
    ]

    with {:ok, decoded} <- gh_json(args) do
      nodes =
        get_in(decoded, ["data", "repository", "pullRequests", "nodes"]) || []

      reviewed =
        nodes
        |> Enum.filter(&yoke_review?/1)
        |> Enum.map(fn node ->
          %{
            number: node["number"],
            url: node["url"],
            merge_commit: get_in(node, ["mergeCommit", "oid"]),
            base: node["baseRefName"],
            head_sha: node["headRefOid"]
          }
        end)
        |> Enum.reject(&is_nil(&1.merge_commit))

      {:ok, reviewed}
    end
  end

  defp yoke_review?(node) do
    node
    |> get_in(["reviews", "nodes"])
    |> List.wrap()
    |> Enum.any?(fn review ->
      body = review["body"] || ""
      String.contains?(body, @yoke_marker) or String.contains?(body, "<!-- yoke-review")
    end)
  end

  @doc """
  Extracts the findings from a PR's Yoke review comments.

  GitHub's REST review-comment endpoint is what carries the inline `path` and
  `line` anchors, which is exactly what the classifier needs.
  """
  def fetch_findings({owner, repo}, pr_number) do
    path = "repos/#{owner}/#{repo}/pulls/#{pr_number}/comments?per_page=100"

    with {:ok, comments} when is_list(comments) <- gh_json(["api", path]) do
      findings =
        comments
        |> Enum.filter(&yoke_comment?/1)
        |> Enum.map(fn comment ->
          %{
            file: comment["path"],
            # `line` moves as the diff is rebased and is null once the anchored
            # line leaves the current diff; `original_line` is the anchor the
            # comment was actually posted at. Preferring `line` would mis-key
            # the finding against the thread evidence, which is anchored at
            # `original_line`, and the reaction would silently miss.
            line: comment["original_line"] || comment["line"],
            title: first_line(comment["body"]),
            severity: severity_of(comment["body"])
          }
        end)
        |> Enum.reject(&(is_nil(&1.file) or is_nil(&1.line)))

      {:ok, findings}
    else
      {:ok, _} -> {:error, "Unexpected response for PR ##{pr_number} comments."}
      error -> error
    end
  end

  # A Yoke inline comment is identified by its severity badge, which the review
  # renderer emits as a coloured circle. Matching on the badge rather than on
  # the author login keeps the script working for both the App identity and a
  # user token, and survives a rename of the bot account.
  #
  # The badge is the only reliable marker: the body carries no hidden HTML
  # comment and no word "high"/"medium"/"low" (the severity is the emoji).
  defp yoke_comment?(comment) do
    body = comment["body"] || ""
    String.contains?(body, "<!-- yoke") or severity_badge(body) != nil
  end

  # Maps the renderer's severity badge onto a severity name. Order matters:
  # the red badge is checked first so a body mentioning several tokens cannot
  # downgrade a high finding.
  @severity_badges [{"\u{1F534}", "high"}, {"\u{1F7E1}", "medium"}, {"\u{1F535}", "low"}]

  # Earlier Yoke releases rendered severity as `**[HIGH]**` / `**[MEDIUM]**`
  # rather than a coloured circle. Both formats exist in real review history,
  # so the measurement must accept both or it silently drops older findings.
  @severity_words [{"HIGH", "high"}, {"MEDIUM", "medium"}, {"LOW", "low"}]

  defp severity_badge(body) when is_binary(body) do
    case Enum.find_value(@severity_badges, fn {badge, severity} ->
           if String.contains?(body, badge), do: severity
         end) do
      nil -> severity_word(body)
      severity -> severity
    end
  end

  defp severity_badge(_), do: nil

  defp severity_word(body) do
    Enum.find_value(@severity_words, fn {word, severity} ->
      if String.contains?(body, "[#{word}]"), do: severity
    end)
  end

  defp severity_of(body), do: severity_badge(body) || "info"

  defp first_line(nil), do: "(no title)"

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != "" and not String.starts_with?(&1, "<!--")))
    |> String.slice(0, 120)
  end

  # Returns the set of files touched by commits inside the PR whose message
  # marks them as a code-review fix.
  #
  # This exists because line movement alone under-counts: a fix can address a
  # finding without moving the anchored line, which is exactly what happened on
  # this repository (a commit titled "CR by Robby Ott" replaced `Map.new` with
  # `Enum.reduce` two lines below the anchor). Matching on the commit message is
  # a heuristic, but it is a heuristic in the safe direction: it can only turn
  # an `:ignored` into an `:acted_on`, never the reverse.
  defp fix_commits(%{merge_commit: sha}) when is_binary(sha) do
    case System.cmd("git", ["log", "--format=%H%x00%s", "#{sha}^1..#{sha}"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&review_fix_message?/1)
        |> Enum.flat_map(&files_in_commit/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end
  # A commit subject that marks itself as a code-review fix, e.g.
  # "CR by Robby Ott", "CRs by Robby Ott", "Robby Ott's CR".
  #
  # The match is deliberately narrow: a standalone `CR`/`CRs` token, not a
  # substring. A loose match on "cr" would sweep in every commit whose message
  # happens to contain those letters and turn the measurement into noise.
  @review_fix_regex ~r/(?:^|\s)CRs?(?:\s|$|['’])/u

  defp review_fix_message?(line) do
    message = line |> String.split("\u0000") |> List.last()
    Regex.match?(@review_fix_regex, message)
  end

  defp files_in_commit(line) do
    sha = line |> String.split("\u0000") |> List.first()

    case System.cmd("git", ["show", "--name-only", "--format=", sha], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  # Fetches thread resolution and reaction evidence for a PR.
  #
  # Failure is not fatal: a rate-limited or unauthenticated API degrades the
  # measurement to the weaker signals rather than breaking the report.
  defp thread_evidence(%{number: number}, {owner, repo}) do
    # `mix run --no-start` skips the application tree, so Req's Finch pool is
    # not running and every request would raise. Starting the two apps the
    # script needs is cheaper than requiring a full application boot.
    {:ok, _} = Application.ensure_all_started(:req)

    case Yoke.Cloud.GitHub.fetch_threads(owner, repo, number, github_token()) do
      {:ok, evidence} ->
        evidence

      {:error, reason} ->
        IO.puts(:stderr, "  PR ##{number}: no thread evidence (#{reason})")
        %{}
    end
  end

  defp github_token do
    System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN") || gh_auth_token()
  end

  # `gh auth token` is the reliable way to pick up the CLI's stored credential
  # without asking the operator to export it a second time.
  defp gh_auth_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} -> String.trim(token)
      _ -> nil
    end
  end

  @doc """
  Classifies every finding on every reviewed PR.

  Evidence is derived from the PR's own diff: a finding is `:acted_on` when its
  anchored line is no longer present in the merged change, and `:ignored` when
  the PR merged with the line untouched. Everything else stays `:pending`,
  which is excluded from the score rather than counted as a miss.
  """
  def classify_all(prs, repo) do
    Enum.flat_map(prs, fn pr ->
      case fetch_findings(repo, pr.number) do
        {:ok, []} ->
          []

        {:ok, findings} ->
          case pr_diff(pr) do
            {:ok, diff} ->
              lines = diff_right_lines(diff)
              reviewed_files = fix_commits(pr)
              threads = thread_evidence(pr, repo)

              Enum.map(findings, fn finding ->
                evidence =
                  %{
                    line_present: MapSet.member?(lines, {finding.file, finding.line}),
                    file_present: Enum.any?(lines, fn {file, _} -> file == finding.file end),
                    pr_merged: true,
                    # A commit inside the PR whose message marks it as a code-review
                    # fix, touching the finding's file, is much stronger evidence
                    # than line movement: it means a human read the comment and
                    # changed that file in response.
                    review_fix: MapSet.member?(reviewed_files, finding.file)
                  }
                  |> Map.merge(Yoke.Cloud.GitHub.evidence_for(threads, finding.file, finding.line))

                finding
                |> Map.put(:pr, pr.number)
                |> then(&{&1, Outcome.classify(&1, evidence)})
              end)
            {:error, reason} ->
              IO.puts(:stderr, "  PR ##{pr.number}: cannot read diff (#{reason}); skipping")
              []
          end

        {:error, reason} ->
          IO.puts(:stderr, "  PR ##{pr.number}: cannot read comments (#{reason}); skipping")
          []
      end
    end)
  end

  # Reuses the review pipeline's own diff parser so the script and the product
  # can never disagree about which lines a diff touches.
  defp diff_right_lines(diff), do: Yoke.PRReview.parse_diff_right_lines(diff)

  # Returns the diff the PR introduced: its merge commit against its FIRST
  # parent, which is the base branch tip at merge time.
  #
  # `origin/<base>...<merge>` is wrong here: a merge commit's merge-base with
  # the base branch is the base branch itself, so the three-dot diff is always
  # empty. Read from local git because the classifier parses raw hunk headers
  # and a JSON round-trip would corrupt them.
  defp pr_diff(%{merge_commit: sha}) when is_binary(sha) do
    _ =
      System.cmd("git", ["fetch", "--no-tags", "--quiet", "origin", sha], stderr_to_stdout: true)

    case System.cmd("git", ["diff", "--no-color", "#{sha}^1", sha], stderr_to_stdout: true) do
      {diff, 0} when diff != "" -> {:ok, diff}
      {_out, 0} -> {:error, :empty_diff}
      {err, _status} -> {:error, String.trim(err) |> String.slice(0, 120)}
    end
  end

  defp pr_diff(_), do: {:error, :no_merge_commit}

  @doc "Renders the measurement as a human-readable report."
  def render(report, pr_count, opts) do
    lines = [
      "",
      "Review precision report",
      "=======================",
      "",
      "Reviewed PRs scanned: #{pr_count}",
      "Findings considered:  #{report.total}",
      "Findings scored:      #{report.scored}",
      "Findings pending:     #{report.pending}",
      "",
      "Outcomes:",
      "  acted on     #{Map.get(report.by_verdict, :acted_on, 0)}",
      "  resolved     #{Map.get(report.by_verdict, :resolved, 0)}",
      "  reacted up   #{Map.get(report.by_verdict, :reacted_up, 0)}",
      "  ignored      #{Map.get(report.by_verdict, :ignored, 0)}",
      "  reacted down #{Map.get(report.by_verdict, :reacted_down, 0)}",
      "  pending      #{Map.get(report.by_verdict, :pending, 0)}",
      "",
      "Precision: #{format_precision(report.acted_on_rate)}",
      "",
      "Note: `acted on` includes findings whose file was touched by a commit",
      "marked as a code-review fix. That is a file-level signal, so it can",
      "over-credit a finding that happened to share a file with a real fix.",
      "Treat this as an upper bound; the lower bound is line movement alone.",
      ""
    ]

    if opts[:json] do
      Json.encode!(
        %{
          "pr_count" => pr_count,
          "total" => report.total,
          "scored" => report.scored,
          "pending" => report.pending,
          "by_verdict" => Map.new(report.by_verdict, fn {k, v} -> {to_string(k), v} end),
          "precision" => report.acted_on_rate
        },
        pretty: true
      )
    else
      Enum.join(lines, "\n")
    end
  end

  defp format_precision(nil), do: "not measurable (no scored findings)"

  defp format_precision(rate) when is_float(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  # ---------------------------------------------------------------------
  # gh plumbing
  # ---------------------------------------------------------------------

  defp gh_json(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, "gh returned non-JSON output"}
        end

      {err, status} ->
        {:error, "gh exited #{status}: #{String.trim(err) |> String.slice(0, 200)}"}
    end
  end
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# `mix run` discards the script's return value, so the exit code must be set
# explicitly; otherwise every failure path silently reports success.
code =
  case PrecisionReport.parse_args(System.argv()) do
    {:help, _opts} ->
      IO.puts("""
      precision_report — measure how often Yoke's review findings were acted on

      USAGE:
        mix run --no-start scripts/precision_report.exs [options]

      OPTIONS:
            --repo <owner/name>  Repository to measure (default: the origin remote)
        -n, --limit <n>          Merged PRs to scan (default: #{PrecisionReport.default_limit()})
            --json               Emit the measurement as JSON
        -h, --help               Show this help

      Requires an authenticated `gh`. This script reads real pull-request history
      and therefore makes network calls; it is an operator tool, not a test.
      """)

      0

    {:error, message} ->
      IO.puts(:stderr, "error: #{message}")
      2

    {:ok, opts} ->
      limit = opts[:limit] || PrecisionReport.default_limit()

      with {:ok, repo} <- PrecisionReport.resolve_repo(opts),
           {:ok, prs} <- PrecisionReport.fetch_reviewed_prs(repo, limit) do
        classified = PrecisionReport.classify_all(prs, repo)
        report = Outcome.report(classified)

        IO.puts(PrecisionReport.render(report, length(prs), opts))

        if report.scored == 0 do
          IO.puts(:stderr, "warning: no scorable findings; the number above is not evidence.")
        end

        0
      else
        {:error, reason} ->
          IO.puts(:stderr, "error: #{reason}")
          3
      end
  end

if code != 0, do: System.halt(code)

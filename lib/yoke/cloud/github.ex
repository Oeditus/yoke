defmodule Yoke.Cloud.GitHub do
  @moduledoc """
  Fetches the review-thread evidence `Yoke.Cloud.Outcome` classifies
  (`docs/YAAS.md` §4.1).

  ## Why this module exists

  Measuring precision with diff movement alone produced a band from 14% to 93%
  on this repository: a fix can address a finding without moving the anchored
  line, and a file-level "review fix commit" signal over-credits anything that
  merely shares a file with a real fix. Neither is good enough to price against.

  GitHub already holds the answer. A review thread carries `isResolved`, and a
  comment carries reactions. Those are human judgements about *that specific
  comment*, not inferences about nearby code, so they collapse the band.

  ## What it returns

  A map from `{file, line}` to evidence, ready to hand to
  `Yoke.Cloud.Outcome.classify/2`. The mapping is by anchor rather than by
  comment id because the precision report reconciles comments against findings
  by location.

  ## Failure is not fatal

  Every function returns `{:ok, evidence}` or `{:error, reason}`, and the caller
  treats an error as "no extra evidence". A rate-limited or unavailable API must
  degrade the measurement to the weaker signals, never break the report.
  """

  alias Yoke.Json

  @graphql_url "https://api.github.com/graphql"

  # One page of threads is enough for a review-sized pull request; the query
  # paginates at 100, which is GitHub's maximum for this connection.
  @threads_query """
  query($owner: String!, $name: String!, $pr: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            isOutdated
            comments(first: 100) {
              nodes {
                path
                line
                originalLine
                body
                reactions(first: 20) {
                  nodes { content }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @typedoc """
  Evidence keyed by `{file, line}`.

    * `:resolved` -- the thread containing the comment was resolved
    * `:reactions` -- reaction counts as `%{"+1" => n, "-1" => n}`
  """
  @type evidence_map :: %{
          optional({String.t(), integer() | nil}) => %{
            resolved: boolean(),
            reactions: %{optional(String.t()) => non_neg_integer()}
          }
        }

  @doc """
  Fetches thread evidence for a pull request.

  `token` is a GitHub token with `pull_requests: read`. It is never logged and
  never included in an error message.
  """
  @spec fetch_threads(String.t(), String.t(), integer(), String.t() | nil, keyword()) ::
          {:ok, evidence_map()} | {:error, String.t()}
  def fetch_threads(owner, repo, pr_number, token, opts \\ []) do
    if is_nil(token) or token == "" do
      {:error, "no GitHub token configured"}
    else
      body =
        Json.encode!(%{
          "query" => @threads_query,
          "variables" => %{"owner" => owner, "name" => repo, "pr" => pr_number}
        })

      request = [
        method: :post,
        url: Keyword.get(opts, :url, @graphql_url),
        headers: [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"},
          {"user-agent", "yoke-cloud"}
        ],
        body: body,
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      ]

      case Req.request(request) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          parse_response(response)

        {:ok, %{status: status}} ->
          {:error, "GitHub GraphQL returned HTTP #{status}"}

        {:error, reason} ->
          {:error, "GitHub GraphQL request failed: #{redact(reason, token)}"}
      end
    end
  end

  @doc """
  Parses a GraphQL response into an evidence map.

  Exposed for testing without a network call. A response carrying `errors` is
  treated as a failure even when it also carries partial data, because a
  partial evidence map would silently under-report resolutions.
  """
  @spec parse_response(term()) :: {:ok, evidence_map()} | {:error, String.t()}
  def parse_response(%{"errors" => [_ | _] = errors}) do
    messages = Enum.map_join(errors, "; ", &to_string(Map.get(&1, "message", "unknown")))
    {:error, "GitHub GraphQL errors: #{messages}"}
  end

  def parse_response(%{
        "data" => %{
          "repository" => %{
            "pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}
          }
        }
      })
      when is_list(nodes) do
    evidence =
      nodes
      |> Enum.flat_map(&thread_evidence/1)
      |> Map.new()

    {:ok, evidence}
  end

  def parse_response(_), do: {:error, "unexpected GitHub GraphQL response shape"}

  @doc """
  Merges thread evidence into the evidence map for a single finding.

  Kept here rather than in `Outcome` so `Outcome` stays free of any knowledge
  about how the facts were obtained.
  """
  @spec evidence_for(evidence_map(), String.t() | nil, integer() | nil) :: map()
  def evidence_for(evidence, file, line) when is_map(evidence) do
    case Map.get(evidence, {file, line}) do
      nil -> %{}
      found -> found
    end
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp thread_evidence(%{"comments" => %{"nodes" => comments}} = thread)
       when is_list(comments) do
    resolved = Map.get(thread, "isResolved", false)

    Enum.flat_map(comments, fn comment ->
      case anchor(comment) do
        nil ->
          []

        key ->
          [{key, %{resolved: resolved, reactions: reaction_counts(comment)}}]
      end
    end)
  end

  defp thread_evidence(_), do: []

  # `line` moves as the diff is rebased and is null once the anchored line
  # leaves the current diff, while `originalLine` is the anchor the comment was
  # actually posted at. Preferring `line` would mis-key the evidence against the
  # finding, which is anchored at `original_line` — the precision report uses
  # that same field, so the two must agree or the evidence silently misses.
  defp anchor(comment) do
    file = Map.get(comment, "path")
    line = Map.get(comment, "originalLine") || Map.get(comment, "line")

    if is_binary(file) and is_integer(line), do: {file, line}, else: nil
  end

  defp reaction_counts(%{"reactions" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(&Map.get(&1, "content"))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp reaction_counts(_), do: %{}

  defp redact(reason, token) do
    text = inspect(reason)
    if is_binary(token) and token != "", do: String.replace(text, token, "[redacted]"), else: text
  end
end

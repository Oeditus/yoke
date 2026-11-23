defmodule Yoke.Cloud.Baseline do
  @moduledoc """
  Fetches and applies the previously-seen findings for a repository, turning a
  noisy reviewer into a signal generator (`docs/YAAS.md` §4).

  ## What a baseline is

  The cloud remembers every finding ever posted on a branch. A baseline is the
  subset that the organisation has consistently *not* acted on, so the next
  review can stop repeating it. This is the one feature that genuinely requires
  a backend, and it is the headline of the paid product.

  ## The rule that keeps it honest

  **Suppression can only ever remove findings the organisation has already
  demonstrated it ignores.** It is not a severity filter and it is not a
  confidence heuristic. A finding is suppressed only when the cloud returns an
  explicit entry for it, which means the cloud observed enough ignored
  occurrences to reach the threshold.

  Consequently:

    * With no baseline configured, nothing is suppressed. A repository that has
      not opted in sees exactly the review it saw before.
    * With the cloud unreachable, nothing is suppressed. A dashboard outage
      must never change what a review reports.
    * `high` severity findings are never suppressed unless the baseline entry
      explicitly says so, so a misconfigured service cannot silence a real
      defect.

  ## What is matched

  A baseline entry identifies a finding by `{file, title}` rather than by line,
  because line numbers move. The title is normalised (lowercased, whitespace
  collapsed, backticks stripped) so cosmetic prompt drift does not defeat the
  match — but two genuinely different findings in the same file keep distinct
  titles and therefore stay distinct.
  """

  require Logger

  alias Yoke.Cloud.Client
  alias Yoke.Json

  @baselines_path "/v1/baselines"
  @default_timeout_ms 5_000

  @typedoc """
  A suppression entry returned by the cloud.

    * `:file` -- the file the finding was anchored to
    * `:title` -- the normalised title used for matching
    * `:severity` -- the highest severity this entry may suppress
    * `:ignored_count` -- how many times the organisation ignored it
  """
  @type entry :: %{
          file: String.t(),
          title: String.t(),
          severity: String.t(),
          ignored_count: non_neg_integer()
        }

  @doc """
  Fetches the baseline for `repo` on `branch`.

  Returns `{:ok, entries}`. Every failure path — an unreachable service, a
  rejected token, a malformed response — yields `{:ok, []}` rather than an
  error, because an unavailable baseline must be indistinguishable from an
  empty one: either way the review reports everything it found.
  """
  @spec fetch(String.t() | nil, String.t() | nil, keyword()) :: {:ok, [entry()]}
  def fetch(repo, branch, opts \\ [])

  def fetch(nil, _branch, _opts), do: {:ok, []}

  def fetch(repo, branch, opts) when is_binary(repo) do
    case Client.endpoint(opts) do
      nil ->
        {:ok, []}

      endpoint ->
        url = baselines_url(endpoint, repo, branch)

        case get(url, opts) do
          {:ok, body} -> {:ok, normalize_entries(body)}
          :error -> {:ok, []}
        end
    end
  end

  @doc """
  Removes findings the baseline says the organisation ignores.

  Returns `{kept, suppressed}`. `suppressed` is returned rather than discarded
  so the artifact and step summary can report *what* was hidden and why — a
  reviewer that silently drops findings is indistinguishable from one that
  missed them.
  """
  @spec apply_baseline([map()], [entry()]) :: {[map()], [map()]}
  def apply_baseline(findings, entries) when is_list(findings) and is_list(entries) do
    if entries == [] do
      {findings, []}
    else
      index =
        Map.new(entries, fn entry ->
          {{entry.file, normalize_title(entry.title)}, entry}
        end)

      Enum.split_with(findings, fn finding ->
        not suppressed?(finding, index)
      end)
    end
  end

  @doc """
  Normalises a finding title for baseline matching.

  Lowercases, strips backticks and punctuation, and collapses whitespace, so
  "Missing index on `user_id`" and "missing index on user_id" match.
  """
  @spec normalize_title(String.t() | nil) :: String.t()
  def normalize_title(nil), do: ""

  def normalize_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[`*_]/, "")
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Returns the severity rank at or below which an entry may suppress.

  `high` is rank 4 and is never suppressed by a lower-ranked entry; an entry
  must be at least as severe as the finding to hide it.
  """
  @spec rank(String.t()) :: non_neg_integer()
  def rank(severity) do
    case String.downcase(to_string(severity)) do
      "high" -> 4
      "medium" -> 3
      "low" -> 2
      "info" -> 1
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp suppressed?(finding, index) do
    key = {finding.file, normalize_title(finding.title)}

    case Map.get(index, key) do
      nil ->
        false

      entry ->
        # An entry may only hide a finding at or below its own severity. This
        # is what stops a stale `low` entry from silencing a new `high` one
        # that happens to share a title.
        rank(finding.severity) <= rank(entry.severity)
    end
  end

  defp baselines_url(endpoint, repo, branch) do
    base = endpoint |> String.replace(~r{/v1/runs/?$}, "")
    query = URI.encode_query(%{"repo" => repo, "branch" => branch || ""})
    base <> @baselines_path <> "?" <> query
  end

  defp get(url, opts) do
    headers =
      [{"accept", "application/json"}, {"user-agent", "yoke-ci"}]
      |> maybe_auth(opts)

    request = [
      method: :get,
      url: url,
      headers: headers,
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
      retry: false
    ]

    case Req.request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("[cloud] Baseline rejected with HTTP #{status}; reviewing without it.")
        :error

      {:error, reason} ->
        Logger.warning(
          "[cloud] Baseline unavailable (#{Client.redact(inspect(reason))}); reviewing without it."
        )

        :error
    end
  end

  defp maybe_auth(headers, opts) do
    case Client.token(opts) do
      nil -> headers
      secret -> [{"authorization", "Bearer " <> secret} | headers]
    end
  end

  # The service returns `{"baselines": [...]}`. Anything else — a proxy error
  # page, a different schema version — yields an empty baseline rather than a
  # crash, because an unparseable response must not change review behaviour.
  defp normalize_entries(%{"baselines" => entries}) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_entry/1)
  end

  defp normalize_entries(body) when is_binary(body) do
    case Json.decode(body) do
      {:ok, decoded} -> normalize_entries(decoded)
      {:error, _} -> []
    end
  end

  defp normalize_entries(_), do: []

  defp normalize_entry(%{"file" => file, "title" => title} = entry)
       when is_binary(file) and is_binary(title) do
    [
      %{
        file: file,
        title: title,
        severity: normalize_severity(entry["severity"]),
        ignored_count: normalize_count(entry["ignored_count"])
      }
    ]
  end

  defp normalize_entry(_), do: []

  defp normalize_severity(value) do
    case String.downcase(to_string(value)) do
      severity when severity in ~w(high medium low info) -> severity
      _ -> "low"
    end
  end

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_), do: 0
end

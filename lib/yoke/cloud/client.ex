defmodule Yoke.Cloud.Client do
  @moduledoc """
  The runner-to-cloud bridge (`docs/YAAS.md` §3, §5.1).

  Posts a completed review artifact to the Yoke Cloud ingestion endpoint so the
  service can score findings against what developers actually did with them.

  ## The one rule that matters

  **Every call here is optional and fail-open.** A review that ran, posted, and
  gated correctly must never be marked as an infrastructure failure because a
  dashboard was unreachable. `docs/CI_PLAN.md` §4.5 states this for later
  phases; this module is where it first becomes real.

  Consequently `upload/2` returns `{:ok, :skipped}` or `{:ok, :uploaded}` on
  every non-fatal path, including a connection refused, a 500, or a malformed
  response. It returns `{:error, reason}` only for a *local* misuse the caller
  can fix — a missing endpoint or a payload that cannot be encoded — and even
  then the caller is expected to warn rather than fail the run.

  ## Configuration

  Precedence, first match wins:

    1. `:endpoint` / `:token` options (from CLI flags)
    2. `YOKE_CLOUD_ENDPOINT` / `YOKE_CLOUD_TOKEN` environment variables
    3. `"cloud"` in `.yoke/config.json`

  With no endpoint configured the upload is skipped silently: a repository that
  has not opted into the service should not see warnings about it.

  ## What is sent

  The artifact `Yoke.CI.Artifact` already wrote — findings, identities, and
  metrics. **Not the diff and not the transcript.** The runner tier never sends
  source to the service; that is the security property the whole enterprise
  story rests on (`docs/YAAS.md` §3.1 rule 3).
  """

  require Logger

  alias Yoke.Json

  @default_timeout_ms 10_000
  @runs_path "/v1/runs"

  @typedoc "The outcome of an upload attempt."
  @type result :: {:ok, :uploaded | :skipped} | {:error, String.t()}

  @doc """
  Uploads a review artifact payload.

  `payload` is the map `Yoke.CI.Artifact.payload/2` builds. Returns
  `{:ok, :uploaded}` on a 2xx, `{:ok, :skipped}` when no endpoint is
  configured or the request failed for a transient reason, and
  `{:error, reason}` only for local misuse.
  """
  @spec upload(map(), keyword()) :: result()
  def upload(payload, opts \\ []) when is_map(payload) do
    case endpoint(opts) do
      nil ->
        {:ok, :skipped}

      url ->
        case Json.encode(payload, pretty: false) do
          {:ok, body} -> post(url, body, opts)
          {:error, reason} -> {:error, "Cannot encode upload payload: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Returns the configured ingestion endpoint, or `nil` when the service is not
  configured.

  A bare host is normalised to the `/v1/runs` path so a user can set
  `YOKE_CLOUD_ENDPOINT=https://api.example.com` without knowing the route.
  """
  @spec endpoint(keyword()) :: String.t() | nil
  def endpoint(opts \\ []) do
    configured =
      opts[:endpoint] ||
        System.get_env("YOKE_CLOUD_ENDPOINT") ||
        config_value("endpoint")

    case configured do
      value when is_binary(value) and value != "" -> normalize_endpoint(value)
      _ -> nil
    end
  end

  @doc """
  Returns the API token, or `nil` when unset.

  Never logged, never included in an error message, never persisted. See
  `redact/1`.
  """
  @spec token(keyword()) :: String.t() | nil
  def token(opts \\ []) do
    configured =
      opts[:token] ||
        System.get_env("YOKE_CLOUD_TOKEN") ||
        config_value("token")

    case configured do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc """
  Removes any credential-looking substring from a message before it is printed
  or logged.

  Error messages from an HTTP client can echo the request, and an Authorization
  header in a CI log is a credential leak. Every message this module returns
  passes through here first.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> then(fn t ->
      case token() do
        nil -> t
        secret -> String.replace(t, secret, "[redacted]")
      end
    end)
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._\-]+/i, "\\1[redacted]")
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp post(url, body, opts) do
    headers =
      [{"content-type", "application/json"}, {"user-agent", "yoke-ci"}]
      |> maybe_auth(opts)

    request = [
      method: :post,
      url: url,
      headers: headers,
      body: body,
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
      retry: false
    ]

    case Req.request(request) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, :uploaded}

      {:ok, %{status: status}} ->
        # A 4xx is a configuration problem the operator can fix, but it is
        # still not a reason to fail a review that already succeeded.
        Logger.warning("[cloud] Upload rejected with HTTP #{status}; continuing without it.")
        {:ok, :skipped}

      {:error, reason} ->
        Logger.warning(
          "[cloud] Upload failed (#{redact(inspect(reason))}); continuing without it."
        )

        {:ok, :skipped}
    end
  end

  defp maybe_auth(headers, opts) do
    case token(opts) do
      nil -> headers
      secret -> [{"authorization", "Bearer " <> secret} | headers]
    end
  end

  defp normalize_endpoint(value) do
    trimmed = String.trim(value)

    cond do
      String.ends_with?(trimmed, @runs_path) -> trimmed
      String.ends_with?(trimmed, "/") -> trimmed <> String.trim_leading(@runs_path, "/")
      true -> trimmed <> @runs_path
    end
  end

  defp config_value(key) do
    case Yoke.Config.load_config(File.cwd!())["cloud"] do
      %{} = cloud -> Map.get(cloud, key)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end

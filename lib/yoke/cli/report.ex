defmodule Yoke.CLI.Report do
  @moduledoc """
  The `yoke report` subcommand (`docs/YAAS.md` §5.1).

  Reads the artifact a previous `yoke review` wrote and uploads it to the Yoke
  Cloud ingestion endpoint. This is the entire runner-to-cloud bridge: the
  review itself stays entirely on the customer's runner, and only results
  leave.

  ## Why a separate command rather than a flag on `review`

  `yoke review` must remain usable with no service configured and no network
  access beyond the model provider. Keeping the upload in its own command means
  a customer can run the review, inspect the artifact, and *then* decide to
  send it — and that a workflow can upload as a separate, clearly-labelled
  step that is trivially removed.

  ## Fail-open

  An upload failure never fails the build. The exit codes reflect that: `0`
  covers uploaded, skipped, and unreachable alike. Exit `3` is reserved for a
  local problem the operator can fix (missing artifact, unreadable JSON).
  """

  alias Yoke.CLI.Formatter
  alias Yoke.Cloud.Client

  @switches [
    upload: :boolean,
    endpoint: :string,
    token: :string,
    artifact: :string,
    output: :string,
    format: :string,
    fail_on: :string,
    timeout: :string,
    help: :boolean
  ]

  @aliases [h: :help]

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke report`."
  @spec report([String.t()]) :: non_neg_integer()
  def report(args) do
    {opts, _extra, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(usage())
        0

      invalid != [] ->
        usage_error("Unknown or malformed option(s): #{inspect(invalid)}")

      true ->
        run(opts)
    end
  end

  @doc "Returns the usage text for `yoke report`."
  @spec usage() :: String.t()
  def usage do
    """
    yoke report — upload a completed review artifact to Yoke Cloud

    USAGE:
      yoke report --upload [options]

    Reads the JSON artifact a previous `yoke review` wrote and posts it to the
    ingestion endpoint. The diff and the model transcript are never sent; only
    findings, identities, and metrics leave the runner.

    OPTIONS:
          --upload          Perform the upload (required; without it nothing happens)
          --artifact <path> Artifact to read (default: $RUNNER_TEMP/yoke-review.json)
          --endpoint <url>  Ingestion endpoint (default: $YOKE_CLOUD_ENDPOINT,
                            else "cloud"."endpoint" in .yoke/config.json)
          --token <t>       API token (default: $YOKE_CLOUD_TOKEN)
          --timeout <ms>    Request timeout (default: 10000)
          --format <fmt>    summary | json (default: summary)
      -h, --help            Show this help

    EXIT CODES:
      0  uploaded, skipped (no endpoint configured), or unreachable
      2  usage error
      3  the artifact could not be read

    An unreachable service exits 0 by design: a review that already ran and
    gated correctly must not be marked failed because a dashboard was down.
    """
  end

  defp run(opts) do
    artifact = opts[:artifact] || default_artifact_path()

    with {:ok, payload} <- read_artifact(artifact),
         {:ok, status} <- Client.upload(payload, upload_opts(opts)) do
      emit(status, artifact, opts[:format] || "summary")
      0
    else
      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        3
    end
  end

  # `--upload` is required so that a bare `yoke report` can never send data
  # anywhere by accident. Without it the command explains itself and exits 0.
  defp upload_opts(opts) do
    if opts[:upload] do
      [
        endpoint: opts[:endpoint],
        token: opts[:token],
        timeout: parse_timeout(opts[:timeout])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    else
      []
    end
  end

  defp parse_timeout(nil), do: nil

  defp parse_timeout(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ms, ""} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp default_artifact_path do
    Path.join(System.get_env("RUNNER_TEMP") || System.tmp_dir!(), "yoke-review.json")
  end

  defp read_artifact(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, %{} = payload} -> {:ok, payload}
            _ -> {:error, "Artifact at #{path} is not a JSON object."}
          end

        {:error, reason} ->
          {:error, "Cannot read artifact at #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "No artifact at #{path}. Run `yoke review` first, or pass --artifact <path>."}
    end
  end

  defp emit(status, artifact, "json") do
    IO.puts(
      Yoke.Json.encode!(%{
        "status" => Atom.to_string(status),
        "artifact_path" => artifact,
        "endpoint" => Client.endpoint([]) || ""
      })
    )
  end

  defp emit(status, artifact, _format) do
    message =
      case status do
        :uploaded -> "Uploaded #{artifact}."
        :skipped -> "Upload skipped (no endpoint configured, or the service was unreachable)."
      end

    IO.puts(Formatter.format_info(message))
  end

  defp usage_error(message) do
    IO.puts(Formatter.format_error(message))
    IO.puts(usage())
    2
  end
end

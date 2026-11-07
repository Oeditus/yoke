defmodule Yoke.CI.Artifact do
  @moduledoc """
  Persists the full review — findings plus the transcript — as a JSON artifact
  (`docs/CI_PLAN.md` Phase 1.1).

  The artifact is the audit trail: it records *what* was reviewed, *what* the
  model said, and *what* was found, so a reviewer can reconstruct the run after
  the fact without scrolling logs.

  ## Where it goes

  `$RUNNER_TEMP/yoke-review.json` by default, or an explicit `--output` path.
  `$RUNNER_TEMP` is wiped between jobs, so an `actions/upload-artifact` step is
  what actually preserves it.

  ## Safety

  Everything written here passes through `Yoke.AIGuard.guard_llm/3` in
  `:enforce` mode first. A transcript that trips a secret pattern is **not**
  written; the artifact records the redaction instead. An artifact is uploaded
  to a third party, so this is a safety property rather than a nicety.
  """

  alias Yoke.AIGuard
  alias Yoke.CI.Findings
  alias Yoke.Json

  @default_filename "yoke-review.json"

  @doc "Returns the default artifact path for the current runner."
  @spec default_path() :: String.t()
  def default_path do
    base =
      case System.get_env("RUNNER_TEMP") do
        path when is_binary(path) and path != "" -> path
        _ -> System.tmp_dir!()
      end

    Path.join(base, @default_filename)
  end

  @doc """
  Builds the artifact payload.

  `opts`:

    * `:identity` -- map with `:base_sha`, `:head_sha`, `:pr_number`, `:repository`
    * `:transcript` -- the model's raw review text (optional)
    * `:model` -- the model identifier used
    * `:run_uid` -- a stable identifier for this run
    * `:policy` -- the effective policy map
  """
  @spec payload(map(), keyword()) :: map()
  def payload(report, opts \\ []) do
    %{
      "schema_version" => 1,
      "run_uid" => Keyword.get(opts, :run_uid),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "model" => Keyword.get(opts, :model),
      "identity" => normalize_identity(Keyword.get(opts, :identity, %{})),
      "summary" => %{
        "findings_count" => report.findings_count,
        "max_severity" => report.max_severity,
        "fail_on" => report.fail_on,
        "failed" => report.failed?,
        "gating_count" => length(report.gating)
      },
      "findings" => Enum.map(report.findings, &normalize_finding/1),
      "transcript" => guarded_transcript(Keyword.get(opts, :transcript)),
      "policy" => Keyword.get(opts, :policy, %{})
    }
  end

  @doc """
  Writes the artifact to `path` (defaulting to `default_path/0`).

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec write(map(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def write(payload, path \\ nil) do
    path = path || default_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Json.encode(payload, pretty: true),
         :ok <- File.write(path, json) do
      {:ok, path}
    else
      {:error, %{} = err} -> {:error, "Cannot encode artifact: #{inspect(err)}"}
      {:error, reason} -> {:error, "Cannot write artifact to #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Convenience: build and write in one call. Returns `{:ok, path}`.
  """
  @spec emit(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def emit(report, opts \\ []) do
    payload = payload(report, opts)
    write(payload, Keyword.get(opts, :path))
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  # `branch` is what Phase 3.2's `GET /v1/baselines?repo=&branch=` keys on, so
  # it must be present even though nothing in v1 consumes it yet. Adding it now
  # costs nothing; retrofitting it would mean every stored run lacks the field.
  defp normalize_identity(identity) when is_map(identity) do
    %{
      "base_sha" => identity[:base_sha],
      "head_sha" => identity[:head_sha],
      "pr_number" => identity[:pr_number],
      "repository" => identity[:repository],
      "branch" => identity[:branch]
    }
  end

  defp normalize_identity(_), do: %{}

  defp normalize_finding(finding) do
    %{
      "id" => finding.id,
      "file" => finding.file,
      "line" => finding.line,
      "title" => finding.title,
      "description" => finding.description,
      "severity" => finding.severity,
      "kind" => finding.kind,
      "fix_suggestion" => finding.fix_suggestion,
      "gating" => Findings.at_or_above?(finding.severity, "high") and finding.kind == "issue"
    }
  end

  # A transcript is the model's own words about the diff, which is exactly
  # where a leaked secret would appear. Run it through AI Guard in enforce
  # mode; if it trips, record the redaction rather than the content.
  defp guarded_transcript(nil), do: nil

  defp guarded_transcript(text) when is_binary(text) do
    case AIGuard.guard_llm(text, :output, mode: :enforce, target: "review_transcript") do
      %{action: :blocked, reason: reason} ->
        %{"redacted" => true, "reason" => reason}

      _ ->
        %{"redacted" => false, "content" => text}
    end
  end

  defp guarded_transcript(_), do: nil
end

defmodule Yoke.CI.Review do
  @moduledoc """
  Headless `yoke review` (`docs/CI_PLAN.md` Phase 1.1).

  This is the orchestrator the CLI calls. It performs the whole review
  pipeline with **no TTY, no human, no `~/.yoke`, and no cloud dependency**:

      1. Resolve the review context (pinned base/head SHAs).
      2. Install the headless seams (`Yoke.Interaction.Policy`, `:ci` Hands).
      3. Run one review turn through `Yoke.Brain.Session.generate_code_review/4`.
      4. Parse and validate the findings.
      5. Classify, rank, and decide the exit code.
      6. Emit the sinks: step summary, annotations, artifact.
      7. Optionally post to the PR, guarded by `Context.verify_current/1`.

  Every step returns `{:ok, _}` or `{:error, reason}`; the caller maps the
  final result onto a process exit code. **Fail-open on infrastructure,
  fail-closed on findings** (§4.5 of the plan): a review that did not happen
  must never look green.

  ## What this module deliberately does *not* do

  It does not start Ragex, does not read `~/.yoke`, and does not touch the
  working tree. The review turn's tool catalog is
  `Yoke.PRReview.Tools`' revision-pinned read-only set, and the `:ci` Hands
  target additionally refuses any write-capable call.
  """

  alias Yoke.Brain.Session
  alias Yoke.CI.Annotations
  alias Yoke.CI.Artifact
  alias Yoke.CI.Findings
  alias Yoke.CI.StepSummary
  alias Yoke.Config.CI, as: CIConfig
  alias Yoke.Interaction.Policy
  alias Yoke.PRReview
  alias Yoke.PRReview.Context

  @doc """
  Runs a review.

  `opts` (all optional unless noted):

    * `:cwd` -- repository root (default `File.cwd!()`)
    * `:base` -- base revision (required for branch reviews)
    * `:head` -- head revision (default `"HEAD"`)
    * `:pr` -- PR number; when given, the context comes from the PR
    * `:fail_on` -- threshold; defaults per `Yoke.Config.CI.fail_on/2`
    * `:post` -- whether to post the review to the PR (default `false`)
    * `:model` / `:endpoint` / `:api_key` -- provider overrides
    * `:output` -- artifact path override
    * `:session` -- an already-started session pid (tests)
    * `:review_context` -- an already-resolved context (tests)

  Returns `{:ok, result}` where `result` is a map containing at least
  `:report`, `:exit_code`, `:artifact_path`, `:summary` (Markdown) and
  `:annotations` (workflow-command text), or `{:error, reason}`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    apply_diff_limit_override(Keyword.get(opts, :max_diff_bytes))

    with {:ok, context} <- resolve_context(opts, cwd),
         :ok <- install_seams(cwd),
         {:ok, response} <- run_review_turn(context, opts, cwd),
         {:ok, findings} <- parse_findings(response),
         :ok <- validate(findings, context) do
      finish(context, findings, response, opts, cwd)
    end
  end

  # `--max-diff-bytes` overrides the policy limit for this run only. Set in the
  # application env because `Yoke.Git.diff_branches/3` reads the limit there,
  # and threading a parameter through it would change a public signature for
  # one caller.
  defp apply_diff_limit_override(nil), do: :ok

  defp apply_diff_limit_override(limit) when is_integer(limit) and limit > 0 do
    Application.put_env(:yoke, :max_diff_bytes_override, limit)
    :ok
  end

  defp apply_diff_limit_override(_), do: :ok

  @doc """
  Resolves the review context from the given options.

  Exposed separately so `--dry-run` can show what *would* be reviewed without
  spending a model call.
  """
  @spec resolve_context(keyword(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def resolve_context(opts, cwd) do
    case Keyword.get(opts, :review_context) do
      %{} = context ->
        {:ok, context}

      nil ->
        case Keyword.get(opts, :pr) do
          nil ->
            Context.from_branches(Keyword.get(opts, :base), Keyword.get(opts, :head, "HEAD"), cwd)

          pr ->
            Context.from_pr(to_string(pr), cwd)
        end
    end
  end

  @doc """
  Installs the headless seams for the duration of a review.

  Idempotent, and deliberately not undone afterwards: a CLI process exits once
  the review is finished, and a test that wants the interactive seams back
  restores them itself.
  """
  @spec install_seams(String.t()) :: :ok
  def install_seams(cwd) do
    _ = CIConfig.install_headless_seams(cwd)
    :ok
  end

  # ---------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------

  defp run_review_turn(context, opts, cwd) do
    session_pid = Keyword.get(opts, :session)

    case session_pid do
      pid when is_pid(pid) ->
        Session.generate_code_review(pid, context.base, context.head, review_context: context)

      _ ->
        with {:ok, pid} <- start_session(opts, cwd) do
          Session.generate_code_review(pid, context.base, context.head, review_context: context)
        end
    end
  end

  defp start_session(opts, cwd) do
    # Hard, fail-closed budgets (`docs/CI_PLAN.md` Phase 1.3). `--max-cost`
    # tightens the policy ceiling for this run only.
    budget =
      Yoke.CI.Budget.from_policy(cwd,
        max_cost_usd: parse_cost(Keyword.get(opts, :max_cost))
      )

    session_opts =
      [
        session_id: "ci-review-#{System.unique_integer([:positive])}",
        cwd: cwd,
        budget: budget
      ]
      |> maybe_put(:model, Keyword.get(opts, :model))
      |> maybe_put(:provider, Keyword.get(opts, :provider))
      |> maybe_put(:endpoint, Keyword.get(opts, :endpoint))
      |> maybe_put(:api_key, Keyword.get(opts, :api_key))

    Yoke.Brain.SessionSupervisor.start_session(session_opts)
  end

  defp parse_cost(nil), do: nil

  defp parse_cost(value) when is_number(value), do: value * 1.0

  defp parse_cost(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {cost, _} -> cost
      :error -> nil
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp parse_findings(%{content: content}) do
    case PRReview.Findings.parse(content) do
      {:ok, findings} -> {:ok, findings}
      {:error, reason} -> {:error, "Review output was not valid structured findings: #{reason}"}
    end
  end

  defp parse_findings(_), do: {:error, "Review produced no content."}

  # `Context.validate_findings/2` already rejects anything not anchored to the
  # reviewed diff; re-running it here means a review that somehow produced an
  # off-diff anchor fails loudly instead of posting a stale comment.
  defp validate(findings, context) do
    case Context.validate_findings(findings, context) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(context, findings, response, opts, cwd) do
    fail_on = CIConfig.fail_on(cwd, Keyword.get(opts, :fail_on))
    report = Findings.report(findings, fail_on)
    identity = identity(context)

    summary = StepSummary.render(report, identity: identity)
    annotations = Annotations.render(report)

    artifact_opts = [
      path: Keyword.get(opts, :output),
      identity: identity,
      transcript: Map.get(response, :content),
      model: Keyword.get(opts, :model),
      run_uid: run_uid(),
      policy: Policy.load(cwd)
    ]

    # Register the in-progress result so the SIGTERM handler can flush it if
    # the runner cancels the job between here and the write below.
    Process.put(:yoke_ci_partial_result, %{report: report, artifact_opts: artifact_opts})

    with {:ok, _status} <- StepSummary.write(summary),
         {:ok, artifact_path} <- Artifact.emit(report, artifact_opts) do
      Process.delete(:yoke_ci_partial_result)

      with {:ok, posted} <- maybe_post(context, findings, opts, cwd) do
        {:ok,
         %{
           report: report,
           exit_code: Findings.exit_code(report),
           summary: summary,
           annotations: annotations,
           artifact_path: artifact_path,
           identity: identity,
           posted: posted
         }}
      end
    end
  end

  defp maybe_post(context, findings, opts, cwd) do
    if Keyword.get(opts, :post, false) do
      post_review(context, findings, cwd)
    else
      {:ok, :not_requested}
    end
  end

  defp post_review(%{pr_number: nil}, _findings, _cwd),
    do: {:error, "Cannot post a review without a PR number; run with --pr <number>."}

  defp post_review(context, findings, _cwd) do
    body = PRReview.build_pr_comment_body(findings, "", cwd: context.cwd)

    case PRReview.post_context_review(context, findings, body) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Failed to post review: #{reason}"}
    end
  end

  defp identity(context) do
    %{
      base_sha: context.base_sha,
      head_sha: context.head_sha,
      pr_number: context.pr_number,
      repository: context.repository,
      # `branch` is what Phase 3.2's baseline-suppression endpoint keys on.
      branch: Map.get(context, :head)
    }
  end

  @doc """
  Returns a stable identifier for this run.

  A UUIDv7-shaped value (time-ordered) so runs sort chronologically without a
  database.
  """
  @spec run_uid() :: String.t()
  def run_uid do
    # UUIDv7: 48-bit big-endian Unix milliseconds, then 80 random bits with
    # the version (7) and variant (RFC 4122) nibbles set. Built byte-wise
    # rather than with sub-byte bit patterns, which are easy to get subtly
    # wrong at the 6/8-byte group boundaries.
    ms = System.system_time(:millisecond)
    <<ms_hi::16, ms_lo::32>> = <<ms::48>>
    <<r1, r2, r3, r4, r5, r6, r7, r8, r9, r10>> = :crypto.strong_rand_bytes(10)

    # Byte layout of a UUIDv7 (16 bytes):
    #   0..5  ms_hi, ms_lo          (48-bit timestamp)
    #   6     version_byte          (0x70 | random nibble)
    #   7     r3
    #   8     variant_byte          (0x80 | random 6 bits)
    #   9..15 r4..r10
    version_byte = Bitwise.bor(0x70, Bitwise.band(r1, 0x0F))
    variant_byte = Bitwise.bor(0x80, Bitwise.band(r2, 0x3F))

    <<g1::binary-size(4), g2::binary-size(2), g3::binary-size(2), g4::binary-size(2),
      g5::binary-size(6)>> =
      <<ms_hi::16, ms_lo::32, version_byte, r3, variant_byte, r4, r5, r6, r7, r8, r9, r10>>

    hex = fn bytes -> Base.encode16(bytes, case: :lower) end
    "#{hex.(g1)}-#{hex.(g2)}-#{hex.(g3)}-#{hex.(g4)}-#{hex.(g5)}"
  end
end

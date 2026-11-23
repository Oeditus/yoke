defmodule Yoke.CI.FixFromReview do
  @moduledoc """
  `yoke fix --from-review` — turn a completed review into applied fixes
  (`docs/YAAS.md` §5.4).

  ## Why this exists

  Measuring review precision on a real repository showed that GitHub's own
  affordances are too sparse to be relied on: across four reviewed pull
  requests there were 16 threads, of which 0 were resolved and 2 carried a
  reaction. A product whose value is "the reviewer learns what you ignore" needs
  a signal that does not depend on reviewers clicking things.

  An accepted patch is that signal. A fix that applies cleanly and passes the
  suite is unambiguously correct in a way a comment never is, so this command is
  both a feature and the measurement instrument the precision loop needs.

  ## Safety

  Applying fixes mutates the working tree, so every guard that protects the
  interactive `/review` fix path applies here unchanged:

    * The checkout must be the repository root, at the reviewed head commit, and
      clean (`Yoke.PRReview.Context.verify_fix_checkout/2`).
    * The review artifact must carry the identity the fixes were computed
      against, and the checkout is re-verified immediately before the agent is
      dispatched, so a commit landing in between aborts rather than applying
      stale fixes.
    * `--dry-run` renders the prompt and applies nothing.

  ## What it does not do

  It does not post to the pull request, does not push, and does not commit. It
  edits the working tree and stops, leaving the diff for a human to inspect —
  the same contract as `yoke fix --apply`.
  """

  alias Yoke.CLI.Formatter
  alias Yoke.Json
  alias Yoke.PRReview

  @doc """
  Loads a review artifact and returns the actionable findings it carries.

  Returns `{:ok, %{findings: [...], identity: map}}` or `{:error, reason}`.
  Endorsements are excluded: praise is not a request for a change, so it is
  never a fix candidate.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with {:ok, raw} <- read(path),
         {:ok, decoded} when is_map(decoded) <- Json.decode(raw) do
      findings =
        decoded
        |> Map.get("findings", [])
        |> Enum.map(&normalize_finding/1)
        |> Enum.reject(&is_nil/1)
        |> PRReview.actionable_findings()

      {:ok, %{findings: findings, identity: Map.get(decoded, "identity", %{})}}
    else
      {:ok, _} -> {:error, "Artifact at #{path} is not a JSON object."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, raw} -> {:ok, raw}
        {:error, reason} -> {:error, "Cannot read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "No artifact at #{path}. Run `yoke review` first, or pass --artifact <path>."}
    end
  end

  # The artifact stores findings with string keys (`Yoke.CI.Artifact` encodes
  # them that way), while the fix-prompt builder expects atom keys. Normalising
  # here keeps the two representations from leaking into each other.
  defp normalize_finding(%{} = finding) do
    %{
      id: Map.get(finding, "id"),
      file: Map.get(finding, "file"),
      line: Map.get(finding, "line"),
      title: Map.get(finding, "title"),
      description: Map.get(finding, "description"),
      severity: Map.get(finding, "severity"),
      kind: Map.get(finding, "kind"),
      fix_suggestion: Map.get(finding, "fix_suggestion") || ""
    }
  end

  defp normalize_finding(_), do: nil

  @doc """
  Verifies that the working tree is the clean, reviewed checkout.

  `identity` is the artifact's identity map, which records `head_sha`. The check
  is deliberately the same one the interactive path uses rather than a parallel
  implementation: two guards that can drift apart are worse than one.
  """
  @spec verify_checkout(map(), String.t()) :: :ok | {:error, String.t()}
  def verify_checkout(identity, cwd) when is_map(identity) do
    head = Map.get(identity, "head_sha")

    if is_binary(head) and head != "" do
      context = %{cwd: Path.expand(cwd), head_sha: head}
      PRReview.Context.verify_fix_checkout(context, cwd)
    else
      {:error,
       "The artifact does not record the reviewed head commit, so fixes cannot be verified. " <>
         "Re-run `yoke review` to produce an artifact with identity."}
    end
  end

  @doc """
  Builds the agent prompt that asks for the fixes.

  Delegates to `Yoke.PRReview.build_fix_prompt/1` so the wording a CI fix run
  uses is identical to the wording the interactive path uses. A second prompt
  would drift.
  """
  @spec build_prompt([map()]) :: String.t()
  def build_prompt(findings) when is_list(findings) do
    base = PRReview.build_fix_prompt(findings)

    if String.trim(base) == "" do
      ""
    else
      base <>
        "\n\nApply each fix directly to the working tree. Do not commit, do not " <>
        "push, and do not touch files unrelated to these findings. If a finding " <>
        "is wrong once you read the surrounding code, say so and skip it rather " <>
        "than editing code to satisfy a mistaken comment.\n"
    end
  end

  @doc """
  Renders a one-line summary of what will be fixed.

  Endorsements are already excluded by `load/1`, so the count is the number of
  actionable findings.
  """
  @spec summary([map()]) :: String.t()
  def summary(findings) when is_list(findings) do
    count = length(findings)
    "#{count} actionable finding(s) to fix"
  end

  @doc """
  Prints the findings that will be fixed, worst first.

  Ordering by severity means a truncated agent turn addresses the important
  findings before the cosmetic ones.
  """
  @spec print_findings([map()]) :: :ok
  def print_findings(findings) when is_list(findings) do
    findings
    |> Enum.sort_by(&severity_rank/1, :desc)
    |> Enum.each(fn finding ->
      location =
        cond do
          finding.file && finding.line -> "#{finding.file}:#{finding.line}"
          finding.file -> finding.file
          true -> "general"
        end

      IO.puts("  [#{finding.severity}] #{finding.title}  (#{location})")
    end)

    :ok
  end

  defp severity_rank(%{severity: severity}) do
    case String.downcase(to_string(severity)) do
      "high" -> 4
      "medium" -> 3
      "low" -> 2
      "info" -> 1
      _ -> 0
    end
  end

  @doc "Renders the usage text for `yoke fix --from-review`."
  @spec usage() :: String.t()
  def usage do
    """
    yoke fix --from-review — apply a completed review's findings to the working tree

    USAGE:
      yoke fix --from-review [--artifact <path>] [--dry-run] [options]

    Reads the JSON artifact `yoke review` wrote, verifies the checkout is the
    clean reviewed commit, and asks the agent to apply the findings. Nothing is
    committed or pushed; the working-tree diff is left for review.

    OPTIONS:
          --from-review      Read findings from a review artifact
          --artifact <path>  Artifact to read (default: $RUNNER_TEMP/yoke-review.json)
          --dry-run          Print the prompt and apply nothing
          --provider <name>  Provider profile
      -h, --help             Show this help

    EXIT CODES:
      0  no actionable findings, or the fixes were applied
      1  fixes were planned but not applied (--dry-run)
      2  usage error
      3  the artifact could not be read, or the checkout is not the reviewed head
    """
  end

  @doc "Prints a warning when the artifact carries no actionable findings."
  @spec warn_empty() :: :ok
  def warn_empty do
    IO.puts(Formatter.format_info("No actionable findings in the artifact; nothing to fix."))
    :ok
  end
end

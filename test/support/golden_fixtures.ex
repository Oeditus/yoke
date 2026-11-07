defmodule Yoke.CI.GoldenFixtures do
  @moduledoc """
  Helpers for the golden-file review tests (`docs/CI_PLAN.md` Phase 1.1 exit
  test: "golden-file tests over 5 real PRs. Byte-identical output on re-run.").

  The fixtures are real merge commits from a sibling repository (`../muex` by
  default, overridable with `YOKE_GOLDEN_REPO`). Using a real repository rather
  than synthetic diffs means the tests exercise the actual shape of production
  code: multi-file changes, renames, deletions, and long diffs.

  ## Why the repo is optional

  A checkout of `../muex` is not guaranteed to exist (a fresh clone, CI). When
  it is absent the golden tests **skip** rather than fail — the suite must stay
  green for contributors who do not have it, while still running for those who
  do.
  """

  @default_repo "../muex"

  # Real merge commits (base parent, merge commit) from muex's history. Each
  # pair is a genuine pull request.
  @ranges [
    {"17098ac446ed472c4fc3327fd56cd30f1558085a", "d5b8498dceed7cd9ae2d829b897cc507ba494419",
     "pr-40-deadline-partial-results"},
    {"a08fe40b6befc34b1df6de8acfa31cb2ba216d03", "6b68ab50f2e85c8bef5d91528e3e389bc969a0cb",
     "pr-38-mutators-when-app-not-loaded"},
    {"598625c9721e77d0cd85229a80fb7dfa081f4607", "40b79e1add1b8f57adf12f10b587db732c646509",
     "pr-37-sandbox-dir-collision"},
    {"2ef1032d24c2b88d403f1965d695a27fa48e20e3", "7762a30a94a33e1f02ecd9fcb35f83dbc619741c",
     "pr-34-opt-in-mirror-dirs"},
    {"8a0c3fda7cb62f171c6f941eb0d02079fc6bbe31", "5d60f4c1258390304cf484d9320628dd61131f56",
     "pr-1-opt-in-mirror-dirs"}
  ]

  @doc "Returns the fixture repository path (overridable via `YOKE_GOLDEN_REPO`)."
  @spec repo() :: String.t()
  def repo, do: System.get_env("YOKE_GOLDEN_REPO") || @default_repo

  @doc """
  Returns the five real PR ranges as `{base_sha, head_sha, label}`.

  The SHAs are pinned, so the fixtures are stable regardless of how the
  repository's history grows.
  """
  @spec ranges() :: [{String.t(), String.t(), String.t()}]
  def ranges, do: @ranges

  @doc """
  Returns true when the fixture repository is present and contains every
  pinned commit. When false, golden tests should be skipped.
  """
  @spec available?() :: boolean()
  def available? do
    path = repo()

    File.dir?(Path.join(path, ".git")) and
      Enum.all?(ranges(), fn {base, head, _} ->
        commit_exists?(path, base) and commit_exists?(path, head)
      end)
  end

  defp commit_exists?(path, sha) do
    match?(
      {_, 0},
      System.cmd("git", ["cat-file", "-e", "#{sha}^{commit}"],
        cd: path,
        stderr_to_stdout: true
      )
    )
  end

  @doc """
  Returns the absolute path to the golden directory.

  Golden files live beside this helper in `test/support/golden/`, next to the
  fixtures that generate them, so the two are always reviewed together.
  """
  @spec golden_dir() :: String.t()
  def golden_dir, do: Path.join(__DIR__, "golden")

  @doc """
  Returns the path of the golden file for `label`.

  `kind` distinguishes the artefacts captured per PR: `"report"` (the rendered
  step summary) and `"annotations"` (the workflow commands).
  """
  @spec golden_path(String.t(), String.t()) :: String.t()
  def golden_path(label, kind), do: Path.join(golden_dir(), "#{label}.#{kind}.golden")

  @doc """
  Normalises volatile content so output is comparable across runs.

  Only genuinely non-deterministic fields are replaced: run identifiers and
  timestamps. Everything else — ordering, wording, escaping — must match
  exactly, or the test is not testing determinism.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.replace(
      ~r/[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}/,
      "<RUN_UID>"
    )
    |> String.replace(~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/, "<TIMESTAMP>")
  end
end

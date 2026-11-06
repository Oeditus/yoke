# Yoke in CI

> Implementation notes for the phased plan in [`CI_PLAN.md`](CI_PLAN.md).
> This document is the operator's manual; `CI_PLAN.md` is the design record.

Yoke runs headlessly in GitHub Actions with **no TTY, no human, no `~/.yoke`,
and no cloud dependency**. This page documents the seams that make that
possible, the policy document that governs them, and the workflow snippets
that use them.

---

## 1. The three seams

Everything below is built on three small seams. They are the foundation every
later CI capability reuses, so they are documented first.

### 1.1 `Yoke.Interaction` — the blocking seam

Every place where an agent turn would otherwise stop and wait for a human is
routed through the `Yoke.Interaction` behaviour:

```elixir
@callback ask(kind(), map()) :: :approve | :deny | {:answer, String.t()}
```

| Kind | Raised when |
| :--- | :--- |
| `:plan_gate` | A non-trivial batch of tool calls needs plan approval |
| `:plan_revision` | The user asked for plan changes and must supply feedback |
| `:loop_break` | The agent is stuck repeating the same tool cycle |
| `:api_error` | The provider failed after all retries |
| `:max_depth` | The agent loop hit its max tool-iteration depth |
| `:tool_permission` | A tool call needs explicit user confirmation |
| `:review_fix` | A review turn wants to apply fixes / record patterns |

Two implementations ship:

* **`Yoke.Interaction.TTY`** — the interactive REPL. It wraps
  `Yoke.CLI.Spinner.with_paused/1` plus `Yoke.CLI.QuestionPrompt`, so REPL
  behaviour is byte-identical to before the seam existed.
* **`Yoke.Interaction.Policy`** — headless. It **never blocks** and **never
  asks**; it answers immediately from the policy document. It is
  **fail-closed**: a missing or malformed policy answers `:deny`.

The implementation is selected **once**, at startup:

```elixir
config :yoke, interaction: Yoke.Interaction.TTY   # default
config :yoke, interaction: Yoke.Interaction.Policy # CI
```

so no call site branches per call — they all just call
`Yoke.Interaction.ask(kind, context)`.

### 1.2 `Yoke.CLI.Output` — the presentation seam

`Yoke.CLI.Output` decides once whether stdout is a real terminal and caches
the answer in `:yoke, :output_mode` (`:auto` | `:tty` | `:plain`).

In `:plain` mode every colour helper in `Yoke.CLI.Formatter` returns `""` and
`display_width/1` returns a plain grapheme count. Because every CLI surface
already builds its lines out of those helpers, **no call site changed** —
`Yoke.Hands.Executor` in particular needed no presentation changes at all.

`Yoke.CLI.Main.main/1` calls `Yoke.CLI.Output.prime()` before anything else,
so the probe happens exactly once.

### 1.3 `Yoke.Hands.Executor` `:ci` mode — the fourth Hands target

`mode: :ci` sits alongside `:local | :remote | :docker`. Differences from
`:local`:

* **Read-only by policy.** Any write-capable tool (`write_file`,
  `replace_file`, `edit_files`, `git_commit`, …) and any write-ish `bash`
  command is refused at the executor, before the tool runs. A prompt-injected
  diff therefore cannot make the runner modify the checkout.
* **Per-call wall-clock budget.** `timeout_ms` bounds each tool call; a call
  that overruns is killed and reported as an error rather than hanging the job.
* **AI Guard in `:enforce`.** Anything reaching the executor is screened with
  `Yoke.AIGuard.guard_tool/3` in enforce mode.
* **Structured JSON-lines tool logs** on stderr when `YOKE_CI_LOGS=1`.

---

## 2. The policy document

`.yoke/policy.json`, repo-relative. The `YOKE_POLICY` environment variable may
point at an alternative path and takes precedence. **`~/.yoke` is never read
or written.**

```json
{
  "plan_gate": "deny",
  "plan_revision": "deny",
  "loop_break": "deny",
  "api_error": "deny",
  "max_depth": "deny",
  "tool_permission": "deny",
  "review_fix": "deny",
  "allow_writes": false,
  "fail_on": "high",
  "max_tool_calls": 120,
  "max_wall_clock_s": 900,
  "max_cost_usd": 2.0,
  "max_tokens": 400000
}
```

| Key | Meaning |
| :--- | :--- |
| `<kind>` | `"approve"` or `"deny"` for that interaction kind |
| `allow_writes` | Whether `:ci` Hands may mutate the checkout at all |
| `fail_on` | Exit-code threshold: `high` \| `medium` \| `low` \| `info` \| `never` |
| `max_tool_calls` | Hard cap on tool calls in one run |
| `max_wall_clock_s` | Hard cap on wall-clock seconds in one run |
| `max_cost_usd` | Hard cap on estimated USD spend |
| `max_tokens` | Hard cap on total tokens |

Every value is validated. An unrecognised value is **dropped** and replaced by
the safe default rather than propagated — a typo must not silently loosen a
safety property.

---

## 3. Quick start

Add three lines to a workflow:

```yaml
name: Review
on: pull_request

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.20'
          otp-version: '29'
      - uses: Oeditus/yoke@v1
        with:
          command: review
          fail-on: high
        env:
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## 4. `yoke review`

```
yoke review --base <rev> [--head <rev>] [options]
yoke review --pr <number> [options]
```

| Flag | Meaning |
| :--- | :--- |
| `--base <rev>` | Base revision for a branch review |
| `--head <rev>` | Head revision (default `HEAD`) |
| `--pr <number>` | Review a GitHub PR instead of a branch range |
| `--fail-on <level>` | `high` \| `medium` \| `low` \| `info` \| `never` |
| `--format <fmt>` | `markdown` \| `json` \| `summary` |
| `--output <path>` | Artifact path (default `$RUNNER_TEMP/yoke-review.json`) |
| `--post` | Post the review to the PR via `gh` |
| `--model` / `--endpoint` | Provider overrides |
| `--max-cost <usd>` | Hard USD budget |
| `--dry-run` | Resolve the context and exit without a model call |

### 4.1 Exit codes are policy

| Code | Meaning |
| :--- | :--- |
| `0` | Review completed; nothing at or above `--fail-on` |
| `1` | Review completed; at least one finding at or above `--fail-on` |
| `2` | Usage error |
| `3` | Infrastructure failure (model error, posting failed, invalid output) |

The default threshold is `high` on `pull_request` and `never` on `push`: a
reviewer is expected to block a PR, but a red build on `main` would be noise.

**Fail-open on infrastructure, fail-closed on findings.** A model failure or a
failed post exits `3` — a review that did not happen must never look green.

### 4.2 The findings pipeline

```
model output
  → Yoke.PRReview.Findings.parse/1        (schema validation)
  → Yoke.PRReview.Context.validate_findings/2  (off-diff anchors rejected)
  → Yoke.CI.Findings.classify/1           (issue vs endorsement)
  → Yoke.CI.Findings.report/2             (severity rank + gating)
```

Endorsements are observations, never requests for changes: they are reported
in the summary and artifact, but they **never** gate and never count toward
`findings-count`.

### 4.3 Sinks

| Sink | Destination | Notes |
| :--- | :--- | :--- |
| `Yoke.CI.StepSummary` | `$GITHUB_STEP_SUMMARY` | Markdown verdict + counts table + findings |
| `Yoke.CI.Annotations` | stdout workflow commands | `::error file=...,line=...::` inline annotations |
| `Yoke.CI.Artifact` | `$RUNNER_TEMP/yoke-review.json` | Full findings + transcript + policy |

**Annotations are escaped.** A finding whose message contains a newline would
truncate the annotation, and one containing `::` could inject a *different*
workflow command. `Yoke.CI.Annotations` escapes `%`, `\r`, `\n`, `:` and `,`
per GitHub's documented rules.

**Artifacts are guarded.** Everything written to the artifact passes through
`Yoke.AIGuard.guard_llm/3` in `:enforce` mode first. A transcript that trips a
secret pattern is replaced by a redaction record, not uploaded.

---

## 5. Budgets

Every run has four hard, **fail-closed** budgets (`Yoke.CI.Budget`), read from
the policy document:

| Key | Meaning | Default |
| :--- | :--- | ---: |
| `max_tool_calls` | Total tool calls in one run | 120 |
| `max_wall_clock_s` | Wall-clock seconds in one run | 900 |
| `max_tokens` | Total tokens (prompt + completion) | 400 000 |
| `max_cost_usd` | Estimated USD spend | 2.00 |

Exceeding any of them aborts the turn with an error naming the ceiling and
the value reached — never a warning that lets the run continue. `--max-cost`
tightens the cost ceiling for a single invocation without editing the policy
file.

Cost uses the same per-million-token prices as the status bar and `/cost`
(`price_per_million_prompt_tokens` / `price_per_million_completion_tokens`), so
a CI run and an interactive session never disagree about what a review cost.

### 5.1 Cancellation

If the runner cancels the job (timeout, superseded run, manual cancel) it
sends `SIGTERM`. The handler in `Yoke.Application` flushes whatever the review
has produced so far to the artifact sink, so a cancelled run still leaves
evidence of how far it got rather than failing silently.

---

## 6. The Action

`action.yml` is a composite action. Inputs:

`command`, `base`, `head`, `pr`, `model`, `endpoint`, `fail-on`, `config-path`,
`post`, `with-ragex`, `upload`, `api-url`, `api-key`, `yoke-version`,
`elixir-version`, `otp-version`.

Outputs: `findings-count`, `max-severity`, `run-uid`, `report-path`.

`scripts/install.sh` downloads the pinned escript and **verifies its SHA-256
before making it executable**, so a corrupted or tampered download can never
run. It never uses `sudo`.

---

### 6.1 Why `:exla` is compile-only under `:test`

`exla`'s NIF links against CUDA libraries (`libnccl`, `libcublas`, `libcudart`,
…). A stock GitHub `ubuntu-latest` runner does not have them, and
`EXLA.Application.start/2` **raises** when they are missing — which took the
whole `:yoke` application down, so `mix test` could not run in CI at all.

Three dependency edges had to be cut for `:test`:

| Dependency | Why |
| :--- | :--- |
| `:exla` | The NIF itself |
| `:image` | Declares `:exla` as a dependency |
| `:ragex` | Declares `:exla` as an *optional* dependency |

Each is declared `runtime: false` under `MIX_ENV=test` in `mix.exs`, so it is
still compiled and available on the code path but never **started**. Nothing in
the test suite needs the NIF: every embeddings-dependent test is tagged
`ragex: true` and excluded in CI, and `Nx.BinaryBackend` is the configured
default backend.

`:dev` and `:prod` are unaffected and keep full embeddings support.

> **Note:** the `EXLA_BUILD: "false"` environment variable that appears in
> several workflows is read by nothing — neither `exla` nor `yoke` consults it.
> It is dead configuration; the `runtime: false` declarations above are what
> actually prevent the NIF from loading.

---

### 6.1 `:exla` and CUDA libraries on CI runners

`exla` downloads a **prebuilt XLA binary** at compile time, and which one it
fetches is decided by the `XLA_TARGET` environment variable:

| `XLA_TARGET` | Prebuilt binary | GPU libraries needed? |
| :--- | :--- | :--- |
| `cpu` (default) | CPU-only | **No** |
| `cuda12` / `cuda13` | CUDA-linked | Yes — cuBLAS, cuDNN, NCCL, nvshmem, … |

If a CUDA installation is detected on the build machine, `exla` **overrides the
default** and downloads the CUDA build. That build's NIF links against ~20 GPU
libraries (`libcublas.so.13`, `libcudnn*.so.9`, `libnccl.so.2`, …), and
`EXLA.Application.start/2` raises when they are absent — taking the whole
`:yoke` application down, so `mix test` cannot run at all.

#### The fix

Pin the CPU build explicitly. This is what `ci.yml` does:

```yaml
env:
  XLA_TARGET: cpu          # CPU-only prebuilt binary, no CUDA linkage
  NX_DEFAULT_BACKEND: Nx.BinaryBackend
```

Two details that matter:

* **The variable is `XLA_TARGET`, not `EXLA_TARGET`.** The workflows previously
  set `EXLA_TARGET`, which nothing reads — so `exla` fell back to auto-detection
  and pulled the CUDA build. The same applies to `EXLA_BUILD`, which is also
  read by nothing; both have been removed.
* **The dependency cache key includes `XLA_TARGET`.** Without it, a runner that
  cached a CUDA build would keep reusing it even after the variable changed.

#### Verifying locally

```bash
# Which prebuilt binary was downloaded:
cat deps/exla/cache/xla_snapshot.txt
# .../xla_extension-0.10.0-x86_64-linux-gnu-cuda13.tar.gz   <- CUDA build
# .../xla_extension-0.10.0-x86_64-linux-gnu-cpu.tar.gz      <- CPU build

# How many GPU libraries the NIF expects but cannot find:
ldd deps/exla/cache/libexla.so | grep -c "not found"
# 20 for the cuda13 build on a machine without CUDA; expected 0 for cpu
```

To reproduce the CI failure locally, point `LD_LIBRARY_PATH` away from your CUDA
libraries and run `mix test` — the `cuda13` build will fail to start `:exla`.

> **Note:** a machine with CUDA installed will try to *rebuild* the NIF from
> source when `deps/exla/cache` is removed, which needs `XLA_BUILD=true` and a
> C++ toolchain. On a clean CI runner, `XLA_TARGET=cpu` avoids that path — it
> downloads a prebuilt binary instead.

---

## 7. Verifying headlessly

The exit test for the seams is that nothing hangs and nothing emits ANSI:

```bash
# No TTY, no hang, no escape bytes on stdout.
echo "" | MIX_ENV=prod yoke "hello"

# A review against a real commit range, with stdin closed.
MIX_ENV=prod yoke review --base <sha> --head <sha> </dev/null
```

### 7.1 Testing convention: declare your output mode

Because `Yoke.CLI.Formatter`'s colour helpers now return `""` when output is
not a terminal, **any test that asserts on ANSI output must pin the mode**:

```elixir
setup do
  prior = Application.get_env(:yoke, :output_mode)
  Application.put_env(:yoke, :output_mode, :tty)

  on_exit(fn ->
    if prior == nil,
      do: Application.delete_env(:yoke, :output_mode),
      else: Application.put_env(:yoke, :output_mode, prior)
  end)

  :ok
end
```

`MIX_ENV=test` is treated as non-TTY by `Yoke.CLI.Output.detect_mode/0`, so
without this pin the assertions see plain text. Modules that follow this
convention today: `formatter_test.exs`, `spinner_test.exs`,
`log_formatter_test.exs`, `question_prompt_test.exs`, `hands_executor_test.exs`.

This is deliberate: it forces every test to say *which* rendering it is
asserting, instead of silently depending on whether the suite happens to run
in CI.

### 7.2 One width algorithm

`Yoke.CLI.Output.display_width/1` is the single implementation of
ANSI-aware display width; `Yoke.CLI.Formatter.display_width/1` delegates to
it. Do not reintroduce a second copy — an earlier draft had `Formatter`
delegate *to* `Output` while `Output` delegated back to `Formatter` in `:tty`
mode, which recursed infinitely and hung the suite.

---

## 8. Further reading

* [`CI_PLAN.md`](CI_PLAN.md) — the design record and full roadmap.
* [`ARCHITECTURE.md`](ARCHITECTURE.md) — Brain/Hands/Plugins overview.
* [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures.

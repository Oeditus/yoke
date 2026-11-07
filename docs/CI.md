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
  "max_tokens": 400000,
  "max_diff_bytes": 300000
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
| `max_diff_bytes` | Cap on the review diff size, in bytes (default 300 KB) |

Recognised `<kind>` values: `plan_gate`, `plan_revision`, `loop_break`,
`api_error`, `max_depth`, `tool_permission`, `review_fix`, `workflow_confirm`,
`lint_fix`.

Every value is validated. An unrecognised value is **dropped** and replaced by
the safe default rather than propagated — a typo must not silently loosen a
safety property.

> **Adding a key requires code changes.** `Yoke.Interaction.Policy` normalises
> against an explicit allowlist, so a key that is not added to
> `normalize_value/2` is silently ignored. This bit us once with
> `max_diff_bytes`; if a policy setting appears to have no effect, check the
> allowlist first.

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

### 3.1 Push review

Review everything that landed on a branch. `fail-on: never` is the right
default here — a red build on `main` for a style nit is noise, and the findings
still reach the step summary.

```yaml
name: Review push
on:
  push:
    branches: [main]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
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
          # The action derives base/head from the push event's before/after.
          fail-on: never
          post: 'false'
        env:
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
```

### 3.2 Scheduled review

A nightly sweep catches drift that per-PR review misses — a dependency that
went stale, a pattern that accumulated. Use `--fail-on never` and read the
artifact, or gate on `high` if you want it to open an issue.

```yaml
name: Nightly review
on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
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
          # Compare the last 7 days of commits against main.
          base: HEAD~7
          head: HEAD
          fail-on: never
          post: 'false'
        env:
          DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}
```

### 3.3 Validating the pipeline without spending credits

Before trusting a real review, exercise the action end-to-end with no model
call. `yoke lint` needs no provider credentials, so this proves install,
checksum verification, dispatch, and the sinks all work:

```bash
gh workflow run yoke-review.yml -f dry-run=true
```

That runs the `dry-run` job only: `command: lint`, no `DEEPSEEK_API_KEY`. If it
passes, the plumbing is sound and a real review failure is a *model* problem,
not an infrastructure one.

### 3.4 Lint only (no model call)

`yoke lint` needs no provider credentials and runs in seconds. This is the
cheapest useful CI job:

```yaml
name: Lint
on: [push, pull_request]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.20'
          otp-version: '29'
      - uses: Oeditus/yoke@v1
        with:
          command: lint
          fail-on: high
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

## 6. `yoke lint`

Runs the project's static-analysis tools as **one annotated report**, in the
same shape `yoke review` produces:

```
yoke lint [--tool <name>]... [options]
```

| Flag | Meaning |
| :--- | :--- |
| `--tool <name>` | Run only this tool (repeatable) |
| `--fail-on <level>` | `high` \| `medium` \| `low` \| `info` \| `never` |
| `--format <fmt>` | `markdown` \| `json` \| `summary` |
| `--output <path>` | Artifact path (default `$RUNNER_TEMP/yoke-lint.json`) |
| `--timeout <ms>` | Per-tool timeout (default 300 000) |

Tools: `format`, `credo`, `oeditus_credo`, `dialyzer`, `deps.audit`.

### 6.1 Exit codes

| Code | Meaning |
| :--- | :--- |
| `0` | All tools ran; nothing at or above `--fail-on` |
| `1` | Findings at or above `--fail-on` |
| `2` | Usage error |
| `3` | A tool could not run |

**Code 3 is deliberately distinct from 1.** A linter that did not run must not
look like a linter that passed, and must not be confused with a real finding.

### 6.2 Why an adapter layer

The tools speak different dialects:

| Tool | Native output | Parsed as |
| :--- | :--- | :--- |
| `credo`, `oeditus_credo` | JSON `{"issues": [...]}` | file, line, message, priority → severity |
| `dialyzer` | `--format short` → `file:line: message` | file, line, message (`high`) |
| `format` | bare paths, one per line | file (`low`) |
| `deps.audit` | advisory blocks | dependency + title (`high`) |
| `propwise` | unstructured prose | one informational finding |

`Yoke.CI.Lint.Parser` is the single place that knows all of them, so the
parsing is unit-testable without shelling out to `mix`.

### 6.3 Exit codes are not failure signals

Every one of these tools signals "issues found" through a **bitmask** exit
code — `credo` 4, `oeditus_credo` 16, `dialyzer` 2, `format` 1. Treating a
non-zero exit as a crash would report every successful run as a failure. The
adapter instead looks for an Elixir stack trace (`** (`) in the output to
distinguish a real crash from a normal findings report.

---

## 7. `yoke describe`

A one-shot pull-request summary. Where `review` runs a read-only agent loop to
find defects, `describe` makes a **single tool-free model call** to explain what
a diff does.

```
yoke describe --base <rev> [--head <rev>] [options]
yoke describe --pr <number> [options]
```

| Flag | Meaning |
| :--- | :--- |
| `--base` / `--head` / `--pr` | The range to describe |
| `--model` / `--endpoint` | Provider overrides |
| `--max-cost <usd>` | Hard USD budget |
| `--format <fmt>` | `markdown` \| `json` \| `summary` |
| `--output <path>` | Artifact path (default `$RUNNER_TEMP/yoke-describe.json`) |

Exit codes: `0` summary produced, `2` usage error, `3` could not be produced
(provider error, empty diff). An empty completion is an **error**, never a
blank success.

The prompt asks for 3–6 sentences covering what changed, why (inferred only
from the diff — "unclear" is an acceptable answer), and what to look at first.
It explicitly excludes defect review, which is `yoke review`'s job, and treats
the diff as untrusted evidence.

---

## 8. `yoke audit`

Emits the `Yoke.AIGuard` audit trail as a CI artifact and step summary.

```
yoke audit [options]
```

| Flag | Meaning |
| :--- | :--- |
| `--fail-on <level>` | `high` \| `medium` \| `low` \| `info` \| `never` |
| `--since <iso8601>` | Only entries at or after this timestamp |
| `--limit <n>` | Max findings rendered (default 50) |
| `--format <fmt>` | `markdown` \| `json` \| `summary` |
| `--output <path>` | Artifact path (default `$RUNNER_TEMP/yoke-audit.json`) |

Exit codes: `0` nothing gating, `1` blocked/flagged at or above `--fail-on`,
`2` usage error, `3` trail unreadable.

### 8.1 What it reports

`Yoke.AIGuard` already writes every guarded LLM call and tool execution to
`.yoke/logs/ai_guard_audit.jsonl`. `yoke audit` turns that into:

- **Counts** by phase (`input` / `output` / `tool_call`) and action
  (`pass` / `flagged` / `blocked`).
- **Findings** for anything `flagged` (`medium`) or `blocked` (`high`).
- **The raw trail** in the artifact.

`pass` entries are counted but never become findings — an audit trail is mostly
evidence that things were fine.

### 8.2 Two things that matter at scale

**`--since`.** A trail accumulates across every local run. Without a window, a
CI report on this repository produced **346 findings from 16 000 entries** —
almost all of it stale test fixtures, not the run under review. Set
`--since` (or `YOKE_AUDIT_SINCE`) to the job's start time.

**`--limit`.** A 300-row step summary is unreadable. The rendered table is
capped at 50 findings by default and says so explicitly
("_Showing 5 of 346 findings_"); the artifact always contains every entry.

---

## 9. `yoke run <workflow>`

Runs a workflow definition end-to-end with no TTY.

```
yoke run <workflow> [--prompt <text>] [--output <path>]
yoke run --list
```

Exit codes: `0` completed, `1` halted (a step declined to continue),
`2` usage error, `3` could not run.

### 9.1 How the engine degrades in CI

The workflow engine was written for an interactive REPL. Once
`Yoke.Interaction.Policy` is installed it degrades without any workflow-specific
code:

| Step | Interactive | In CI |
| :--- | :--- | :--- |
| `task_split` | Asks; may fan out into parallel git worktrees | Policy answers `:deny` → **single task** |
| `branch` | Asks before branching off an unexpected base | Policy answers `:deny` → **halts** with a clear message |

Single-task is the correct behaviour: a CI job has one checkout and no
worktrees to spare. Halting rather than branching is also correct — a runner
should not create branches as a side effect of a review.

### 9.2 A seam gap this closed

`task_split` and `branch` called `Yoke.CLI.QuestionPrompt` **directly**, outside
the seven call sites enumerated in `docs/CI_PLAN.md` §2.1. They are on the
`yoke run` path, so they would have blocked forever in CI. Both now route
through `Yoke.Interaction.ask(:workflow_confirm, ...)`, and
`test/yoke/ci_run_test.exs` asserts they never regress to calling the prompt
directly.

This is worth noting because the original audit was scoped to
`Yoke.Brain.Session` and `Yoke.CLI.Repl`; the workflow steps were missed.
`Yoke.Linter.Interactive` still calls `QuestionPrompt` directly, but it is not
reachable from any CI subcommand.

---

## 10. `yoke rag`

Builds or inspects Ragex code intelligence. **Optional**, and the last Milestone
2 command.

```
yoke rag --index [--strict] [--timeout <ms>]
yoke rag --status
```

| Flag | Meaning |
| :--- | :--- |
| `--index` | Start Ragex and wait for indexing to finish |
| `--status` | Report whether Ragex is running and whether a graph exists |
| `--strict` | Exit `3` when Ragex is unavailable |
| `--timeout <ms>` | Indexing timeout (default 600 000) |

### 10.1 Why it is a separate command

`yoke review` deliberately does **not** start Ragex (§4.2): starting it spawns a
`dllb-server` and may download an embedding model — 2–4 minutes on a cold
runner — for marginal benefit on a diff review. `yoke rag` exists so a
repository that *does* want the graph can build it in a dedicated, cacheable
step:

```yaml
- uses: actions/cache@v4
  with:
    path: .ragex
    key: ragex-${{ hashFiles('**/*.ex', '**/*.exs', 'mix.lock') }}
- run: yoke rag --index
```

### 10.2 Failure is not fatal

Ragex is an **enhancement, not a dependency**. If it cannot start (no
`dllb-server`, no model, no network), `yoke rag` reports why and exits `0` — a
review that would merely have been slower must not fail because an optional
accelerator was unavailable. `--strict` opts into failing instead.

---

## 11. The Action

`action.yml` is a composite action. Inputs:

`command`, `base`, `head`, `pr`, `model`, `endpoint`, `fail-on`, `config-path`,
`post`, `with-ragex`, `upload`, `api-url`, `api-key`, `yoke-version`,
`elixir-version`, `otp-version`.

Outputs: `findings-count`, `max-severity`, `run-uid`, `report-path`.

`scripts/install.sh` downloads the pinned escript and **verifies its SHA-256
before making it executable**, so a corrupted or tampered download can never
run. It never uses `sudo`.

---

### 11.1 `:exla` on CI runners — and why we leave it alone

`exla` downloads a prebuilt XLA binary chosen by `XLA_TARGET`, then compiles
**its own** NIF from source. That compile fails on `exla` 1.0.0 with GCC 15:

```
deps/fine/c_include/fine.hpp:479: error: 'try_decode' is not a member of
  'fine::Decoder<xla::Shape>'
```

`main` is green only because it never reaches that code path — it restores a
`deps` cache containing a prebuilt `libexla.so`.

**The correct configuration is therefore `main`'s**, and `EXLA_TARGET` /
`EXLA_BUILD` stay in place as harmless dead config. They are read by nothing,
but they are not worth "fixing":

| Change | Effect |
| :--- | :--- |
| Leave `EXLA_TARGET` (dead) | Cache hit, no compile, **green** |
| Replace with `XLA_TARGET=cpu` | Cache key changes → cold compile → **red** |

The second is what this branch did on its first CI run, and it made CI strictly
worse. `XLA_TARGET=cpu` *does* download the CPU-only XLA archive correctly
(the log confirms `Unpacking ... x86_64-linux-gnu-cpu.tar.gz`) — the failure is
in `exla`'s own NIF compile, which happens either way on a cold cache.

> **Lesson:** a dead environment variable is not automatically worth fixing.
> Replacing `EXLA_TARGET` with the "real" `XLA_TARGET` looked like a clean fix
> and broke the build. The cost was hidden in a cache key.

If a cold compile ever becomes unavoidable (cache eviction, an `exla` upgrade),
the blocker is the `fine` / GCC 15 incompatibility, not the target selection.

## 12. Verifying headlessly

The exit test for the seams is that nothing hangs and nothing emits ANSI:

```bash
# No TTY, no hang, no escape bytes on stdout.
echo "" | MIX_ENV=prod yoke "hello"

# A review against a real commit range, with stdin closed.
MIX_ENV=prod yoke review --base <sha> --head <sha> </dev/null
```

### 12.1 Testing convention: declare your output mode

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

### 12.2 One width algorithm

`Yoke.CLI.Output.display_width/1` is the single implementation of
ANSI-aware display width; `Yoke.CLI.Formatter.display_width/1` delegates to
it. Do not reintroduce a second copy — an earlier draft had `Formatter`
delegate *to* `Output` while `Output` delegated back to `Formatter` in `:tty`
mode, which recursed infinitely and hung the suite.

### 12.3 Escript startup logs

An escript archive starts the dependency tree (`:ragex`, `:dllb`) before
`config/runtime.exs` is evaluated and before `Yoke.CLI.Main.main/1` runs, so
~15 startup lines were emitted raw — timestamps and `[info]` tags included —
ahead of the command's own output.

**Fixed** by baking the formatter into the archive's `:logger` app env at build
time, in `config/config.exs`:

```elixir
if config_env() == :escript do
  config :logger, default_handler: [formatter: {Yoke.CLI.LogFormatter, %{}}]
end
```

Runtime installation (in `runtime.exs` or `main/0`) cannot work for an escript,
because by then the dependencies have already logged. The config must be
present in the archive itself.

Two related fixes in the same area:

* `config/runtime.exs` configured `:exla` unconditionally, but `mix.exs`
  excludes that dep under `MIX_ENV=escript` — every escript boot printed
  *"Please ensure :exla exists or remove the configuration"*. Now guarded by
  `config_env() != :escript`.
* `escript: [app: :yoke]` made the archive start the application before
  `main/0` could install anything. Removed; `main/0` starts it explicitly.

### 12.4 Golden-file review tests

`test/yoke/golden_review_test.exs` pins the rendered output of the review
sinks over **5 real pull requests**. The fixtures are genuine merge commits
from a sibling checkout (`../muex` by default, or `YOKE_GOLDEN_REPO`), with
base/head SHAs pinned so they stay stable as that repository grows.

Each PR captures two artefacts under `test/support/golden/`:

| File | Contents |
| :--- | :--- |
| `<label>.report.golden` | The rendered step-summary Markdown |
| `<label>.annotations.golden` | The GitHub workflow commands |

Only run UIDs and timestamps are normalised away; everything else — ordering,
wording, escaping, severity→level mapping — must match byte for byte.

```bash
# Run them
mix test test/yoke/golden_review_test.exs

# Regenerate after an intentional change — review the diff before committing
YOKE_UPDATE_GOLDEN=1 mix test test/yoke/golden_review_test.exs
```

The tests **skip rather than fail** when the sibling checkout is absent, so a
fresh clone stays green. To verify they actually catch regressions, tamper with
a `.golden` file and confirm the test fails.

---

## 13. Further reading

* [`CI_PLAN.md`](CI_PLAN.md) — the design record and full roadmap.
* [`ARCHITECTURE.md`](ARCHITECTURE.md) — Brain/Hands/Plugins overview.
* [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures.

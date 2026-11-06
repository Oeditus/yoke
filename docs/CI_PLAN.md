# Yoke in CI — Design & Phased Implementation Plan

> **The MVP: PR reviews done by yoke, running in GitHub Actions.**
> PR review is the first thing we ship and the thing the rest of this plan is sequenced around —
> but it is the *first* of several yoke capabilities going to CI, not the only one.

---

## 0. The MVP: `yoke review` in CI

`yoke review` must become a first-class, headless, CI-native command that reviews a pull
request and posts findings — with **no TTY, no human, no `~/.yoke`, no cloud dependency**.

That is the MVP, and it is what we build first. It is also the **forcing function**: the three
seams it requires (§2) are the same seams every later yoke capability needs to run in CI. So the
MVP is not a throwaway vertical slice — it is the foundation the rest of the roadmap stands on.

**What comes after the MVP** (see §6 for the near-term set):

| Capability | Yoke module it exposes |
| :--- | :--- |
| `yoke lint` — format/credo/dialyzer/deps.audit as one annotated report | `Yoke.Linter`, `Workflow.Steps.Lint` |
| `yoke describe` — one-shot PR summary | `Workflow.Engine.ask_llm/3` |
| `yoke run <workflow>` — headless workflow engine | `Yoke.Workflow.Engine` |
| `yoke audit` — `AIGuard` audit trail as a CI artifact | `Yoke.AIGuard` |
| `yoke rag` — Ragex code intelligence in CI (optional, cached) | `Yoke.MCP.ServerManager` |

Each of these reuses the seams built for the MVP. None of them requires a new architecture.

**Why the MVP is cheap:** yoke already has ~90% of it. `Yoke.PRReview` has the pinned-SHA review
context, the revision-pinned read-only tool catalog, the `<findings>` parser, the diff-line
validator, and the GitHub posting path. `Yoke.Brain.Session.generate_code_review/4` already runs a
review turn. What's missing is **a non-interactive seam** — and that seam is small.

---

## 1. Why in-yoke, not a fork

I initially proposed copying modules into a new `yoke_gate` project and extracting a shared
`yoke_core` package later. That was wrong. Measurement of the actual coupling:

| Module | `Yoke.CLI.*` references | What they actually are |
| :--- | :--- | :--- |
| `Yoke.Brain.Session` | 17 | 2 `Formatter` color calls, 1 `TerminalOwner` block, 1 unused `ContextExpander` alias, **6 `QuestionPrompt` call sites** |
| `Yoke.Hands.Executor` | 17 | All `Formatter` width math + `LineEditor.expand_tool_calls?()` — pure presentation |
| `Yoke.MCP.ServerManager` | 0 | Already gated by `Application.get_env(:yoke, :auto_start_ragex, true)` |

The real work is **6 question sites, 1 terminal block, 2 formatter sites, 2 presentation
modules**. That's days, not a fork.

**Decisive evidence:** `Yoke.CLI.QuestionPrompt.do_ask_single_question/5` already has a headless
branch — `god_mode?()` at line 118 short-circuits to the recommended option with no TTY. Yoke can
be driven non-interactively *today*. The seam exists; it just needs to become a policy hook
instead of a global "approve everything" switch.

**No `yoke_core` package.** Extracting one solves a divergence problem that only exists if you
fork first. Don't fork. Revisit only if CI constraints start distorting REPL design.

---

## 2. The seams to add

Three small seams, all inside yoke.

### 2.1 `Yoke.Interaction` — the blocking seam

```elixir
defmodule Yoke.Interaction do
  @type kind :: :plan_gate | :loop_break | :api_error | :max_depth | :tool_permission
  @type decision :: :approve | :deny | {:answer, String.t()}

  @callback ask(kind(), map()) :: decision()
end
```

Two implementations:

- **`Yoke.Interaction.TTY`** — wraps today's `Spinner.with_paused` + `QuestionPrompt`. Zero
  behaviour change for the REPL.
- **`Yoke.Interaction.Policy`** — reads `.yoke/policy.json` (or env), returns a decision
  immediately. **Never blocks. Never returns `:ask`.** Fail-closed by default.

Selected once at startup (`Application.get_env(:yoke, :interaction, Yoke.Interaction.TTY)`), so
there is no per-call branching.

**Call sites to convert** (all in `Yoke.Brain.Session` unless noted):

| Line | Site | Policy default in CI |
| :--- | :--- | :--- |
| 1234 | `run_agent_loop` max tool depth | `:deny` (stop turn, report partial) |
| 1342 | `prompt_user_on_error` after 3 retries | `:deny` (fail the run) |
| 1504 | `request_plan_approval` (plan gate) | `:approve` if plan-gate disabled, else `:deny` |
| 1533 | `handle_plan_revisions` | `:deny` |
| 1736 | `prompt_user_on_loop` (unyielding loop) | `:deny` (stop, report) |
| 2171 | `confirm_tool_with_user` | `:deny` for destructive bash, `:approve` for read-only |
| `Repl:113` | `review_yes?` (fix application, pattern recording) | `:deny` |

### 2.2 `Yoke.CLI.Output` — the presentation seam

`Formatter`'s color functions return `""` and `display_width` returns a plain byte length when
output is not a TTY. `TerminalOwner.active?()` already returns `false` when nothing is registered,
so the `:subagent_completed` block is a no-op headless — no change needed there.

`Spinner.with_paused(fun)` is already a no-op wrapper when the spinner isn't running. Leave it.

Net effect: **`Yoke.Hands.Executor` needs no changes at all** if `Formatter` degrades cleanly.

### 2.3 `Yoke.Hands.Executor` `:ci` mode — the fourth Hands target

Add `mode: :ci` alongside `:local | :remote | :docker`. Differences from `:local`:

- Emits structured JSON-lines tool logs instead of ANSI (for `$GITHUB_STEP_SUMMARY` + artifacts).
- Enforces a hard wall-clock timeout per tool call.
- Refuses `write_file` / `replace_file` / `bash`-with-write-markers unless policy allows them.
  **A PR review is read-only.** This is a safety property, not a preference.

---

## 3. Architecture

```
┌──────────────────────────── GitHub Actions job ─────────────────────────────┐
│                                                                             │
│  action.yml (composite)                                                     │
│    ├─ erlef/setup-beam (Elixir 1.19 / OTP 27)                               │
│    ├─ cache deps                                                             │
│    ├─ download `yoke` escript (pinned SHA + checksum)                       │
│    └─ yoke review --base <sha> --head <sha> --fail-on high                  │
│                                                                             │
│  ┌────────────────────── yoke (existing app) ──────────────────────────┐    │
│  │                                                                     │    │
│  │  Yoke.CLI.Main  →  dispatch table: review | lint | describe | run   │    │
│  │       │                                                             │    │
│  │       ├─ Yoke.Config.load_ci_config/1   (inputs→env→repo, no ~/.yoke)│   │
│  │       ├─ Yoke.Interaction.Policy        (never blocks)              │   │
│  │       ├─ Yoke.CLI.Output                (non-TTY degradation)       │   │
│  │       │                                                             │    │
│  │       └─ Yoke.Brain.Session.generate_code_review/4                  │   │
│  │             ├─ Yoke.PRReview.Context    (pinned SHAs)               │   │
│  │             ├─ Yoke.PRReview.Tools      (read-only, revision-pinned)│   │
│  │             ├─ Yoke.PRReview.Findings   (<findings> parser)         │   │
│  │             └─ Yoke.PRReview.Context.validate_findings/2            │   │
│  │                                                                     │    │
│  │  Sinks: StepSummary │ Annotations │ Artifact │ (Remote — Phase 3)   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

Note what is **not** in the diagram: no `dllb-server`, no Bumblebee embeddings, no `libgit2`.
`MIX_ENV=escript` already excludes `bumblebee`/`nx`/`exla`/`image` from the escript build, and
`auto_start_ragex` is already configurable. v1 sets it `false`.

---

## 4. Key design decisions

### 4.1 PR review is read-only, and enforced as such
The review turn gets `Yoke.PRReview.Tools`' catalog (`read_file`, `read_files`, `list_dir`,
`grep_search`, `glob_search`, `git_diff`, `git_root`) — already revision-pinned to the reviewed
SHA. The `:ci` Hands mode additionally refuses any write-capable tool at the executor, so a
prompt-injected diff cannot make the runner modify the checkout.

### 4.2 No Ragex in v1
Auto-starting Ragex spawns `dllb-server`, needs `libgit2-dev`, and downloads an embedding model —
~2–4 minutes of CI for marginal value on a diff review. Plain revision-pinned tools only.
Optional `with-ragex: true` input in v1.1, behind a cache key.

### 4.3 Escript, not OTP release
`release.yml` already builds and publishes `yoke` + `yoke.sha256` from `MIX_ENV=escript`. The
Action downloads that artifact. No new build pipeline.

### 4.4 Reuse `gh` where it already works, add a token path where it doesn't
`Yoke.PRReview` currently shells out to `gh` (`detect_pr`, `post_atomic_review`,
`fetch_peer_comments`). In Actions, `gh` is preinstalled and `GITHUB_TOKEN` is in scope — so
**this works today**. Keep it for v1. Add a `Req`-based `Yoke.PRReview.GitHub` client in v1.1 for
GitLab/self-hosted and for when `gh` is absent.

### 4.5 Fail-open on infrastructure, fail-closed on findings
- If the model API fails → the job fails (a review that didn't happen must not look green).
- If the *posting* fails → the job fails.
- If a *later* remote upload fails → the job **still passes**. CI must not go red because a
  dashboard is down. (Phase 3 concern.)

### 4.6 Exit codes are policy
`--fail-on high|medium|low|never`. Default: `high` on `pull_request`, `never` on `push`.
Findings below the threshold are reported but don't gate.

---

## 5. Milestone 1 — MVP: `yoke review` in GitHub Actions

**Definition of done:** a repo adds three lines to a workflow, opens a PR with a real bug, and
gets an inline review comment on the right line with a non-zero exit. No cloud. Under 3 minutes.

### Phase 1.0 — The seams (2–3 days)

- [x] `Yoke.Interaction` behaviour + `Yoke.Interaction.TTY` (wraps existing `QuestionPrompt`).
- [x] `Yoke.Interaction.Policy` + `.yoke/policy.json` schema (`fail_on`, `plan_gate`,
      `allow_writes`, `max_tool_calls`, `max_wall_clock_s`, `max_cost_usd`).
- [x] Convert the 7 call sites in §2.1. **REPL behaviour must be byte-identical** — snapshot-test
      the TTY implementation.
- [x] `Yoke.CLI.Output` — non-TTY degradation for `Formatter` color/width functions.
- [x] `Yoke.Hands.Executor` `:ci` mode (structured logs, per-call timeout, write refusal).
- [x] `Yoke.Config.load_ci_config/1` — action inputs → env → repo `.yoke/config.json`. **Never
      reads or writes `~/.yoke`.**
- [x] `Application.put_env(:yoke, :auto_start_ragex, false)` in CI mode.

**Exit test:** `echo "" | MIX_ENV=prod yoke "hello"` completes with no TTY, no hang, no ANSI in
stdout. Then: `yoke review --base <sha> --head <sha>` against a real PR, `</dev/null`, exits 0.

### Phase 1.1 — `yoke review` command (4–6 days)

- [x] `Yoke.CLI.Main` dispatch table: `review | lint | describe | run | audit | --doctor | --help`.
      Build the full table now (even if only `review` is wired), so later capabilities are
      additive rather than a refactor.
- [x] `yoke review` flags: `--base`, `--head`, `--pr`, `--fail-on`, `--format
      json|markdown|summary`, `--output <path>`, `--post`, `--model`, `--max-cost`.
- [x] Wire `Session.generate_code_review/4` through `Interaction.Policy`.
- [x] **Findings pipeline:** parse → `Context.validate_findings/2` (already rejects off-diff
      anchors) → classify (`issue` / `endorsement`) → severity rank.
- [x] **Sinks:**
  - `Yoke.CI.StepSummary` → `$GITHUB_STEP_SUMMARY` (markdown table of findings)
  - `Yoke.CI.Annotations` → `::error file=...,line=...::` workflow commands
  - `Yoke.CI.Artifact` → `$RUNNER_TEMP/yoke-review.json` (full transcript + findings)
- [x] **Posting:** reuse `PRReview.post_context_review/4` via `gh`. Guard with
      `Context.verify_current/1` so a moved PR head aborts instead of posting stale findings.
- [x] Exit-code mapping from `--fail-on`.

**Exit test:** golden-file tests over 5 real PRs. Byte-identical output on re-run. A PR with a
deliberate bug produces exactly one inline annotation on the correct line.

### Phase 1.2 — The Action (2–3 days)

- [x] `action.yml` (composite): setup-beam, cache, download escript by pinned SHA + checksum, run.
- [x] Inputs: `command`, `base`, `head`, `pr`, `model`, `endpoint`, `fail-on`, `config-path`,
      `post`, `with-ragex`, `upload`, `api-url`, `api-key`.
- [x] Outputs: `findings-count`, `max-severity`, `run-uid`, `report-path`.
- [x] `scripts/install.sh` — curl + checksum verify, no `sudo`.
- [x] Dogfood: run `yoke review` on this repo's own PRs, in this repo's own CI.

**Exit test:** install in a scratch repo, open a buggy PR, confirm annotation + summary +
non-zero exit. Then confirm a clean PR passes.

### Phase 1.3 — Hardening (3–4 days)

- [x] Budgets, all fail-closed: max tool calls, wall clock, tokens, USD.
- [x] `AIGuard` in `:enforce` for anything written to the artifact sink.
- [x] SIGTERM handler flushes the artifact sink before exit.
- [x] Diff-size cap (yoke's existing 300 KB limit is a good default).
- [x] CI matrix: Elixir 1.19/1.20 × OTP 27/29, `mix quality.ci`, `</dev/null` smoke test.
- [x] `docs/CI.md` — copy-pasteable workflows for PR review, push review, and scheduled review.

**Milestone 1 total: ~2–3 weeks.** Shippable, useful, zero backend.

---

## 6. Milestone 2 — The rest of yoke in CI (~2–3 weeks)

Begins once `yoke review` is solid. These are not optional extras — they are the next tranche of
capabilities going to CI, and each reuses the seams from §2. Ship them one at a time, each behind
its own subcommand, each independently useful.

- [ ] `yoke lint` — wrap `mix format --check-formatted`, `mix credo`, `mix dialyzer`,
      `mix deps.audit` into one annotated report (ports `Yoke.Linter` + `Workflow.Steps.Lint`).
- [ ] `yoke describe` — one-shot PR summary (ports `Workflow.Engine.ask_llm/3`).
- [ ] `yoke run <workflow>` — headless `Yoke.Workflow.Engine`. `task_split` degrades to
      single-task (CI has one checkout, no worktrees).
- [ ] `yoke audit` — emit `Yoke.AIGuard`'s audit trail as a CI artifact and step summary, so every
      LLM call and tool execution in a run is reviewable after the fact.
- [ ] `yoke rag` — optional Ragex code intelligence in CI, cached and explicitly opted into
      (this is the `with-ragex: true` path deferred from §4.2).

Each subcommand shares the same `Interaction.Policy`, `CLI.Output`, `:ci` Hands mode, and sink
implementations. The marginal cost of each is small; the marginal value compounds.

---

## 7. Milestone 3 — Phoenix counterpart (paid)

**Worth building once `yoke review` has real users.** The cloud is a *sink* for what the
runner already produces — it must never become a dependency.

The one feature that genuinely requires a backend: **baseline suppression**. The cloud remembers
every finding ever seen on a branch; the runner reports only *new* ones. That turns a noisy
reviewer into a signal generator, and it is what people will pay for.

### Phase 3.0 — Skeleton (3–4 days)
Umbrella `yoke_web`, Postgres + Ecto, deploy to Fly.io. Reuses the `yoke` escript as-is; the
Phoenix app does **not** link yoke's Elixir code — the contract is JSON over HTTP.

### Phase 3.1 — Identity & tenancy (4–5 days)
`mix phx.gen.auth`; `users`, `organizations`, `memberships`, `api_keys` (Argon2-hashed, shown
once). Every Ecto query scoped by `org_id`. Multi-tenancy is a security boundary — test
adversarially.

### Phase 3.2 — Ingestion API (5–6 days)
- `POST /v1/runs` — `run_uid` (UUIDv7, idempotent upsert), repo, SHAs, findings, metrics.
- `GET /v1/baselines?repo=&branch=` — previously-seen findings for suppression.
- `GET /v1/policy` — org policy, falling back to the repo file.
- `Oban` ingestion worker, `hammer` rate limiting, quota checks.

### Phase 3.3 — Dashboard (6–8 days)
LiveView: org switcher, run list, run detail, findings trends, policy editor, API key management.

### Phase 3.4 — GitHub App (4–5 days)
Installation flow, short-lived tokens, webhook receiver for orgs that want cloud-side runs.

### Phase 3.5 — Billing (5–6 days)
`plans`, `subscriptions`, `usage_events` (add schemas in 3.1). Stripe Checkout + Portal +
webhooks. Entitlement checks. Dunning with read-only grace, never data deletion.

### Phase 3.6 — Operations (3–4 days)
Retention cron, backups + restore drill, OpenTelemetry, status page, privacy policy + DPA
(we'd be storing customers' source diffs).

---

## 8. Risks

| Risk | Mitigation |
| :--- | :--- |
| Review quality too noisy to gate on. | Ship `--fail-on never` as the default for the first release; let users opt into gating after they've seen the output. |
| CI runtime. | No Ragex in v1; escript is already lean; 300 KB diff cap; `deepseek-flash` not reasoner. |
| Prompt injection from a malicious diff. | Read-only tool catalog + `:ci` write refusal + `AIGuard` enforce. The review turn already gets a system prompt treating diffs as untrusted evidence. |
| Secrets in uploaded artifacts. | `AIGuard` enforce-mode redaction. Transcripts opt-in and truncated. |
| LLM cost per PR. | Hard token/USD budgets in `Policy`, fail-closed. |
| Fork temptation if CI distorts REPL design. | Don't fork preemptively. If it happens, the seams in §2 are already the extraction boundary. |

---

## 9. Immediate next steps

1. **Spike (½ day):** set `god_mode: true` + `auto_start_ragex: false`, run
   `yoke review <pr>` with `</dev/null`. Confirm it completes without hanging. This validates the
   entire premise before any code is written.
2. **Spike (½ day):** confirm `MIX_ENV=escript mix escript.build` produces a binary that runs
   `review` on a bare `ubuntu-latest` with only `erlef/setup-beam`.
3. Then Phase 1.0 → 1.1 → 1.2 in order. **Each phase ends with `yoke review` working headlessly
   against a real PR** — no phase is "infrastructure only".
4. After the MVP ships, pick Milestone 2 commands by demand (§6), not in the order listed.

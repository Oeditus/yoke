# Yoke as a Service — Product & Architecture Plan

> **The thesis: every AI code reviewer on the market is a generator. Yoke becomes a learner.**
> The paid product is not "more findings". It is *fewer, and they are the ones your team
> actually fixes*. This document is the design record for that product; [`CI_PLAN.md`](CI_PLAN.md)
> is the record for getting `yoke` itself into CI, which is the prerequisite.

**Status:** sketch. No code written. Phase 0 exists to falsify the thesis cheaply before any
backend is built.

---

## 0. The asset inventory

What already exists in this repository, and why each piece is commercially load-bearing.

| Capability | Where | Why it matters commercially |
| :--- | :--- | :--- |
| Headless `yoke review` with pinned base/head SHAs | `Yoke.CI.Review`, `Yoke.PRReview.Context` | Reviews are reproducible and auditable — you can prove what was reviewed |
| Revision-pinned read-only tool catalog and `:ci` Hands write refusal | `Yoke.PRReview.Tools`, `Yoke.Hands.Executor` | A prompt-injected diff cannot make the runner write. The hardest thing to retrofit in a review product |
| Schema-validated findings with off-diff anchor rejection | `Yoke.PRReview.Findings`, `Context.validate_findings/2` | No hallucinated line numbers. Most competitors post comments onto lines that do not exist |
| Endorsements separated from issues | `PRReview.endorsement?/1`, `Yoke.CI.Findings` | Praise never gates a build. Nobody else models this |
| Fail-closed budgets (calls, wall clock, tokens, USD) | `Yoke.CI.Budget` | You can price a review *before* you sell one |
| Four sinks: step summary, annotations, artifact, PR review | `Yoke.CI.{StepSummary,Annotations,Artifact}`, `PRReview.post_context_review/4` | Distribution is already multi-channel |
| Living pattern memory | `Yoke.PRReview.Patterns` (`.yoke/review_patterns.md`, `Seen: 3+` promotes to a mandatory check) | The seed of the moat. Currently per-repo and file-based |
| Episodic error→fix memory, UCB1 model bandit, critic, skill synthesis | `Yoke.SelfImprove.{Episodes,Telemetry,Router,Critic,SkillSynthesizer}` | This is a *learning* review product, not a prompt wrapper |
| Telemetry with `undone` and `user_corrected` fields | `Yoke.SelfImprove.Telemetry` | The labelling primitive for "was this comment right?" |
| AI Guard with audit trail | `Yoke.AIGuard`, `yoke audit` | The enterprise answer to "what did the AI do on our code" |
| Six CI subcommands sharing one flag contract | `docs/CI_PLAN.md` §6 | The surface is already wider than "PR review" |
| MIT plus a restriction to DeepSeek and open models | `LICENSE`, `Provider.validate_license_restrictions!/2` | Constrains the business model — see §2 |

**What does not exist:** any way to learn whether a posted comment was *right*. That is the whole
gap, and it is the entire product.

---

## 1. The thesis

Every AI code review product on the market is a **generator**. It produces comments and hopes.
The comments are noisy, and the noise is invisible to the vendor because the signal — did the
developer fix it, dismiss it, or resolve it as "won't fix"? — lives in GitHub and never comes back.

Yoke is unusually well positioned to be a **learning reviewer**, because the primitives for
learning already exist here and are simply not wired to the review path:

- `Patterns.record_finding/3` already increments `Seen` counts.
- `Seen >= 3` already promotes a pattern to a mandatory check.
- `Telemetry` already carries `undone` and `user_corrected`.
- `Episodes` already captures error→fix transitions.

The paid product is: **close the loop from GitHub reaction back into the pattern store, per
organisation, and charge for the resulting precision.**

That framing also defuses the largest commercial risk named in `CI_PLAN.md` §8 — *"review quality
too noisy to gate on"*. You do not sell gating. You sell the convergence *to* gating.

### 1.1 The headline, stated precisely

> **Yoke remembers every finding it has ever made on your repository, and stops making the ones
> you did not act on.**

One sentence, one mechanism, one thing you can measure and charge for.

Today `Yoke.PRReview.Patterns` does a file-based, per-repo, append-only version of this: `Seen: 3+`
promotes a pattern to a mandatory check. It only ever **grows**; it never learns that a pattern is
*noise* for this team. The paid service makes the loop **bidirectional**:

```
finding posted  ──►  GitHub reaction observed  ──►  per-org verdict  ──►  next review
     ▲                                                                        │
     └──────────────────── suppressed / promoted ◄────────────────────────────┘
```

The commercial consequence: **precision is a number that goes up every week, and the customer can
see it.** That is a defensible story in a market where everyone else's precision is a number
nobody measures.

---

## 2. Decisions taken

These four decisions were settled before this document was written. They constrain everything
below, so they are recorded first.

### 2.1 Licence: strict

`LICENSE` forbids using Yoke as a harness, adapter, or integration layer for OpenAI, Anthropic, or
Google models — directly or through an intermediary. `Provider.validate_license_restrictions!/2`
enforces it for `api.openai.com` and `gpt-*` / `claude-*` / `gemini-*` model names.

**Decision:** the hosted service runs DeepSeek plus open-weight models only. Bring-your-own-key is
limited to open-weight providers.

Consequences to plan around:

1. **"Bring your own Claude key" cannot be a tier.** Expect this to be asked for in the first
   enterprise call; the answer is the self-hosted tier, not a licence exception.
2. **A hosted service is arguably a distribution of the Software**, so the restriction travels with
   it. The hosted reviewer must not be a thin proxy onto a prohibited model.
3. **Legitimate offerings:** DeepSeek (hosted or self-hosted), Qwen and Devstral via vLLM, SGLang,
   or Ollama, and OpenRouter routes to open-weight models. `Yoke.Provider`'s named profiles
   (`local`, `local-qwen`, `deepseek`) already cover this surface.

### 2.2 First customer: small teams, self-serve

Teams of 2–20 developers on GitHub. Stripe checkout, no sales calls, no security questionnaire.

This means: **no dashboard before the loop works**, no SSO in v1, and no on-prem box before ten
paying customers.

### 2.3 Execution: both, runner-based first

Cloud runners for the self-serve tier; the customer's own GitHub Actions runner for
enterprise and on-prem. The runner tier ships first because it costs nothing to operate and
sidesteps the "send us your source" objection entirely.

### 2.4 Headline value: precision over time

Baseline suppression plus learned per-org patterns, so noise converges toward zero. This is the
one claim on the marketing page; coverage and remediation are supporting features, not the pitch.

---

## 3. Architecture: the cloud is a sink, never a dependency

This is the most important architectural rule in the document, and `CI_PLAN.md` §4.5 already states
it. Keep it absolute.

```
┌──────────── GitHub Actions runner (customer pays compute) ────────────────┐
│                                                                           │
│  Oeditus/yoke@v1                                                          │
│    ├─ yoke review --base <sha> --head <sha> --post --fail-on <level>      │
│    │     ├─ Yoke.PRReview.Context      (pinned SHAs)                      │
│    │     ├─ Yoke.PRReview.Tools        (read-only, revision-pinned)       │
│    │     ├─ Yoke.PRReview.Findings     (schema + off-diff rejection)      │
│    │     └─ Yoke.CI.{StepSummary,Annotations,Artifact}                    │
│    │                                                                      │
│    └─ yoke report --upload  ─────────────────────────────┐                │
│                                                          │                │
└──────────────────────────────────────────────────────────┼────────────────┘
                                                           │  HTTPS, JSON
                                                           ▼
┌──────────────────────── Yoke Cloud (Phoenix) ─────────────────────────────┐
│  POST /v1/runs            idempotent by run_uid (UUIDv7)                  │
│  GET  /v1/baselines       previously-seen findings for (repo, branch)     │
│  GET  /v1/policies        org policy, falling back to .yoke/policy.json   │
│  POST /v1/feedback        reactions, resolutions, dismissals              │
│  GET  /v1/patterns        learned patterns, injected into the review      │
└───────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Hard rules

1. **Every cloud call is optional and fail-open.** If the cloud is unreachable, the review still
   runs, still posts, still gates. `CI_PLAN.md` §4.5 already says this; enforce it with a test that
   points the client at a dead port and asserts exit code `0` or `1`, never `3`.
2. **The cloud never holds a model credential on the runner's behalf in the runner tier.** The
   customer's `DEEPSEEK_API_KEY` stays in their secrets. The cloud sees results only.
3. **The cloud never sees the diff in the runner tier.** It sees findings, identities, and metrics.
   That is a materially easier security review than "send us your source", and it is the strongest
   enterprise argument available.
4. **`~/.yoke` is never read or written in CI.** Already true via `Yoke.Config.CI`; keep it true.
5. **No feature may weaken the read-only review guarantee.** `:ci` Hands refuses every
   shell-executing and write-capable tool, and `Yoke.PRReview.Tools` is pinned to the reviewed Git
   objects. Any feature that needs to write runs through `Context.verify_fix_checkout/2` and an
   explicit approval, never through the review turn.

The practical consequence: **the runner tier is shippable with no backend at all.** The first
version of the loop can be a `POST` to one endpoint running on a laptop.

---

## 4. The feedback loop

### 4.1 Reaction signals, ranked by reliability

> **Corrected after measurement.** The original ranking put line movement first, on the grounds
> that it needs no human action. Measuring this repository showed that was wrong: line movement
> scored 14.3% while a review-fix commit signal scored 92.9% on the same 14 findings. A fix can
> address a finding without moving the anchored line, so the cheap signal is the *weakest* one,
> not the primary one. See §8 Phase 0.

| Signal | Source | Reliability | Interpretation |
| :--- | :--- | :--- | :--- |
| **`suggestion` block accepted** | GitHub suggestion-commit events | Highest — an explicit machine-readable yes | Unambiguously right |
| **Code-review fix commit** | A commit inside the PR whose subject marks it as a review fix (`CR by ...`) and which touches the finding's file | High, but file-level | A human read the comment and changed that file |
| **Comment resolved or dismissed** | GitHub review-thread `isResolved` (GraphQL) | High | Resolved without a change means probably noise; resolved with a change means right |
| **Reaction (thumbs up / down)** | Review comment reactions | Medium — sparse | Explicit but rare |
| **Line changed in a later commit** | `git diff` from the reviewed head to the new head, restricted to the finding's `{file, line}` | Low on its own — cheap, but under-counts badly | The line moved; the comment may or may not have caused it |
| **PR merged with the line untouched** | Merge event plus diff | Medium | Weak negative; could mean "we will fix later" |

`Yoke.PRReview.Queue` already speaks GraphQL through `gh` and already models review state, so the
query surface exists. The line-changed signal needs no new API at all, which is exactly why it was
over-trusted: it was the only one available before the App.
### 4.2 The learning rule: deliberately dumb at first

Do **not** start with a bandit. `Yoke.SelfImprove.Telemetry.bandit_scores/2` exists and is
tempting, but a review comment is not an arm you can pull repeatedly — you get one observation per
PR. Use a simple, explainable score:

```
score(pattern) = (acted_on + 1) / (acted_on + ignored + 2)      # Laplace-smoothed precision
```

Then:

- `score >= 0.6` and `occurrences >= 3` → **promote** to a mandatory check, reusing the existing
  `Seen: 3+` mechanism verbatim.
- `score <= 0.2` and `occurrences >= 5` → **suppress**: still counted in the artifact, never
  posted, never annotated, never gates.
- Otherwise → **observe**: post, but tag it internally so the next round can score it.

The thresholds are policy, not code. Put them in `.yoke/policy.json` beside `fail_on` and
`max_cost_usd`, so a customer can tune them and an enterprise can freeze them. Note the warning in
`docs/CI.md` §2: `Yoke.Interaction.Policy` normalises against an explicit allowlist, so a new key
that is not added to `normalize_value/2` is silently ignored. Any new policy key must be added to
that allowlist and to the contract test.

**Why explainability is a commercial requirement, not a nicety:** the dashboard must be able to say
*"we suppressed 14 findings this week because your team ignored five or more of them previously"*.
A learned model that cannot say that is unsellable to anyone who will ask.

### 4.3 What the customer sees

A per-repo precision trend line, and a list of suppressed patterns with the evidence that
suppressed them. That list is also an editing surface: un-suppress a pattern and it returns on the
next PR. This is the difference between "an AI that ignores things" and "an AI that has learned
your standards".

---

## 5. Product surface, in build order

### 5.1 `yoke report` — the missing subcommand (2–3 days)

There is no way today to get a review result *out* of the runner except as an artifact nobody
downloads. Add:

```
yoke report --upload [--endpoint <url>] [--token <t>] [--artifact <path>]
```

Reads the artifact `Yoke.CI.Artifact` already writes, POSTs it, and exits `0` on success **and** on
network failure (with a warning). This is the entire runner→cloud bridge and it is small.

### 5.2 The precision dashboard (1–2 weeks)

LiveView, four screens:

1. **Runs** — every review with cost, duration, findings, and pinned SHAs.
2. **Precision** — the trend line, per repo and per pattern category. This is the sales asset.
3. **Patterns** — promoted, observed, suppressed, with evidence, editable.
4. **Policy** — the org-level `.yoke/policy.json` editor, with the same validation rules as
   `Yoke.Interaction.Policy`: unknown keys dropped, not propagated.

### 5.4 `yoke fix --from-review` — the executable suggestion list (1 week)

`PRReview.build_fix_prompt/1` already renders findings into an agent prompt, and
`build_pr_comment_body/4` already has a `robot_instructions` mode that embeds it in the PR comment.
The missing piece is a command that reads a review artifact and applies the findings locally:

```bash
yoke fix --from-review --artifact <path> --dry-run   # print the prompt, apply nothing
yoke fix --from-review --artifact <path>             # apply to the working tree
```

This turns comments into a patch. It is the highest-value feature after precision, because it
converts a review comment into saved developer time — the thing a buyer can put in a slide.

It is also the measurement instrument. Phase 0 showed that GitHub's own affordances are too sparse
to rely on: 16 threads, 0 resolved, 2 with reactions. An accepted patch is self-evidently correct
in a way a comment never is, so every `--from-review` run that a developer keeps is an unambiguous
positive signal.

The guard is `Context.verify_fix_checkout/2` — the same one the interactive path uses. The checkout
must be the repository root, at the reviewed head, and clean, and it is re-verified immediately
before the agent is dispatched. Nothing is committed or pushed; the working-tree diff is left for a
human to inspect.
This turns comments into a patch. It is the highest-value paid feature after precision, because it
converts a review comment into saved developer time — the thing a buyer can put in a slide.

Guard it exactly as `Context.verify_fix_checkout/2` already does: clean checkout at the reviewed
head, revalidated after confirmation. Do not weaken that.

### 5.5 On-prem / self-hosted tier (3–4 weeks, later)

The `yoke` escript plus a single-container Phoenix app, no external services. Required because
execution is "both", but build it **after** the self-serve tier has ten paying customers. An
on-prem box built before demand is a maintenance liability.

---

## 6. Pricing

You can price a review before you sell one, because `Yoke.CI.Budget` computes USD from token counts
at configurable per-million prices. Use that.

| Tier | Price | Included | Rationale |
| :--- | ---: | :--- | :--- |
| **Free** | $0 | 1 repo, 50 reviews/month, 7-day dashboard history, no learned patterns | The loop needs data. The runner tier costs you zero compute, so this is cheap |
| **Team** | $29/dev/month, 3-seat minimum | Unlimited repos, full precision dashboard, learned patterns, `yoke fix --emit pr` | Small teams, self-serve, no sales call. Per-seat is what this segment expects |
| **Business** | $79/dev/month | Plus org policy, AI Guard audit retention, SSO, per-repo cost caps | The features large orgs ask for in the security questionnaire |
| **Enterprise** | Custom | On-prem, air-gapped, bring-your-own open-weight models | Only after demand |

Two decisions that matter more than the numbers:

1. **Never charge per review.** Per-review pricing makes customers review less, which starves the
   loop, which destroys the product. Charge per seat and let them review everything.
2. **Model cost is the customer's in the runner tier.** That is a genuine advantage: gross margin on
   the runner tier is approximately 100%, and you can say so honestly.

---

## 7. The moat

Three layers, in increasing order of defensibility:

1. **Safety engineering** (weeks to copy). Read-only pinned tools, `:ci` write refusal, fail-closed
   budgets, off-diff anchor rejection, AI Guard. A competitor can rebuild this in a quarter.
2. **The feedback loop** (months to copy, because it needs *your* customers' data). Precision that
   converges requires volume. A new entrant starts at zero and is noisy for six months.
3. **Per-org learned standards** (years, and it is the customer's own switching cost). Once Yoke
   knows that *this* team cares about Ecto query counts and does not care about module length,
   moving to a competitor means re-teaching it from scratch. This is the same mechanism as
   `Patterns` today, but it becomes genuine lock-in only when it is bidirectional and org-scoped.

The honest caveat: layer 3 works only if the loop actually converges. **Build the measurement
before the moat.** If precision does not improve measurably over 500 reviews across 10 repos, the
thesis is wrong and you should find out in month two, not month nine.

---

## 8. Roadmap
**Measured (2026-11-23, `Oeditus/yoke`, 4 merged PRs with Yoke reviews, 16 findings):**

| Signal set | Precision |
| :--- | ---: |
| Line movement alone (lower bound) | 14.3% |
| Plus review-fix commits | 92.9% |
| Plus thread reactions and resolutions | 93.8% |

The first measurement read 14.3%, which would have killed the thesis. It was wrong. Three commits
inside PR #15 are titled `CR by Robby Ott`, `CRs by Robby Ott`, and `Robby Ott's CR`; together they
fixed 13 of the 14 findings. The one finding they did not touch (`lib/yoke/pr_review/tools.ex`) is
the one scored `:ignored`. Line movement missed all of them because a fix can address a finding
without moving the anchored line: the `Map.new` → `Enum.reduce` fix sits two lines below the anchor
that was commented on.

Thread evidence added 1.4 points on this sample, not the collapse the plan expected. The reason is
visible in the data: across the four reviewed pull requests there are 16 threads, of which **0 were
resolved and 2 carry a reaction**. This repository's reviewers do not use either affordance. The
signal is real — both `THUMBS_UP` reactions were on genuine findings — but it is far too sparse to
carry the measurement on its own.

Four consequences for the design:
The honest conclusion: the thesis is plausible rather than proven. The measurement instrument is now
correct, which is the important part — an instrument that reads 14% when the truth is 94% would have
killed a viable product, and one that reads 94% when the truth is 40% would have sold a bad one.

### Calibration: three findings withdraw themselves

Reading all 16 findings by hand found something no signal could have caught. **Three of them retract
themselves inside their own published text:**

| Finding | Verdict in its own body |
| :--- | :--- |
1. **The review spends tokens reasoning its way to a conclusion and then publishes the reasoning.**
   A comment that says "this is fine; withdrawn" should never have been posted. This is a review
   quality defect, not a measurement one, and it is the single highest-value fix available: it
   removes 19% of all output at no cost to recall.

   **Addressed.** Two changes, because a prompt rule alone is not enforcement:

   * `Yoke.PRReview.prompt_instructions/1` gains self-critique rule 11: if your own reasoning refutes
     a finding, drop it entirely; never publish a finding whose text retracts itself.
   * `Yoke.PRReview.Findings` rejects such a finding at parse time, so it cannot reach the report,
     the annotations, or the PR. The patterns match a retraction as a *conclusion* ("withdrawn." at
     the end, "this is fine", "no action needed"), not the word appearing anywhere in a description —
     a bare `withdrawn` match discarded a legitimate finding about code that retracts something, and
     the test suite caught it.
by roughly 25 points on this sample.

Two consequences, both of which change the roadmap:
The recommendation that follows: fix the withdrawal defect before building the service. It improves
the product and the measurement at the same time, and it is a prompt change rather than an
architectural one.

**Done.** The guard is in place and covered by five tests: three asserting that a self-retracting
finding is rejected, one asserting a legitimate finding is unaffected, and one asserting a finding
*about* a retraction bug is not mistaken for a retraction.
   (§8 of `Yoke.PRReview.prompt_instructions/1`); it is clearly not being applied to the final
   answer, only to the draft.
2. **File-level credit is not good enough to price against.** 68.8% is a plausible number for an AI
   reviewer, but the true figure could still be lower. Any dashboard built on the upper bound would
   be selling a number the product cannot defend.

The recommendation that follows: fix the withdrawal defect before building the service. It improves
the product and the measurement at the same time, and it is a prompt change rather than an
architectural one.
   reliable and should be preferred wherever available.
2. **The upper bound is file-level and therefore generous.** A finding that merely shares a file with
   a real fix is credited. The true number is somewhere between 14% and 93%, and narrowing that band
   needs thread-level resolution data, which is Phase 3's GitHub App.

The honest conclusion: the thesis is plausible rather than proven, and the measurement instrument
needs the App before it can produce a number worth pricing against.
### Phase 1 — The loop, self-hosted (3 weeks)
- [x] Client side of suppression: `Yoke.Cloud.Baseline` fetches the baseline, matches on
      `{file, normalised title}`, and refuses to hide a finding more severe than the entry.
      Wired into `Yoke.CI.Review` with `--no-baseline` as the escape hatch.
- [x] Suppressed findings recorded in the artifact rather than discarded, so hiding is auditable.
- [x] The scoring rule as a pure module (`Yoke.Cloud.Scoring`): Laplace-smoothed precision over
      per-pattern tallies, promote at `>= 3` observations and `>= 0.6`, suppress at `>= 5` and
      `<= 0.2`. Every decision carries the counts that produced it, because a dashboard must be
      able to explain why a finding disappeared.
- [ ] `yoke_cloud` Phoenix app: `runs`, `findings`, `patterns`, `feedback` tables. Postgres + Ecto.
- [ ] `GET /v1/baselines`, `POST /v1/runs`, `POST /v1/feedback` — thin wrappers over `Scoring`.
- [ ] **Exit test:** a suppressed pattern demonstrably stops appearing in the next review of the
      same repo.
- [ ] `mix phx.gen.auth`, orgs, memberships, Argon2-hashed API keys shown once.
- [ ] Stripe Checkout, Portal, and webhooks; entitlement checks; dunning with read-only grace,
      never data deletion.
- [ ] **Exit test:** a stranger can sign up, install the action, and see their own precision trend
      without talking to you.

### Phase 3 — The GitHub App (2 weeks)

- [ ] Installation flow, short-lived tokens, webhook receiver for review-thread resolution and
      reactions.
- [ ] Backfill: on install, walk the last 50 merged PRs and seed the pattern store.
- [ ] **Exit test:** the loop works with zero extra customer configuration.

### Phase 4 — Executable suggestions (2 weeks)

- [x] `yoke fix --from-review --artifact <path>` reads a review artifact, verifies the checkout is the
      clean reviewed commit, and asks the agent to apply the findings. `--dry-run` prints the prompt
      and applies nothing. Implemented in `Yoke.CI.FixFromReview` and wired into `Yoke.CLI.Fix`.
- [x] Reuses `Yoke.PRReview.Context.verify_fix_checkout/2` rather than a parallel guard: two guards
      that can drift apart are worse than one.
- [x] Endorsements excluded from fix candidates, findings ordered worst-first so a truncated turn
      addresses the important ones.
- [ ] A machine-readable `patch` field on findings, so a fix can be offered as a ready-made diff
      rather than requiring a model turn.
- [x] **Exit test:** the checkout guard refuses a dirty tree, a moved head, and an artifact with no
      identity; a clean tree at the reviewed head is accepted. Covered by four tests against a real
      git repository.
### Phase 5 — Enterprise (only on demand)

- [ ] On-prem container, SSO, audit retention, frozen policy.

---

## 9. Risks, ranked by likelihood of killing the project

| Risk | Likelihood | Mitigation |
| :--- | :--- | :--- |
| **The loop does not converge** — precision plateaus and the headline claim is false | Medium-high | Phase 0 exists to falsify this cheaply. Measure before building |
| **The licence restriction loses deals** | High | The decision is strict. Compensate with open-weight model quality — Qwen3-Coder is competitive — and make self-hosting a feature, not a compromise |
| **GitHub does not surface enough feedback cheaply** — reactions are sparse, thread-resolution GraphQL is rate-limited | Medium | The line-changed signal needs no human action and is the most reliable; make it primary, not the fallback |
| **Small teams will not pay $29/dev for a reviewer** | Medium | `yoke fix --emit pr` is what justifies a seat price. A comment is not worth $29; a patch might be |
| **A big vendor ships the same thing** | Medium | They cannot ship per-org learned standards without your data. Compete on the loop, not on the review |
| **Prompt injection from a malicious diff** | Low — already mitigated | `:ci` write refusal plus read-only pinned tools. Do not regress this for any feature |
| **Storing customer source in the cloud tier** | Low in the runner tier, high in the cloud tier | The runner tier stores findings only. The cloud tier needs a DPA, a retention policy, and a restore drill before the first enterprise call |

---

## 10. Five adjacent ideas worth considering

Offered because they are cheap to build on existing primitives, not because all of them are good.

1. **Review-as-a-diff, not review-as-a-comment.** Ship the findings as a *patch* to
   `.yoke/review_patterns.md` and `.yoke/practices/*.lmml` that the customer commits. The review
   then improves the repository's own configuration, and the improvement is version-controlled and
   reviewable. This makes the loop visible in the repository, not only in your dashboard.

2. **A "review your reviewer" mode.** `yoke review --audit-self` re-reviews the previous review's
   findings against the merged code and reports which ones were wrong. Sell it as a trust-building
   feature; it is also your own quality metric.

3. **Team standards extraction.** `Practices.squeeze_practices/3` already walks exemplary projects
   and extracts conventions. Point it at the customer's *own* best-reviewed PRs and generate the
   org's `.yoke/practices/<lang>.lmml` automatically. The review then enforces the team's actual
   standards rather than generic ones. Nearly free to build, and it pairs well with the precision
   loop.

4. **The "why did this get merged" report.** A quarterly PDF from run history: which classes of
   defect reach `main`, which reviewers catch what, which modules are risk hotspots. Pure
   reporting, zero model cost, and it sells to engineering managers rather than developers — a
   different buyer with a bigger budget.

5. **A public precision leaderboard.** Publish your own precision numbers on your own repository,
   monthly, with the raw artifacts. Nobody in this market does it. It is the cheapest credibility
   available, and it forces the loop to stay honest.

---

## 11. Immediate next steps

1. **This week:** write the throwaway script that classifies the last 20 reviews on this repository
   as acted-on or ignored, and compute precision. One number. At 80%, the thesis is already proven
   and you build. At 30%, you have a review-quality problem to fix before you have a business
   problem to solve.
2. **Next:** `yoke report --upload` plus a minimal Phoenix endpoint that stores runs. No dashboard,
   no auth, no billing.
3. **Then:** the baseline endpoint and suppression, tested against this repository. If the second
   review of a PR is quieter than the first, in a way you can explain, you have a product.

Everything else — dashboard, Stripe, GitHub App, on-prem — is execution on a thesis that step 1
either confirms or kills for the price of a day.

---

## 12. Further reading

- [`CI_PLAN.md`](CI_PLAN.md) — how `yoke` got into CI, and the seams this product stands on.
- [`CI.md`](CI.md) — the operator's manual for the CI subcommands, policy document, and sinks.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Brain/Hands/Plugins overview.

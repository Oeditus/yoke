# Yoke (Yoke) — Workflow Engine

The Workflow Engine runs named, customizable, multi-step processes on top of
the ordinary agent loop -- branch, describe, split, execute (in parallel when
possible), require tests + docs, lint, and commit -- with the *entire* run
(every prompt, model response, user confirmation, and command executed)
persisted under `.yoke/workflows/`.

It ships with one built-in workflow, `elixir`, covering the seven steps most
Elixir feature work needs, and is designed so you can define your own from
scratch or by editing a copy of `elixir`.

---

## Quick start

```bash
# See what's available (built-in + anything you've already defined)
/workflow list

# Run the bundled "elixir" workflow for a task
/workflow run elixir Add JWT-based session refresh to the auth module

# Check on a run later (or after a crash / Ctrl+C)
/workflow status
/workflow status elixir-1730000000-ab12cd

# Continue a run that failed or was interrupted
/workflow resume elixir-1730000000-ab12cd

# Give up on a run for good
/workflow abort elixir-1730000000-ab12cd

# Scaffold your own workflow, starting from the elixir template
/workflow init my-team-flow --from elixir
```

The model can also trigger a workflow itself mid-conversation via the
`run_workflow` tool, if you explicitly ask it to ("run the elixir workflow
for this").

---

## The `elixir` workflow, step by step

| # | Step type | What it does |
| :--- | :--- | :--- |
| ① | `branch` | Creates and checks out `yoke/elixir/<run-id>` off the current branch. If the current branch isn't `main`/`master`, it warns and asks for confirmation before branching off it anyway. A detached HEAD or a directory outside a Git repository halts the run with an explicit message naming the SHA (or the missing repository) -- there is no branch to record as the run's origin, so branching is refused rather than guessed. |
| ② | `task_description` | Summarizes your request into a structured Markdown spec (Goal / Requirements / Acceptance Criteria), saved to the run's `task_description.md`. |
| ③ | `task_split` | Asks the model whether the task can be split into 2-5 independent, non-clashing subtasks. If it proposes a split, you're asked to approve it before anything runs in parallel. |
| ④ | `tests_and_docs` | After the task (or each subtask) is implemented, requires tests and documentation updates for the change, then actually runs `mix test` to verify it -- not just trusting the model's claim. |
| ⑤ | *(ambient, not a step)* | Every prompt sent during the run is prefixed with this workflow's `elixir_workflow`-scoped rules (see [Rules](#rules-scope) below), by default nudging toward `oeditus_credo`/`propwise`/`credo` conventions. |
| ⑥ | `lint` | Hard-gates on `mix format --check-formatted` and `mix credo diff <base>` before the workflow may proceed to `commit`, plus a richer non-gating report from `/linter` saved as an artifact. |
| ⑦ | `commit` | Formats, stages everything except `.yoke/` itself, and commits with a comprehensive message drafted from the diff -- the same "please commit" convention Yoke already follows for a manual `/commit`. |

---

## Non-clashing parallel execution

An LLM-proposed "non-clashing" split is a best-effort heuristic, not a
guarantee. So when a split is accepted, each subtask gets its own **git
worktree** on its own branch (`<workflow-branch>/subtask/<id>`) and its own
`Brain.Session` actor rooted at that worktree. Concurrent agent processes can
then never write to the same files on disk, even if the model's split wasn't
perfectly non-overlapping -- filesystem isolation, not just a well-intentioned
plan, is what actually prevents clashes.

Each subtask runs its own tests-and-docs pass *before* being merged back.
Once every subtask finishes, their branches are merged into the workflow
branch one at a time; a merge conflict halts the workflow with the
conflicting worktree left in place for manual resolution (resolve it, commit
the merge, then `/workflow resume <run-id>`) rather than discarding anything.

If the model decides the task shouldn't be split (or you decline the
proposed split), it simply runs as a single task on the workflow's own
branch -- no worktrees involved.

---

## Everything is persisted under `.yoke/workflows/`

```
.yoke/workflows/
  definitions/
    elixir.json              # materialized on first use -- edit freely
    <your-custom-workflow>.json
  runs/
    <workflow>-<timestamp>-<id>/
      workflow.json            # exact step spec this run was started with
      state.json               # status/step/branch checkpoint (resumable)
      transcript.jsonl          # every prompt, response, confirmation, command
      task_description.md       # step ②'s output
      split_plan.json           # step ③'s proposal + accept/reject decision
      subtasks/<id>/             # one per accepted parallel subtask
        branch.txt
        worktree.txt
        result.md
      artifacts/                 # lint_report.txt, etc.
```

`workflow.json` is a frozen snapshot: editing `.yoke/workflows/definitions/elixir.json`
later never changes how an already-started run is interpreted, including on
resume. Like the rest of `.yoke/`, this directory should stay gitignored (Yoke's
own commit step explicitly excludes `.yoke/` from staging as a safety net even
if your `.gitignore` doesn't).

---

## Writing a custom workflow

A workflow definition is a small JSON document:

```json
{
  "name": "my-team-flow",
  "description": "Our team's variant of the elixir workflow.",
  "rules_scope": "my_team_flow",
  "base_branch_prefixes": ["main"],
  "steps": [
    { "type": "branch", "branch_prefix": "yoke/my-team-flow" },
    { "type": "task_description" },
    { "type": "prompt", "template": "Before writing any code for: {{task_description}}, check docs/ADRs/ for a relevant architecture decision record and follow it." },
    { "type": "task_split" },
    { "type": "tests_and_docs" },
    { "type": "lint", "tools": "all" },
    { "type": "commit" }
  ]
}
```

Built-in step types: `branch`, `task_description`, `task_split`,
`tests_and_docs`, `lint`, `commit`. The free-form `prompt` step is the
customization escape hatch -- its `"template"` string is sent as an
instruction to a session on the workflow's branch, with `{{task_description}}`,
`{{branch}}`, `{{workflow}}`, and `{{run_id}}` placeholders interpolated.

Definitions are discovered in priority order:

1. Workspace: `.yoke/workflows/definitions/<name>.json`
2. Global (shared across projects): `~/.yoke/workflows/definitions/<name>.json`
3. Bundled with Yoke (currently just `elixir`), materialized into the
   workspace tier the first time you use it.

Use `/workflow init <name> [--from <template>]` to scaffold a new one from an
existing template (default template: `elixir`) instead of writing the JSON
by hand.

### Rules scope

Set `"rules_scope"` to whatever scope name you like; every prompt the
workflow sends is prefixed with that scope's rules from `.yoke/rules.json`
(see `/rules`). A bundled workflow's `default_rules` are seeded under its
scope the first time it's materialized (skipping any rule whose exact text
is already present, so re-running `/workflow init` from the same template
never piles up duplicates).

---

## Resumability

`state.json` is checkpointed after every step transition, so a crash, a
Ctrl+C, or `/workflow abort` never loses the run:

- `/workflow status [run-id]` reads the persisted state directly off disk --
  no live process required.
- `/workflow resume <run-id>` continues from the last incomplete step, using
  the step spec frozen in that run's own `workflow.json` (not whatever the
  live definition file says now).
- A run marked `aborted` refuses to resume. A run that `failed` can be
  resumed and will simply retry the step it failed on.

Resuming is best-effort for work already *in flight*: like a regular agent
turn, Yoke cannot forcibly interrupt synchronous work that's actively
running -- `/workflow abort` only prevents a *future* resume.

---

## Design notes

- The engine is a plain module, not a `GenServer`: Yoke's actual concurrency
  model is "one thing happens at a time in the interactive TTY, with real
  BEAM concurrency only where it's genuinely needed" (subagents, the task
  engine's tool-call batches). A workflow run is no exception -- it blocks
  the caller synchronously, exactly like a normal agent turn, and its
  genuine parallelism comes from spawning real concurrent `Brain.Session`
  processes for accepted subtasks, not from the engine itself being an
  independently-schedulable process.
- `task_description`, the split proposal, and the commit message are all
  one-shot, tool-free chat completions that never touch any `Brain.Session`'s
  visible message history, so they don't pollute your own conversation's
  context window with plumbing.
- The `lint` step calls `mix format`/`mix credo` directly (for a hard
  pass/fail signal) rather than only `Yoke.Linter.run/2`, which
  always returns `{:ok, output}` even when the underlying tool reports
  issues -- it's designed for interactive `/linter` display, not automated
  gating.

---

## Idea Lifecycle Pipeline Integration

The Workflow Engine seamlessly integrates with the **Idea Lifecycle Pipeline**:

1. **Idea Triage & Sparring:** Capture ideas with `/thought <Title>`, search prior art with `/sweep <tokens>`, and pressure-test designs using `/spar [soc|adv] <topic>`.
2. **Backlog Promotion:** Refine raw thoughts into backlog items using `/promote <slug> [code|initiative] [Must Have|Should Have|Nice to Have]`.
3. **Automated Activation:** When `/workflow run <definition> <slug_or_prompt>` is executed, Yoke automatically matches the task against `project/workflow/backlog/`, promotes it to `project/workflow/active/`, and enriches the workflow context with frontmatter metadata & acceptance criteria.
4. **Close-Out Verification Gate:** When the workflow finishes committing, Yoke automatically moves the active item from `active/` to `completed/`, records a close-out lesson entry in `project/lessons.md`, and regenerates `_MAP.md` and `_DEPS.md` derived index maps.

# Yoke (Yoke) — Development Workflows

Yoke provides versatile agentic workflows for software engineering tasks.

---

## 1. Interactive REPL Mode
Launch the interactive agent REPL:
```bash
yoke
```
- **Slash Commands**: Use `/help`, `/stats`, `/tokens`, `/session`, `/git`, `/diff`, `/review`, `/commit`.
- **Reference Files**: Attach context with `@file.ex`, `@file://path`, or `@https://domain.com/doc`.
- **Multi-line Inputs**: End a line with `\` or open `"""` to type multi-line prompts.

---

## 2. One-Shot Command Execution
Pass a prompt directly on the command line:
```bash
yoke "Refactor lib/auth.ex to use JWT tokens"
```
Flags:
- `--model deepseek-reasoner`: Switch to DeepSeek-R1 reasoning model.
- `--plugin path/to/plugin.exs`: Load custom Elixir tools on startup.

---

## 3. Human-in-the-Loop PR Reviews & Queue Triage
Yoke provides an interactive code review workstation inspired by pair-review workflows:

```bash
# Review open GitHub Pull Request
/review 142

# Compare active branch against main
/review main HEAD
# Or quick shortcut:
/cr

# Manage live PR review queue
/prboard
/review next
/review skip 142
/review patterns
```

### The Review Lifecycle
1. **Queue Triage (`/prboard`)**: Displays live repository PRs categorized by readiness (`re-review`, `new`, `waiting on author`). Skipping a PR pins it to its current commit SHA until new commits land.
2. **Context & Living Patterns**: Reviews diffs against mandatory tripwires (`.yoke/review_patterns.md`) and excludes existing reviewer comments or CI checks.
3. **Interactive Decision Making**: Presents each finding one by one for engineering approval:
   - `[i] Include`: queues comment for atomic submission.
   - `[e] Edit`: opens inline prompt to adjust title, description, or fix suggestion.
   - `[d] Drop`: discards finding.
4. **Atomic GitHub Submission**: Validates right-side diff lines and posts all inline comments and the summary review atomically via `gh api` (`APPROVE`, `COMMENT`, or `REQUEST_CHANGES`).
5. **Memory Loop & Typography**: Accepted findings can be saved to `.yoke/review_patterns.md` to reinforce organizational knowledge over time. Reviews strictly adhere to typographic standards (real em dashes `—` and proper typographic quotes `“ ”` and `‘ ’`).

---

## 4. Spatiotemporal Checkpoints & Undo
Create manual checkpoints before major refactorings:
```bash
/checkpoint Pre-refactor-auth
```
If an automated step introduces issues, roll back instantly:
```bash
/undo
```

---

## 5. Subagent Worker Delegation
Delegate complex or parallel sub-tasks to supervised background subagents:
```bash
/subagent "Research quantum encryption algorithms and summarize in markdown"
```

---

## 6. Customizable Multi-Step Workflows (`/workflow`)
Run a named, customizable, multi-step process on top of the ordinary agent
loop -- branch, describe the task, propose a non-clashing parallel split,
require tests + docs, lint, and commit -- with the entire run persisted
under `.yoke/workflows/`:
```bash
/workflow run elixir Add JWT-based session refresh to the auth module
```
See [`docs/WORKFLOW_ENGINE.md`](WORKFLOW_ENGINE.md) for the full reference,
including how to write your own custom workflow definitions.

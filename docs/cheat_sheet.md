# Yoke (Yoke) — Cheat Sheet & Tactics Guide

A comprehensive quick-reference guide for **Yoke (`yoke`)**, covering CLI flags, REPL slash commands, prompt syntax (`@`, `!`), rule engine scoping, branch code reviews, local transcripts, and execution tactics. For a complete walkthrough of onboarding and customization, see the **[Getting Started Guide](GETTING_STARTED_GUIDE.md)**.

---

## Table of Contents
1. [CLI Invocation & Command Line Flags](#1-cli-invocation--command-line-flags)
2. [Context Expansion (`@`) & Shell Execution (`!`)](#2-context-expansion--and-shell-execution-)
3. [Slash Commands Reference](#3-slash-commands-reference)
4. [Rule Engine & Scoping Tactics (`/rules`)](#4-rule-engine--scoping-tactics-rules)
5. [Code Review & Git Workflow (`/cr`, `/diff`, `/commit`)](#5-code-review--git-workflow-cr-diff-commit)
6. [Session Management & Persistence (`-c`, `/resume`, Transcripts)](#6-session-management--persistence--c-resume-transcripts)
7. [Model Selection Strategy (`/model`)](#7-model-selection-strategy-model)
8. [MCP & Ragex Code Analysis (`/mcp`, `/ragex`)](#8-mcp--ragex-code-analysis-mcp-ragex)
9. [Subagents & Distributed Execution (`/subagent`, `/mode`, `/nodes`)](#9-subagents--distributed-execution-subagent-mode-nodes)
10. [Customizable Workflows (`/workflow`)](#10-customizable-workflows-workflow)
11. [Keyboard Shortcuts & Navigation](#11-keyboard-shortcuts--navigation)

---

## 1. CLI Invocation & Command Line Flags

Launch `yoke` from any directory in interactive REPL mode, one-shot mode, or resume mode:

```bash
# Launch interactive REPL mode (generates new UUID session)
yoke

# Resume specific conversation ID across CLI restarts
yoke -c df97eb34-cb33-4f21-bada-2e9c3cf75d46
yoke --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46

# One-shot mode with inline prompt
yoke "Analyze project architecture in @mix.exs"

# Specify model alias for one-shot execution
yoke -m deepseek-coder "Write a binary search algorithm in @lib/search.ex"
yoke --model deepseek-reasoner "Diagnose race condition in @lib/worker.ex"

# Run in background self-update mode
yoke --update

# Display CLI help menu
yoke --help
```

### Supported Flags & Aliases
| Flag | Short | Description |
| :--- | :--- | :--- |
| `--conversation <id>` | `-c <id>` | Resume a persisted conversation ID |
| `--resume <id>` | `-r <id>` | Alias for `--conversation` |
| `--prompt <str>` | `-p <str>` | Input prompt string for one-shot execution |
| `--model <name>` | `-m <name>` | Select model (`deepseek-chat`, `deepseek-coder`, `deepseek-reasoner`) |
| `--update` | `-u` | Trigger background release update to latest git codebase |
| `--node <name>` | — | Start local Erlang distributed node |
| `--connect <node>`| — | Connect to remote Erlang Hands worker node |
| `--plugin <path>` | — | Load external Elixir plugin script (`.ex` or `.exs`) |

---

## 2. Context Expansion (`@`) & Shell Execution (`!`)

### `@` File & Context Reference Syntax
Type `@` anywhere in user prompts to attach contents:
- **File references**: `@mix.exs`, `@lib/yoke/cli/line_editor.ex`
- **URI references**: `@https://raw.githubusercontent.com/...`
- **Interactive File Picker**: Typing `@` in REPL triggers an interactive fuzzy file picker modal. It respects `.gitignore` rules (`git ls-files`) and strictly excludes `_build/`, `deps/`, `.elixir_ls/`, and `.git/`.

### `!` Shell Command Execution Syntax
Prefix any line with `!` to execute a shell command directly without sending it to DeepSeek:
```
📁 my_app 🤖 deepseek-chat ❯ !git status
📁 my_app 🤖 deepseek-chat ❯ !mix test
📁 my_app 🤖 deepseek-chat ❯ !cargo check
```

### `!!` Pure Console Mode (Flip-Flop)
Type `!!` on its own to flip `yoke` into **pure console mode**: a bare shell passthrough with no Brain/Hands actors, no LLM turns, and no slash-command dispatch in between. Every line you type executes directly via `sh -c`, with output streamed live and `cd` applied to `yoke`'s own working directory (like a real shell builtin). Type `!!` again (or `Ctrl+D`) to flip back into the normal harness REPL, picking up right where you left off -- no need to spawn a second terminal tab just to run a few plain commands:
```
my_app deepseek-chat > !!
Flipped into pure console mode -- plain shell passthrough, no AI/tooling in between. Type !! again to return to Yoke.
console my_app $ cd ..
console Proyectos $ ls
console Proyectos $ !!
Back to Yoke -- pure console mode OFF.
my_app deepseek-chat >
```

---

## 3. Slash Commands Reference

| Slash Command | Description | Example |
| :--- | :--- | :--- |
| `!!` | Flip into/out of pure console mode (plain shell passthrough, no AI/tooling) | `!!` |
| `/review [<base> [head] \| <pr>]` | Human-in-the-loop PR review with inline triage (`[i] Include`, `[e] Edit`, `[d] Drop`) | `/review 142` |
| `/prboard` \| `/review queue` | Live Pull Request review queue board (CI, approvals, status) | `/prboard` |
| `/review next` | Auto-advance and review next queued PR | `/review next` |
| `/review skip <pr>` \| `unskip` | Commit-pinned PR skip (hidden until author pushes new commits) | `/review skip 142` |
| `/review patterns` | View living codebase review patterns (`.yoke/review_patterns.md`) | `/review patterns` |
| `/cr [base]` | Shortcut to review active branch against `main` or custom base | `/cr main` |
| `/diff [target]` | View colorized git diff of workspace or against target branch | `/diff main` |
| `/resume [id]` | Resume specific session ID or open interactive conversation picker modal | `/resume` |
| `/rules [add\|delete]` | List, add, or open checkbox modal to delete prompt rules | `/rules add cr: format tables 80 cols` |
| `/model <alias>` | Switch model (`chat`, `coder`, `reasoner`, `openrouter-r1`, `ollama-r1`) | `/model reasoner` |
| `/mode <target>` | Set execution target (`local`, `docker <id>`, `remote <node>`) | `/mode local` |
| `/compact` | Compress conversation context window to save tokens | `/compact` |
| `/undo` | Roll back conversation state to previous temporal checkpoint | `/undo` |
| `/checkpoint [lbl]` | Create a manual temporal state snapshot | `/checkpoint "Before refactoring"` |
| `/config` | Manage prompt styles (`starship`, `compact`) and UI settings | `/config style starship` |
| `/plugins [reload]` | List tools or hot-reload custom plugins live without resetting state | `/plugins reload` |
| `/mcp [list\|add]` | Mount or inspect Model Context Protocol (MCP) servers | `/mcp list` |
| `/ragex` | Mount Ragex MCP server for AST refactoring & SCIP semantic search | `/ragex` |
| `/skills [name]` | List available skills or execute a skill instruction file | `/skills` |
| `/update` | Refresh production OTP release in background (`yoke --update`) | `/update` |
| `/commit <msg>` | Auto-stage all modified workspace files and create git commit | `/commit "feat: add user login"` |
| `/cost` \| `/tokens` | Display token usage breakdown and cumulative session cost | `/cost` |
| `/permissions` | Set tool execution safety mode (`auto` or `ask`) | `/permissions ask` |
| `/subagent <prompt>` | Spawn a background subagent worker for heavy sub-tasks | `/subagent "Search all TODOs"` |
| `/workflow [cmd]` | Run customizable multi-step workflows: `list\|run\|status\|resume\|abort\|init` | `/workflow run elixir Add dark mode` |
| `/cb` \| `/clipboard` | Copy latest assistant response to system clipboard | `/cb` |
| `/clear` | Clear terminal output screen | `/clear` |
| `/reset` | Reset conversation context, history, checkpoints, and clear screen | `/reset` |
| `/help` | Print REPL help menu | `/help` |
| `/exit` \| `/quit` | Exit Yoke and print conversation resume banner | `/exit` |

### Keyboard Shortcuts & Hotkeys
- **`Ctrl+P`**: Toggle tool execution safety mode (`ask_confirm` ⇄ `auto_approve`)
- **`Ctrl+G`**: Toggle workspace sandbox bounds on/off
- **`Ctrl+B`**: Toggle idle status bar mode (gauge ⇄ compact session line)
- **`Ctrl+O`**: Toggle tool call log expansion mode (collapsed/truncated ⇄ expanded/full text)
- **`Ctrl+Q`**: Interrupt active AI turn while responding

---

## 4. Rule Engine & Scoping Tactics (`/rules`)

The Rule Engine allows defining persistent prompt preambles and formatting constraints saved in `.yoke/rules.json`.

### Rule Scope Syntax
- `all: <text>` — Injected into system preamble for **every** prompt turn.
- `<command>: <text>` — Injected **only** when that specific command is executed.

### Pre-seeded Default Rules
1. `all: typographic quotes “” mean the exact quote`
2. `all: backticks mean a code quote`
3. `cr: format table cells multiline to fit in 80 symbols width`

### Rule Commands
- **List Rules**: `/rules`
- **Add Rule**: `/rules add all: Always prefer pattern matching over if/else`
- **Add Command Rule**: `/rules add cr: Highlight security vulnerabilities first`
- **Delete Rules (Interactive TUI Modal)**: `/rules delete` or `/rules rm`
  *(Opens a checkbox modal with OK/Cancel buttons to delete selected rules)*
- **Toggle Rule**: `/rules toggle <id>`

---

## 5. Code Review & Git Workflow (`/review`, `/prboard`, `/cr`, `/diff`, `/commit`)

### 1. Human-in-the-Loop PR Code Review (`/review`, `/cr`)
Runs a comprehensive AI code review comparing branches or evaluating a GitHub Pull Request:
```bash
# Review active branch against default base 'main'
/cr
/review main HEAD

# Review specific GitHub PR by number
/review 142

# Inline review help & standards
/review help
```

**Key Review Capabilities**:
- **Granular Triage**: Review findings one by one with `[i] Include`, `[e] Edit` (modify comment inline), or `[d] Drop`.
- **Atomic GitHub Review Posting**: Submits review events (`APPROVE`, `COMMENT`, `REQUEST_CHANGES`) alongside native right-side inline diff comments and committable ` ```suggestion ` blocks via `gh api`.
- **10-Point Self-Critique Checklist**: Discards suggestions if gated by feature flags/supervisors, speculative, bikeshedding, or already flagged by linters/CI.
- **Typographic Standards**: Enforces real em dashes (`—`) for parenthetical clauses/breaks and proper typographic quotes (`“ ”` and `‘ ’`) in prose explanations.

### 2. Live PR Review Queue Board (`/prboard`, `/review queue`)
Manage and triage your repository's open pull requests without switching contexts:
```bash
# Open live review queue board
/prboard
/review queue

# Step through the queue automatically
/review next

# Commit-pinned skip (hides PR until author pushes new commits)
/review skip 142
/review unskip 142
```
Categorizes open PRs into **Visible** (ranked by readiness: `re-review` > `new`) and **Hidden** (`draft`, `yours`, `approved`, `waiting on author`, `skipped`).

### 3. Living Codebase Review Memory (`/review patterns`)
Maintains an evolving codebase memory in `.yoke/review_patterns.md`:
```bash
# View active review patterns and tripwires
/review patterns
```
- Real accepted comments are recorded to `.yoke/review_patterns.md` after each review.
- Patterns with `[Seen: 3+]` are automatically enforced as **mandatory tripwire checks** on future reviews.

### 4. Workspace & Branch Diffing (`/diff`)
```bash
# View colorized diff of unstaged/staged workspace changes
/diff

# View colorized diff against target branch or commit
/diff main
/diff origin/main
```

### 3. Auto-Commit (`/commit`)
Stages all workspace modifications and creates a git commit:
```bash
/commit "fix(cli): resolve terminal cursor offset on emoji rendering"
```

---

## 6. Session Management & Persistence (`-c`, `/resume`, Transcripts)

### Session State Persistence
All REPL and one-shot sessions automatically save their GenServer state, snapshots, and conversation messages to `.yoke/sessions/<session_id>.lmml` -- an `lmml` narrative (a Markdown-superset markup for LLM conversations). The file is plain, self-contained Markdown that any Markdown viewer renders sensibly, yet round-trips every structured message losslessly through its inline-embed model. Legacy `.json` session files from earlier versions are still read transparently on resume.

### Exit Resume Banner
Upon exit via `/exit`, `/quit`, or `Ctrl+D`, `yoke` prints your exact conversation UUID:
```
Resume with -c (or command below):
yoke --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46
```

### Local Transcripts Log Files
Every session maintains dual JSONL transcript logs in `.yoke/sessions/<session_id>/`:
- `transcript_full.jsonl`: Complete, untruncated step-by-step logs of all user prompts, tool calls, and model responses.
- `transcript_compact.jsonl`: Token-efficient version with large binary/text outputs truncated for rapid grepping.

### Ambiguous Context Expansion & Issue Tracking
`yoke` automatically detects ambiguous context references in prompts (such as *"error above"*, *"the build failure"*, or `@error`):
- Resolves previous tool execution tracebacks from session history.
- Maintains an internal Issue Tracker categorizing issues as `:open` or `:resolved`.
- Automatically marks issues as `:resolved` when subsequent tool calls succeed.

---

## 7. Model & Endpoint Selection Strategy (`/model`, `/endpoint`)

Switch model architectures or LLM providers on the fly during a session:

```bash
/model chat       # Switch to DeepSeek-V3 (Default agentic model)
/model coder      # Switch to DeepSeek-Coder-V2.5 (Idiomatic code writing)
/model reasoner   # Switch to DeepSeek-R1 (Deep chain-of-thought debugging)

# OpenRouter & Local Model shortcuts
/endpoint openrouter    # Switch endpoint to OpenRouter API
/model openrouter-free  # Switch to meta-llama/llama-3.3-70b-instruct:free

/endpoint ollama        # Switch endpoint to local Ollama (http://localhost:11434)
/model ollama-qwen      # Switch to local qwen2.5-coder:14b
```

| Scenario | Recommended Model / Provider | Rationale |
| :--- | :--- | :--- |
| **Multi-turn file editing & bash commands** | `deepseek-chat` | Highest tool call precision and execution reliability |
| **Writing complex algorithms & tests** | `deepseek-coder` | Trained on 338+ languages; idiomatic syntax generation |
| **Diagnosing stack traces & deadlocks** | `deepseek-reasoner` | Streams live `[DeepSeek-R1 Reasoning]` thoughts before execution |
| **Open-source & Free AI Models** | OpenRouter (`/endpoint openrouter`) | Free tier access to Llama 3.3, Qwen 2.5 Coder, Gemini 2.0 |
| **Offline & Air-gapped Execution** | Local Ollama / LM Studio (`/endpoint ollama`) | Complete privacy, offline tool execution without API key requirements |

---

## 8. MCP & Ragex Code Analysis (`/mcp`, `/ragex`)

### Model Context Protocol (MCP) Management
```bash
# List all connected MCP servers and tools
/mcp list

# Connect a stdio MCP server
/mcp add sqlite npx -y @modelcontextprotocol/server-sqlite --db-path ./app.db
```

### Native Ragex Integration (`/ragex`)
Mounts the **Ragex** code analysis MCP server targeting the workspace:
- SCIP Code Indexing & Graph Queries
- AST Pattern Searching (`metaast_search`)
- Refactoring Effort Estimation & Security Auditing
- Graph Stats (`/ragex stats`)

---

## 9. Subagents & Distributed Execution (`/subagent`, `/mode`, `/nodes`)

### Background Subagents (`/subagent`)
Delegate non-blocking sub-tasks to concurrent subagent processes running in separate BEAM GenServers:
```bash
/subagent "Analyze all TODO comments across lib/ and generate a report"
```

### Execution Target Modes (`/mode`)
Control where Hands tools execute:
```bash
/mode local                # Local host filesystem (Default)
/mode docker container_id  # Execute bash/tools inside running Docker container
/mode remote hands@host    # Execute tools on remote Erlang node
```

---

## 10. Customizable Workflows (`/workflow`)

Runs a named, customizable, multi-step process on top of the ordinary agent
loop -- branch, describe the task, propose a non-clashing parallel split,
require tests + docs, lint, and commit -- with the entire run persisted under
`.yoke/workflows/`. Full reference: [`docs/WORKFLOW_ENGINE.md`](WORKFLOW_ENGINE.md).

```bash
/workflow list                          # discover built-in + custom workflows
/workflow run elixir Add dark mode      # run the bundled "elixir" workflow
/workflow status [run-id]               # inspect a run (works even after a crash)
/workflow resume <run-id>               # continue a failed/interrupted run
/workflow abort <run-id>                # mark a run as aborted
/workflow init <name> [--from <tmpl>]   # scaffold a custom workflow definition
```

Parallel subtasks each get their own git worktree and branch, so concurrent
agent processes can never clash on disk even if the model's proposed split
wasn't perfectly non-overlapping.

---

## 11. Keyboard Shortcuts & Navigation

| Key Combination | Action |
| :--- | :--- |
| `Tab` | Trigger slash-command or path autocomplete |
| `Ctrl+R` | Reverse history search (type query to search past inputs) |
| `Up Arrow` / `Down Arrow` | Navigate input history (or navigate options in TUI modals) |
| `Left Arrow` / `Right Arrow` | Move cursor left/right (or accept ghost auto-suggestion) |
| `Home` / `Ctrl+A` | Jump cursor to line start |
| `End` / `Ctrl+E` | Jump cursor to line end |
| `Ctrl+U` | Clear text from cursor to start of line |
| `Ctrl+K` | Clear text from cursor to end of line |
| `Ctrl+W` | Delete word backward |
| `Spacebar` | Toggle checkbox option in TUI Question Modals |
| `Enter` | Submit input / confirm modal selection |
| `Ctrl+C` | Cancel line input |
| `Ctrl+D` | Signal EOF and exit `yoke` |

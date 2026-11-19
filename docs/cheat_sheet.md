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
7. [Model, Provider & Endpoint Selection (`/model`, `/provider`, `/endpoint`)](#7-model-provider--endpoint-selection-model-provider-endpoint)
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

# Explicit generation providers (independent of Hands /mode)
yoke --provider local
yoke --provider local-qwen
yoke --provider deepseek

# Resume specific conversation ID across CLI restarts
yoke -c df97eb34-cb33-4f21-bada-2e9c3cf75d46
yoke --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46

# One-shot mode with inline prompt
yoke "Analyze project architecture in @mix.exs"

# Specify model alias for one-shot execution
yoke -m deepseek-coder "Write a binary search algorithm in @lib/search.ex"
yoke --model deepseek-reasoner "Diagnose race condition in @lib/worker.ex"

# Custom endpoint (OpenRouter, Ollama, LM Studio, vLLM, or any OpenAI-compatible URL)
yoke -e ollama -m qwen2.5-coder:14b

# Print the runtime diagnostic report
yoke --doctor

# Update in the foreground and report the pull/build result
yoke --update

# Replay the last terminal command, analyse the failure, and plan a fix
yoke fix
yoke fix --apply
yoke fix --no-run "mix test test/foo_test.exs:42"

# Display CLI help menu
yoke --help
```

### Supported Flags & Aliases
| Flag | Short | Description |
| :--- | :--- | :--- |
| `--conversation <id>` | `-c <id>` | Resume a persisted conversation ID |
| `--resume <id>` | `-r <id>` | Alias for `--conversation` |
| `--prompt <str>` | `-p <str>` | Input prompt string for one-shot execution |
| `--model <name>` | `-m <name>` | Select model (`deepseek-flash`, `deepseek-v4-pro`, `deepseek-coder`, `deepseek-reasoner`, `deepseek-v4-flash-vision-exp`) |
| `--provider <name>` | — | Select model and endpoint together: `local` (Devstral), `local-qwen`, `deepseek` |
| `--endpoint <url>` | `-e <url>` | Custom chat-completions endpoint URL |
| `--languages <list>` | `-l <list>` | Explicitly set project languages instead of auto-detecting |
| `--update` | `-u` | Update the release in the foreground and report its actual result |
| `--doctor` | `-d` | Print the runtime diagnostic report |
| `--node <name>` | — | Start local Erlang distributed node |
| `--connect <node>`| — | Connect to remote Erlang Hands worker node |
| `--plugin <path>` | — | Load external Elixir plugin script (`.ex` or `.exs`) |
| `--help` | `-h` | Display CLI help |

### CLI Subcommands
| Subcommand | Description |
| :--- | :--- |
| `yoke review` | CI code review of a branch range or PR (`--base`, `--head`, `--pr`, `--fail-on`, `--post`, `--dry-run`) |
| `yoke lint` | Run the project's linters in CI mode |
| `yoke describe` | Summarize the change set in one model call |
| `yoke run <workflow> "<task>"` | Run a named workflow end-to-end (`--list`, `--prompt`) |
| `yoke audit` | Emit the AI Guard audit trail as a CI artifact |
| `yoke fix [options] ["<command>"]` | Replay the last terminal command, analyse the failure, and plan a fix |
| `yoke rag` | Build or inspect Ragex code intelligence (`--index`, `--status`) |
| `yoke update` | Check GitHub Releases for updates and install |

`yoke fix` options: `-n/--no-run` (plan only), `-a/--apply` (let the agent fix it), `--plan-only` (print triage and prompt, then stop), `-p/--previous` (use the command before the last one), `--command <cmd>`, `--history-file <path>`, `--timeout <ms>`, `--agent-timeout <ms>`, `--session <id>`. Exit codes: `0` succeeded, `1` failed and a plan was produced, `2` usage error, `3` no command found in history.

---

## 2. Context Expansion (`@`) & Shell Execution (`!`)

### `@` File & Context Reference Syntax
Type `@` anywhere in user prompts to attach contents:
- **File references**: `@mix.exs`, `@lib/yoke/cli/line_editor.ex`, `@file://path/to/file`
- **URI references**: `@https://raw.githubusercontent.com/...`
- **Ambiguous error references**: `@error` or `"error above"` attaches the recent tool/build traceback from session history.
- **Interactive File Picker**: Typing `@` in REPL triggers an interactive fuzzy file picker modal. It respects `.gitignore` rules (`git ls-files`) and strictly excludes `_build/`, `deps/`, `.elixir_ls/`, and `.git/`.

### `!` Shell Command Execution Syntax
Prefix any line with `!` to execute a shell command directly without sending it to the model:
```
📁 my_app ● deepseek-flash ❯ !git status
📁 my_app ● deepseek-flash ❯ !mix test
📁 my_app ● deepseek-flash ❯ !cargo check
```
Use `/bash stats` to review tracked shell-call analytics afterwards.

### `!!` Pure Console Mode (Flip-Flop)
Type `!!` on its own to flip `yoke` into **pure console mode**: a bare shell passthrough with no Brain/Hands actors, no LLM turns, and no slash-command dispatch in between. Every line you type executes directly via `sh -c`, with output streamed live and `cd` applied to `yoke`'s own working directory (like a real shell builtin). Type `!!` again (or `Ctrl+D`) to flip back into the normal harness REPL, picking up right where you left off -- no need to spawn a second terminal tab just to run a few plain commands:
```
my_app deepseek-flash > !!
Flipped into pure console mode -- plain shell passthrough, no AI/tooling in between. Type !! again to return to Yoke.
console my_app $ cd ..
console Proyectos $ ls
console Proyectos $ !!
Back to Yoke -- pure console mode OFF.
my_app deepseek-flash >
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
| `/model <alias>` | Switch model (`flash`, `pro`, `coder`, `reasoner`, `vision`, …); no argument lists endpoint models | `/model reasoner` |
| `/provider [name]` | Show transport or atomically select `local`, `local-qwen`, or `deepseek` | `/provider local` |
| `/endpoint [url\|shortcut]` | Set the generation endpoint (`default`, `deepseek`, `openrouter`, `opencode`, `ollama`, `lmstudio`, `vllm`, or a URL) | `/endpoint ollama` |
| `/sandbox [on\|off]` | Restrict file references and tools to the workspace directory | `/sandbox on` |
| `/mode <target>` | Set execution target (`local`, `docker <id>`, `remote <node>`) | `/mode local` |
| `/compact` | Compress context and show token estimates before/after and percentage change | `/compact` |
| `/undo` | Restore and identify the latest conversation checkpoint (not working-tree files) | `/undo` |
| `/checkpoint` | List checkpoint IDs, labels, and turns without creating one | `/checkpoint` |
| `/checkpoint <label>` | Save a labeled conversation snapshot | `/checkpoint Before refactoring` |
| `/config` | Manage prompt styles (`starship`, `extended`, `compact`, `minimal`), custom prompt templates, and UI toggles | `/config style starship` |
| `/explorer` | Interactive TUI for exploring & managing config, rules, skills, jobs, and analytics | `/explorer` |
| `/plugins [reload]` | List tools or hot-reload custom plugins live without resetting state | `/plugins reload` |
| `/mcp [list\|add\|load]` | Mount, load, or inspect Model Context Protocol (MCP) servers | `/mcp list` |
| `/ragex [stats\|audit\|quality\|reindex\|help]` | Mount Ragex MCP server for AST refactoring & SCIP semantic search; `export <mermaid\|dot\|d3>` dumps the graph | `/ragex stats` |
| `/skills [show\|path\|edit\|new\|<name>]` | List, inspect, scaffold, or execute a skill instruction file (alias: `/skill`) | `/skills` |
| `/practices [add\|delete\|learn\|edit]` | View, teach, or edit language-specific good practices in `.yoke/practices/<lang>.lmml` | `/practices learn ../exemplar` |
| `/update` | Refresh the production release in the foreground and report success/failure | `/update` |
| `/alias [list\|show\|add\|rm\|run]` | Manage and run reusable session command aliases (or `/<alias>`) | `/alias list` |
| `/finish [files] [--commit-only]` | Complete work: format, structured commit (5 sections) & create PR | `/finish lib/app.ex` |
| `/pr [files] [--commit-only]` | Alias for `/finish` (supports `--commit-only` / `-c`) | `/pr --commit-only` |
| `/commit-structured [files]` | Staged commit with 5 PR sections without creating a PR (alias: `/cpr`) | `/commit-structured` |
| `/commit <msg>` | Auto-stage all modified workspace files and create git commit | `/commit "feat: add user login"` |
| `/cost` \| `/tokens` | Display token usage breakdown and cumulative session cost | `/cost` |
| `/permissions` | Set tool execution safety mode (`auto`, `yolo`, or `ask`) | `/permissions ask` |
| `/plan [on\|off\|status]` | Configure the plan-approval gate for non-trivial modifying tool batches | `/plan off` |
| `/god [on\|off\|status\|toggle]` | Auto-answer all model questions and confirmations (unattended runs) | `/god status` |
| `/subagent <prompt>` | Spawn a background subagent worker for heavy sub-tasks | `/subagent "Search all TODOs"` |
| `/jobs [kill <id>|kill all]` | List running background jobs or kill specific/all jobs | `/jobs kill all` |
| `/workflow [cmd]` | Run customizable multi-step workflows: `list\|run\|status\|resume\|abort\|init` | `/workflow run elixir Add dark mode` |
| `/audit [code\|ux]` | Whole-project audit: strong parts, weaknesses & glitches, codebase + UX improvement ideas | `/audit` |
| `/linter [fix] <tool> [project\|diff\|cr]` | Run `oeditus_credo`, `propwise`, `credo`, `dialyzer`, `javac`/`mvn`/`checkstyle`, `cargo`/`clippy`, or `all` (alias: `/lint`) | `/linter credo diff` |
| `/bash [stats\|export\|clear\|help]` | Shell-call analytics: invocation counts, frequencies, and Ragex tool analogs | `/bash stats` |
| `/doctor` | Print the runtime diagnostic report (environment, provider, toolchain readiness) | `/doctor` |
| `/env` | Show runtime, workspace, provider, and effective credential state (never the value) | `/env` |
| `/edit [path\|prompt]` | Compose a prompt in `$EDITOR`, or open an existing file | `/edit lib/app.ex` |
| `/stats` | Session analytics dashboard (tokens, cost, tools, jobs) | `/stats` |
| `/history [search <q>]` | Show recent REPL input or search input history | `/history search auth` |
| `/git <subcommand>` | Run a raw `git` subcommand and print colorized output | `/git status` |
| `/cb` \| `/clipboard` | Copy latest assistant response to system clipboard | `/cb` |
| `/paste` \| `/clipboard image` | Save a clipboard image in `.yoke/sessions/assets` and send it for analysis | `/paste` |
| `/export [lmml\|lmmlz\|json\|markdown]` | Export the active conversation (Markdown is the default) | `/export json` |
| `/import <path> [id]` | Import an external `.lmml` or JSON session without overwriting an existing one | `/import saved.json` |
| `/session [list\|switch\|cleanup]` | Inspect, switch, or prune persisted workspace sessions (alias: `/status`) | `/session list all` |
| `/review_conversation [id]` | Review the current or specified conversation history | `/review_conversation` |
| `/clear` | Clear terminal output screen | `/clear` |
| `/reset` | Reset conversation context, history, checkpoints, and clear screen | `/reset` |
| `/help [command]` | Print REPL help menu or contextual help for one command | `/help workflow` |
| `/guide` \| `/docs` | Display the Getting Started & Customization Guide summary | `/guide` |
| `/exit` \| `/quit` | Exit Yoke and print conversation resume banner | `/exit` |

### Idea Lifecycle Pipeline

A `thoughts/ → backlog/ → active/ → completed/` pipeline with git-ignored
derived maps (`_MAP.md`, `_DEPS.md`) parsed from YAML frontmatter metadata.

| Slash Command | Description | Example |
| :--- | :--- | :--- |
| `/thought <Title> [\| Summary]` | Capture a raw pipeline thought | `/thought Token refresh \| Renew expired tokens` |
| `/promote <slug> [code\|initiative] [Must Have\|Should Have\|Nice to Have]` | Promote a thought to backlog (defaults to `code` and `Should Have`) | `/promote refresh-tokens code Must Have` |
| `/backlog` | Display the idea pipeline map and regenerate its indexes | `/backlog` |
| `/what-next` | Recommend a backlog item or thought to work on next | `/what-next` |
| `/audit-thoughts` | Validate pipeline item frontmatter and dependencies | `/audit-thoughts` |
| `/prune-completed` | List completed items with a knowledge-extraction checklist | `/prune-completed` |
| `/scrap [add <note>\|clear]` | Capture or view transient scratch notes in `project/scrap.md` | `/scrap add check retry logic` |
| `/process-scrap` | Display scrap notes with guidance for turning them into thoughts | `/process-scrap` |
| `/lessons [add <text>]` | View or record operational lessons in `project/lessons.md` | `/lessons add Pin md to 0.13` |
| `/prune-lessons` | Display lessons and guidance for synthesizing durable reference material | `/prune-lessons` |
| `/sweep <token1> [token2…]` | Multi-corpus prior-art search across workflow, reference, lessons, and vault | `/sweep auth jwt session` |
| `/spar [socratic\|adversarial] <topic>` | Prior-art-backed sparring discussion; defaults to socratic | `/spar adversarial Token refresh` |

### Keyboard Shortcuts & Hotkeys
- **`Ctrl+P`**: Toggle tool execution safety mode (`ask_confirm` ⇄ `auto_approve`)
- **`Ctrl+G`**: Toggle workspace sandbox bounds on/off
- **`Ctrl+B`**: Toggle idle status bar mode (gauge ⇄ compact session line)
- **`Ctrl+O`**: Toggle tool call log expansion mode (collapsed/truncated ⇄ expanded/full text)
- **`Ctrl+Q`**: Interrupt active AI turn while responding
  - Works while the AI is streaming or running tools. While a confirmation or
    `ask_question` modal owns the terminal, the modal's own `Ctrl+C` (deny /
    cancel) is the interrupt path; `Ctrl+Q` resumes as soon as the modal closes.

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

### 5. Auto-Commit (`/commit`)
Stages all workspace modifications and creates a git commit:
```bash
/commit "fix(cli): resolve terminal cursor offset on emoji rendering"
```

### 6. Structured Commits & Pull Requests (`/finish`, `/pr`, `/commit-structured`, `/cpr`)
Automate task completion with a comprehensive 5-section rationale (The PR reason, Implementation, How to verify, Risk & rollout, Reviewer guidance):
```bash
# Formats code, commits staged files, and creates GitHub PR via gh
/finish

# Optionally stage specific files before commit
/finish lib/yoke/aliases.ex lib/yoke/cli/repl.ex

# Create structured commit only without opening a PR
/finish --commit-only
/finish -c lib/app.ex
/commit-structured lib/app.ex
/cpr
```

### 7. Session Command Aliases (`/alias`, `/<name>`)
Declare and execute prepared command sequences in the active session:
```bash
/alias list                     # List declared aliases
/alias show finish              # Display steps of an alias
/alias add test !mix test       # Define a new quick alias
/alias rm test                  # Remove an alias
/<alias_name> [args]            # Execute alias directly
```

---

## 6. Session Management & Persistence (`-c`, `/resume`, Transcripts)

### Session State Persistence
All REPL and one-shot sessions automatically save their GenServer state, snapshots, and conversation messages to `.yoke/sessions/<session_id>.lmml` -- an `lmml` narrative (a Markdown-superset markup for LLM conversations). The file is plain, self-contained Markdown that any Markdown viewer renders sensibly, yet round-trips every structured message losslessly through its inline-embed model. Legacy `.json` session files from earlier versions are still read transparently on resume.

`/checkpoint` lists existing snapshot metadata; `/checkpoint <label>` creates
a new snapshot. `/undo` identifies the snapshot restored and affects the
conversation/provider settings, not files on disk.

When a `yoke fix` analysis exceeds `--agent-timeout <ms>`, Yoke cancels it
before cleanup and attempts to persist the triage context. If saving succeeds,
the output includes a session ID and a `yoke -c <id>` continuation command.
Continuation is a new turn using that context, not a resumed background task.
Independently started jobs retain their lifecycle and can be inspected with
`/jobs`; cancellation does not roll back external side effects.

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

### Export & Import
- `/export [lmml|lmmlz|json|markdown]` writes the active conversation to disk; Markdown is the default.
- `/import <path> [session_id]` loads an external `.lmml` or JSON session without overwriting an existing one.

### Ambiguous Context Expansion & Issue Tracking
`yoke` automatically detects ambiguous context references in prompts (such as *"error above"*, *"the build failure"*, or `@error`):
- Resolves previous tool execution tracebacks from session history.
- Maintains an internal Issue Tracker categorizing issues as `:open` or `:resolved`.
- Automatically marks issues as `:resolved` when subsequent tool calls succeed.

---

## 7. Model, Provider & Endpoint Selection Strategy (`/model`, `/provider`, `/endpoint`)

Switch model architectures, generation providers, or LLM endpoints on the fly during a session:

```bash
/model flash      # deepseek-flash — default agentic model
/model pro        # deepseek-v4-pro
/model coder      # deepseek-coder — idiomatic code writing
/model reasoner   # deepseek-reasoner (R1) — deep chain-of-thought debugging
/model vision     # deepseek-v4-flash-vision-exp

# OpenRouter & Local Model shortcuts
/endpoint openrouter    # Switch endpoint to OpenRouter API
/model openrouter-free  # Switch to meta-llama/llama-3.3-70b-instruct:free

/endpoint ollama        # Switch endpoint to local Ollama (http://localhost:11434)
/model ollama-qwen      # Switch to local qwen2.5-coder:14b
```

### Model Aliases

`/model <alias>` accepts any of the following shorthand aliases, or a full model ID:

| Alias | Resolves to |
| :--- | :--- |
| `flash`, `chat`, `v3`, `deepseek-chat` | `deepseek-flash` |
| `pro`, `v4-pro` | `deepseek-v4-pro` |
| `reasoner`, `r1` | `deepseek-reasoner` |
| `coder`, `v2.5` | `deepseek-coder` |
| `vision`, `v4` | `deepseek-v4-flash-vision-exp` |

An unrecognised model ID is validated against the provider's own model list
before switching, so a typo fails immediately instead of at the next HTTP 400.
Use `/model` with no argument to list the models the active endpoint offers.

### Provider Profiles (`/provider`, `--provider`)

A provider profile selects the **model and endpoint together**, atomically:

```bash
yoke --provider local        # Devstral Small 2 24B Q4_K_M, localhost Ollama
yoke --provider local-qwen   # Qwen3-Coder 30B-A3B Q4_K_M, localhost Ollama
yoke --provider deepseek     # deepseek-flash, official remote DeepSeek API
```

Inside the REPL, `/provider` shows the profile, model, endpoint, and
`LOCAL`/`REMOTE` transport; `/provider local`, `/provider local-qwen`, and
`/provider deepseek` switch all settings at once while idle. The prompt always
includes `[LOCAL]` or `[REMOTE]`, independently of the Hands `/mode`.

Selection precedence is CLI `--provider`, then `YOKE_PROVIDER`, then
`"provider"` in global/workspace config. Without a profile, the existing
model/endpoint behavior is preserved. Explicit profiles ignore unrelated
`DEEPSEEK_MODEL`, `DEEPSEEK_ENDPOINT`, aggregator routing, and `OLLAMA_HOST`.
Local profiles reject non-loopback endpoints and never fall back remotely.

### Endpoint Shortcuts (`/endpoint`)

| Shortcut | Endpoint |
| :--- | :--- |
| `default` / `deepseek` | `https://api.deepseek.com/chat/completions` |
| `openrouter` | `https://openrouter.ai/api/v1/chat/completions` |
| `opencode` | `https://opencode.ai/zen/go/v1/chat/completions` |
| `ollama` | `http://localhost:11434/v1/chat/completions` |
| `lmstudio` | `http://localhost:1234/v1/chat/completions` |
| `vllm` | `http://localhost:8000/v1/chat/completions` |

Any other value is used verbatim as the endpoint URL. `/endpoint` reports the
resulting session credential state immediately, so a missing token is visible
before the next turn fails. `/env` shows the effective credential state and the
variable or setting it came from, without revealing the secret.

| Scenario | Recommended Model / Provider | Rationale |
| :--- | :--- | :--- |
| **Multi-turn file editing & bash commands** | `deepseek-flash` | Highest tool call precision and execution reliability |
| **Writing complex algorithms & tests** | `deepseek-coder` | Trained on 338+ languages; idiomatic syntax generation |
| **Diagnosing stack traces & deadlocks** | `deepseek-reasoner` | Streams live `[DeepSeek-R1 Reasoning]` thoughts before execution |
| **Open-source & Free AI Models** | OpenRouter (`/endpoint openrouter`) | Free tier access to Llama 3.3, Qwen 2.5 Coder, Gemini 2.0 |
| **Offline & Air-gapped Execution** | Local Ollama / LM Studio (`/provider local`) | Complete privacy, offline tool execution without API key requirements |

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

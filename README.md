<p align="center">
  <img src="stuff/img/logos-500x500.png" width="220" alt="Yoke logo" />
</p>
<h1 align="center">Yoke</h1>
<p align="center"><b>An agentic CLI coding harness (originally built for DeepSeek models,) purely on Elixir &amp; Erlang/OTP</b></p>
<p align="center">
  <img alt="Elixir" src="https://img.shields.io/badge/elixir-1.19%2B-4B275F?logo=elixir&logoColor=white" />
  <img alt="Erlang/OTP" src="https://img.shields.io/badge/erlang%2FOTP-27%2B-A90533?logo=erlang&logoColor=white" />
  <img alt="Version" src="https://img.shields.io/badge/version-0.2.0-blue" />
  <img alt="Architecture" src="https://img.shields.io/badge/architecture-Brain%20%2F%20Hands-teal" />
</p>

An agentic CLI coding harness for **DeepSeek** models (`deepseek-chat` V3, `deepseek-coder` V2.5, and `deepseek-reasoner` R1), built in **Elixir & Erlang/OTP**. `OpenRouter` and local models are also supported.

Derived from **José Valim's architectural framework** for process-isolated AI agents, **DeepSeek V3/R1 model architecture**, **Google Antigravity**, and **Warp Terminal TUI patterns**.

---

## Table of Contents
- [Architectural Foundation](#architectural-foundation-josé-valims-vision--deepseek-model-integration)
- [Key Features & Capabilities](#key-features--capabilities)
- [Installation & Setup](#installation--setup)
- [Getting Started & Customization Guide](#getting-started--customization-guide)
- [REPL Slash Commands & Shortcuts](#repl-slash-commands--shortcuts)
- [Configuration](#configuration)
- [Documentation](#documentation)
- [License](#license)

---

## <img src="stuff/img/logos-48x48.png" width="20" valign="middle" /> Architectural Foundation: José Valim's Vision & DeepSeek Model Integration

Yoke (Yoke) bridges modern LLM reasoning capabilities with Erlang/OTP's battle-tested fault tolerance and process concurrency model.

### 1. José Valim's Actor-Driven Harness Architecture
In traditional AI harnesses (typically single-threaded Node.js or Python runtimes), a tool execution error or unhandled exception can crash the entire interactive session, wiping out conversation context and active state. Yoke implements José Valim's vision for agentic harnesses on the BEAM virtual machine:

- **Decoupled Brain & Hands Architecture**: The agent's cognitive state ("Brain") runs as an isolated GenServer process (`Yoke.Brain.Session`). Tool execution ("Hands") is cleanly separated (`Yoke.Hands.Executor`), allowing commands to execute locally, on remote Erlang nodes, or inside isolated Docker containers.
- **Fault-Tolerant Supervision**: If a tool execution or sub-task process fails, the OTP supervision tree isolates the failure without impacting the user's interactive REPL session.
- **Spatiotemporal Checkpoints & Instant Rollback**: State snapshots record conversation history, model configurations, and context state before each tool execution turn, providing temporal undo capabilities (`/undo`) and state branching.
- **Live Hot-Code Tool Reloading**: Tools and plugins can be compiled, hot-swapped, or reloaded live (`/plugins reload`) without losing conversation memory or resetting GenServer process state.
- **Lightweight Parallel Subagents**: Sub-tasks can be delegated to child session processes (`SessionSupervisor.start_session`), running parallel agentic loops concurrently across BEAM worker threads.
- **Concurrent OTP Task Engine**: Batches of tool calls (`Yoke.TaskEngine.Orchestrator`) run concurrently under a `Task.Supervisor`, with per-file write locks and a real-time "N running" badge on the status bar ruler.
- **Distributed Erlang Node Clustering**: Hands execution can target the local host, a remote Erlang node (`/mode remote <node>`), or a Docker container (`/mode docker <id>`), decoupling where the Brain thinks from where the Hands act.

### 2. DeepSeek Model Selection & Best Practices

Yoke supports the full suite of official DeepSeek models, local open-weights models, and third-party API aggregators. Switch models anytime via `/model <alias>` or `--model <alias>`:

| Model | ID / Alias in Yoke | Best Used For | Strengths & Characteristics |
| :--- | :--- | :--- | :--- |
| **DeepSeek-V3** | `deepseek-chat`<br>`/model chat` | **Agentic workflows & multi-tool tasks** *(Default)* | 671B MoE model. Offers high general reasoning and **highest tool-calling precision** across multi-turn agent loops. |
| **DeepSeek-Coder-V2.5** | `deepseek-coder`<br>`/model coder` | **Direct code generation, syntax completion & refactoring** | Trained specifically on **338+ programming languages**. Produces idiomatic Elixir/C++/Rust code with high precision on syntax and language conventions. |
| **DeepSeek-R1** | `deepseek-reasoner`<br>`/model reasoner` | **Complex debugging & architectural design** | Reinforcement Learning (RL) reasoning model. Yoke captures and streams `[DeepSeek-R1 Reasoning]` Chain-of-Thought output live before tool execution. |

### 3. OpenRouter & Local Model Integration (Ollama, LM Studio, vLLM)

While `yoke` defaults to the official remote **DeepSeek API** (`https://api.deepseek.com/chat/completions` with `deepseek-chat`), it provides native support for **OpenRouter** (including free models) and **Local Open-Weights Models** running via Ollama, LM Studio, vLLM, or LocalAI.

#### A. OpenRouter Configuration
Connect `yoke` to OpenRouter endpoints (such as `meta-llama/llama-3.3-70b-instruct:free`, `qwen/qwen-2.5-coder-32b-instruct:free`, or `deepseek/deepseek-r1:free`):

- **Environment Variables**:
  ```bash
  export OPENROUTER_API_KEY="sk-or-v1-..."
  export DEEPSEEK_ENDPOINT="https://openrouter.ai/api/v1/chat/completions"
  export DEEPSEEK_MODEL="meta-llama/llama-3.3-70b-instruct:free"

  yoke
  ```
- **CLI Flags**:
  ```bash
  yoke -e openrouter -m meta-llama/llama-3.3-70b-instruct:free
  ```
- **Live REPL Commands**:
  ```text
  /endpoint openrouter
  /model openrouter-free
  ```

#### B. Local Models (Ollama, LM Studio, vLLM)
Run `yoke` completely offline against local LLM servers without requiring API keys:

- **Ollama (`http://localhost:11434`)**:
  ```bash
  # 1. Start Ollama model
  ollama run qwen2.5-coder:14b

  # 2. Launch yoke with local endpoint
  yoke -e ollama -m qwen2.5-coder:14b
  
  # Or via environment variables:
  export OLLAMA_HOST="http://localhost:11434"
  export DEEPSEEK_MODEL="qwen2.5-coder:14b"
  yoke
  ```
- **LM Studio (`http://localhost:1234`) & vLLM (`http://localhost:8000`)**:
  ```bash
  yoke -e lmstudio -m qwen2.5-coder-32b-instruct
  # OR
  yoke -e vllm -m deepseek-r1-distill-qwen-32b
  ```
- **Automatic Reasoning & `<think>` Tag Extraction**:
  Local models and OpenRouter models that return reasoning inside `<think>...</think>` tags are automatically parsed into `[Reasoning]` output.
- **API Key Bypass**: Local loopback endpoints (`localhost`, `127.0.0.1`, `::1`, `192.168.*`) do not require API keys and automatically bypass offline mock mode.

---

## <img src="stuff/img/logos-48x48.png" width="20" valign="middle" /> Key Features & Capabilities

### 1. Persistent Session Resumption (`yoke -c <id>` & `/resume`)
- Every session is assigned a unique UUID (e.g. `df97eb34-cb33-4f21-bada-2e9c3cf75d46`).
- On exit, `yoke` prints your conversation ID:
  ```
  Resume with -c (or command below):
  yoke --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46
  ```
- Resume any conversation across restarts with `yoke -c <id>` or interactively pick past sessions in the REPL via `/resume`.
- Conversations are stored in **`lmml`** (a Markdown-superset markup for LLM conversations) as `<session_id>.lmml` narratives under `.yoke/sessions/` — plain, self-contained Markdown that any Markdown viewer renders sensibly, yet round-trips every structured message losslessly through its inline-embed model. Legacy `.json` session files from earlier versions are still read transparently on resume.

### 2. Scoped Rule Engine (`/rules`)
- Manage prompt preambles and execution constraints.
- **Scopes**:
  - `all:` — Applied to all user prompt turns (e.g. `all: typographic quotes “” mean the exact quote`).
  - `<command>:` — Applied only when executing specific commands (e.g. `cr: format table cells multiline to fit in 80 symbols width` for `/cr`).
- Use `/rules` to list rules, `/rules add <scope: text>` to add rules, and `/rules delete` to launch the interactive checkbox modal.

### 3. Context Reference Expansion (`@`) & Smart Error Resolution
- Type `@filename`, `@/path`, `@file://...`, or `@https://...` anywhere in user prompts to attach contents.
- `@` triggers an interactive TUI file picker filtered by `.gitignore` rules (excluding `_build`, `deps`, `.elixir_ls`).
- Intelligently expands ambiguous error references ("error above", `@error`) and tracks `:open` vs `:resolved` issue status across tool calls.

### 4. Interactive Question TUI Modal (`ask_question`)
- Allows the AI model to request user feedback, clarify requirements, or present multi-choice design decisions with keyboard navigation and OK/Cancel buttons.

### 5. Model Context Protocol (MCP) & First-Class Ragex Integration
- Mount external Model Context Protocol (MCP) servers via `stdio` (JSON-RPC) or HTTP/SSE.
- Native integration with **Ragex** for SCIP code indexing, AST refactoring, and semantic code search (`/ragex`).

### 6. One-Command Global Installation & Updates
- Install globally to `~/.local/bin/yoke` via `mix yoke.install` or `install.sh`.
- Run `yoke` smoothly from **any** workspace directory.
- Perform background in-place self-updates anytime using `yoke --update` or `/update`.

### 7. Pure Console Mode (`!!`)
- Type `!!` on its own line to flip `yoke` completely out of the way: no Brain/Hands actors, no LLM turns, no slash-command dispatch -- just a bare `sh -c` passthrough with live-streamed output.
- `cd` is applied to `yoke`'s own process, exactly like a real shell builtin, so navigation persists across commands.
- Type `!!` again (or `Ctrl+D`) to flip straight back into the harness REPL -- no need to open a second terminal tab for a quick burst of plain shell commands.

### 8. Concurrent OTP Task Engine
- Tool call batches execute concurrently under `Yoke.TaskEngine.Orchestrator`, each in its own supervised `Task`, with automatic per-file write locking to prevent concurrent edit races.
- The idle status bar surfaces a live "N running" badge with per-task summaries whenever background tool work is in flight.

### 9. Native Elixir Static Analysis (`/linter`, `/lint`)
- Runs `oeditus_credo`, `propwise`, `credo`, or `dialyzer` against the full project, a git diff, or a branch code review via `/linter <tool> [project|diff|cr] [args...]`.

### 10. Configurable Prompt Styles & Status Bar (`/config`)
- Switch prompt layout with `/config style <starship|extended|compact|minimal>` or supply a fully custom template via `/config prompt <template>`.
- Toggle UI features (`enable_autosuggestions`, `enable_syntax_highlighting`, `enable_context_gauge`, `compact_status_bar`, and more) with `/config toggle <key>`.

### 11. Customizable Multi-Step Workflows (`/workflow`)
- Runs a named, customizable, multi-step process on top of the ordinary agent loop: branch off `main`/`master` (with a warn/confirm gate), summarize the task, propose a non-clashing split for parallel execution, require tests + docs, lint, and commit -- with the entire run persisted under `.yoke/workflows/`.
- Parallel subtasks each get their own isolated `git worktree` and branch, so concurrent agent processes can never clash on disk.
- Ships with a built-in `elixir` workflow; scaffold your own with `/workflow init <name> [--from <template>]`. Full reference: [`docs/WORKFLOW_ENGINE.md`](docs/WORKFLOW_ENGINE.md).

### 12. Idea Lifecycle Pipeline & Strategic Memory Engine (`/sweep`, `/spar`, `/thought`, `/backlog`)
- Implements an idea-lifecycle pipeline (`thoughts/ → backlog/ → active/ → completed/`) with git-ignored derived maps (`_MAP.md`, `_DEPS.md`) parsed from YAML frontmatter metadata.
- **Multi-Corpus Prior-Art Sweep (`/sweep <tokens>`)**: Searches active pipeline, reference docs, operational lessons, and local knowledge vault to prevent repeating past work.
- **Socratic & Adversarial Sparring (`/spar [soc|adv] <topic>`)**: Pressure-tests new feature designs turn-by-turn with Socratic requirement probing and blunt Adversarial counter-arguments.
- **Structured Memory Architecture**: Transient scratch notes (`/scrap`), operational lessons learned (`/lessons`), and automated close-out gates.

---

<p align="center">
  <img src="stuff/img/logos-128x128.png" width="64" alt="Yoke" />
</p>

## <img src="stuff/img/logos-48x48.png" width="20" valign="middle" /> Installation & Setup

This guide provides step-by-step instructions to get **Yoke (`yoke`)** up and running on your system, along with its database backend **`dllb`** (which powers **Ragex** code analysis and knowledge graph indexing).

---

### Prerequisites (What You Need First)

Before installing `yoke` or `dllb`, ensure your machine has the following tools installed:

1. **Elixir & Erlang/OTP**: 
   - `yoke` is built using the Elixir programming language on top of the Erlang runtime engine.
   - **Required versions**: Elixir `1.19+` and Erlang/OTP `27+`.
   - *How to install*: Use your system package manager (e.g. `brew install elixir` on macOS or `sudo apt install elixir` on Ubuntu) or a version manager like [`asdf`](https://asdf-vm.com/) / [`mise`](https://mise.jdx.dev/).
2. **Git**: Required to download the project source code.
3. **C/C++ Build Tools & Libraries** *(Linux only)*:
   - Required for compiling native code dependencies: `build-essential` and `libgit2-dev`.
   - *Ubuntu/Debian command*: `sudo apt-get install -y build-essential libgit2-dev`

---

### 1. Installing `yoke` (Yoke)

Choose **one** of the two installation methods below:

#### Option A: Quick Automated Installer (Recommended)

Run this single command in your terminal to automatically clone, build, and install `yoke`:

```bash
curl -fsSL https://raw.githubusercontent.com/Oeditus/yoke/main/install.sh | bash
```

#### Option B: Manual Installation from Source

If you prefer installing manually from the source code:

```bash
# 1. Clone the repository
git clone https://github.com/Oeditus/yoke.git
cd yoke

# 2. Fetch project dependencies
mix deps.get

# 3. Compile and install yoke globally to ~/.local/bin/yoke
mix yoke.install
```

#### Adding `~/.local/bin` to Your System `$PATH`

After installation, ensure `~/.local/bin` is included in your shell path so you can run `yoke` from any terminal directory:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

> **Tip:** Add the line above to your shell configuration file (e.g. `~/.bashrc` or `~/.zshrc`) so it is available automatically in every new terminal window.

---

### 2. Installing `dllb` for `ragex` Code Indexing

#### What is `dllb` and why do I need it?
`yoke` features a powerful code intelligence engine called **Ragex** (`/ragex`). To store code symbol relationship graphs, perform fast full-text code searches, and cache project metadata across restarts, Ragex uses a lightweight, high-performance database server called **`dllb-server`** (written in Rust).

Installing `dllb-server` enables persistent, per-project database indexing.

#### Option A: Download Pre-Compiled Binary (Easiest)

1. Go to the [`dllb` GitHub Releases](https://github.com/Oeditus/dllb/releases) page.
2. Download the `dllb-server` binary for your platform (e.g., Linux or macOS).
3. Move the binary into your `~/.local/bin` directory (or any directory in your system `$PATH`) and make it executable:

```bash
# Move to local bin directory
mv dllb-server ~/.local/bin/

# Make executable
chmod +x ~/.local/bin/dllb-server
```

#### Option B: Compile `dllb-server` from Source (Rust / Cargo)

If you have the **Rust toolchain** installed (`cargo`):

```bash
# 1. Clone the dllb repository
git clone https://github.com/Oeditus/dllb.git
cd dllb

# 2. Build the optimized release binary
cargo build --release -p dllb-server

# 3. Option i: Copy the compiled binary to your PATH
cp target/release/dllb-server ~/.local/bin/

# OR Option ii: Leave it in sibling directory `../dllb/target/release/dllb-server`
```

#### How Ragex Finds `dllb-server` (Path Resolution Precedence)

When you run `/ragex` inside `yoke`, Ragex looks for the `dllb-server` executable automatically in this order:

1. **Custom Environment Variable**: `DLLB_SERVER_BIN=/path/to/dllb-server`
2. **System `$PATH`**: Directories in your `$PATH` (e.g. `~/.local/bin/dllb-server` or `/usr/local/bin/dllb-server`).
3. **Sibling Repository Path**: Relative path `../dllb/target/release/dllb-server` or `../dllb/target/debug/dllb-server`.

---

### 3. Verifying Your Installation

1. **Check `yoke` CLI**:
   ```bash
   yoke --version
   ```
2. **Start `yoke` in any project**:
   ```bash
   cd /path/to/your/project
   yoke
   ```
3. **Test Ragex Code Indexing**:
   Inside the `yoke` REPL session, type:
   ```text
   /ragex
   ```
   You should see confirmation that Ragex and the `dllb` knowledge graph backend have been successfully initialized!

---

## <img src="stuff/img/logos-48x48.png" width="20" valign="middle" /> Getting Started & Customization Guide

For complete, step-by-step instructions on onboarding, teaching Yoke language idiomatics, driving multi-step workflows, writing custom plugins, setting scoped rules, and tuning the iterative feedback loop, refer to the full **[Getting Started & Customization Guide](docs/GETTING_STARTED_GUIDE.md)** (also accessible inside the REPL via `/guide` or `/docs`).

### Onboarding & Customization Summary

1. **[Core Architecture & Quickstart](docs/GETTING_STARTED_GUIDE.md#1-core-architecture--quickstart)**
   - BEAM actor isolation (Brain GenServer decoupled from Hands executor).
   - Basic CLI invocation (`yoke`, `yoke "prompt"`), inline `@file` / `@url` context references, and spatiotemporal `/checkpoint` & `/undo`.
2. **[Teaching Yoke New Language Idiomatics (`.yoke/practices`)](docs/GETTING_STARTED_GUIDE.md#2-teaching-yoke-new-language-idiomatics-yokepractices)**
   - LMML practice manifests in `.yoke/practices/<language>.lmml`.
   - Run `/practices teach <language>` to automatically inspect exemplary codebases and extract team-specific coding conventions.
3. **[Starting & Driving Workflows (`/workflow`)](docs/GETTING_STARTED_GUIDE.md#3-starting--driving-workflows-workflow)**
   - Run built-in engineering pipelines (`/workflow run elixir "<task>"`).
   - Parallel subtasks execute in physically isolated Git worktrees under `.yoke/workflows/`.
4. **[Tuning Workflows for Your Team's Needs](docs/GETTING_STARTED_GUIDE.md#4-tuning-workflows-for-your-teams-needs)**
   - Scaffold custom JSON workflow definitions via `/workflow init my-team-flow --from elixir`.
5. **[Writing Custom Elixir Plugins (`Plugin.Behaviour`)](docs/GETTING_STARTED_GUIDE.md#5-writing-custom-elixir-plugins-pluginbehaviour)**
   - Expose domain-specific tools by implementing `Yoke.Plugin.Behaviour` and hot-reloading live with `/plugins reload`.
6. **[Managing Scoped Rules, Custom Skills & Ragex MCP](docs/GETTING_STARTED_GUIDE.md#6-managing-scoped-rules-custom-skills--ragex-mcp)**
   - Set prompt preambles via `/rules add <scope>:<text>`, add modular skill packages in `.yoke/skills/`, and mount `/ragex` for SCIP/AST symbol graph search.
7. **[The Iterative Feedback Loop: Fitting Expectations 100%](docs/GETTING_STARTED_GUIDE.md#7-the-iterative-feedback-loop-fitting-expectations-100)**
   - 4-step tuning cycle: Observe → Codify (`.yoke/practices`) → Automate (`.yoke/workflows`) → Snapshot & Replicate (version control `.yoke/`).

---

## <img src="stuff/img/logos-48x48.png" width="20" valign="middle" /> REPL Slash Commands & Shortcuts

The full reference lives in [`docs/cheat_sheet.md`](docs/cheat_sheet.md); the essentials are grouped below.

#### Shell & Console
| Command | Action |
| :--- | :--- |
| `!command` | Execute shell command directly (e.g. `!git status`, `!mix test`) |
| `!!` | Flip into/out of pure console mode (plain shell passthrough, no AI/tooling) |
| `/git <subcommand>` | Run a raw `git` subcommand and print colorized output |

#### Session, History & Persistence
| Command | Action |
| :--- | :--- |
| `/resume [id]` | Resume specific session ID or open interactive conversation picker modal |
| `/session [list\|switch\|cleanup]` | Inspect, switch, or prune persisted workspace sessions |
| `/status` | Alias for `/session` -- active session & system status |
| `/checkpoint [label]` | Create a manual temporal state snapshot |
| `/undo` | Roll back state to previous temporal checkpoint |
| `/compact` | Compress conversation context to save tokens |
| `/export [json\|markdown]` | Export full session transcript to disk |
| `/history [search <query>]` | Show or search persistent REPL input history |
| `/cost` \| `/tokens` | Display token usage breakdown and cumulative session cost |

#### Git & Code Review
| Command | Action |
| :--- | :--- |
| `/cr [base]` | Generate Code Review for current branch against `main` or custom base |
| `/diff [branch]` | Display colorized git diff of workspace or against target branch |
| `/commit <message>` | Auto-stage and commit workspace changes |
| `/linter <tool> [project\|diff\|cr]` | Run `oeditus_credo`, `propwise`, `credo`, or `dialyzer` (alias: `/lint`) |

#### Model, Execution & Rules
| Command | Action |
| :--- | :--- |
| `/model [chat\|coder\|reasoner\|openrouter-free\|ollama-qwen]` | Switch active model (`deepseek-chat`, `deepseek-coder`, `deepseek-reasoner`, OpenRouter/Ollama shortcuts, or custom model string) |
| `/endpoint [url\|default\|openrouter\|ollama\|lmstudio]` | Switch API base endpoint URL dynamically |
| `/mode [local\|remote\|docker]` | Set Hands execution target |
| `/sandbox [on\|off]` | Restrict file references & tools to the workspace directory |
| `/permissions [auto\|ask]` | Set tool execution safety mode |
| `/rules [add\|delete\|toggle]` | Manage scoped prompt preambles and launch deletion checkbox modal |
| `/nodes` | View distributed Erlang node cluster status |

#### Tooling & Extensibility
| Command | Action |
| :--- | :--- |
| `/plugins [reload\|info]` | List tools or hot-reload plugins live without dropping state |
| `/mcp [list\|add\|load]` | Manage Model Context Protocol (MCP) servers and tools |
| `/ragex [stats\|reindex\|export]` | Mount and drive the first-class Ragex code analysis & refactoring MCP server |
| `/skills [list\|show\|path\|edit\|new\|<name>]` \| `/skill <name>` | List, inspect, scaffold, or execute skills (arguments may be passed to a skill) |
| `/subagent <prompt>` | Spawn a background subagent worker for sub-tasks |
| `/workflow [list\|run\|status\|resume\|abort\|init]` | Run customizable multi-step workflows (branch, describe, split & parallelize, test/docs, lint, commit) |
| `/config [style\|prompt\|toggle]` | Manage prompt styles and UI toggles |
| `/env` | Show runtime environment (Elixir/OTP version, model, workspace) |
| `/update` | Background self-update `yoke` release to latest code |

#### Utility
| Command | Action |
| :--- | :--- |
| `/cb` \| `/clipboard` | Copy latest assistant response to system clipboard |
| `/clear` | Clear terminal output |
| `/help` | Display help menu |
| `/exit` \| `/quit` | Exit Yoke and print conversation resume banner |

---

## Configuration

`yoke` reads settings from `~/.yoke/config.json` (global) merged with `.yoke/config.json` (per-workspace override, taking precedence). Notable keys:

| Key | Default | Purpose |
| :--- | :--- | :--- |
| `model` | `"deepseek-chat"` | Default LLM model identifier |
| `endpoint` | `"https://api.deepseek.com/chat/completions"` | LLM API base endpoint URL (DeepSeek, OpenRouter, Ollama, etc.) |
| `prompt_style` | `"starship"` | Prompt layout: `starship`, `extended`, `compact`, or `minimal` |
| `permission_mode` | `"ask_confirm"` | Tool execution safety mode (`ask_confirm` or `auto_approve`) |
| `sandbox_workspace` | `false` | Restrict file references & tools to the workspace directory |
| `enable_autosuggestions` | `true` | Fish-style ghost autosuggestions from input history |
| `enable_syntax_highlighting` | `true` | Highlight `/commands` and `!shell` lines as you type |
| `enable_context_gauge` | `true` | Show the token/cost usage gauge on the idle status bar |
| `compact_status_bar` | `false` | Swap the gauge for a compact `id + message count` line |
| `max_context_tokens` | `64000` | Assumed model context window used by the usage gauge |
| `max_tool_depth` | `100` | Consecutive tool-calling turns before pausing to confirm |

Manage most of these live from the REPL with `/config style <name>`, `/config prompt <template>`, and `/config toggle <key>` -- or toggle permission mode, sandbox bounds, and the status bar mode instantly with `Ctrl+P`, `Ctrl+G`, and `Ctrl+B`.

---

## Documentation

- [`docs/GETTING_STARTED_GUIDE.md`](docs/GETTING_STARTED_GUIDE.md) — Comprehensive Onboarding & Customization Guide (Practices, Workflows, Plugins, Rules, Skills & Ragex).
- [`docs/WORKFLOW_ENGINE.md`](docs/WORKFLOW_ENGINE.md) — Multi-step Workflow Engine Reference (`/workflow`).
- [`docs/cheat_sheet.md`](docs/cheat_sheet.md) — Full Slash Command & Shortcuts Cheatsheet.

---

## Roadmap & Future Enhancements (TODO)

- **Sandboxed Code Mode over MCP**: Implement a sandboxed Lua expression surface over MCP tools (`lua_docs`, `lua_eval`) allowing external and internal subagents to project, filter, and aggregate large data structures or file fields on the host without loading multi-megabyte raw context into model prompts.
- **Enhanced Git Worktree Isolation & Multi-Lock Serialization**: Introduce dual-lock mechanics (`gate_lock` for CPU/testing serialization and `land_lock` for branch advancement) alongside warm dependency cache copying (`deps`/`_build`) for git worktree subagents managed by the workflow engine.

---

## License

MIT, see [`LICENSE`](LICENSE) -- with one additional restriction: this project may **not** be used, modified, or distributed as a harness, adapter, or integration layer for proprietary third-party models from OpenAI, Anthropic, or Google (e.g. GPT, Claude, Gemini), whether accessed directly or through an intermediary API, proxy, or aggregator.

<p align="center">
  <img src="stuff/img/logos-128x128.png" width="48" alt="Yoke" />
  <br />
  <sub>Yoke (Yoke) -- Actors, Hot-Code Reloading, Distributed Brain/Hands, Spatiotemporal Checkpoints.</sub>
</p>

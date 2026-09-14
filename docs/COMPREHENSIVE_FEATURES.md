# Yoke (Yoke) — Comprehensive Features & Architecture Guide

Yoke (**Yoke**) is an open-source, production-grade agentic AI coding harness for DeepSeek models (`deepseek-chat` V3, `deepseek-coder` V2.5, and `deepseek-reasoner` R1), constructed on the **Erlang/OTP** virtual machine and **Elixir**.

Designed around **José Valim’s actor-driven agent harness framework**, **Google Antigravity UI patterns**, and **Warp Terminal TUI design**, Yoke provides developer-controlled, fault-tolerant execution, concurrent subagent orchestration, spatiotemporal state checkpoints, and deep code intelligence.

---

## Table of Contents

1. [Architectural Overview & Actor Model](#1-architectural-overview--actor-model)
2. [DeepSeek Model Integration & Reasoning Streaming](#2-deepseek-model-integration--reasoning-streaming)
3. [Interactive Terminal UI & Prompt Capabilities](#3-interactive-terminal-ui--prompt-capabilities)
4. [Session Management & Persistence (LMML & Transcripts)](#4-session-management--persistence-lmml--transcripts)
5. [Scoped Prompt Rule Engine (`/rules`)](#5-scoped-prompt-rule-engine-rules)
6. [Interactive Questions & Permission Gates](#6-interactive-questions--permission-gates)
7. [Concurrent Task Engine & Parallel Subagents](#7-concurrent-task-engine--parallel-subagents)
8. [Model Context Protocol (MCP) & Ragex Integration](#8-model-context-protocol-mcp--ragex-integration)
9. [Native Elixir Linters (`/linter`, `/lint`)](#9-native-elixir-linters-linter-lint)
10. [Customizable Workflows Engine (`/workflow`)](#10-customizable-workflows-engine-workflow)
11. [Distributed Erlang Node Execution (`/mode`)](#11-distributed-erlang-node-execution-mode)
12. [Configuration & Prompt Customization (`/config`)](#12-configuration--prompt-customization-config)

---

## 1. Architectural Overview & Actor Model

In traditional single-threaded agent runtimes (Node.js/Python), an uncaught tool exception or network timeout can terminate the process, discarding conversation history and active state. Yoke solves this by leveraging the Erlang BEAM actor model:

### Decoupled Brain & Hands Architecture
- **The Brain (`Yoke.Brain.Session`)**: A dedicated `GenServer` actor maintaining conversation memory, active model parameters, system rules, token accounting, and temporal snapshots.
- **The Hands (`Yoke.Hands.Executor`)**: Cleanly decoupled tool execution service capable of targeting the local host, a remote Erlang node, or an isolated Docker container.
- **Fault-Tolerant OTP Supervision**: The session actor runs under a `DynamicSupervisor`. If a tool execution or sub-task crashes, the OTP supervision tree isolates the failure, preventing interactive session collapse.

```
                  ┌─────────────────────────────────────┐
                  │          CLI LineEditor / TUI       │
                  └──────────────────┬──────────────────┘
                                     │ GenServer.call
                                     ▼
                  ┌─────────────────────────────────────┐
                  │   Brain Actor (Session GenServer)   │
                  │  - Messages & Context Memory        │
                  │  - Snapshots & Rollback History     │
                  │  - Rule Preamble Injector           │
                  └──────────────────┬──────────────────┘
                                     │
           ┌─────────────────────────┼─────────────────────────┐
           ▼                         ▼                         ▼
┌───────────────────┐     ┌───────────────────┐     ┌───────────────────┐
│ Task Supervisor   │     │ MCP Server Manager│     │ Hands Executor    │
│ Concurrent Workers│     │ Ragex / SCIP      │     │ Local/Remote/Docker│
└───────────────────┘     └───────────────────┘     └───────────────────┘
```

### Key BEAM Features in Yoke
- **Live Hot-Code Tool Reloading**: Compile and hot-swap custom Elixir tools live (`/plugins reload`) without restarting the session actor or losing context memory.
- **Spatiotemporal State Checkpoints**: Automatic or manual snapshots (`/checkpoint`) record state before tool iterations, enabling instant rollbacks (`/undo`).
- **Parallel BEAM Process Monitoring**: Real-time rendering of active serving BEAM processes and background task workers directly on the status bar ruler.

---

## 2. DeepSeek Model Integration & Reasoning Streaming

Yoke natively supports official DeepSeek models, local Ollama endpoints, and third-party aggregators (OpenRouter):

| Model Alias | DeepSeek Model ID | Purpose & Strengths |
| :--- | :--- | :--- |
| `chat` / `v3` | `deepseek-chat` | **Default Agentic Model**: 671B MoE. Highest tool-calling precision for multi-turn loops. |
| `coder` | `deepseek-coder` | **Direct Syntax Generation**: Trained on 338+ languages. Optimized for idiomatic code writing and refactoring. |
| `reasoner` | `deepseek-reasoner` | **Deep Reasoning & Debugging**: Reinforcement learning model. Streams live `[DeepSeek-R1 Reasoning]` Chain-of-Thought output before tool execution. |
| `openrouter-r1` | `deepseek/deepseek-r1` | OpenRouter endpoint integration for DeepSeek-R1. |
| `ollama-r1` | `ollama/deepseek-r1` | Local offline reasoning execution via Ollama API. |

### Features
- **Live Reasoning Stream**: For `deepseek-reasoner` (R1), Yoke extracts and streams thinking logs live to the console before executing tool calls.
- **Max Tokens Cap**: Configurable completion token caps forwarded to DeepSeek API requests (`max_tokens` config setting).

---

## 3. Interactive Terminal UI & Prompt Capabilities

Built with custom ANSI color rendering, line editing, and fuzzy file pickers:

### 1. Interactive Line Editor (`LineEditor`)
- **Ghost Auto-Suggestions**: Light gray inline completion suggestions derived from history; press `Right Arrow` or `End` to accept.
- **Slash Command Autocomplete**: Press `Tab` on `/` commands to view and autocomplete slash commands.
- **Status Bar Themes**: Customizable status bar rulers (`starship`, `extended`, `compact`, `minimal`) showing model, hands target, context token gauge bar, USD cost, and active BEAM process counters.

### 2. Context Expansion (`@`) & Fuzzy File Picker
- Type `@` anywhere in a prompt to open an interactive fuzzy file picker modal.
- Automatically respects `.gitignore` rules and ignores build artifacts (`_build`, `deps`, `.elixir_ls`).
- Supports attaching relative paths (`@lib/main.ex`), URLs (`@https://...`), or ambiguous error references (`@error`, "error above").

### 3. Shell Command Shortcut (`!`)
- Prefix any line with `!` to execute a shell command directly without LLM invocation:
  ```bash
  !git status
  !mix test
  ```

### 4. Pure Console Mode (`!!`)
- Type `!!` on its own line to flip `yoke` into **Pure Console Mode**: a plain shell passthrough bypassing Brain/Hands actors and LLM calls.
- Directory changes (`cd`) apply directly to `yoke`'s main OS process, persisting when returning to the REPL.
- Type `!!` again to flip back into the interactive harness REPL.

---

## 4. Session Management & Persistence (LMML & Transcripts)

### 1. LMML Conversation Persistence
Sessions are persisted to `.yoke/sessions/<session_id>.lmml` using **LMML** (a Markdown-superset markup format for LLM conversations).
- Plain, self-contained Markdown readable by standard viewers.
- Round-trips multi-turn assistant tool calls, tool results, system preambles, and image attachments losslessly.
- Supports transparent backward compatibility with legacy `.json` session files.

### 2. Dual JSONL Transcripts Logging
Every session automatically maintains audit transcripts in `.yoke/sessions/<session_id>/`:
- `transcript_full.jsonl`: Complete, untruncated log of all turns, prompts, tool calls, and model outputs.
- `transcript_compact.jsonl`: Token-efficient log with truncated payload content for rapid searching and grepping.

### 3. Session Import & Export
- **Export**: Export active sessions to formatted Markdown or JSON via `/export` or `Session.export_session/2`.
- **Import**: Import external `.lmml` or JSON session files directly using the `import_session` tool or `/import <path>`.
- **Clipboard Sync**: Copy the latest assistant response to the OS clipboard via `/cb` or `/clipboard`.

---

## 5. Scoped Prompt Rule Engine (`/rules`)

The Rule Engine manages persistent prompt preambles saved in `.yoke/rules.json`:

### Rule Scopes
- **`all:`**: Injected into the prompt preamble of every user turn (e.g. `all: typographic quotes “” mean exact quote`).
- **`<command>:`**: Injected only when running a specific command (e.g. `cr: format table cells multiline to fit 80 cols` for `/cr`).
- **Workflow Scopes**: Custom scopes injected during specific multi-step workflows.

### Commands
- `/rules`: List active rules.
- `/rules add <scope: text>`: Add a new rule.
- `/rules delete` / `/rules rm`: Launch an interactive TUI checkbox modal to delete rules.
- `/rules toggle <id>`: Enable or disable a rule by ID.

---

## 6. Interactive Questions & Permission Gates

### 1. Interactive Question TUI Modal (`ask_question`)
Allows the model to pause execution and present structured choices or request user feedback using a terminal modal:
- Single-choice and multi-choice support (`is_multi_select`).
- Write-in custom input option.
- Keyboard navigation (`Up`/`Down`, `1-9`, `Space` to select, `Enter` to submit).

### 2. God Mode (`/god`)
Auto-answers all model questions and confirmation prompts with recommended options, enabling unattended background execution.

### 3. Plan Approval Gate (`PlanGate`)
Hardcoded safety gate for non-trivial file modifications:
- Automatically detects when a turn contains $\ge 2$ file-modifying tool calls (`write_file`, `replace_file`, `edit_file`, or write-ish `bash` commands).
- Pauses execution and drafts a structured Markdown plan (`summary`, `steps`, `files`).
- Displays an approval modal (`Approve & execute`, `Request changes`, `Deny`).

### 4. Tool Execution Safety Modes (`/permissions`)
- `:ask_confirm` (Default): Requires interactive confirmation before running write-ish or destructive tools. Toggle anytime with **`Ctrl+P`**.
- `:auto_approve`: Executes tool batches automatically without confirmation prompts.

---

## 7. Concurrent Task Engine & Parallel Subagents

### 1. OTP Task Engine (`Orchestrator`)
- Concurrent tool batches execute under a supervised `Task.Supervisor`.
- Automatic per-file write locks prevent file corruption during parallel file writes.
- Live status bar indicator showing active background task workers.

### 2. Parallel Subagents (`spawn_subagent`, `/subagent`)
Spawns child session actors (`DynamicSupervisor`) to execute sub-tasks concurrently in parallel:
- **`async: true`** (Default): Fire-and-forget subagent execution. Returns immediately, appending the subagent's completed result to the main session upon finish.
- **`async: false`**: Synchronously waits for subagent completion and returns output directly.

---

## 8. Model Context Protocol (MCP) & Ragex Integration

### 1. Model Context Protocol (MCP) Client
Connect external MCP servers via `stdio` (JSON-RPC) or HTTP/SSE using `/mcp add <name> <command> [args...]` or `.yoke/config.json`.

### 2. Native Ragex Integration (`/ragex`)
First-class integration with **Ragex** (`@../ragex`) and database server **`dllb`**:
- **SCIP Code Indexing**: Cross-language symbol definition, caller, and reference graphs.
- **AST Pattern Search**: `metaast_search` and structural refactoring tools.
- **Code Quality & Security**: Dead code detection, coupling reports, circular dependency detection, and security auditing.
- **Ragex Image Processing Suite**:
  - `image_info`: Read image dimensions, color channels, and EXIF/metadata.
  - `image_resize`, `image_crop`, `image_rotate`: Perform transformations.
  - `image_convert`: Convert between PNG, JPEG, WebP, TIFF formats.
  - `image_apply_filter`: Apply blur, sharpen, brightness, or contrast adjustments.
  - `image_composite` & `image_draw_text`: Overlay graphics and render styled text onto images.
  - `image_compare`: Compute structural similarity index (SSIM) and visual diff maps.

---

## 9. Native Elixir Linters (`/linter`, `/lint`)

Run native Elixir static analysis tools directly from `yoke`:
- **`oeditus_credo`**: Enforces Oeditus coding standards.
- **`credo`**: Strict style and code consistency checks.
- **`propwise`**: Property-based test generator and contract checker.
- **`dialyzer`**: Success-typing static analysis.

Commands: `/linter <tool> [project|diff|cr] [args...]`

---

## 10. Customizable Workflows Engine (`/workflow`)

Executes multi-step automated workflows built on isolated Git Worktrees:

```
           ┌──────────────────────────────────────────────┐
           │              /workflow run elixir            │
           └──────────────────────┬───────────────────────┘
                                  │
      ┌───────────────────────────┼───────────────────────────┐
      ▼                           ▼                           ▼
┌───────────┐               ┌───────────┐               ┌───────────┐
│ Step 1:   │               │ Step 2:   │               │ Step 3:   │
│ Create    │──────────────►│ Task      │──────────────►│ Require   │
│ Branch    │               │ Split     │               │ Tests/Docs│
└───────────┘               └─────┬─────┘               └─────┬─────┘
                                  │                           │
                                  ▼                           ▼
                            ┌───────────┐               ┌───────────┐
                            │ Worktrees │               │ Lint &    │
                            │ Parallel  │               │ Commit    │
                            └───────────┘               └───────────┘
```

- **Isolated Git Worktrees**: Parallel workflow sub-tasks execute in isolated `git worktrees` and branches to prevent disk collisions.
- **Workflow State Persistence**: Runs persist state in `.yoke/workflows/<run_id>.json`, allowing status inspection (`/workflow status`) and resumption after failure (`/workflow resume`).
- **Scaffolding**: Create custom workflows via `/workflow init <name>`.

---

## 11. Distributed Erlang Node Execution (`/mode`)

Decouples where the Brain actor thinks from where the Hands executor operates:
- **`:local`**: Tools execute on the local filesystem (Default). Toggle workspace sandbox boundary with **`Ctrl+G`**.
- **`:docker`**: Tools execute inside a running Docker container (`/mode docker <container_id>`).
- **`:remote`**: Tools execute on a remote Erlang node cluster (`/mode remote hands@node_host`).

---

## 12. Configuration & Prompt Customization (`/config`)

Managed via `~/.yoke/config.json` or project-local `.yoke/config.json`:

```json
{
  "model": "deepseek-chat",
  "permission_mode": "ask_confirm",
  "max_tool_depth": 1000,
  "plan_gate_enabled": true,
  "plan_gate_threshold": 2,
  "prompt_style": "starship",
  "enable_autosuggestions": true,
  "enable_syntax_highlighting": true,
  "compact_status_bar": false
}
```

### Slash Commands
- `/config style <starship|extended|compact|minimal>`: Switch prompt styling.
- `/config toggle <key>`: Toggle UI options.
- `/config show`: Display active configuration keys.

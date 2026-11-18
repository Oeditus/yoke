# Yoke (Yoke) — Architecture & Design

Yoke is an autonomous, agentic CLI coding framework written in Elixir on Erlang/OTP. It pairs powerful LLM reasoning (DeepSeek-V3 and DeepSeek-R1) with BEAM actor concurrency, hot-code reloading, distributed execution, and spatiotemporal state checkpoints.

---

## High-Level Architecture Diagram

```mermaid
flowchart TD
    User([User TTY Terminal]) <--> REPL[CLI.Repl / LineEditor / QuestionPrompt]
    REPL <--> Brain[Brain.Session GenServer]
    
    subgraph Brain Layer
        Brain <--> Compressor[Brain.ContextCompressor]
        Brain <--> Store[Brain.SessionStore]
        Brain <--> Sup[Brain.SessionSupervisor]
        Sup --> Subagent[Brain.Session Subagent Actor]
    end
    
    subgraph Hands Layer
        Brain <--> HandsExec[Hands.Executor]
        HandsExec --> Local[Local OS Execution]
        HandsExec --> Remote[Remote Erlang Node via RPC]
        HandsExec --> Docker[Docker Sandbox Container]
    end
    
    subgraph Knowledge Graph & MCP
        Brain <--> MCPSrv[MCP.ServerManager]
        MCPSrv <--> Ragex[Ragex Knowledge Graph Engine]
        MCPSrv <--> ExtMCP[External MCP Servers over stdio]
    end

    Brain <--> APIClient[Client.DeepSeekAPI with Exponential Backoff Retry]
    APIClient <--> API[DeepSeek API Endpoint]

    subgraph Workflow Engine
        Workflow[Workflow.Engine] --> WDef[Workflow.Definition]
        Workflow --> WStore[Workflow.Store]
        Workflow --> WSteps[Workflow.Steps.*]
        WSteps --> Sup
        WSteps --> GitMod[Git worktrees/branches]
    end

    REPL <--> Workflow
```

---

## Core Components

### 1. Brain Layer (`lib/yoke/brain/`)
- **`Session` (`GenServer`)**: Manages conversation context state, model selection, permission authorization gates, temporal state snapshots, and turn execution loops. Each turn runs in its own supervised `Task` so the actor stays responsive to `cancel_current_turn/1` (Ctrl+Q) and to any other call for the turn's whole duration; a crashed or cancelled turn always replies to its waiting caller.
- **`SessionSupervisor` (`DynamicSupervisor`)**: Dynamically spawns and monitors interactive user sessions and subagent worker actors.
- **`ContextCompressor`**: Summarizes long context histories when token limits or `/compact` commands are triggered.
- **`ConfirmationSummary`**: Pure renderer for the permission modal. Every clause truncates, so a tool with a large argument payload cannot produce an unreadable wall of text before the user approves it.
- **`MessageRepair`**: Pure list transforms that restore the provider's tool-call contract (`repair/1`) and, as a last resort, flatten every tool role into a user message (`flatten_tool_roles/1`). A broken sequence otherwise makes the provider reject the entire request with HTTP 400.

### 2. Hands Layer (`lib/yoke/hands/`)
- **`Executor`**: Dispatches tool calls across execution targets (`:local`, `:remote` Erlang nodes, `:docker` container sandboxes, and `:ci`). Enforces workspace sandbox bounds when `/sandbox` is enabled. In `:ci` mode it is read-only by policy: every write-capable tool **and every shell-executing tool** is refused unless `.yoke/policy.json` sets `"allow_writes": true`. Shells are refused outright rather than classified, because no substring heuristic can decide whether an arbitrary command writes.

### 3. Knowledge Graph & MCP (`lib/yoke/mcp/`)
- **`ServerManager`**: First-class supervisor for the `Ragex` code intelligence engine and external Model Context Protocol (MCP) servers over stdio JSON-RPC. Automatically builds dynamic Elixir tool modules for live hot-code tool access.

### 4. Client Layer (`lib/yoke/client/`)
- **`DeepSeekAPI`**: Handles REST communications with `deepseek-chat` (V3) and `deepseek-reasoner` (R1) API endpoints with automatic exponential backoff retry for transient network and rate-limit HTTP errors. Deterministic failures (HTTP 401, 403, and other 4xx responses) are not retried; they surface immediately with a message naming the cause, because repeating the same rejected request cannot succeed.

### 5. CLI & TUI Layer (`lib/yoke/cli/`)
- **`LineEditor`**: Fixed bottom command bar TUI with horizontal ruler, grapheme-aware Unicode cursor navigation, and persistent history.
- **`QuestionPrompt`**: In-place interactive terminal modal for single-choice and multi-choice questions with multi-line text wrapping and pixel-perfect border alignment.

### 6. Workflow Engine (`lib/yoke/workflow/`)
- **`Definition`**: Parses/validates customizable, JSON-defined multi-step workflows; two-tier discovery (workspace + global) plus bundled defaults (`elixir`), materialized on first use.
- **`Store`**: Disk persistence for workflow runs under `.yoke/workflows/runs/<id>/` -- resumable `state.json` checkpoint plus an append-only `transcript.jsonl` of every prompt, response, confirmation, and command.
- **`Engine`**: Drives step execution/resume; a plain module (not a `GenServer`) that blocks the caller synchronously like a regular agent turn, delegating genuine parallelism to real `Brain.Session` processes for accepted subtasks.
- **`Steps.*`**: One module per step type (`Branch`, `TaskDescription`, `TaskSplit`, `TestsAndDocs`, `Lint`, `Commit`, `Prompt`) behind a common `Workflow.Step` behaviour. `TaskSplit` isolates parallel subtasks in their own `git worktree` so concurrent agents can never clash on disk. See [`docs/WORKFLOW_ENGINE.md`](WORKFLOW_ENGINE.md) for the full reference.

### 7. Cross-Cutting Infrastructure
- **`AIGuard` / `AIGuard.AuditLog`**: Dual-seam guardrail (LLM input/output, tool arguments) plus a single-writer JSONL audit sink. The writer is a supervised process so the audit trail lands in the *session's* workspace rather than the VM's working directory, and so concurrent tool calls cannot interleave partial lines.
- **`Interaction`**: The blocking seam. `TTY` renders the interactive modal; `Policy` answers immediately from `.yoke/policy.json` and fails closed. Selected once at startup, so no call site branches per call.
- **`UUID`**: Single home for `v4/0` (random) and `v7/0` (time-ordered). Session ids and CI run uids previously came from four byte-identical copies.

### Supervision strategy
`Yoke.Application` uses `:rest_for_one` with children ordered least- to most-critical. A crash in a collector (`BashTracker`, `AIGuard.AuditLog`) restarts only the children after it; a crash in the task engine or a session supervisor still restarts the session tree, which is the part that genuinely depends on it. Under the previous `:one_for_all` a statistics-collector crash dropped every live conversation.

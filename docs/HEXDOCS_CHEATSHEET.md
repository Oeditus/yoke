# Yoke (Yoke) Cheatsheet

> Quick reference guide for **Yoke (`yoke`)**, formatted in the standard HexDocs cheatsheet layout.

---

## Command Line Invocation

### Launch Modes & CLI Flags

```bash
# Start interactive REPL in current directory
yoke

# Resume a specific session by UUID
yoke -c df97eb34-cb33-4f21-bada-2e9c3cf75d46
yoke --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46

# Execute a one-shot prompt
yoke "Analyze project architecture in @mix.exs"

# Specify model alias for execution
yoke -m deepseek-coder "Fix syntax error in @lib/worker.ex"
yoke --model deepseek-reasoner "Diagnose deadlock in @lib/session.ex"

# Run background release update to latest commit
yoke --update

# Display CLI help
yoke --help
```

### CLI Flag Reference

| Flag | Short | Description |
| :--- | :--- | :--- |
| `--conversation <id>` | `-c <id>` | Resume a persisted session by ID |
| `--resume <id>` | `-r <id>` | Alias for `--conversation` |
| `--prompt <str>` | `-p <str>` | Input prompt string for one-shot mode |
| `--model <name>` | `-m <name>` | Model alias (`chat`, `coder`, `reasoner`) |
| `--update` | `-u` | Background in-place self-update |
| `--node <name>` | — | Start local Erlang distributed node |
| `--connect <node>`| — | Connect to remote Erlang Hands worker node |
| `--plugin <path>` | — | Load external Elixir script plugin (`.ex` / `.exs`) |

---

## REPL Keyboard Shortcuts & Hotkeys

### Global Navigation & Toggles

| Shortcut | Description |
| :--- | :--- |
| `Ctrl+P` | Toggle tool safety mode (`ask_confirm` ⇄ `auto_approve`) |
| `Ctrl+G` | Toggle workspace sandbox bounds mode |
| `Ctrl+B` | Toggle idle status bar mode (gauge bar ⇄ compact status line) |
| `Ctrl+O` | Toggle tool call expansion mode (collapsed ⇄ full text) |
| `Ctrl+Q` | Interrupt active AI turn while responding |
| `Tab` | Autocomplete slash commands and file paths |
| `Ctrl+R` | Search command input history |
| `Right Arrow` | Accept ghost auto-suggestion completion |
| `Ctrl+A` / `Home` | Move cursor to beginning of line |
| `Ctrl+E` / `End` | Move cursor to end of line |
| `Ctrl+U` | Delete from cursor to start of line |
| `Ctrl+K` | Delete from cursor to end of line |
| `Ctrl+W` | Delete word backward |
| `Ctrl+D` | Signal EOF / exit REPL |

---

## Prompt Modifiers & Shortcuts

### Context References & Direct Commands

```elixir
# @ File & Context Expansion
@lib/my_app.ex           # Attach full content of a file
@https://raw.github...   # Attach content from a URL
@error                   # Intelligently resolve recent error traceback

# ! Direct Shell Execution (bypasses LLM)
!git status              # Execute shell command directly
!mix test                # Run test suite directly

# !! Pure Console Mode (Flip-Flop)
!!                       # Enter pure shell passthrough mode (cd persists)
!!                       # Exit pure shell passthrough mode, return to Yoke
```

---

## REPL Slash Commands

### Session & Model Controls

| Slash Command | Description | Example |
| :--- | :--- | :--- |
| `!!` | Flip into/out of pure console mode | `!!` |
| `/model <alias>` | Switch active model (`chat`, `coder`, `reasoner`) | `/model reasoner` |
| `/mode <target>` | Set Hands target (`local`, `docker <id>`, `remote <node>`) | `/mode docker container_1` |
| `/resume [id]` | Resume session or open session picker modal | `/resume` |
| `/compact` | Compress conversation history to save tokens | `/compact` |
| `/undo` | Roll back state to previous temporal checkpoint | `/undo` |
| `/checkpoint [lbl]` | Create temporal snapshot with label | `/checkpoint "Pre-refactor"` |
| `/permissions [mode]`| Set tool safety mode (`auto` or `ask`) | `/permissions auto` |
| `/god [on\|off]` | Toggle God Mode auto-answering | `/god on` |
| `/cost` \| `/tokens` | Display token consumption and cost statistics | `/cost` |
| `/reset` | Clear context memory, checkpoints, and screen | `/reset` |
| `/cb` \| `/clipboard`| Copy latest AI response to clipboard | `/cb` |
| `/clear` | Clear terminal screen | `/clear` |
| `/exit` \| `/quit` | Exit harness REPL | `/exit` |

---

## Code Review & Static Analysis

### Git & Code Audit Commands

```bash
# Branch Code Review
/cr                     # Compare active branch against default 'main'
/cr origin/main         # Compare active branch against custom base branch

# Workspace & Branch Diffs
/diff                   # View colorized diff of unstaged/staged changes
/diff main              # View colorized diff against target branch

# Commit & Git Shortcuts
/commit "feat: add user auth"  # Stage all modified files and commit
/git status             # Execute git subcommand via helper

# Native Elixir Linters
/linter credo           # Run Credo static analysis on project
/linter oeditus_credo   # Run Oeditus strict rules
/linter dialyzer diff   # Run Dialyzer analysis on active diff
```

---

## Scoped Rule Engine (`/rules`)

### Scope Syntax & Management

```bash
# Scope Formats
all: <text>             # Applied to ALL prompt turns
<command>: <text>       # Applied ONLY when executing specific command

# Rule Commands
/rules                  # List active rules and preambles
/rules add all: Prefer pattern matching over if/else
/rules add cr: Highlight security vulnerabilities first
/rules delete           # Launch interactive TUI checkbox modal to delete rules
/rules toggle <id>      # Enable/disable rule by ID
```

---

## Model Context Protocol (MCP) & Ragex

### MCP & Code Intelligence Commands

```bash
# MCP Server Management
/mcp list               # List all active MCP servers and registered tools
/mcp add <name> <cmd>   # Connect stdio MCP server

# Ragex Integration
/ragex                  # Mount Ragex code analysis MCP server
/ragex stats            # View knowledge graph statistics

# Ragex Image Tools
# - mcp_ragex_image_info         : Get image dimensions & EXIF metadata
# - mcp_ragex_image_resize       : Resize image with quality presets
# - mcp_ragex_image_crop         : Crop bounding box
# - mcp_ragex_image_convert      : Convert formats (PNG, JPEG, WebP, TIFF)
# - mcp_ragex_image_apply_filter : Apply blur, sharpen, brightness/contrast
# - mcp_ragex_image_composite    : Composite overlay images
# - mcp_ragex_image_draw_text    : Render styled text on image
# - mcp_ragex_image_compare      : Compute SSIM visual diff map
```

---

## Subagents & Workflows

### Background Delegation & Workflows

```bash
# Parallel Subagents
/subagent "Scan codebase for deprecated function calls"

# Workflows Engine
/workflow list          # Discover built-in and custom workflows
/workflow run elixir    # Run bundled Elixir workflow
/workflow status        # Inspect workflow run state
/workflow resume <id>   # Resume interrupted workflow run
/workflow abort <id>    # Abort workflow run
/workflow init <name>   # Scaffold new custom workflow definition
```

---

## Configuration Settings (`.yoke/config.json`)

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

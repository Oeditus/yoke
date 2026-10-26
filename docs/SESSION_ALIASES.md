# Session Command Aliases

Yoke allows you to declare reusable **session aliases** that execute a prepared command (or sequence of commands) sequentially within the current active session.

Aliases can combine shell commands (`!command`), native Yoke slash commands (e.g. `/diff`, `/linter`, `/commit`), and natural-language LLM agent prompts while preserving session memory and context.

---

## 1. Where Aliases Are Declared

Aliases are discovered and merged with workspace overrides taking precedence:

1. **Workspace Aliases**: `.yoke/aliases.json` (or `.yoke/config.json` under `"aliases"`)
2. **Global User Aliases**: `~/.yoke/aliases.json` (or `~/.yoke/config.json` under `"aliases"`)
3. **Built-in Defaults**: Initialized automatically if no alias configuration exists.

---

## 2. Invocation

You can execute declared aliases in multiple convenient ways:

```bash
# Direct slash command invocation
/finish

# Passing arguments/files to the alias
/finish lib/yoke/aliases.ex lib/yoke/cli/repl.ex

# Using flags such as --commit-only or -c
/finish --commit-only

# Explicit runner syntax
/alias run finish
/alias run finish lib/my_file.ex
```

In the interactive REPL, pressing `Tab` on `/` or `/alias ` provides full autocompletion for all declared alias names and subcommands.

---

## 3. Alias Definition Format

An alias can be defined as a single string, a list of commands, or an object with descriptions:

### Object Format (Recommended)
```json
{
  "finish": {
    "description": "Commit staged changes and create structured PR (supports --commit-only)",
    "commands": [
      "{{#if_args}}!git add {{args}}{{/if_args}}",
      "Please inspect the staged git changes (`git diff --cached`). First run `mix format` if applicable to ensure clean code formatting. Then create a git commit with a comprehensive commit message explicitly structured into the following sections:\n- **The PR reason**: Why this change is made and what issue or motivation drives it.\n- **Implementation**: Architectural details, key design decisions, and components modified.\n- **How to verify**: Exact test commands executed or reproduction steps to verify functionality.\n- **Risk & rollout**: Blast radius, potential risks, dependencies, or rollback instructions.\n- **Reviewer guidance**: Specific areas, critical files, or subtle logic where reviewer attention is needed.\n{{#if_commit_only}}Commit the changes with this message only; do not open a pull request.{{/if_commit_only}}{{#unless_commit_only}}After committing, create a GitHub pull request using `gh pr create` with the title matching the commit summary line and the body containing the exact same structured sections.{{/unless_commit_only}}"
    ]
  }
}
```

### Short Key-Value Format
```json
{
  "check": "!mix test",
  "status-diff": ["!git status", "/diff"]
}
```

---

## 4. Parameter Placeholders & Conditionals

When an alias is invoked with arguments (e.g. `/finish lib/app.ex --commit-only`):

| Placeholder | Meaning |
| :--- | :--- |
| `{{args}}`, `$@`, `$*` | Clean argument string with flags stripped |
| `$1`, `$2`, `{{arg1}}` | Positional arguments |
| `{{#if_args}}...{{/if_args}}` | Included only when arguments were supplied |
| `{{#unless_args}}...{{/unless_args}}` | Included only when no arguments were supplied |
| `{{#if_commit_only}}...{{/if_commit_only}}` | Included when `--commit-only` or `-c` is present |
| `{{#unless_commit_only}}...{{/unless_commit_only}}` | Included when `--commit-only` or `-c` is omitted |

If a command line evaluates to empty or whitespace (such as `{{#if_args}}!git add {{args}}{{/if_args}}` when no files were specified), it is automatically skipped.

---

## 5. Built-in PR & Commit Aliases

Yoke comes with preconfigured aliases for structured commits and pull requests:

### `/finish` (or `/pr`)
- **Staging**: If files are provided (`/finish lib/foo.ex`), stages them with `git add`. If files were already added manually (`git add ...`), running `/finish` uses the currently staged files.
- **Commit Message**: Formats code and writes a comprehensive commit message explicitly detailing:
  1. **The PR reason**
  2. **Implementation**
  3. **How to verify**
  4. **Risk & rollout**
  5. **Reviewer guidance**
- **Pull Request**: Opens a GitHub PR using `gh pr create` with matching sections.
- **Commit-Only Option**: Pass `--commit-only` or `-c` (`/finish --commit-only` or `/finish lib/foo.ex -c`) to commit changes without creating a PR.

### `/commit-structured` (or `/cpr`)
- Dedicated alias that creates the commit with the 5 structured sections without opening a PR.

---

## 6. Managing Aliases via REPL

```
/alias                         # List declared aliases
/alias list                    # List declared aliases
/alias show <name>             # Inspect alias commands & details
/alias add <name> <command>    # Add a single-command alias
/alias rm <name>               # Delete an alias from .yoke/aliases.json
/alias run <name> [args]       # Execute an alias
/<name> [args]                 # Direct shortcut to execute an alias
```

# Yoke — Troubleshooting Guide

Common diagnostic procedures for Yoke CLI and runtime issues.

---

## 1. DeepSeek API Key Issues
**Symptom**: `AI configuration validation failed: API key not set`
**Resolution**:
Export your DeepSeek API Key before launching Yoke:
```bash
export DEEPSEEK_API_KEY="sk-..."
yoke
```

---

## 2. Line Boundary Mismatch Error on `edit_file` / Ragex
**Symptom**: `Validation Error: Code changes produced invalid Elixir syntax: unexpected reserved word: "end"`
**Resolution**:
This occurs when `line_start` or `line_end` in `edit_file` extends past block boundaries (clipping or duplicating `def`, `do`, or `end` keywords). Inspect the line numbers of the function in your target file and pass the exact span to `edit_file`.

---

## 3. Remote Node Connection Failures
**Symptom**: `Remote node unreachable: nodedown`
**Resolution**:
Ensure both nodes share the exact same Erlang cookie and host configuration:
```bash
# On Hands host:
elixir --sname hands@127.0.0.1 --cookie secret_yoke_cookie -S mix run --no-halt

# On CLI Brain host:
yoke --node brain@127.0.0.1 --connect hands@127.0.0.1
```

---

## 4. MCP Server Stdio Timeouts
**Symptom**: `Failed to fetch tools/list from MCP server`
**Resolution**:
Check that the MCP server binary is executable and installed in system `$PATH`. Test manual execution via `/mcp list` or inspect `.yoke/config.json`.

---

## 5. `/import` rejects a Markdown export
**Symptom**: `'...' is a Markdown export, which is for reading, not re-importing.`
**Cause**: `/export markdown` runs the session narrative through `Lmml.to_md/2`,
which strips the `@@@` embeds the importer relies on. The result is a readable
document, not a resumable session.
**Resolution**: Use `/export lmml` (or `/export lmmlz` when images are attached)
to produce a resumable file, then `/import` that. `/export` with no argument now
defaults to `lmml` for this reason.

---

## 6. `yoke review --dry-run` reports a diff over the cap
**Symptom**: `This diff exceeds the cap and the real run would fail.`
**Cause**: The review diff is larger than `max_diff_bytes` (default 300 KB,
configurable in `.yoke/policy.json`). The real run refuses to generate a partial
review rather than reviewing a truncated diff.
**Resolution**: Raise `max_diff_bytes` in `.yoke/policy.json`, pass
`--max-diff-bytes <n>` for a one-off run, or narrow the commit range.

---

## 7. A tool call times out with no visible cause
**Symptom**: The spinner stops, the model narrates a retry, and nothing explains
the pause.
**Cause**: A tool call exceeded its per-call budget (60 s by default) and was
stopped. The terminal now shows `Tool '<name>' exceeded its Ns budget and was
stopped.` when a TTY is attached.
**Resolution**: For a command that legitimately needs longer, re-run it with
`async: true` so it becomes a background job; for a long-lived server or watcher,
use `async: true` as well rather than blocking the turn.

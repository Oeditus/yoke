# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.31.1] - 2026-11-25

### Added

- **Bounded provider retry budget and request-size diagnostics**: Added `Yoke.Client.RetryBudget` to enforce a single cumulative per-turn budget (`max_attempts`, `total_timeout_ms`, `max_backoff_ms`, and an `identical_failure_limit` circuit breaker) across both `Yoke.Client.DeepSeekAPI` and `Yoke.Brain.Session`, configurable via session options and `api_retry_*` keys in `Yoke.Config` (fixes #22). Added `Yoke.Client.RequestDiagnostics` to attach metadata-only payload metrics (serialized bytes, message count, largest message, and tool-definition bytes) to retry logs and final errors, and surfaced current-turn retry consumption in `/cost`.

### Fixed

- **Misleading zero-file `/audit` results for nested projects**: `Yoke.Audit` now resolves the audited root before measuring. When the given directory holds no project root, the single nested project below it is audited instead (`Yoke.Audit.resolve_root/2`), several nested projects are reported as ambiguous rather than guessed, and an explicit `--root <dir>` (or `:root` option) selects one directly. The facts gained a **Scope** block that names the audited root, records every unmeasurable fact (empty scan, no project root, non-Git directory), and the prompt forbids reading a zero-file scan as a clean project. `format_facts/1` no longer claims "every source file has a matching test file" when no source files were found, and `/audit` prints an explicit warning when nothing was scanned.

## [0.31.0] - 2026-11-25

### Added

- **`yoke fix --from-review`**: Applies findings from a `yoke review` JSON artifact directly to the local working tree (`Yoke.CI.FixFromReview`), supporting `--dry-run`, clean-checkout and `head_sha` verification via `Yoke.PRReview.Context.verify_fix_checkout/2`, worst-first severity ordering, and endorsement filtering without auto-committing or pushing.
- **Yoke Cloud client, precision measurement, and baseline suppression**:
  - `Yoke.Cloud.Client` and `yoke report --upload` to upload CI review artifacts (fail-open; warns and exits `0` on non-fatal errors).
  - `Yoke.Cloud.Baseline` for fail-open, severity-bounded, auditable suppression of consistently ignored findings during CI reviews (suppressed items are recorded under `"suppressed"` in the review artifact).
  - `Yoke.Cloud.Outcome`, `Yoke.Cloud.GitHub` (GraphQL thread resolution and reaction evidence), and `scripts/precision_report.exs` to measure review precision on merged pull requests.
  - `Yoke.Cloud.Scoring` implementing Laplace-smoothed precision scoring (`promote` / `suppress` / `observe`) and baseline generation.
  - Design and CI documentation in `docs/YAAS.md` and `docs/CI.md`.
- **Cross-project conversation history in `/explorer`**: Track known project directories (`Yoke.Brain.SessionStore.register_project_dir/2`, `known_project_dirs/1`), store project labels in `Yoke.Brain.SessionMetadata`, render a tabular conversation list, and toggle between current-project and all-project conversations.

### Changed

- **Reject self-retracting review findings**: Added self-critique rule 11 to `Yoke.PRReview` prompt instructions and parse-time rejection in `Yoke.PRReview.Findings` so findings whose text withdraws themselves (e.g., "withdrawn.", "this is fine", "no action needed") never reach reports or pull request annotations.
- **Outcome classification precedence**: Reordered `Yoke.Cloud.Outcome` to prioritize explicit human signals (`reaction` > `resolved` > `review_fix` commit > `line movement`).

### Fixed

- **Malformed JSON in tool-call responses**: Hardened `Yoke.Client.DeepSeekAPI` against malformed, double-encoded, non-object, and truncated (`finish_reason: "length"`) tool-call arguments, with automatic recovery retries in `Yoke.Brain.Session`.
- **Tool subprocess `PATH` and ERTS environment leakage**: Captured `YOKE_ORIG_PATH` in the `yoke` launcher and sanitized `PATH` and ERTS/release variables (`RELEASE_*`, `ROOTDIR`, `BINDIR`, `EMU`, `PROGNAME`) in `Yoke.Hands.Environment` so spawned tools reliably resolve host executables.
- **Conversation loading in `/explorer`**: Fixed pagination guards, background loader cancellation (`cancel_loading/1`), and fast prefix-based LMML metadata extraction with legacy fallback.
- **Precision measurement accuracy**: Fixed GraphQL reaction parsing (`THUMBS_UP`/`THUMBS_DOWN`), `originalLine` anchoring fallback, merge-commit diff range (`<merge>^1..<merge>`), and legacy `**[HIGH]**` severity badge detection in `Yoke.Cloud.Outcome`, `Yoke.Cloud.GitHub`, and `scripts/precision_report.exs`.

## [0.29.0] - 2026-11-23

### Added

- **Cross-language MetaCredo linting**: Integrated MetaCredo (`metacredo`, aliases `meta_credo` / `meta-credo`) into `Yoke.Linter` and `run_linter` for ~70 security, warning, design, readability, and refactoring checks across Elixir, Go, JS/TS, Rust, Python, Ruby, and more.
- **Go linting and syntax checks**: Added `go vet` support in `Yoke.Linter` and Go syntax validation in `Yoke.Plugin.DefaultTools`.
- **Explicit user-question enforcement**: Added opt-out enforcement (`Yoke.Config.explicit_questions_enabled?/1`, `Yoke.Brain.AgentLoop.contains_implicit_question?/1`, `Yoke.Brain.Session.set_explicit_questions/2`, and `/config toggle` in the REPL) to nudge the agent to ask explicit clarifying questions via `ask_user` when uncertain.
- **LFE dependency**: Added `{:lfe, "~> 2.2"}` to `mix.exs`.

### Changed

- **Metastatic, MetaCredo, and Ragex alignment**: Updated `:ragex` to `~> 0.46`, updated `.metacredo.exs`, added `mcp_ragex_metacredo_analyze` guidance to `Yoke.Brain.Session` and `Yoke.BashTracker`, and adjusted PR review markdown formatting in `Yoke.PRReview.Markdown`.

## [0.28.0] - 2026-11-21

### Added

- **Cached session metadata**: Added `Yoke.Brain.SessionMetadata` to extract and cache lightweight session listing metadata for LMML, JSON, and ZIP-backed session files without decoding full conversation narratives.
- **Lazy-loaded conversation pagination**: Added paginated lazy loading for conversations in `/explorer` (`Yoke.CLI.ConfigExplorer.load_sessions_page/2`) along with `Page Up` / `Page Down` pager navigation in `Yoke.CLI.QuestionPrompt`.

### Changed

- **Event-driven lock waiting and job monitoring**: Replaced polling-based resource lock waiting in `Yoke.TaskEngine.Orchestrator` with `Registry`-dispatched `{:lock_released, resource_key}` notifications and improved process `:DOWN` monitoring in `Yoke.TaskEngine.JobManager`.
- **LMML 0.3 integration**: Updated `:lmml` to `~> 0.3` and streamlined LMML narrative-to-Markdown export in `Yoke.Brain.Session` and `Yoke.Brain.SessionLmml`.

[0.31.1]: https://github.com/Oeditus/yoke/compare/v0.31.0...v0.31.1
[0.31.0]: https://github.com/Oeditus/yoke/compare/v0.29.0...v0.31.0
[0.29.0]: https://github.com/Oeditus/yoke/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/Oeditus/yoke/compare/v0.27.0...v0.28.0

# Elixir/Erlang Analysis Tooling: Typle, ExPanda, Prisma

> **Status:** research + empirical verification. Every claim marked ✅ was executed against this
> repo (Elixir 1.20.4-otp-29, `deps/ex_panda` 0.2.2, `deps/metastatic` 0.33.1,
> `deps/ragex`). Claims marked ⚠️ are reasoned but unverified.

**Question:** can these three libraries enhance Elixir/Erlang support in `yoke` (and/or `ragex`)?

**Answer in one line:** yes, all three — but they sit at *three different layers*, and only one of
them (ExPanda) is a genuinely low-risk, high-value win. Typle is gated on an Elixir version we
already satisfy and gives us something no Elixir tool has ever had (per-expression inferred
types). Prisma is the strongest *product* of the three but is the worst *fit* for an embedded
library, because it is a rebar3-first CLI that only exposes Mix tasks.

**Headline finding:** `ex_panda` is **already a transitive dependency** (via `metastatic`) and
Metastatic **already exposes** `:expand_macros`. Ragex's `:full` expansion mode is **verified dead
code** — it returns the AST byte-for-byte unchanged. So the highest-value work here is not adding
a dependency; it is **wiring up a capability we already ship and pay for**.

---

## 0. TL;DR matrix

| | **ExPanda** | **Typle** | **Prisma** |
|---|---|---|---|
| Layer | AST / macro expansion | Type inference (Elixir) | Type + dead-code analysis (BEAM) |
| Form factor | Library | Library + 2 mix tasks | **rebar3 plugin** + mix tasks + escript |
| Programmatic API | ✅ `expand/2`, `expand_string/2`, `expand_file/2`, `expand_to_string/2` | ✅ `type_at/4`, `types_for/2`, `types_for_file/2`, `signatures/2`, `return_type/4` | ❌ only `run/1` mix task + CLI; **no public API** |
| Needs compiled beams | ❌ (source/AST only) | ✅ for `signatures/return_type`; ❌ for `type_at` | ✅ **required** — analyzes `_build/*/ebin` |
| Needs running app / deps loaded | ⚠️ for `use` expansion of 3rd-party macros (verified: `GenServer` ✅, `Ecto.Schema` ❌) | ⚠️ same (it calls ExPanda) | ✅ full compile + PLT-like `.pplt` |
| Elixir/OTP floor | `~> 1.18` | **`~> 1.20`** | any (Erlang-first) |
| Maturity | 0.2.2, stable, in our tree | **0.3.1, released 2026-05-06, 822 downloads total** | **0.1.0, single release, 0 downloads** |
| Already in our tree? | ✅ **yes** (transitive via `metastatic`) | ❌ | ❌ |
| Risk | **Low** | Medium (young, private-API dependent) | **High** (alpha, CLI-only, needs build) |
| Verdict | **Integrate now** | **Prototype behind a flag** | **Shell out, optional, dev-only** |

---

## 1. ExPanda — the one that matters most, and it's already here

### What it is

Full macro expansion for Elixir AST. `Code.string_to_quoted/1` gives you the *surface* AST —
`|>`, `unless`, `use GenServer`, Ecto `schema` and Phoenix macros all stay as opaque calls.
ExPanda resolves them to real `case`/remote-call forms while **preserving `defmodule` and
`def`/`defp` structure**:

```elixir
{:ok, expanded} = ExPanda.expand_string("1 |> to_string() |> String.upcase()")
# => {{:., _, [String, :upcase]}, _, [{{:., _, [String.Chars, :to_string]}, _, [1]}]}
```

Mechanism (from `deps/ex_panda/lib/ex_panda/walker.ex`):
1. `:elixir_expand.expand/3` — the compiler's *internal* expansion engine (primary).
2. `Macro.expand/2` — public fallback.
3. Direct `MACRO-__using__/2` invocation for `use`, bypassing the compiler's ETS module table
   so `use GenServer` works inside a `defmodule` without full compilation.

Unexpandable nodes are preserved and tagged with an `@unexpanded` attribute rather than
crashing — graceful degradation, which matters a lot for a tool that must analyze arbitrary
user code.

### The key discovery: we already depend on it, and the wiring already exists

- `mix.lock` line 43: `metastatic 0.33.1` depends on `{:ex_panda, "~> 0.2", optional: false}`.
- `deps/ex_panda` is present (v0.2.2).
### Where ragex is currently weak — **verified**

`deps/ragex/lib/ragex/analyzers/elixir.ex` is the main Elixir analyzer, and its macro handling is
the weak spot:

```elixir
expand_macros = Keyword.get(opts, :expand_macros, :partial)   # line 13
```

- `:none` → raw surface AST.
- `:partial` (**the default**) → `expand_common_macros/1`, which only rewrites `defdelegate`
  (line ~455). Everything else is untouched.
- `:full` → `expand_with_compilation/1` (line 507), which builds a **hand-rolled, essentially
  empty `%Macro.Env{}`** and calls `Macro.expand/1` on the *whole file AST*:

```elixir
env = %Macro.Env{
  file: file_path, line: 1, module: nil, function: nil, context: nil,
  requires: [], aliases: [], functions: [], macros: [],
  macro_aliases: [], context_modules: [], lexical_tracker: nil, tracers: []
}
Macro.expand(ast, env)   # rescue -> expand_common_macros(ast)
```

**✅ Verified defect: `:full` is a no-op.** `Macro.expand/2` on a top-level `defmodule` node with
no `requires`/`aliases`/`functions`/`macros` returns the AST *unchanged*:

```
Macro.expand(defmodule_ast, empty_env) == ast   # => true
```

Because the top-level node is a `defmodule`, `Macro.expand/2` does not descend into the body at
all — so `:full` produces **byte-identical results to `:none`**. Measured on a module with
`use GenServer` + a pipe + a plain call, `:full` and `:none` returned the same calls and the same
functions. **`:full` is dead code today.**

**✅ Verified defect: piped calls lose their arity.** This is a real bug I initially mis-stated —
piped calls *are* captured (the `{:|>, ...}` node's children are traversed, and the inner
`Repo.insert()` is a normal remote call), but the recorded arity is wrong:

| source | recorded call |
|---|---|
| `d |> Repo.insert()` | `{Repo, :insert, **0**}` ❌ |
| `Repo.insert(d)` | `{Repo, :insert, **1**}` ✅ |

Why: `data |> Repo.insert()` parses as `{:|>, _, [{:data,_,nil}, {{:.,_,[Repo,:insert]},_,[]}]}` —
the remote call node has **zero arguments** (the piped value is supplied by `|>` itself), so
`length(args)` is `0`. Every piped call in a codebase gets a wrong arity, which corrupts call-graph
edges, `find_callers`, and arity-based refactoring. ExPanda fixes this for free because it
*desugars* the pipe into `Repo.insert(data)` with one real argument.

**✅ Verified defect: `use`-injected definitions are invisible.** For
`defmodule T do use MyDSL end` where `MyDSL.__using__/1` injects `def injected_helper(x)`,
ragex with `expand_macros: :full` reports **`T functions: []`**. The generated function is never
seen. Same for `use GenServer` (no `child_spec/1`, no `init/1`), `use Ecto.Schema` (no struct,
no fields), and every Phoenix/Absinthe/router DSL.

**✅ Verified defect: `Metastatic.Cache` does not key on expansion mode.**
`Metastatic.Cache.get/2` and `put/4` take only `(adapter, source)`
(`deps/metastatic/lib/metastatic/cache.ex:77,85`). If we turn `:expand_macros` on, the same source
string returns whichever document was cached first. Any integration must fold the expansion mode
into the key or bypass the cache.

**✅ Verified: ExPanda fixes all three.** Executed against `deps/ex_panda`:

```elixir
# pipe → fully desugared, correct arity
ExPanda.expand_string("data |> Repo.insert()")
# => {{:., _, [Repo, :insert]}, _, [{:data, _, nil}]}      ← 1 real argument ✅

# use GenServer → callbacks materialised
expand_string("defmodule S do\n  use GenServer\nend")
# => require GenServer; @behaviour GenServer;
#    def child_spec(init_arg) do ... end;  @before_compile GenServer;
#    def handle_call(msg, _from, state) do ... end;  ...   ✅

# unloaded module → graceful, not a crash
expand_string("defmodule S do\n  use Ecto.Schema\nend")
# => defmodule S do
#      @unexpanded "use/1: use: module Ecto.Schema is not available"
#      use Ecto.Schema
#    end                                                    ✅ degrades safely
```

Note the last case: `use GenServer` works because Elixir's stdlib is always loaded, but
`use Ecto.Schema` does **not** unless the project's deps are compiled and loaded. This is the
central limitation to design around (see open question 1).

### Recommended integration (concrete)

**Step 1 — route ragex's Elixir analyzer through the existing Metastatic expander.**

Replace `expand_with_compilation/2` with a call to the adapter that already exists:

```elixir
# deps/ragex/lib/ragex/analyzers/elixir.ex
defp expand_with_compilation(ast, file_path) do
  case Metastatic.Adapters.Elixir.MacroExpander.expand_and_annotate(ast, file: file_path) do
    {:ok, annotated} -> annotated
    {:error, _} -> expand_common_macros(ast)   # keep graceful fallback
  end
end
```

This is a ~5-line change that turns `:full` from dead code into a working mode, and it inherits
the `__original_macro__` annotations so downstream rendering can still show the user's original
source. It also removes the hand-rolled `%Macro.Env{}` bug.

**Step 2 — add a `:partial` that actually expands something.**

`:partial` should mean "expand what is safe without loading the world": `|>` desugaring, `unless`,
`if`/`cond`/`with` special forms, and `use` for modules that *are* loaded. This is exactly
ExPanda's default behaviour. Suggested semantics:

- `:none` — surface AST (fast, current behaviour, keep for perf-sensitive bulk indexing).
- `:partial` — `ExPanda.expand/2` with a fresh env; unexpandable nodes tagged `@unexpanded`.
- `:full` — `ExPanda.expand/2` with the **caller's** `__ENV__` so project macros resolve.

**Step 3 — teach the analyzer to see through the expansion.**

Once pipes expand to remote calls, the existing `{{:., _, [mod, fun]}, _, args}` clause starts
catching them **with the correct arity**. But three new things need handling:
- `@unexpanded` markers must be **skipped, not counted** as calls or attributes (otherwise every
  module using an unavailable DSL grows a phantom `@unexpanded` attribute node).
- Expanded `use` bodies inject `def` nodes the user never wrote. These must be attributed to the
  *macro* (via `:original_macro`) rather than reported as user-authored functions, or every
  module using a DSL will appear to have phantom functions at the `use` line.
- `use` expansion also injects `@behaviour`, `@before_compile` and `defoverridable` nodes. The
  analyzer should record `@behaviour` (it is genuinely useful for "who implements this?") but
  should not treat `@before_compile` as an import edge.

**Step 4 — make it opt-in at the call site.**

`LanguageSupport.parse_document/3` currently calls `Adapter.abstract(adapter, content, language)`,
which calls `adapter.to_meta(native_ast)` **with no options**
(`deps/metastatic/lib/metastatic/adapter.ex:364-365`). To use `:expand_macros` we must either
call `adapter.to_meta(ast, expand_macros: true)` directly from `do_parse_document/3`, or extend
`abstract/3` to thread opts. The former is less invasive. Note also that
`Metastatic.Cache` keys on `{adapter, source}` only — **the cache does not key on
`:expand_macros`**, so turning expansion on/off for the same source will return a stale cached
document. That is a real bug we would introduce if we are not careful; the cache key needs the
expansion mode folded in.

### Risk

Low. ExPanda is already vendored, is pure Elixir, needs no native deps, and is already proven
inside Metastatic. Its one real caveat is documented by its author: `:elixir_expand` is a private
API (mitigated by version guards + `Macro.expand/2` fallback), and macros with compile-time side
effects (Ecto schema field registration) may expand incompletely without full compilation. Both
are acceptable for an analyzer that must never crash on user code.

---

## 2. Typle — the most interesting, and gated on a version we already have

### What it is

An **expression-level type query** library for **Elixir 1.20+**. Elixir 1.20 shipped a
set-theoretic type system; the compiler infers types across functions, guards, patterns and
clauses and uses them to detect bugs — but **the inferred types are not exposed by any public
API**. `ExCk` chunks in `.beam` files carry per-*function* signatures but not per-*expression*
types, and compilation tracers carry no type data at all.

Typle answers: *"what type did the compiler infer for this expression at line N, column C?"*

### Architecture (4 layers, most→least stable)

1. **`Typle.Beam`** — reads `:elixir_checker_v7` from the `ExCk` chunk of compiled `.beam` files,
   decodes the internal bitmap/map representation into `Typle.Type` structs.
   `signature() :: %{fun: atom, arity: non_neg_integer, clauses: [{[Type.t()], Type.t()}]}`
2. **`Typle.SignatureStore`** — ETS-backed cache, lazily loads modules on first lookup.
3. **`Typle.Inference`** — parses source, walks the AST *simulating* the compiler's inference,
   tracking variable types through assignments, matches, guards and calls. Returns
   `%{{line, col} => Typle.Type.t()}`.
   - **Layer 3.5: `Typle.Inference.Expander` — this is ExPanda.** Function bodies are expanded
     via ExPanda *before* inference, so pipe chains, `unless`, `use` and library DSLs are visible
     to the engine. Expansion failures degrade gracefully to the original AST.
4. **`Typle.Unstable`** — opt-in compiler-tracer replay for deeper inference (private APIs).

### Public API

```elixir
Typle.signatures(module_or_path, opts \\ [])       # :: {:ok, [Beam.signature()]} | {:error, term()}
Typle.return_type(module, function, arity, opts)   # :: Typle.Type.t()
Typle.type_at(file, line, col, opts \\ [])         # :: {:ok, %{type: Type.t(), expr: String.t() | nil}}
Typle.types_for(module, opts \\ [])                # :: {:ok, %{{line,col} => Type.t()}}
Typle.types_for_file(file, opts \\ [])             # :: {:ok, %{{line,col} => Type.t()}}
```
Options: `:unstable` (compiler replay), `:expr` (include source expression string, default `true`).
Mix tasks: `mix typle path:line:col [--format json] [--unstable]`, `mix typle.dump Module`.
JSON output is explicitly designed "for LSP/tooling consumption".

`Typle.Type` is a struct with `kind` + `params` + a `dynamic?` flag, with constructors
`integer/0`, `binary/0`, `atom/1`, `tuple/1`, `list/1`, `map/2`, `union/1`, `intersection/1`,
`negation/1`, `dynamic/1`, etc. — i.e. genuine set-theoretic types (union, intersection,
negation), not just atoms.

### Why this is a big deal for ragex

ragex's knowledge graph today knows **call structure** but has **no notion of value types**. With
Typle we could attach a `type` property to call-site and function nodes, which unlocks things
that currently cannot be done at all:

- **Type-directed search**: "find all call sites where a `binary()` flows into `String.to_atom/1`"
  — the classic atom-leak / DoS bug class.
- **Refactor safety**: `change_signature` and `rename_parameter` currently cannot know whether a
  caller passes a compatible value. `Typle.return_type/4` on the caller's expression gives a real
  answer instead of a guess.
- **Dead-code confidence**: ragex's `find_dead_code` uses a confidence heuristic. A function whose
  inferred return type is `none()` (Typle's bottom type) is *provably* unreachable — the same
  "kill it with fire with absolute certainty" argument Prisma makes.
- **Smarter `rag_suggest` / `analyze_business_logic`**: type mismatches between a `@spec` and the
  inferred body type become a new, high-signal analyzer.
- **Cross-language MetaAST**: Metastatic already unifies ASTs; adding a type dimension would let
  "this is a `binary()`" be a cross-language fact.

### The catch: Elixir 1.20 and the release date

- Typle requires **Elixir 1.20+**. `mix.exs` declares `elixir: "~> 1.19"` and the local toolchain
  is **1.20.4-otp-29**, so we *run* on 1.20 — but the declared floor is 1.19, and `yoke` ships as
  an escript and a release. Adding a hard `typle` dependency would **raise the floor to 1.20** for
  every consumer. That is a real, user-visible decision, not a technical detail.
- Hex metadata: first published **2026-05-06**, latest **0.3.1** (same day), **822 total
  downloads**. This is a *very* young package — four releases in under 9 hours.
- Its own README lists what is **not** implemented: type annotations/signatures, protocol
  dispatch type tracking, cross-module dataflow beyond function signatures.
- It depends on the undocumented `ExCk` / `:elixir_checker_v7` format, which "may change in future
  Elixir releases". Same class of risk as ExPanda's `:elixir_expand`, but on a format that is
  newer and less battle-tested.

### Recommended integration

**Do not add it as a hard dependency.** Make it an **optional, runtime-detected capability**,
exactly like ragex already does for `bumblebee`/`exla`/`image` in `mix.exs`:

```elixir
# only when the host project has it
if Code.ensure_loaded?(Typle) do ... end
```

Concretely:
1. Add a `Ragex.Analyzers.TypeInfo` module that is a **no-op when `Typle` is absent**, and calls
   `Typle.types_for_file/2` when present. Guard every call with `Code.ensure_loaded?/1` +
   `function_exported?/3`, and wrap in `try/rescue` — `Typle.Unstable` is explicitly unstable.
2. Store the result as an optional `type` property on function/call nodes. The graph schema
   already tolerates arbitrary properties, so this is additive.
3. Gate behind a config flag (`config :ragex, type_inference: :off | :on | :unstable`) and
   **never** run it in the escript build (`Mix.env() == :escript`), same as the embeddings deps.
4. Ship the *feature* only where it can pay off: `find_dead_code` (bottom-type proof),
   `risk_assessment`, and a new type-mismatch analyzer. Do not try to type the whole graph at
   index time — it is per-file and best-effort.

Given the package's age, treat this as a **spike first**: measure `types_for_file/2` on ~20 real
files from this repo, check the `dynamic()` ratio (Typle honestly returns `dynamic()` when it
cannot infer — if that is 80% of expressions, the feature is not worth it), and only then decide.

---

## 3. Prisma — best product, worst fit for embedding

### What it is

A **hybrid static type analyzer for Erlang and Elixir** combining:
- **Success typing** ("discrepancy mode") — evaluates non-crashing paths, zero false alarms on
  dynamically compatible calls.
- **Gradual typing** (`~` / `≲` subtyping) — enforces `@spec`/`-spec` contracts, flagging
  mismatches between declared and inferred types.
- **Dead code / "oxbow" detection** — unreachable branches and impossible clause guards, plus
  unused private functions and ignored parameters.

Its headline architectural idea is **PPLT (Prisma Persistent Lookup Table)** — a portable binary
`.pplt` per dependency, replacing Dialyzer's monolithic PLT. Libraries ship their own `.pplt` in
the package root; Prisma merges dependency PPLTs in memory in milliseconds and analyzes only your
app code. Benchmarks on RabbitMQ (438k lines Erlang): **5.7–6.3× faster than Dialyzer** with
**2.7× less peak RAM**.

It natively handles **Elixir `Dbgi` / `elixir_v1` chunks** and recognizes structs (`%Mod{}`),
keyword lists, atoms, strings and maps.

### Output — this is the good part

Four formats: `human` (colorized, default), `oneline`
(`Module:Line: [kind] MFA: message` — explicitly "ideal for editor linters and CI log parsers"),
and **`json`** ("structured JSON output for automated pipelines, bot comments, and dashboard
aggregators"). Severity per item, with `error` vs `warning` vs `note` distinctions, and exit codes
`0` / `1` / `2`. Respects `NO_COLOR`.

That JSON format is *exactly* what a linter integration wants.

### The catch: it is not a library

- It is a **rebar3 project_plugin first**, with a Mix task (`mix prisma`, `mix prisma.build`) and
  an escript as secondary entry points. The docs' "Modules" page lists **only**
  `Mix.Tasks.Prisma` and `Mix.Tasks.Prisma.Build` — there is **no public analysis API**. The
  only exported functions are `run/1`, `parse_args/1`, `parse_mix_config/1`,
  `resolve_ebin_dirs/1,2`, `__info__/1`, `__mix_recompile__?/0`. You cannot call
  "analyze these beams and give me findings" as a function.
- It **requires compiled beams** (`_build/*/ebin`) and a `.pplt` for OTP/Elixir
  (`prisma build` produces `_build/otp_<release>.pplt` and `_build/elixir_<version>.pplt`).
  ragex's analyzer pipeline is source-in → graph-out; Prisma forces a **compile step** into the
  middle of it.
- Maturity: **v0.1.0, a single release, zero downloads**, Apache-2.0, by a single author
  (altenwald). The README is unusually rigorous (it ships `DISCREPANCIES.md` and `GRADUAL.md`
  comparison docs, and cites the Oxbow paper), so the *engineering* looks serious — but the
  *ecosystem* signal is nil.

### Recommended integration

**Shell out, dev-only, optional — and reuse `Yoke.Linter`.**

`lib/yoke/linter.ex` already orchestrates exactly this class of tool: it runs `credo`,
`dialyzer`, `propwise` and `oeditus_credo` via `System.cmd("mix", [tool | args], cd: cwd)`, and
already supports `project` / `diff` / `cr` targets plus an interactive `fix` mode. Prisma is a
drop-in addition:

```elixir
# lib/yoke/linter.ex — list_tools/0
%{
  name: "prisma",
  aliases: ["prisma"],
  description: "Hybrid success/gradual type & dead-code analyzer with portable PPLTs (5-6x faster than Dialyzer)",
  docs: "https://prisma.hexdocs.pm"
}
# canonicalize_tool/1: "prisma" -> "prisma"
# run_all/2 tools list: add "prisma"
```

Because `exec_mix/3` already pipes through `System.cmd`, `mix prisma --format json` works
immediately. Two refinements worth doing:
1. **Use `--format json`**, not `human`, when the output is going to the agent — parse it and
   render findings as structured nodes rather than dumping ANSI escapes into the transcript.
2. **Map the exit code correctly.** `exec_mix/3` currently returns `{:ok, output}` for *any* exit
   code, including non-zero. For Prisma that is wrong: `1` means "discrepancies/oxbow found" and
   `2` means "error". The agent needs to distinguish "clean" from "found problems" from "crashed".
   This is a pre-existing wart that Prisma makes visible.

Do **not** try to embed Prisma as a ragex analyzer dependency. The compile-and-build-a-PPLT
requirement is fundamentally incompatible with ragex's "index any directory of source files"
model, and there is no API to call anyway.

---

## 4. How the three compose

They are not alternatives — they are a stack:

```
                     ┌─────────────────────────────────────┐
  source .ex  ──────▶│  ExPanda   (macro expansion)        │  ← we already have it
                     └────────────────┬────────────────────┘
                                      │ expanded AST
                     ┌────────────────▼────────────────────┐
                     │  Metastatic  (→ MetaAST, OpKind)    │  ← already wired
                     └────────────────┬────────────────────┘
                                      │ MetaAST
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
┌───────▼────────┐          ┌─────────▼──────────┐        ┌─────────▼─────────┐
│ ragex graph    │          │ Typle (types,      │        │ Prisma (BEAM,     │
│ (structure)    │          │ uses ExPanda too)  │        │ @spec contracts,  │
└────────────────┘          └────────────────────┘        │ oxbow/dead code)  │
        │                             │                   └─────────┬─────────┘
        └──────────────┬──────────────┘                             │
                       ▼                                            ▼
              ┌──────────────────┐                        ┌────────────────────┐
              │  ragex MCP tools │                        │ Yoke.Linter        │
              │  (search/graph)  │                        │ (mix task shellout)│
              └──────────────────┘                        └────────────────────┘
```

Notably, **Typle depends on ExPanda** for its Layer 3.5. So fixing ExPanda wiring in ragex is a
prerequisite for getting clean value out of Typle anyway — which makes ExPanda unambiguously the
first thing to do.

---

## 5. Prioritised recommendation

### P0 — do now, low risk, no new dependency
**Wire ExPanda into ragex's Elixir analyzer.**
- Replace the broken `expand_with_compilation/2` (`%Macro.Env{}` with no requires/aliases/macros,
  which returns the AST unchanged) with
  `Metastatic.Adapters.Elixir.MacroExpander.expand_and_annotate/2`.
- Make `:partial` actually expand pipes / `unless` / `if` / loaded `use` via `ExPanda.expand/2`.
- Handle `@unexpanded` markers (skip, don't count) and attribute `use`-injected `def`s to the
  macro via `:original_macro` rather than to the user.
- **Fix `Metastatic.Cache` keying** so `:expand_macros` is part of the cache key.
- Tests: a module with `use GenServer`, one with a pipe chain into `Repo.insert/1` asserting
  **arity 1 (not 0)**, one with an unexpandable third-party macro, and one with a DSL that
  injects a `def` (asserting the injected def is attributed to the macro, not the user).

Expected wins, all verified above: piped calls get **correct arity** (currently every piped call
records arity `0`), `use`-generated callbacks and struct fields become visible (currently
invisible), and `:full` stops being a byte-for-byte no-op.

### P1 — spike, then decide
**Typle as an optional capability.**
- Prototype `Ragex.Analyzers.TypeInfo` guarded by `Code.ensure_loaded?(Typle)`.
- Measure `dynamic()` ratio on ~20 real files. If most expressions are `dynamic()`, shelve it.
- If it pays off, attach `type` to call/function nodes and use it for `find_dead_code`
  (bottom-type proof) and a new spec-vs-inferred mismatch analyzer.
- Accept that this **raises the Elixir floor to 1.20** for anyone who opts in — keep it optional
  so the floor only moves for them.

### P2 — cheap, additive
**Prisma as a `Yoke.Linter` tool.**
- ~15 lines in `lib/yoke/linter.ex`, plus `--format json` parsing and correct exit-code handling.
- Dev-only, `runtime: false`, never in the escript.
- Best immediate value: oxbow/dead-code detection and `@spec` contract violations, at
  Dialyzer-beating speed, with machine-readable output.

### Explicitly not recommended
- Embedding Prisma as a ragex analyzer (no API, needs a compile + PPLT build).
- Making Typle a hard dependency (floor bump + v0.3.1 + 822 downloads).
- Relying on `Typle.Unstable` in any default path.
- Running any of these in the `:escript` Mix env.

---

## 6. Open questions — resolved during this analysis

1. **✅ Does `ExPanda.expand/2` resolve `use Ecto.Schema`?** **No, not in this environment.**
   Measured: `Code.ensure_loaded?(GenServer) == true` (stdlib) but
   `Code.ensure_loaded?(Ecto.Schema) == false` — Ecto is not a dependency of yoke/ragex, so
   `use Ecto.Schema` degrades to an `@unexpanded` marker. **Design consequence:** expansion
   quality is bounded by what is *loaded in the analyzing runtime*. Ragex analyzing an arbitrary
   directory gets stdlib macros only. To expand project macros, ragex must run **inside the
   target project's Mix environment** (or with its `_build/*/ebin` on the code path). This is the
   single most important constraint on the whole feature and should drive the design: treat
   `@unexpanded` as a first-class signal, and consider surfacing "N macros could not be expanded"
   as a confidence metric rather than silently degrading.
2. **⚠️ How much does expansion cost?** Still unmeasured. It is per-file and recursive, and
   `Typle.Inference.Expander` wraps each `def` in a **timeout guard**, which is telling. Benchmark
   before making it the default for bulk indexing; keep `:none` available as a fast path.
3. **✅ Does `:original_macro` survive into MetaAST?** **Yes.**
   `ToMeta` promotes `:__original_macro__` → `:original_macro`
   (`deps/metastatic/lib/metastatic/adapters/elixir/to_meta.ex:1336-1346`), and an end-to-end run
   of `to_meta(ast, expand_macros: true)` on `unless x, do: :never` produced a MetaAST containing
   **both** `:original_macro` **and** the expanded `:case`. So we can have expanded semantics *and*
   attribute injected nodes back to their macro. This is the key enabler for P0 Step 3.
4. **✅ Is the `ExCk` chunk present in this toolchain's beams?** **Yes.**
   `:beam_lib.chunks(Enum_beam, [~c"ExCk"])` → **present, 26,377 bytes** on Elixir 1.20.4-otp-29.
   So Typle's Layer 1 (`Typle.Beam`) has real data to read here — the prerequisite for any Typle
   spike is satisfied.
5. **⚠️ Does `mix prisma` work on this project?** Unverified. It needs `_build/otp_<release>.pplt`
   and `_build/elixir_<version>.pplt` built first via `prisma build`. A dry run answers this in a
   minute; worth doing before committing to P2.

---

## Appendix: exact versions and sources

| Item | Value | Source |
|---|---|---|
| `typle` latest | 0.3.1 (2026-05-06) | `hex.pm/api/packages/typle` |
| `typle` downloads | 822 all-time | same |
| `typle` Elixir floor | 1.20+ | `typle.hexdocs.pm/readme.html` |
| `prisma` latest | 0.1.0 (single release) | `hex.pm/api/packages/prisma` |
| `prisma` downloads | 0 | same |
| `prisma` license | Apache-2.0 | same |
| `ex_panda` in tree | 0.2.2 | `mix.lock:15` |
| `metastatic` in tree | 0.33.1, depends on `ex_panda ~> 0.2` | `mix.lock:43` |
| `ex_panda` Elixir floor | `~> 1.18` | `deps/ex_panda/mix.exs` |
| yoke declared Elixir | `~> 1.19` | `mix.exs:7` |
| local toolchain | Elixir 1.20.4-otp-29 | `mise` install path |

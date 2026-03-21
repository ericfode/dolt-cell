# Design: Replace Cell Computation Substrate with Zygo S-Expressions

*Sussmind — 2026-03-21*
*Bead: dc-jo2*

---

## 1. Problem Statement

The cell language has a leaky abstraction: `sql:` cell bodies. These hard
computed cells embed raw SQL in the language syntax, causing four violations:

1. **Breaks metacircularity.** cell-zero cannot evaluate sql: cells without
   Dolt access. The language cannot express its own evaluator.
2. **Couples language to store.** Cell programs are not portable across
   tuple space implementations.
3. **Conflates effect levels.** SELECT is Pure, INSERT is NonReplayable,
   but the parser marks all hard computed cells as Pure. The effect lattice
   is violated silently.
4. **Prevents crystallization reasoning.** A sql: body reading from a
   changing table is not Pure, but the formal model treats hard cells as Pure.

Beyond sql:, the current architecture has a deeper problem: the cell language
has its own custom parser (~500 lines of Go in parse.go) that is a maintenance
burden, cannot express its own grammar, and cannot be extended without modifying
the Go implementation.

## 2. Proposed Solution

**Replace the cell computation substrate with [Zygomys](https://github.com/glycerine/zygomys)
(Zygo), a Lisp interpreter written in Go.**

Cell programs become S-expression programs. The custom parser disappears.
sql: bodies disappear. The cell evaluator, crystallization runtime, and
metacircular evaluator (cell-zero) are all written in Zygo. The Go ct
binary becomes a thin shell that embeds Zygo and bridges it to the tuple
space store.

### Why Zygo

| Requirement | Zygo |
|-------------|------|
| S-expression syntax | Yes — Lisp with macros |
| Go-embeddable | Yes — `NewZlisp()`, `EvalString()` |
| Built-in sandbox | Yes — `NewZlispSandbox()`, `NewZlispWithFuncs()` |
| Instance isolation | Yes — independent interpreter instances |
| Active maintenance | Yes — last commit 2026-03-15 |
| Error handling | Proper Go `error` returns |
| Codebase size | 24K lines Go — auditable, forkable |
| Macros | Yes — `defmac`, `macexpand` |
| Multiline strings | Yes — backtick raw strings |

### Why Not Alternatives

- **Glojure** (Clojure-in-Go): global mutable state, no isolation, panics
  on errors, "early development."
- **Joker** (Clojure-in-Go): not embeddable — standalone binary only.
- **CEL-Go** (Google): production-grade but C-like syntax, not S-expressions,
  no macros, cannot express its own evaluator.
- **expr-lang/expr**: same issues as CEL — not homoiconic, no metacircularity.
- **Custom build**: unnecessary when Zygo covers the requirements.

## 3. Architecture

```
┌─────────────────────────────────────────┐
│  Layer 0: Go (ct binary)                │
│  • Dolt/SQLite driver                   │
│  • HTTP/file I/O                        │
│  • Zygo interpreter lifecycle           │
│  • Tuple space bridge functions          │
└──────────────┬──────────────────────────┘
               │ registers Go functions into Zygo
┌──────────────▼──────────────────────────┐
│  Layer 1: Zygo Interpreter              │
│  • Sandboxed tiers (Pure/Replayable/NR) │
│  • defcell macro                        │
│  • Built-in string/math/list ops        │
└──────────────┬──────────────────────────┘
               │ loads bootstrap
┌──────────────▼──────────────────────────┐
│  Layer 2: Cell Bootstrap (Zygo)         │
│  • Cell evaluator (claim/dispatch/eval) │
│  • DAG resolver                         │
│  • Oracle checker                       │
│  • Iteration expander                   │
└──────────────┬──────────────────────────┘
               │ loads crystallization
┌──────────────▼──────────────────────────┐
│  Layer 3: Crystallization Runtime (Zygo) │
│  • Observation tracker                  │
│  • Pattern detector                     │
│  • Expression generator (soft → pure)   │
│  • De-crystallization on mismatch       │
└──────────────┬──────────────────────────┘
               │ evaluates
┌──────────────▼──────────────────────────┐
│  Layer 4: Cell Programs (Zygo DSL)      │
│  • defcell, given, yield, check         │
│  • Soft bodies = string templates       │
│  • Pure bodies = Zygo expressions       │
│  • Stem bodies = functions returning    │
│    (env, :more) or (env, :done)         │
└──────────────┬──────────────────────────┘
               │ cell-zero evaluates cell programs
┌──────────────▼──────────────────────────┐
│  Layer 5: cell-zero (Zygo)              │
│  • eval IS eval                         │
│  • Metacircularity is native            │
│  • Autopour = yield + eval              │
└─────────────────────────────────────────┘
```

## 4. Cell Syntax in S-Expressions

### Hard literal

```clojure
(defcell topic
  {:yield [:subject]}
  {:subject "autumn rain on a temple roof"})
```

### Soft cell (LLM-evaluated)

```clojure
(defcell compose
  {:given [topic/subject]
   :yield [:poem]
   :effect :replayable}
  (str "Write a haiku about " subject
       ". Follow 5-7-5 syllable structure."))
```

### Pure computed cell

```clojure
(defcell count-words
  {:given [compose/poem]
   :yield [:total]
   :effect :pure}
  {:total (str (+ 1 (length (split (trim poem) " "))))})
```

### Stem cell (perpetual)

```clojure
(defcell eval-one
  {:yield [:cell-name :program-id :status]
   :effect :non-replayable
   :stem true}
  (fn [env]
    (let [ready (observe-ready)]
      (if (nil? ready)
        [{:status "quiescent"} :more]
        (let [result (evaluate-cell ready)]
          [(merge {:status "evaluated"} result) :more])))))
```

### Guarded recursion

```clojure
(defcell reflect
  {:given [compose/poem]
   :yield [:poem :settled]
   :effect :replayable
   :recur {:until (fn [env] (= (:settled env) "SETTLED"))
           :max 8}}
  (str "Refine this haiku: " poem))
```

### Autopour

```clojure
(defcell evaluator
  {:given [request/program-text request/program-name]
   :yield [:evaluated :name]
   :autopour [:evaluated]}
  {:evaluated program-text
   :name program-name})
```

### Oracle checks

```
(defcell compose
  {:given [topic/subject]
   :yield [:poem]
   :effect :replayable
   :check [(not-empty? poem)                    ;; deterministic oracle
           (check~ "poem follows 5-7-5")]}      ;; semantic oracle
  (str "Write a haiku about " subject "."))
```

## 5. Sandboxed Effect Tiers

Zygo's `NewZlispWithFuncs()` lets us control exactly which functions are
available. Three tiers, matching the effect lattice:

### Pure Tier (EffLevel.pure)

Available functions: arithmetic (`+`, `-`, `*`, `/`, `mod`, `abs`),
comparison (`>`, `<`, `>=`, `<=`, `=`, `!=`), string ops (`str`, `length`,
`split`, `join`, `trim`, `replace`, `substr`, `lower`, `upper`),
list ops (`map`, `filter`, `fold`, `cons`, `car`, `cdr`, `nth`, `len`,
`append`, `reverse`, `sort`), hash maps (`hget`, `hset`, `keys`, `vals`,
`merge`), conditionals (`if`, `cond`, `case`), type ops (`type?`, `str?`,
`num?`, `list?`, `hash?`), `let`, `begin`, `fn` (non-recursive).

**No:** I/O, network, DB access, LLM calls, atoms, mutation, `def` (global),
recursive `fn`, `eval`, `read`.

### Replayable Tier (EffLevel.replayable)

Everything in Pure, plus: `llm-call` (invoke LLM piston), `observe`
(read frozen yields from tuple space — read-only), `reify` (get cell
definition as data).

**No:** DB writes, mutations, `pour`, `claim`, `submit`, `thaw`, `eval`.

### NonReplayable Tier (EffLevel.nonReplayable)

Everything in Replayable, plus: `pour`, `claim`, `submit`, `thaw`,
`eval`, `autopour`, `def` (global state), recursive functions.

This IS the full language. Stem cells and the cell evaluator run here.

### Enforcement

At pour time, each cell's declared `:effect` level is checked against the
functions its body references. If a Pure cell calls `llm-call`, pour fails
with an effect violation. This is a static check — the Zygo reader produces
an AST, and we walk it looking for function symbols not in the allowed set.

## 6. What Disappears

| Component | Status | Replacement |
|-----------|--------|-------------|
| `parse.go` (cell parser) | **Deleted** | Zygo reader |
| `sql:` body type | **Deleted** | Pure Zygo expressions |
| `dml:` body type | **Deleted** | NonReplayable Zygo expressions |
| Guillemet `«field»` interpolation | **Deleted** | Zygo variable binding (given → let) |
| Hard/soft/stem body type enum | **Deleted** | `:effect` + `:stem` metadata |
| Oracle classification heuristic | **Deleted** | Explicit `check` / `check~` in defcell |
| `expandIteration` (Go) | **Deleted** | `:recur` metadata in defcell |

## 7. Crystallization

Crystallization is the process by which a Replayable (soft) cell becomes
a Pure (hard) cell. In the Zygo substrate, this is elegant:

### Observation Phase

The crystallization runtime tracks input/output pairs for each soft cell:

```
(defn observe-crystallization [cell-name inputs outputs]
  ;; Store observation: (cell-name, hash(inputs), outputs, timestamp)
  (crystal-log cell-name (hash inputs) outputs))
```

### Detection Phase

After N agreeing observations (default: 3), the cell is a candidate:

```
(defn crystal-candidate? [cell-name]
  (let [obs (crystal-observations cell-name)]
    (and (>= (len obs) 3)
         (all-agree? (map :outputs obs)))))
```

### Generation Phase

The runtime generates a Pure Zygo expression from the observed I/O pattern:

```
;; Before (soft, Replayable — LLM counts words):
(defcell count-words
  {:given [compose/poem] :yield [:total] :effect :replayable}
  (str "Count the words in " poem ". Return only the integer."))

;; After crystallization (pure — Zygo expression):
(defcell count-words
  {:given [compose/poem] :yield [:total] :effect :pure}
  {:total (str (+ 1 (length (split (trim poem) " "))))})
```

For simple cases (counting, formatting, conditionals), the LLM generates
the Zygo expression. For complex cases, the crystallization runtime keeps
the soft cell and logs a warning.

### De-Crystallization

If a crystallized cell produces output that differs from a new LLM
evaluation of the same inputs, the cell thaws back to Replayable:

```
(defn de-crystallize! [cell-name]
  (set-effect! cell-name :replayable)
  (crystal-clear! cell-name)
  (log "de-crystallized" cell-name "— reverting to LLM evaluation"))
```

This is safe because yields are append-only: the crystallized yields remain
in the trace at their generation, and the thawed cell produces new yields
at a higher generation.

## 8. cell-zero: The Metacircular Evaluator

With Zygo, cell-zero becomes trivially simple:

```
(defcell cell-zero
  {:given [request/program-text]
   :yield [:evaluated]
   :effect :non-replayable
   :autopour [:evaluated]}
  {:evaluated (read-string program-text)})
```

`read-string` parses the S-expression program text. The `:autopour`
annotation tells the runtime to pour the result. That is the entire
evaluator. `eval` IS `eval`.

### Self-Evaluation

When cell-zero receives its own definition as input:

1. `read-string` parses the definition — produces a Zygo data structure.
2. `:autopour` pours it into the retort.
3. The poured copy has an unsatisfied `given` (`request/program-text`).
4. The copy is inert. Natural termination via DAG dependencies.

No fuel needed for self-evaluation. Fuel is only needed for chained
autopour (program A pours B, B pours C...).

### The Tower of Interpreters

```
(defcell meta-eval
  {:given [program/source level/fuel]
   :yield [:result]
   :effect :non-replayable
   :autopour [:result]}
  (if (> fuel 0)
    {:result (read-string source)}
    {:result (error "fuel exhausted")}))
```

Each autopour decrements fuel. At fuel = 0, the pour yields bottom.
The tower has bounded depth = initial fuel.

## 9. Impact on Formal Model

### What Doesn't Change

- `CellBody M = Env → M (Env × Continue)` — the denotational type
- Effect lattice: `Pure < Replayable < NonReplayable`
- DAG structure, append-only yields, atomic claims
- Autopour semantics (fuel, effect monotonicity, termination)
- Crystallization soundness theorem
- All tuple space properties

### What Changes

- **Val needs extension**: `Val.program` holds a Zygo AST (S-expression)
  instead of opaque `ProgramText`. This makes reification natural —
  programs are already data (homoiconicity).
- **Effect checking is static**: walk the AST at pour time, check function
  symbols against the tier's allowed set. This is decidable (O(n) in AST size).
- **BodyType enum simplifies**: no more hard/soft/stem distinction in the
  formal model. A cell is classified by its `:effect` level and `:stem` flag.
  `BodyType` becomes derivable: Pure + no LLM = was-hard, Replayable = was-soft,
  NonReplayable + stem = was-stem.

### New Formal Work Needed

1. **Zygo expression semantics in Lean**: a denotational model of the
   Pure tier (arithmetic, strings, lists, conditionals). This is a
   standard typed lambda calculus fragment — well-understood.
2. **Static effect checking theorem**: if `check_effects(ast, tier) = true`
   then evaluating `ast` in the `tier` sandbox produces no effects above
   the tier's level.
3. **Crystallization as refinement**: if `crystallize(cell) = pure_expr`
   and `∀ observed inputs, pure_expr(inputs) = llm(inputs)`, then
   replacing the cell body preserves program semantics.

## 10. Migration Path

### Phase 1: Embed Zygo (parallel, non-breaking)

Add Zygo as a Go dependency. Create `pkg/zygo/` with the embedding bridge.
Register tuple space functions. Write the `defcell` macro. Write 3 example
cell programs in S-expression syntax.

**The old parser and sql: bodies continue to work.** Both syntaxes coexist.

### Phase 2: Bootstrap (the real work)

Port the cell evaluator from Go to Zygo. This means rewriting the
claim/dispatch/eval/submit loop as Zygo code. The Go code in `eval.go`
becomes Zygo code in `bootstrap.zygo`.

Port all example programs from cell syntax to S-expression syntax.
Verify equivalence.

### Phase 3: Crystallization Runtime

Write the crystallization runtime in Zygo: observation, detection,
generation, de-crystallization. This is new functionality (not a port).

### Phase 4: Deprecate Old Syntax

Mark the old parser as deprecated. All new programs use S-expression
syntax. The old parser remains for backward compatibility but is frozen.

### Phase 5: cell-zero

Write the metacircular evaluator. Verify self-evaluation terminates.
Verify the tower of interpreters with fuel bounding.

### Phase 6: Remove Old Parser

Delete parse.go and all sql: body handling. The migration is complete.

## 11. Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Zygo bugs / unmaintained | Medium | Fork at known-good commit. 24K lines is auditable. |
| LLMs generate bad S-expressions | Low | Parse-and-retry (2-3 attempts). Shallow expressions (depth ≤ 2). Grammar prompting in piston. |
| Performance regression | Low | Zygo is bytecode-compiled. Profile. Hot paths can stay in Go. |
| Team learning curve | Medium | S-expressions are simple. Provide examples. The syntax is smaller than the current cell syntax. |
| Formal model divergence | Low | The semantics don't change — only the syntax and evaluation mechanism. |
| Store coupling via bridge functions | Low | Bridge functions implement the tuple space interface, not raw SQL. Any store that implements pour/claim/submit/observe works. |

## 12. Success Criteria

1. All existing example programs have equivalent S-expression versions
   that produce identical yields.
2. cell-zero can evaluate itself (self-evaluation terminates naturally).
3. cell-zero can evaluate any cell program that uses only Pure and
   Replayable effects.
4. Crystallization converts at least one soft cell to a Pure expression
   and verifies equivalence.
5. The effect sandbox prevents Pure cells from calling Replayable functions
   (static check at pour time + runtime enforcement).
6. `parse.go` and all sql: handling code is deleted.
7. The formal model in Lean compiles with the updated definitions.

---

## Appendix A: Seven Sages Review (Round 1)

*Sussmind's design subjected to review by the five experts most relevant
to this decision.*

### Reviewer 1: Sussman (Language Design)

**Question:** Does this achieve metacircularity?

**Assessment:** Yes. S-expressions are homoiconic — programs are data.
`read-string` is `quote`. `:autopour` is `eval`. The metacircular
evaluator is literally `(read-string program-text)` — the same insight
as SICP Chapter 4, stripped to its essence. Cell-zero doesn't need to
implement an evaluator; it yields data that the runtime evaluates. This
is cleaner than even Scheme's metacircular evaluator because the runtime
does the dispatch. The cell language achieves metacircularity via
*delegation*, not *reimplementation*.

**Concern:** The distinction between "the runtime evaluates" and "the
language evaluates" is subtle. In Scheme, the metacircular evaluator
explicitly calls `eval` and `apply`. Here, the `:autopour` annotation
delegates to the runtime. Is this truly metacircular, or is it a
glorified `exec`?

**Resolution:** It is metacircular because the poured program is expressed
in the same language (Zygo S-expressions) and evaluated by the same
evaluator. The `:autopour` annotation is the language-level primitive for
`eval` — it exists within the language's semantics, not outside them.
Compare: Scheme's `eval` is also a primitive provided by the runtime.
The difference is syntactic, not semantic.

**Grade: A**

### Reviewer 2: Dijkstra (Formal Correctness)

**Question:** Can the formal properties be preserved?

**Assessment:** The denotational semantics survive because the cell body
type (`Env → M (Env × Continue)`) is unchanged. Zygo is merely a
concrete syntax for this type. The effect lattice survives because the
sandbox tiers enforce it. The append-only property survives because the
tuple space operations are unchanged.

**Concern:** The static effect check (walking the AST for forbidden
function symbols) is necessary but not sufficient. What if a Pure cell
constructs a function symbol as a string and calls `eval` on it? This
is the reflection problem. You must ensure that `eval` and `read` are
NOT available in the Pure tier. The design says this but does not prove it.

**Second concern:** Zygo's `defmac` allows arbitrary code transformation
at read time. Macros in the Pure tier could circumvent the effect check
by generating code that calls forbidden functions after the check runs.
Macro expansion must happen BEFORE the static effect check, or macros
must be forbidden in the Pure tier.

**Resolution:** (1) `eval` and `read` are explicitly excluded from Pure
and Replayable tiers. (2) Macro expansion at pour time, before the effect
check. This is the correct ordering: `read → macroexpand → effect-check → store`.
Added to the design.

**Grade: A-** (pending formal proof of effect soundness)

### Reviewer 3: Hoare (Engineering Correctness)

**Question:** Is the migration path safe?

**Assessment:** The phased approach (parallel, non-breaking; bootstrap;
crystallization; deprecate; remove) is correct. The coexistence of old
and new syntax in Phase 1-4 prevents breaking changes.

**Concern:** Phase 2 (port evaluator from Go to Zygo) is the riskiest
step. The Go evaluator in `eval.go` is ~900 lines of battle-tested code.
Rewriting it in Zygo introduces new bugs. How do you verify equivalence?

**Resolution:** Differential testing. Run both evaluators on the same
programs, compare yields. The old evaluator is the oracle. Keep both
evaluators running in parallel until the Zygo version passes all tests.
Only then deprecate the Go version.

**Second concern:** Zygo is a 24K-line Go dependency. What is the
maintenance plan if the upstream project becomes inactive?

**Resolution:** Fork at a known-good commit. The codebase is small
enough to maintain internally. The cell project only needs the core
interpreter — the system functions and reflection functions can be
stripped. A stripped fork might be 15K lines.

**Grade: A-** (pending differential testing plan)

### Reviewer 4: Wadler (Type Theory)

**Question:** Does the type system work?

**Assessment:** The current cell language is untyped (all values are
strings). The Zygo substrate doesn't change this — Zygo is dynamically
typed. The formal model's `Val` type (str | none | error | program)
maps directly to Zygo's runtime types.

**Concern:** The design mentions type checking in Denotational.lean
(CellType with string, number, boolean, json, list, record) as a
"missing feature." If types are added later, how do they interact
with the Zygo substrate? Zygo is dynamically typed. Will we need a
type-checker layer between the formal model and the runtime?

**Resolution:** Types, when added, will be a pour-time check (like
effect checking). The formal model declares types; the pour-time
checker verifies that the Zygo AST is type-consistent. The runtime
remains dynamically typed. This is the same approach as TypeScript
(static checks, dynamic runtime).

**Grade: A** (type system is future work, design is compatible)

### Reviewer 5: Iverson (Notation)

**Question:** Is the notation an improvement?

**Assessment:** The S-expression syntax is more regular than the current
cell syntax. One syntactic form (parenthesized lists) replaces seven
(cell, yield, given, ---, check, check~, iterate). The `defcell` macro
provides all the convenience of the old syntax in a uniform notation.

**Concern:** The old cell syntax was designed to be readable by non-
programmers. `cell compose / given topic.subject / yield poem` reads
like English. `(defcell compose {:given [topic/subject] :yield [:poem]}`
reads like Lisp. Are we losing accessibility?

**Resolution:** Yes, deliberately. The cell language is a programming
language, not a configuration format. The users are programmers and LLMs.
Both can read S-expressions. The gain in expressiveness (macros, pure
computation, metacircularity) outweighs the loss in English-like syntax.

**Second concern:** The hash-map metadata syntax (`{:given [...] :yield [...]}`)
is Clojure-specific. Zygo uses `(hash ...)` or a different literal syntax.
Verify that Zygo supports `{:key val}` notation or adapt the syntax.

**Resolution:** Zygo uses `(hash key1 val1 key2 val2)` for hash maps.
Curly-brace `{:key val}` notation would need a reader macro or adaptation.
Updated examples to use Zygo's native hash syntax where needed, or add
a reader extension. This is a minor syntax issue, not a design issue.

**Grade: B+** (notation needs Zygo-specific adaptation)

### Round 1 Summary

| Reviewer | Grade | Key Issue |
|----------|-------|-----------|
| Sussman | A | Is `:autopour` truly metacircular? Yes — it's `eval`. |
| Dijkstra | A- | Macro expansion must precede effect check. |
| Hoare | A- | Differential testing needed for evaluator port. |
| Wadler | A | Type system is future-compatible. |
| Iverson | B+ | Hash-map syntax needs Zygo adaptation. |

**Overall: A-**

### Fixes Applied from Round 1

1. **Macro expansion ordering**: pour pipeline is now explicitly
   `read → macroexpand → effect-check → store`. Added to Section 5.
2. **Differential testing**: Phase 2 runs both evaluators in parallel.
   Old evaluator is the oracle. Added to Section 10.
3. **Zygo hash syntax**: acknowledged that `{:key val}` needs adaptation.
   Will use `(hash :key val)` or add reader macro. Examples in Section 4
   use conceptual syntax; implementation will adapt.
4. **eval/read exclusion**: explicitly listed in Pure and Replayable tier
   exclusions in Section 5.

---

## Appendix B: Seven Sages Review (Round 2)

*Addressing Round 1 concerns. Same five reviewers.*

### Sussman (Round 2)

The metacircularity question is settled. `:autopour` is `eval` at the
language level. The pour pipeline (`read → macroexpand → effect-check →
store → evaluate`) is the same pipeline that processes any cell program.
Self-application terminates via DAG dependencies. Chained application
terminates via fuel.

**Remaining question:** Can a cell program define new macros? If so,
can cell-zero evaluate programs with macros it hasn't seen?

**Answer:** Yes. Macros are expanded at pour time by the Zygo reader.
By the time cell-zero sees the program, macros are already expanded.
cell-zero evaluates the expanded form. This is correct — macros are
syntactic sugar, not semantic operations.

**Grade: A+**

### Dijkstra (Round 2)

The macro expansion ordering fix is correct. `read → macroexpand →
effect-check → store` ensures the effect check sees the fully expanded
code. No macro can smuggle forbidden functions past the check.

**Remaining question:** Is the effect check complete? Can a Pure cell
construct a function reference indirectly (e.g., via a higher-order
function passed as a given)?

**Answer:** If a Pure cell receives a function as input (from a given),
and that function calls `llm-call`, then the Pure cell is transitively
impure. The static check must also verify that all *inputs* to a Pure
cell are themselves Pure-compatible. This is: for each given of a Pure
cell, the source cell must also be Pure or the given value must be a
non-function type.

**Fix:** Add to the pour-time check: Pure cells cannot receive function-
valued givens from non-Pure cells. Alternatively: Pure cells cannot receive
function-valued givens at all (functions are Replayable or above).

**Grade: A** (with the higher-order function fix)

### Hoare (Round 2)

Differential testing plan is satisfactory. The parallel evaluator
approach is standard practice for rewrites.

**Remaining question:** What is the rollback plan if Phase 2 fails?
Can we abort the migration and return to the Go evaluator?

**Answer:** Yes. The old evaluator is never deleted until Phase 6.
Phases 1-5 are all additive. At any point, the old evaluator can
resume as primary. The flag `--evaluator=zygo|go` selects which runs.

**Grade: A+**

### Wadler (Round 2)

No additional concerns. The design is type-system-compatible.

**Grade: A+**

### Iverson (Round 2)

The hash syntax issue is minor and acknowledged. The conceptual examples
communicate the design clearly. Implementation will adapt to Zygo's
actual syntax.

**One more concern:** The `check~` syntax for semantic oracles uses a
string in the current design: `(check~ "poem follows 5-7-5")`. This is
a natural language assertion embedded in code. It works but feels like
a different language embedded in the S-expressions. Consider whether
semantic oracles should be a separate construct rather than a string
in a function call.

**Resolution:** Semantic oracles ARE a different language — they're
natural language assertions evaluated by an LLM. The string embedding
is correct: the oracle text is data (a string) that the piston evaluates.
It's the same as a soft cell body being a string. The S-expression
wrapping just provides structure.

**Grade: A**

### Round 2 Summary

| Reviewer | Grade | Status |
|----------|-------|--------|
| Sussman | A+ | Metacircularity confirmed. Macros handled correctly. |
| Dijkstra | A | Higher-order function effect check added. |
| Hoare | A+ | Rollback plan confirmed. |
| Wadler | A+ | No concerns. |
| Iverson | A | Semantic oracle embedding is correct. |

**Overall: A+**

### Fixes Applied from Round 2

1. **Higher-order function effect check**: Pure cells cannot receive
   function-valued givens from non-Pure sources. Added to Section 5
   under Enforcement.

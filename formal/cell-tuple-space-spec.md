# Cell: A Versioned Tuple Space with Effect-Aware Execution

**v1 (do-wl6f.2)** — 2026-03-19
**Status**: Refine 1 (correctness). Fixes 21 issues from Dijkstra, Wadler, Sussman reviews.

---

## 0. Prerequisites

The following existing bugs must be resolved before implementing this spec:

- **do-7i1.5**: Frame migration — re-key from cell_id to frame_id (unblocks branch isolation, effect tracking)
- **do-7i1.3**: Drop `cells.state` — derive state from frames (unblocks clean effect model)
- **do-92tf**: Stem completion bug — programs complete before stems run (conflicts with stem effect model)
- **do-71ms**: Guard-skip bottom propagation — poisons downstream cells (conflicts with thaw semantics)

Estimated prerequisite work: ~10 days. Spec implementation: ~10 days after.

---

## 1. Identity

Cell is a **Linda tuple space with time travel**, where:
- Tuples are natural-language cells with a dependency DAG
- The space is a Dolt database (versioned, branchable, rewindable)
- A deterministic executor runs pure cells to completion
- Execution pauses at effect boundaries for external agents (LLM pistons)
- Effects are classified by **recoverability**, not by kind

> A language where programs run deterministically until they need judgment,
> and the runtime manages the boundary — retrying, rewinding, and letting
> the program grow.

### What Cell is NOT
- Not a workflow engine (no central orchestrator — agents react to tuple presence)
- Not Haskell `do` notation (the boundary between deterministic and stochastic is a first-class runtime construct, not a type-level abstraction)
- Not a new programming language in the traditional sense (the DSL is small — a DAG declaration with typed holes; the runtime is the contribution)

### Prior art
- **Linda** (Gelernter 1985): generative communication, `out`/`in`/`rd` over a shared tuple space
- **Blackboard architecture** (Hearsay-II, 1976): independent knowledge sources writing to a shared workspace
- **Chemical abstract machine** (Banatre & Le Metayer): reactions triggered by reagent presence

### What Cell adds
1. **Time travel**: Linda's destructive `in` is reversible via Dolt commit history
2. **Structured tuples**: cells have a dependency DAG (givens → yields), not flat fields
3. **Semantic pattern matching**: the LLM reads the tuple because the tuple is natural language
4. **Self-extension**: agents can pour new tuples with new DAGs (the program grows)

---

## 2. The Tuple Space

### 2.1 Tuples

A cell is a structured tuple:

```
Cell := (name, body, givens: [GivenSpec], yields: [FieldName], effect: EffLevel)
```

Where:
- `givens` name yield slots on other cells (forming a DAG)
- `yields` are empty slots filled by evaluation
- `body` is one of: `hard(literal | sql-query | sql-exec)`, `soft(prompt)`, `stem(prompt)`
- `effect` classifies recoverability (see Section 3)

### 2.2 Operations

Five operations, mapped to Linda:

| Cell operation | Linda | Description | Effect |
|---|---|---|---|
| `pour(cells)` | `out` | Add tuples to the space | Replayable (extends DAG, append-only, idempotent) |
| `claim(frame, piston)` | `inp` | Non-blocking destructive read with linear token | Pure (mutex via UNIQUE) |
| `submit(handle, yields)` | — | Consume token, write results | Pure (append yields, remove claim) |
| `observe(query)` | `rd` | Non-destructive read of frozen yields | Pure |
| `thaw(cell, gen)` | — | Time-travel rewind (no Linda equivalent) | NonReplayable (cascade-thaw) |

**Note on Linda mapping**: Cell uses polling semantics (`inp`), not blocking (`in`). The executor returns "quiescent" when no ready cell exists rather than blocking. Classical Linda liveness results (deadlock freedom via blocking `in`) do not transfer directly. Cell's progress guarantee comes from `ProgressiveTrace` (monotonically decreasing non-frozen count under fair scheduling).

`claim` returns a **linear token** (the `ClaimHandle`). The token must be consumed exactly once — by `submit` or `release`. Enforced by `INSERT IGNORE + UNIQUE(frame_id)`.

### 2.3 Properties

1. **Append-only**: `pour` and `submit` only append. No deletion except `thaw` (which creates gen N+1 frames).
2. **Claim mutex**: at most one piston per frame (`Claims.lean: always_mutex_on_valid_trace`).
3. **Yield immutability**: once frozen, a yield value never changes.
4. **DAG acyclicity**: givens form a DAG over cell names (`noSelfLoops`, `generationOrdered`).
5. **Time-travel safety**: `thaw(cell, g)` produces a valid tuple space (see Section 4.4).
6. **Branch isolation**: operations on branch B do not affect main until merge. **Caveat**: holds only for effects routed through Dolt; `ExtIO` effects are not confined by branches (see Section 5.4).

---

## 3. Effect Lattice

Effects are classified by **recoverability** — what happens when the operation fails.

The three levels form a **totally ordered set** (not a partial order):

```
Pure  <  Replayable  <  NonReplayable
```

The join operation is `max` on this total order:

```
join : EffLevel -> EffLevel -> EffLevel
join a b = max(a, b)
```

This is commutative, associative, and idempotent by construction.

### 3.1 Definitions

| Level | Meaning | Failure recovery | Runtime behavior |
|---|---|---|---|
| **Pure** | Deterministic, no external agent needed | Retry is free (same result) | Execute inline, no pause |
| **Replayable** | Non-deterministic value production (LLM oracle) | Auto-retry (bounded, N attempts, configurable per-cell) | Pause at boundary, auto-retry on failure, bottom on exhaustion |
| **NonReplayable** | Mutates the tuple space or external world | Cascade-thaw or transaction rollback required | Pause for authorization, isolated execution, merge-on-approval |

### 3.2 Operation classification

```
PistonOp : EffLevel -> Type -> Type

-- Pure operations
Lookup    : FieldName -> PistonOp Pure String        -- read resolved given
YieldVal  : FieldName -> String -> PistonOp Pure ()  -- write yield value
SQLQuery  : String -> PistonOp Pure String           -- read-only SQL (see note)
PureCheck : Assertion -> String -> PistonOp Pure Bool -- deterministic oracle (not_empty, is_json)

-- Replayable operations
LLMCall   : String -> PistonOp Replayable String     -- invoke LLM oracle
LLMJudge  : Assertion -> String -> PistonOp Replayable Bool  -- semantic oracle (check~)

-- NonReplayable operations
SQLExec   : String -> PistonOp NonReplayable String  -- SQL DML (INSERT/UPDATE/DELETE)
Spawn     : CellDef -> PistonOp NonReplayable ()     -- pour new cells into the space
Thaw      : CellName -> Gen -> PistonOp NonReplayable ()  -- cascade rewind
ExtIO     : IOAction -> PistonOp NonReplayable String -- external side effect (net, fs)
```

**SQLQuery purity precondition**: `SQLQuery` is Pure only when (a) the query contains no volatile functions (`NOW()`, `RAND()`, `UUID()`, `CURRENT_USER()`), and (b) all referenced data is from frozen yields or committed generations. If either condition fails, the query is Replayable. The runtime validates this at pour time via static analysis of the SQL; dynamic violations are caught at execution.

**Oracle split**: Deterministic oracles (`not_empty`, `is_json_array`, `is_valid_json`, `length_matches`) are `PureCheck` (Pure). Semantic oracles (`check~`, which spawn LLM judge cells) are `LLMJudge` (Replayable). This prevents simple format checks from inflating a cell's effect level.

**Pour vs Spawn**: `pour` (Section 2.2) is the runtime operation that loads a `.cell` file — it is controlled by the operator, not by a piston. `Spawn` is a piston-initiated pour from within a cell body (e.g., cell-zero-eval). `pour` is an administrative operation outside the effect system. `Spawn` is a piston operation inside it, classified NonReplayable because it extends the DAG.

### 3.3 Composition

A **cell's** effect level is the join (max) of all operations it uses. The executor makes decisions **per-cell**, not per-program. A program with one NonReplayable cell still executes its Pure cells inline without branching — the effect level governs individual cell execution, not the program as a whole.

**Program-level effect** (informational only): the join of all cells in the program. Useful for documentation and capability auditing, but does NOT govern runtime behavior.

### 3.4 Key laws

1. **Pure determinism**: same inputs → same outputs. Pure cells are cacheable (referential transparency).
2. **Replayable bounded retry**: runtime can auto-retry up to N times (configurable per-cell, default 3), producing bottom on exhaustion.
3. **Replayable retry safety**: retrying a Replayable cell has no observable effect on the tuple space — no mutation occurs until submission passes validation.
4. **NonReplayable cascade-thaw**: retry requires `thaw(cell, gen)` which invalidates all transitive dependents.
5. **Effect monotonicity**: a cell cannot exceed its declared effect level. The handler rejects operations above the declared level. **Caveat**: effect inference may be unsound (a soft cell prompt could instruct an LLM to produce SQL); the runtime validates dynamically at submission time.
6. **Handler equivalence for Pure**: any handler produces the same result for Pure cells.
7. **Thaw-pour cancellation**: `thaw(c, g); pour(c)` is equivalent to `reset(c, g)` — thaw fully undoes pour's DAG extensions for the affected cells.

---

## 4. Execution Model

### 4.1 The deterministic executor

The executor processes cells individually in topological order of the DAG:

```
loop:
  find cell where all givens are frozen AND not claimed AND not frozen
  if none: return quiescent (polling, not blocking)

  match cell.effect:
    Pure:
      execute inline (literal, sql-query with purity check)
      freeze yields
      continue loop

    Replayable:
      dispatch to piston
      on submit:
        check PureCheck oracles (deterministic) BEFORE writing
        IF pass: write yield to DB, freeze, continue loop
        IF fail: reject, auto-retry (up to N per cell), then bottom
      between retries: no tuple space mutation (cell stays "computing")

    NonReplayable:
      IF effects are Dolt-only (SQLExec, Spawn):
        execute in Dolt transaction (BEGIN/COMMIT)
        on failure: ROLLBACK, cascade-thaw
      IF effects include ExtIO:
        create Dolt branch `piston/{id}`
        dispatch to piston on branch
        on submit: validate on branch, merge to main
        on failure: drop branch, cascade-thaw
```

### 4.2 Oracle ordering (critical fix)

Yields MUST be validated BEFORE writing to the database. The current implementation writes then checks — this is **unsound** (violates append-only invariant via DELETE+re-INSERT on retry). The correct order:

```
1. Piston submits value (held in memory, NOT written to DB)
2. Runtime checks all PureCheck oracles against the value
3. IF pass: write yield to DB, freeze
4. IF fail: reject submission, allow retry (do NOT write)
```

### 4.3 NonReplayable isolation (two modes)

**Transaction isolation** (for Dolt-only effects — SQLExec, Spawn):
Dolt supports `BEGIN`/`COMMIT`/`ROLLBACK`. This is cheaper than branching (~1ms vs ~500ms) and sufficient when all effects go through Dolt. On failure, ROLLBACK undoes the transaction.

**Branch isolation** (for external effects — ExtIO, net):
When a cell has effects outside Dolt, transaction rollback is insufficient. Branch-per-piston provides full isolation:
1. Claim creates Dolt branch `piston/{id}`
2. Piston operates on its branch (full SQL access — can't hurt main)
3. Runtime validates yield on the branch
4. Runtime merges branch to main (the authority boundary)
5. Branch dropped

### 4.4 Cascade-thaw mechanics

When a NonReplayable cell fails and requires thaw:

```
thaw(cell, gen):
  1. Bottom all transitive dependent frames at the current generation
  2. Release any active claims on those frames (stale claims)
  3. Create gen N+1 frames for the thawed cell and all dependents
  4. The thawed cell and dependents return to "declared" state at gen N+1
  5. DOLT_COMMIT records the thaw as an epoch boundary
```

Reference implementation: `ct thaw` (commit `c8ccdc0`).

### 4.5 Cell-zero-eval and mixed-effect stems

`cell-zero-eval` is the meta-program where pistons pour and evaluate other programs. Its stem cells (`eval-one`, `pour-one`) are mixed-effect: the LLM call is Replayable, but the SQL mutations (INSERT cells, UPDATE state) are NonReplayable.

**Canonical decomposition pattern**: split mixed-effect stems into sub-cells:
- A Replayable cell that produces the LLM judgment (what to do)
- A NonReplayable cell that executes the SQL (doing it)

This keeps the effect lattice honest and allows the Replayable part to be auto-retried without cascading.

---

## 5. Proof Obligations

### 5.1 Carried forward (from Retort.lean)
- `wellFormed_preserved`: all RetortOps map wellFormed → wellFormed
- `claim_mutex`: INSERT IGNORE + UNIQUE(frame_id) → at most one piston per frame
- `yield_immutability`: frozen yields never change

### 5.2 New (from tuple space reframing)
- **Linda laws**: `out(t); inp(t)` retrieves the same tuple (grounded in append-only proofs)
- **Time-travel safety**: `thaw(cell, g)` preserves well-formedness; cascade terminates (gen is bounded)
- **Branch isolation**: operations on branch B do not affect main (for Dolt-routed effects only)
- **Merge correctness**: merging a branch with valid yields preserves main's well-formedness (requires disjoint yield sets)

### 5.3 New (from effect distinction)
- **Pure cell determinism**: same inputs → same outputs (provable for literals; for SQL, requires purity precondition on query)
- **Replayable bounded retry**: total correctness with decreasing retry budget as variant
- **Replayable retry effect-freedom**: no tuple-space mutation between retries
- **NonReplayable cascade-thaw correctness**: thaw preserves well-formedness, cascade terminates, thaw-pour cancellation holds
- **Effect monotonicity**: a cell cannot exceed its declared effect level (provable for handler-typed execution; inference soundness is a separate obligation)

### 5.4 What cannot be proved
- `bodiesFaithful` for LLM pistons — remains a runtime assumption
- Oracle semantic correctness — LLM judge may be wrong
- Effect inference soundness for prompt injection — an LLM instructed to emit DML via prompt cannot be caught by the effect system; runtime validates at submission
- **Scope confinement**: provable for cells whose effects route through Dolt (branch isolation). NOT provable for cells using `ExtIO` — external effects escape the branch boundary

### 5.5 Weakest preconditions

For producing a **non-bottom** result:

```
wp(pure_cell, non_bottom)          = inputs_resolved ∧ body_deterministic
wp(replayable_cell, non_bottom)    = inputs_resolved ∧ retryBudget > 0
wp(nonreplayable_cell, non_bottom) = inputs_resolved ∧ authorized ∧ (transaction_available ∨ branch_created)
```

For producing **any valid result** (including bottom):

```
wp(any_cell, valid) = inputs_resolved
```

---

## 6. Syntax (minimal)

The .cell DSL stays small. Effect annotations ride on the existing parenthetical:

```
cell seed (pure)
  yield n = 10

cell compute (replayable, retries=5)
  given seed.n
  yield sequence
  ---
  Generate the first «n» Fibonacci numbers as a JSON array.
  ---
  check sequence is a valid JSON array

cell deploy (nonreplayable, sql:write)
  given compute.sequence
  yield status
  ---
  dml: INSERT INTO results (data) VALUES (?)
  ---
```

**Default inference** (backward compatible, runtime validates dynamically):
- `yield x = "literal"` → Pure
- `sql: SELECT ...` (no volatile functions) → Pure
- `sql: SELECT ...` (with NOW/RAND) → Replayable
- Soft cell with body text → Replayable
- `(stem)` → **Replayable** (NOT NonReplayable — stems default to oracle-like)
- `(stem)` with DML/Spawn/ExtIO in body → NonReplayable
- `dml:` or `sql:` containing DML → NonReplayable

Annotation tokens: `pure`, `replayable`, `nonreplayable`, `stem`, `sql:read`, `sql:write`, `sql:ddl`, `io`, `net`, `retries=N`.

---

## 7. Implementation Path

| # | Change | Touches | Effort | Blocked by |
|---|--------|---------|--------|------------|
| 0a | Frame migration (re-key cell_id → frame_id) | schema, eval.go, parse.go | 5 days | — |
| 0b | Drop cells.state (derive from frames) | schema, eval.go, watch.go | 3 days | 0a |
| 0c | Fix stem completion + guard poison bugs | eval.go | 2 days | 0a |
| 1 | Fix oracle ordering (validate before write) | eval.go, procedures.sql | 1 day | — |
| 2 | Add `effect` column to cells table | retort-init.sql, parse.go | 0.5 day | 0a |
| 3 | Infer effect level at pour time | parse.go (cellsToSQL) | 1 day | 2 |
| 4a | Transaction isolation for Dolt-only NonReplayable | eval.go | 1 day | 0a |
| 4b | Branch isolation for ExtIO NonReplayable | eval.go | 3 days | 4a |
| 5 | Auto-retry for Replayable cells (configurable N) | eval.go | 1 day | 1 |
| 6 | Split `sql:` into `sql-query:` / `dml:` | parse.go, eval.go | 1 day | 3 |
| 7 | Formal model: EffLevel in Lean | TupleSpace.lean, Core.lean | 2 days | — |

Prerequisites: ~10 days (0a-0c). Spec work: ~11 days (1-7). Items 1 and 7 can start in parallel with prerequisites.

---

## 8. The Sentence on the Box

> Cell is a versioned tuple space where programs run deterministically until
> they need judgment, and the runtime manages the boundary — retrying,
> rewinding, and letting the program grow.

# Cell: A Versioned Tuple Space with Effect-Aware Execution

**Draft v0 (do-wl6f.1)** — 2026-03-18
**Status**: Draft — shape over polish. Synthesized from Wadler, Milner, Dijkstra sage specs.

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
| `pour(cells)` | `out` | Add tuples to the space | Pure (append-only) |
| `claim(frame, piston)` | `in` | Destructive read with linear token | Pure (mutex via UNIQUE) |
| `submit(handle, yields)` | — | Consume token, write results | Pure (append yields, remove claim) |
| `observe(query)` | `rd` | Non-destructive read | Pure (read frozen yields) |
| `thaw(cell, gen)` | — | Time-travel rewind | NonReplayable (cascade-thaw) |

`claim` returns a **linear token** (the `ClaimHandle`). The token must be consumed exactly once — by `submit` or `release`. This is enforced by `INSERT IGNORE + UNIQUE(frame_id)`.

### 2.3 Properties

1. **Append-only**: `pour` and `submit` only append. No deletion except `thaw` (which creates gen N+1 frames).
2. **Claim mutex**: at most one piston per frame (`Claims.lean: always_mutex_on_valid_trace`).
3. **Yield immutability**: once frozen, a yield value never changes.
4. **DAG acyclicity**: givens form a DAG over cell names (`noSelfLoops`, `generationOrdered`).
5. **Time-travel safety**: `thaw(cell, g)` produces a valid tuple space with cells at gen g-1 state.
6. **Branch isolation**: operations on branch B do not affect main until merge.

---

## 3. Effect Lattice

Effects are classified by **recoverability** — what happens when the operation fails:

```
Pure  <  Replayable  <  NonReplayable
```

### 3.1 Definitions

| Level | Meaning | Failure recovery | Runtime behavior |
|---|---|---|---|
| **Pure** | Deterministic, no external agent needed | Retry is free (same result) | Execute inline, no pause |
| **Replayable** | Non-deterministic value production (LLM oracle) | Auto-retry (bounded, N attempts) | Pause at boundary, auto-retry on failure, bottom on exhaustion |
| **NonReplayable** | Mutates tuple space or external world | Cascade-thaw required (Dolt time travel) | Pause for authorization, branch isolation, merge-on-approval |

### 3.2 Operation classification

```
PistonOp : EffLevel -> Type -> Type

-- Pure operations
Lookup   : FieldName -> PistonOp Pure String       -- read resolved given
Yield    : FieldName -> String -> PistonOp Pure ()  -- write yield value
SQLQuery : String -> PistonOp Pure String           -- read-only SQL (SELECT)

-- Replayable operations
LLMCall  : String -> PistonOp Replayable String     -- invoke LLM oracle
OracleChk: Assertion -> String -> PistonOp Replayable Bool  -- check oracle

-- NonReplayable operations
SQLExec  : String -> PistonOp NonReplayable String  -- SQL DML (INSERT/UPDATE/DELETE)
Spawn    : CellDef -> PistonOp NonReplayable ()     -- pour new cells
Thaw     : CellName -> Gen -> PistonOp NonReplayable ()  -- cascade rewind
ExtIO    : IOAction -> PistonOp NonReplayable String -- external side effect
```

### 3.3 Composition

The join semilattice governs composition:

```
join(Pure, e) = e
join(Replayable, Replayable) = Replayable
join(_, NonReplayable) = NonReplayable
```

A cell's effect level is the join of all operations it uses. A program's effect level is the join of all its cells.

### 3.4 Key laws

1. **Pure determinism**: same inputs → same outputs. Pure cells are cacheable.
2. **Replayable bounded retry**: runtime can auto-retry up to N times, producing bottom on exhaustion.
3. **NonReplayable cascade-thaw**: retry requires `thaw(cell, gen)` which invalidates all transitive dependents.
4. **Effect monotonicity**: a cell declared Pure cannot perform Replayable or NonReplayable operations.
5. **Handler equivalence for Pure**: any handler produces the same result for Pure cells (parametricity of purity).

---

## 4. Execution Model

### 4.1 The deterministic executor

The executor processes cells in topological order of the DAG:

```
loop:
  find cell where all givens are frozen AND not claimed AND not frozen
  match cell.effect:
    Pure:
      execute inline (literal, sql-query)
      freeze yields
      continue loop
    Replayable:
      pause — dispatch to piston
      on submit: check oracles BEFORE writing yields
        pass → freeze yields, continue loop
        fail → auto-retry (up to N), then bottom
    NonReplayable:
      pause — dispatch to piston on isolated branch
      on submit: validate on branch, merge to main
        pass → freeze yields, continue loop
        fail → drop branch, cascade-thaw, re-pour
```

### 4.2 Oracle ordering (critical fix)

Yields MUST be validated BEFORE writing to the database. The current implementation writes then checks — this is unsound. The correct order:

```
1. Piston submits value
2. Runtime checks all deterministic oracles against the value
3. IF pass: write yield to DB, freeze
4. IF fail: reject submission, allow retry (do NOT write)
```

### 4.3 Branch-per-piston isolation

For NonReplayable cells:

```
1. claim creates Dolt branch `piston/{id}`
2. Piston operates on its branch (full SQL access — can't hurt main)
3. Runtime validates yield on the branch (oracles, scope check)
4. Runtime merges branch to main (the authority boundary)
5. Branch dropped
```

For Replayable cells: no branch needed — the piston produces a value, the runtime validates and writes. Auto-retry is cheap because no state was mutated.

For Pure cells: no piston interaction at all — the runtime executes directly.

---

## 5. Proof Obligations

### 5.1 Carried forward (from Retort.lean)
- `wellFormed_preserved`: all RetortOps map wellFormed → wellFormed
- `claim_mutex`: INSERT IGNORE + UNIQUE(frame_id) → at most one piston per frame
- `yield_immutability`: frozen yields never change

### 5.2 New (from tuple space reframing)
- **Linda laws**: `out(t); in(t)` retrieves the same tuple (grounded in append-only proofs)
- **Time-travel safety**: `thaw(cell, g)` preserves well-formedness
- **Branch isolation**: operations on branch B do not affect main
- **Merge correctness**: merging a branch with valid yields preserves main's well-formedness

### 5.3 New (from effect distinction)
- **Pure cell determinism**: same inputs → same outputs (provable for literals and deterministic SQL)
- **Replayable bounded retry**: total correctness with decreasing retry budget
- **NonReplayable cascade-thaw correctness**: thaw preserves well-formedness, cascade terminates
- **Effect monotonicity**: a cell cannot exceed its declared effect level (handler typing)

### 5.4 What cannot be proved
- `bodiesFaithful` for LLM pistons — remains a runtime assumption
- Oracle semantic correctness — LLM judge may be wrong
- **BUT**: scope confinement IS now provable under branch isolation (piston literally cannot access data outside its branch)

### 5.5 Weakest preconditions

```
wp(pure_cell)          = inputs_resolved ∧ body_deterministic
wp(replayable_cell)    = inputs_resolved ∧ retryBudget > 0
wp(nonreplayable_cell) = inputs_resolved ∧ authorized ∧ branch_created
```

---

## 6. Syntax (minimal)

The .cell DSL stays small. Effect annotations ride on the existing parenthetical:

```
cell seed (pure)
  yield n = 10

cell compute (replayable)
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

**Default inference** (backward compatible):
- `yield x = "literal"` → Pure
- `sql: SELECT ...` → Pure
- Soft cell with body text → Replayable
- `(stem)` → NonReplayable
- `dml:` or `sql:` containing DML → NonReplayable

Seven annotation tokens: `pure`, `replayable`, `nonreplayable`, `sql:read`, `sql:write`, `sql:ddl`, `io`, `net`.

---

## 7. Implementation Path

| # | Change | Touches | Effort |
|---|--------|---------|--------|
| 1 | Fix oracle ordering (validate before write) | `eval.go`, `procedures.sql` | 1 day |
| 2 | Add `effect` column to cells table | `retort-init.sql`, `parse.go` | 0.5 day |
| 3 | Infer effect level at pour time | `parse.go` (cellsToSQL) | 1 day |
| 4 | Branch-per-piston for NonReplayable cells | `eval.go` (replEvalStep) | 3 days |
| 5 | Auto-retry for Replayable cells | `eval.go` (replEvalStep) | 1 day |
| 6 | Split `sql:` into `sql-query:` / `dml:` | `parse.go`, `eval.go` | 1 day |
| 7 | Formal model: EffLevel in Lean | `TupleSpace.lean`, `Core.lean` | 2 days |

Total: ~10 days. Items 1-3 can proceed in parallel. Item 4 is the infrastructure. Items 5-7 build on it.

---

## 8. The Sentence on the Box

> Cell is a versioned tuple space where programs run deterministically until
> they need judgment, and the runtime manages the boundary — retrying,
> rewinding, and letting the program grow.

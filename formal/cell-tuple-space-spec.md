# Cell: A Versioned Tuple Space with Effect-Aware Execution

**v3 (do-wl6f.4)** — 2026-03-19
**Status**: Refine 3 (edge cases). Added Section 4.6 covering 12 edge cases.

---

## 0. Prerequisites

These existing bugs block implementation of this spec:

| Bug | What | Why it blocks |
|-----|------|---------------|
| do-7i1.5 | Frame migration: re-key from cell_id to frame_id | Branch isolation and effect tracking need frame-keyed tables |
| do-7i1.3 | Drop `cells.state`: derive state from frames | Clean effect model requires single source of truth |
| do-92tf | Stem completion: programs complete before stems run | Stem effect model requires stems to participate in completion |
| do-71ms | Guard-skip bottom propagation poisons downstream | Thaw semantics must distinguish "failed" from "intentionally skipped" |

Estimated: ~10 days prerequisites, ~11 days spec implementation.

---

## 1. What Cell Is

Cell is a **shared workspace** where:

1. **Programs are DAGs of cells** — each cell has inputs (givens), outputs (yields), and a body
2. **The workspace is a Dolt database** — every change is versioned, branchable, and rewindable
3. **A deterministic executor** runs cells it can compute (literals, SQL queries) without external help
4. **When it can't compute**, it pauses and hands the cell to an external agent (an LLM "piston")
5. **The agent produces a value**, the runtime validates it, and execution resumes
6. **If the agent fails**, the runtime either retries automatically or rewinds the workspace

The key insight: **effects are classified by what happens on failure**, not by what they are. A cell that calls an LLM can be retried cheaply (just re-ask). A cell that writes to the database requires rewinding. This distinction — replayable vs. non-replayable — drives the entire execution model.

### In one sentence

> Cell is a versioned tuple space where programs run deterministically until they
> need judgment, and the runtime manages the boundary — retrying, rewinding, and
> letting the program grow.

### Prior art

| System | Relationship to Cell |
|--------|---------------------|
| **Linda** (Gelernter 1985) | Cell's direct ancestor. Shared tuple space with `out` (add), `in` (consume), `rd` (observe). Cell adds: time travel, structured tuples, semantic matching |
| **Blackboard architecture** (Hearsay-II) | Independent agents read/write a shared workspace. Cell adds: dependency DAGs, effect-aware scheduling |
| **Haskell do-notation** | Sequences effects with intermediate bindings. Cell differs: the boundary between pure and effectful is a runtime construct managed by the executor, not a type-level abstraction managed by the programmer |

### What Cell adds beyond these

1. **Time travel**: consuming a tuple is reversible (Dolt commit history preserves every prior state)
2. **Structured tuples**: cells have dependency DAGs, not flat fields — the executor knows the evaluation order
3. **Semantic matching**: the LLM reads the tuple because the tuple is natural language
4. **Self-extension**: agents can add new cells with new DAGs — programs grow at runtime

---

## 2. The Tuple Space

### 2.1 What's in the space

Each **cell** is a structured tuple:

```
Cell := {
  name:    CellName,           -- unique within a program
  body:    Body,               -- what to compute (see below)
  givens:  [GivenSpec],        -- inputs: references to other cells' yields
  yields:  [FieldName],        -- output slots: empty until frozen
  effect:  Pure | Replayable | NonReplayable  -- recoverability class
}

Body :=
  | literal(value)             -- Pure: yield a constant
  | sql-query(SELECT ...)      -- Pure: read-only SQL (no volatile functions)
  | sql-exec(INSERT/UPDATE...) -- NonReplayable: SQL that mutates
  | prompt(text)               -- Replayable: natural language for an LLM
  | stem(text)                 -- Replayable by default; NonReplayable if body contains DML/Spawn
```

Cells form a **DAG** through their givens: cell B's given `A.x` means "B needs the value of A's yield `x` before B can run." The executor uses this DAG to determine evaluation order.

### 2.2 Five operations

| Operation | What it does | Linda equivalent | Example |
|-----------|-------------|-----------------|---------|
| **pour** | Add cells to the space | `out` (generative) | `ct pour myprogram file.cell` |
| **claim** | Reserve a ready cell for evaluation (non-blocking) | `inp` (probe) | A piston locks frame F; others get "already claimed" |
| **submit** | Provide the value for a claimed cell's yields | — (consumes claim token) | `ct submit prog cell field "value"` |
| **observe** | Read frozen yields without modifying anything | `rd` (non-destructive) | Reading resolved givens before evaluation |
| **thaw** | Rewind a cell and its dependents to an earlier generation | — (no Linda equivalent) | `ct thaw cell` creates gen N+1 frames, re-evaluates |

**Claim is non-blocking**: unlike Linda's `in` which blocks until a matching tuple exists, Cell's `claim` returns "quiescent" immediately if no cell is ready. The executor polls. Progress is guaranteed by `ProgressiveTrace`: under fair scheduling, the count of unfrozen cells monotonically decreases.

**Claim produces a linear token**: the `ClaimHandle` must be consumed exactly once by either `submit` (success) or `release` (give up). This is enforced by `INSERT IGNORE + UNIQUE(frame_id)` in Dolt — only one piston can hold a frame at a time.

### 2.3 Invariants

These hold at all times (proved in Lean for the first four):

1. **Append-only**: `pour` and `submit` only add data. Nothing is deleted except by `thaw`.
2. **Claim mutex**: at most one piston per frame.
3. **Yield immutability**: once a yield is frozen, its value never changes.
4. **DAG acyclicity**: the given-yield graph has no cycles.
5. **Time-travel safety**: `thaw` produces a valid tuple space (see Section 4.4).
6. **Branch isolation**: a piston's branch cannot affect main until the runtime merges it. *Caveat*: only holds for effects routed through Dolt; external IO escapes branch boundaries.

---

## 3. The Effect Lattice

### 3.1 The core idea

When a cell's evaluation fails, what can the runtime do about it?

| Effect level | What it means | On failure | Cost of recovery |
|-------------|--------------|-----------|-----------------|
| **Pure** | Same inputs always produce the same output | Retry for free (deterministic) | Zero — just re-execute |
| **Replayable** | Produces a value without mutating anything | Auto-retry (bounded, N attempts) | Cheap — re-ask the LLM |
| **NonReplayable** | Mutates the workspace or external world | Cascade-thaw: rewind and redo | Expensive — undo all downstream work |

These form a **total order**: `Pure < Replayable < NonReplayable`. The `max` of two levels gives the combined level.

### 3.2 Which operations live at which level

**Pure** — the runtime computes these without any external agent:

| Operation | What | Example |
|-----------|------|---------|
| `Lookup` | Read a resolved given | Reading `seed.n = 10` |
| `YieldVal` | Write a yield value | Freezing `target.value = "claimed"` |
| `SQLQuery` | Read-only SQL (no volatile functions) | `sql: SELECT CAST(10 + 25 AS CHAR)` |
| `PureCheck` | Deterministic oracle | `check result is not empty` |

**Replayable** — the runtime pauses for an external agent but can retry automatically:

| Operation | What | Example |
|-----------|------|---------|
| `LLMCall` | Invoke an LLM with a prompt | Soft cell body: "Sort these items..." |
| `LLMJudge` | LLM evaluates a semantic oracle | `check~ sorted is in ascending order` |

**NonReplayable** — the runtime pauses and requires authorization; failure requires rewinding:

| Operation | What | Example |
|-----------|------|---------|
| `SQLExec` | SQL that modifies data | `dml: INSERT INTO results VALUES (?)` |
| `Spawn` | Add new cells to the space (from a piston) | cell-zero-eval pouring a new program |
| `Thaw` | Rewind a cell to a prior generation | `ct thaw` with cascade |
| `ExtIO` | External side effects (network, filesystem) | Sending a message, writing a file |

**Note on SQLQuery purity**: A `SELECT` is Pure only when it (a) contains no volatile functions (`NOW()`, `RAND()`, etc.) and (b) reads only from frozen/committed data. The parser checks (a) at pour time; the runtime enforces (b) at execution.

**Note on PureCheck vs LLMJudge**: Deterministic oracles like `check X is not empty` are `PureCheck` (Pure). Semantic oracles like `check~ X follows the 5-7-5 pattern` spawn an LLM judge cell and are `LLMJudge` (Replayable). This matters because a simple format check should not inflate a cell's effect level.

### 3.3 How effects compose

A **cell's** effect level = max of all operations it uses. The executor decides isolation **per-cell**, not per-program:

- A Pure cell in a program that also has NonReplayable cells still executes inline without isolation
- A program's "effect level" is informational (the max across all cells) — useful for auditing but does not change runtime behavior

### 3.4 Laws

1. **Pure determinism**: same inputs → same outputs. Pure cells are cacheable.
2. **Replayable retry safety**: retrying has no observable effect on the tuple space — no data is written until validation passes.
3. **Replayable bounded retry**: the runtime retries up to N times (configurable per-cell, default 3), then produces bottom.
4. **NonReplayable cascade-thaw**: retry requires `thaw(cell, gen)`, which invalidates all transitive dependents.
5. **Effect monotonicity**: a cell cannot perform operations above its declared level. *Caveat*: effect inference from syntax can be fooled (an LLM prompt could instruct the piston to emit SQL); the runtime validates at submission.
6. **Handler equivalence for Pure**: any handler produces the same result for Pure cells.
7. **Thaw-pour cancellation**: `thaw(c, g)` followed by `pour(c)` is equivalent to `reset(c, g)`.

---

## 4. Execution Model

### 4.1 The executor loop

```
loop:
  cell = findReadyCell()
    -- ready = all givens frozen, not claimed, not frozen
    -- returns immediately (polling, not blocking)
  if no cell ready: return "quiescent"

  match cell.effect:

    Pure:
      result = execute(cell.body)    -- literal value, SQL query, etc.
      validate(result, cell.oracles) -- PureCheck only
      freeze(cell, result)           -- write yields, mark frozen
      continue loop

    Replayable:
      dispatch(cell, piston)         -- send prompt + resolved givens to piston
      value = awaitSubmission()      -- piston calls ct submit
      if validate(value, cell.oracles):  -- check BEFORE writing (critical!)
        freeze(cell, value)
        continue loop
      else:
        retryBudget--
        if retryBudget > 0: goto dispatch  -- auto-retry
        else: bottom(cell)                  -- give up

    NonReplayable:
      if cell uses only Dolt effects (SQLExec, Spawn):
        BEGIN TRANSACTION
        result = execute(cell.body)
        if validate(result):
          COMMIT; freeze(cell, result); continue loop
        else:
          ROLLBACK; cascadeThaw(cell)
      else:  -- cell uses ExtIO
        branch = createBranch("piston/" + pistonId)
        dispatch(cell, piston, on: branch)
        value = awaitSubmission()
        if validate(value):
          mergeBranch(branch); freeze(cell, value); continue loop
        else:
          dropBranch(branch); cascadeThaw(cell)
```

### 4.2 Oracle ordering (critical fix from current codebase)

**Current bug**: `cell_submit` in `procedures.sql` writes the yield to the database, THEN checks oracles. A failed oracle leaves an artifact — a written-but-unfrozen yield. On retry, the procedure DELETEs and re-INSERTs, violating the append-only invariant.

**Required fix**: validate BEFORE writing. The piston's submitted value is held in memory. Oracles run against the in-memory value. Only on success is the value written to Dolt.

### 4.3 Two modes of NonReplayable isolation

| Mode | When | Cost | Mechanism |
|------|------|------|-----------|
| **Transaction** | Cell effects are Dolt-only (SQLExec, Spawn) | ~1ms | `BEGIN`/`COMMIT`/`ROLLBACK` |
| **Branch** | Cell has external effects (ExtIO, net) | ~500ms | Dolt branch per piston, merge on success |

Transaction isolation is the common case and is cheap. Branch isolation is reserved for cells that can affect systems outside Dolt, where transaction rollback is insufficient.

### 4.4 Cascade-thaw: rewinding on failure

When a NonReplayable cell fails and cannot be retried:

```
cascadeThaw(cell):
  dependents = transitiveDependents(cell)  -- all cells reachable via givens
  for each frame in [cell] ++ dependents:
    bottom(frame, currentGeneration)        -- mark as failed
    releaseClaim(frame)                     -- free any active claims
    createFrame(frame, generation + 1)      -- new frame, "declared" state
  DOLT_COMMIT("thaw: cascade from " + cell.name)
```

After cascade-thaw, the cell and all its dependents are back to "declared" at the next generation. The executor will re-evaluate them from scratch. Previous generation data remains in Dolt history for audit.

### 4.5 Cell-zero-eval: the meta-program

`cell-zero-eval` is where pistons pour and evaluate other programs. Its stems (`eval-one`, `pour-one`) mix effects: the LLM call is Replayable, but the SQL mutations are NonReplayable.

**Recommended pattern — decompose mixed-effect stems**:

```
cell decide (replayable, stem)       -- LLM decides what to do
  given pour-request.text
  yield action
  ---
  Read the .cell text. Decide what SQL to execute to pour it.
  ---

cell execute (nonreplayable, stem)   -- runtime executes the decision
  given decide.action
  yield status
  ---
  dml: ... (the SQL from decide.action)
  ---
```

This lets the Replayable part be auto-retried without cascading.

### 4.6 Edge cases

These scenarios are not obvious from the main execution model and require explicit handling.

**E1: Concurrent thaw**
Two pistons independently thaw cells with overlapping transitive dependents. If A and B share dependent C, both thaw cascades try to bottom C and create gen N+1 frames.
**Resolution**: Thaw acquires a program-level mutex (one thaw at a time per program). Concurrent thaws from different programs are safe because programs have disjoint cell namespaces.

**E2: Claim timeout**
A piston claims a Replayable cell, then crashes or hangs. The cell stays "computing" forever.
**Resolution**: Claims have a TTL (default 2 minutes, already implemented in `replEvalStep`). The stale-claim reaper releases expired claims and returns cells to "declared." The retry budget is NOT decremented by a timeout — timeouts are infrastructure failures, not evaluation failures.

**E3: Piston submits to wrong cell**
A piston holding a claim on cell A submits a value for cell B.
**Resolution**: The runtime rejects submissions where the claim handle doesn't match the target cell. Currently NOT enforced — `ct submit` takes cell name as a free argument. The linear token model (Section 2.2) requires this check.

**E4: SQL query with volatile functions**
A cell declared `(pure)` has body `sql: SELECT NOW()`. The parser infers Pure, but the query is non-deterministic.
**Resolution**: The parser maintains a denylist of volatile SQL functions (`NOW`, `RAND`, `UUID`, `CURRENT_USER`, `CURRENT_TIMESTAMP`, `SYSDATE`). If any are present, the inferred effect is elevated to Replayable. Authors can override with explicit `(pure)` annotation — at their own risk.

**E5: Replayable cell with all retries exhausted**
A Replayable cell has `retries=3`, all three fail oracle checks. The cell bottoms.
**Resolution**: Bottom propagates to all transitive dependents (same as NonReplayable failure but without cascade-thaw — no gen N+1 frames are created because no state was mutated). The program may be quiescent with some cells frozen and some bottomed.

**E6: Guard-skip vs. failure bottom**
A `recur until` guard fires at iteration 2, skipping iterations 3-4. Skipped cells are bottomed. Downstream cells that depend on `reflect[*]` (all iterations) see bottomed inputs and bottom-propagate.
**Resolution**: Introduce a distinct bottom reason: `bottom:guard-skip` vs. `bottom:failure`. The `hasBottomedDependency` check should ignore `bottom:guard-skip` for optional givens and fan-in patterns (`[*]`). Only `bottom:failure` triggers poison propagation. *This requires fixing bug do-71ms.*

**E7: Mixed-effect stem without decomposition**
An author writes a stem cell that both calls an LLM and executes SQL DML in the same body, without decomposing into sub-cells (Section 4.5).
**Resolution**: The parser detects mixed effects in stem bodies (prompt text + `dml:` or `sql:` with DML) and emits a warning recommending decomposition. The cell is classified NonReplayable (max of its operations). The warning is advisory, not an error — the system still works, just with coarser recovery.

**E8: Pour of a program that already exists**
`ct pour myprogram file.cell` when `myprogram` already has cells.
**Resolution**: Already handled — pour is additive and errors with "program already has N cells — pour is additive. To overwrite, first run: ct reset." No change needed.

**E9: Branch merge conflict**
A NonReplayable cell on a branch modifies the same row as a concurrent operation on main (e.g., two pistons both try to freeze the same yield).
**Resolution**: Dolt merge conflicts are detected at merge time. The runtime rejects the merge and drops the branch — equivalent to a NonReplayable failure, triggering cascade-thaw. The claim mutex (UNIQUE on frame_id) prevents most conflicts; this edge case arises only if the branch modifies non-claim state.

**E10: Piston reads data outside its scope**
A Replayable piston calls an LLM. The LLM's prompt includes resolved givens, but the piston's database connection can also query arbitrary tables.
**Resolution**: For Replayable cells, the piston receives only the prompt + resolved givens (no direct database access). The runtime constructs the prompt and the piston returns only yield values. For NonReplayable cells with transaction isolation, the piston operates within a transaction scoped to its frame's tables. For branch isolation, the branch limits visibility.

**E11: Self-referential spawn**
A stem cell in cell-zero-eval spawns a copy of itself (self-replication). This could create unbounded growth.
**Resolution**: Spawn is NonReplayable and requires authorization. The runtime enforces a per-program cell count limit (configurable, default 1000). Spawn that would exceed the limit is rejected and the cell bottoms. The `stemHasDemand` predicate in the formal model should be constrained to be monotone — once demand is false, it stays false.

**E12: Partial multi-yield submission**
A cell has three yields (`word_count`, `char_count`, `longest_word`). The piston submits two but not the third.
**Resolution**: A cell is frozen only when ALL yields are submitted. Partial submission is valid — the submitted yields are held in a pending state. The cell remains "computing" until all yields arrive or the claim times out. On timeout, all pending yields are discarded and the cell returns to "declared."

---

## 5. Proof Obligations

### 5.1 Already proved (from Retort.lean, unchanged)

| Property | Theorem | What it means |
|----------|---------|---------------|
| Database safety | `wellFormed_preserved` | Every operation maps a valid state to a valid state |
| Claim exclusivity | `always_mutex_on_valid_trace` | At most one piston per frame |
| Yield permanence | `always_yields_preserved_on_valid_trace` | Frozen yields never change |

### 5.2 New: tuple space properties

| Property | Status | What it means |
|----------|--------|---------------|
| Linda out/inp consistency | Derivable from append-only | What you pour, you can later claim |
| Time-travel safety | Needs proof | Thaw produces a valid tuple space |
| Branch isolation | Axiom (from Dolt COW) | Operations on a branch don't affect main |
| Merge correctness | Needs proof | Merging valid branches preserves validity |

### 5.3 New: effect properties

| Property | Status | What it means |
|----------|--------|---------------|
| Pure determinism | Provable (literals, safe SQL) | Same inputs → same outputs |
| Replayable retry safety | Provable (validate-before-write) | No mutation between retries |
| Replayable bounded termination | Provable (budget as variant) | Retries always terminate |
| Cascade-thaw correctness | Needs proof | Thaw preserves validity, cascade terminates |
| Effect monotonicity | Provable (handler typing) | Cell can't exceed declared level |

### 5.4 What cannot be proved

| Property | Why | Mitigation |
|----------|-----|------------|
| `bodiesFaithful` | LLM pistons are opaque | Runtime validates output, not process |
| Oracle semantic correctness | LLM judges may be wrong | Multiple judges, human review |
| Effect inference soundness | Prompt injection can hide effects | Runtime validates at submission |
| Scope confinement for ExtIO | External effects escape branches | Only provable for Dolt-only cells |

### 5.5 Weakest preconditions

For **non-bottom** termination:

| Cell type | Precondition |
|-----------|-------------|
| Pure | `inputs_resolved ∧ body_deterministic` |
| Replayable | `inputs_resolved ∧ retryBudget > 0` |
| NonReplayable | `inputs_resolved ∧ authorized ∧ (transaction ∨ branch)` |

For **any valid result** (including bottom): just `inputs_resolved`.

---

## 6. Syntax

The DSL stays minimal. Effect annotations extend the existing `(stem)` parenthetical:

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

### Default inference (backward compatible)

| Pattern | Inferred effect |
|---------|----------------|
| `yield x = "literal"` | Pure |
| `sql: SELECT ...` (no volatile functions) | Pure |
| `sql: SELECT NOW()` or `RAND()` | Replayable |
| Soft cell (body text, no DML) | Replayable |
| `(stem)` (no DML/Spawn/ExtIO) | Replayable |
| `(stem)` with DML/Spawn/ExtIO | NonReplayable |
| `dml:` prefix | NonReplayable |

### Annotation tokens

`pure`, `replayable`, `nonreplayable`, `stem`, `sql:read`, `sql:write`, `sql:ddl`, `io`, `net`, `retries=N`

---

## 7. Implementation Path

### Phase 0: Prerequisites (~10 days)

| # | Task | Effort | Notes |
|---|------|--------|-------|
| 0a | Frame migration (cell_id → frame_id) | 5 days | Unblocks everything |
| 0b | Drop cells.state | 3 days | Needs 0a |
| 0c | Fix stem completion + guard poison | 2 days | Needs 0a |

### Phase 1: Effect-aware runtime (~11 days)

| # | Task | Effort | Needs |
|---|------|--------|-------|
| 1 | Fix oracle ordering (validate before write) | 1 day | — |
| 2 | Add `effect` column + inference at pour | 1.5 days | 0a |
| 3 | Transaction isolation for NonReplayable | 1 day | 0a |
| 4 | Branch isolation for ExtIO | 3 days | 3 |
| 5 | Auto-retry for Replayable (configurable N) | 1 day | 1 |
| 6 | Split `sql:` / `dml:` body prefixes | 1 day | 2 |
| 7 | Formal model: EffLevel in Lean | 2 days | — |

Items 1 and 7 can start in parallel with Phase 0.

---

## 8. Glossary

| Term | Meaning |
|------|---------|
| **Cell** | A structured tuple in the workspace: name + body + givens + yields + effect |
| **Piston** | An external agent (LLM or human) that evaluates cells the runtime cannot |
| **Frame** | A versioned instance of a cell — generation 0 is the original, gen N+1 after thaw |
| **Yield** | An output slot on a cell, initially empty, frozen once filled |
| **Given** | An input dependency: "this cell needs that cell's yield before it can run" |
| **Freeze** | Writing a value to a yield slot — permanent and immutable |
| **Bottom** | A cell that failed permanently — propagates to dependents |
| **Thaw** | Rewinding a cell (and its dependents) to a prior generation for re-evaluation |
| **Pour** | Loading a `.cell` program into the workspace (administrative, not a piston action) |
| **Spawn** | A piston adding new cells from within a cell body (meta-programming) |
| **Claim** | Reserving a cell for evaluation — produces a linear token consumed by submit |
| **Tuple space** | The shared workspace (the Dolt database) where all cells, yields, and claims live |
| **Linda** | Gelernter's 1985 coordination model: `out`/`in`/`rd` over a shared tuple space |

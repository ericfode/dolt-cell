# Cell Runtime Design v2: Dolt IS the Runtime

**Date**: 2026-03-14
**Status**: Approved direction — pending implementation plan
**Bead**: do-27k
**Supersedes**: 2026-03-14-cell-repl-design.md (pre-adversarial-review)

## One-Sentence Summary

The Cell runtime is Dolt stored procedures; hard cells are SQL views; the LLM
is a piston that fires when the crankshaft (stored procedures) tells it to;
the turnstyle syntax is a frontend that compiles to INSERT statements via
`cell_pour`, which itself bootstraps from soft (LLM-parsed) to hard
(deterministic parser).

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │          Dolt Database       │
                    │                              │
                    │  Retort Schema:              │
                    │    cells, givens, yields,     │
                    │    oracles, trace             │
                    │                              │
                    │  Views:                      │
                    │    cell_* (hard cells)        │
                    │    ready_cells (frontier)     │
                    │    cell_program_status        │
                    │                              │
                    │  Stored Procedures:           │
                    │    cell_pour()                │
                    │    cell_eval_step()           │
                    │    cell_submit()              │
                    │    cell_status()              │
                    │                              │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────┴───────────────────┐
                    │    LLM Pistons (1..N)         │
                    │                              │
                    │  Loop:                        │
                    │    CALL cell_eval_step()      │
                    │    if 'dispatch' → think      │
                    │    CALL cell_submit(result)   │
                    │    repeat                     │
                    └──────────────────────────────┘
```

### The Three Layers

| Layer | What | Implementation |
|-------|------|----------------|
| **Runtime** | Eval loop, DAG resolution, state management, hard cell evaluation, oracle checking, commits | Dolt stored procedures + SQL views |
| **Semantic Substrate** | Soft cell evaluation, semantic oracle checking | LLM pistons (any model, any count) |
| **Language Frontend** | Human-readable authoring format | `cell_pour` (soft → hard bootstrap) |

### What Lives Where

| Concern | Lives in | Why |
|---------|----------|-----|
| Cell definitions | Retort `cells` table | Data, not code — inspectable, quotable |
| Dependencies | Retort `givens` table | Indexed, queryable, proper foreign keys |
| Yield values | Retort `yields` table | Separate is_frozen flag, typed value columns |
| Hard cell logic | Dolt VIEWs | Evaluation = SELECT. Lazy. Composable. |
| Readiness computation | `ready_cells` VIEW | SQL, indexed, no application code |
| Eval loop | `cell_eval_step()` procedure | Atomic claim, state transitions, branching |
| Oracle checking (det.) | `cell_submit()` procedure | SQL comparisons, no LLM needed |
| Oracle checking (sem.) | LLM piston | Returned to LLM for judgment |
| Execution history | Dolt commits | Each freeze = commit. Time travel via AS OF. |
| Parallel execution | Dolt branches | Fork = branch. Compare = diff. Join = merge. |
| Status/observability | `cell_program_status` VIEW | SQL query, instant |
| Quotation (`§`) | SELECT from cells / INFORMATION_SCHEMA.VIEWS | Data is inspectable by definition |

---

## Hard Cells as Views

A hard cell is a `CREATE VIEW`. Its body is SQL. Evaluation is `SELECT * FROM
view_name`. No dispatch needed. No eval loop involvement. The database resolves
it.

```sql
CREATE VIEW cell_word_count AS
SELECT
  LENGTH(y.value_text) - LENGTH(REPLACE(y.value_text, ' ', '')) + 1 as value
FROM yields y
JOIN cells c ON y.cell_id = c.id
WHERE c.name = 'data' AND y.field_name = 'text' AND y.is_frozen = 1;
```

If upstream inputs aren't frozen, the view returns empty — readiness is implicit
in the `WHERE is_frozen = 1` clause.

Views compose: a chain of 10 hard cells is a nested SQL query that resolves
instantly. No LLM calls, no dispatch, no scheduling overhead.

Crystallization = converting a soft cell to a view:
1. LLM writes SQL that produces the same output as the `∴` body
2. Oracle verifies equivalence
3. `DROP` the soft cell row, `CREATE VIEW` with the SQL
4. The cell is now part of the database schema

### Hard Cell Executors

SQL is the default because Dolt is already running. But `⊢=` means
"deterministic," not "SQL." A hard cell can reference an external executor:

```sql
-- The cell's body column stores the executor reference
INSERT INTO cells (name, body_type, body) VALUES
  ('transform', 'hard', 'exec:./tools/transform'),
  ('query', 'hard', 'sql:SELECT ...'),
  ('check', 'hard', 'view:cell_check');
```

The `cell_eval_step` procedure dispatches based on prefix:
- `view:` → SELECT from the named view
- `sql:` → execute the SQL directly
- `exec:` → shell out to the executable (JSON in, JSON out)

SQL views are the fast path (zero overhead). External executors are the escape
hatch for when SQL isn't the right tool.

---

## Soft Cells and the Piston Model

A soft cell has a `∴` body — natural language instructions. It needs an LLM to
evaluate. The stored procedure handles everything except the thinking.

### The Piston Loop

```
LLM calls:  CALL cell_eval_step('sort-proof')
Procedure:  Finds ready soft cell, resolves inputs, interpolates «» references,
            marks cell as 'computing', returns prompt + metadata
LLM:        Reads prompt, thinks, produces output
LLM calls:  CALL cell_submit('sp-sort', 'sorted', '[1,2,3,4,7,9]')
Procedure:  Writes tentative yield, checks deterministic oracles in SQL,
            if pass → freezes + commits, if fail → returns failure for retry
LLM calls:  CALL cell_eval_step('sort-proof')
Procedure:  Next ready cell... or 'quiescent'
```

The LLM holds NO state. Every step starts fresh: call the procedure, see what
it says. The procedure maintains all state in Dolt. The LLM can't corrupt the
eval loop because it doesn't run the eval loop — SQL does.

### Multiple Pistons

Any number of LLMs can connect. The procedure handles assignment atomically:

```sql
-- Inside cell_eval_step:
SELECT id INTO ready_id FROM ready_cells
WHERE program_id = ? AND state = 'declared'
LIMIT 1 FOR UPDATE;

UPDATE cells SET state = 'computing' WHERE id = ready_id;
```

Two LLMs calling simultaneously get different cells. Confluence guarantees the
result is the same regardless of who evaluates what.

### Model Routing

Different cells can hint at different models:

```sql
INSERT INTO cells (..., model_hint) VALUES (..., 'haiku');  -- cheap/fast
INSERT INTO cells (..., model_hint) VALUES (..., 'opus');   -- deep reasoning
```

Different agents filter by affinity. Three Haiku agents churn cheap cells.
One Opus agent handles complex reasoning. All against the same Dolt database.

### Soft Cell Complexity Spectrum

| Cell | What the LLM does |
|------|-------------------|
| "Sort this list" | Thinks, responds (seconds) |
| "Summarize this document" | Reads input, thinks, responds (seconds) |
| "Write a parser for this grammar" | Uses tools, writes code, tests (minutes) |
| "Review this codebase" | Full Claude Code session with grep, read, etc. (minutes) |

For complex soft cells, the LLM uses its full toolset. The stored procedure
doesn't care how long it takes — it just waits for `cell_submit`.

---

## The Language Frontend: `cell_pour`

The turnstyle syntax is a human-readable format that compiles to INSERT
statements. `cell_pour` is the compiler.

```sql
CALL cell_pour('sort-proof', '
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» in ascending order.
  ⊨ sorted is a permutation of items
  ⊨ sorted is in ascending order
');
```

### Bootstrap Path

**Phase A: LLM parses (soft cell_pour).** The procedure sends the text to
the LLM and says "parse this into INSERT statements." The LLM is good at
structured extraction for well-defined syntax. Works TODAY with zero parser code.

**Phase B: SQL string parsing.** The turnstyle syntax is line-oriented.
`⊢` starts a cell. Indented lines are cell parts. Parseable with SQL string
functions (`SUBSTRING_INDEX`, `REGEXP`). Deterministic, zero external deps.

**Phase C: Proper parser.** A real parser (Go UDF, external tool, or stored
procedure calling a binary). The crystallized form.

The bootstrap: A → B → C. The LLM-parsed version becomes the test oracle for
the deterministic parser. This IS the crystallization pattern — the parser is
the first Cell program to crystallize.

---

## Observability

### Status as a View

```sql
CREATE VIEW cell_program_status AS
SELECT c.name, c.state, c.body_type,
       GROUP_CONCAT(y.field_name, '=', COALESCE(y.value_text, '(pending)'))
       as yields
FROM cells c
LEFT JOIN yields y ON y.cell_id = c.id
WHERE c.program_id = ?
GROUP BY c.id;
```

Instant status via `SELECT * FROM cell_program_status`.

### Time Travel (Free from Dolt)

```sql
SELECT * FROM cells AS OF 'abc123';              -- State at any commit
SELECT * FROM dolt_diff('HEAD~3', 'HEAD', 'yields');  -- Last 3 steps
```

### Execution as Branches

```sql
CALL DOLT_BRANCH('sort-proof/run-1');            -- Fork execution
CALL DOLT_BRANCH('sort-proof/run-2');            -- Try different approach
CALL DOLT_DIFF('sort-proof/run-1', 'sort-proof/run-2', 'yields');  -- Compare
```

### Document-Is-State

The `cell_status` procedure can render the original program text with frozen
values filled in — exactly as the spec describes:

```
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]        -- ■ frozen

⊢ sort
  given data→items ≡ [4, 1, 7, 3, 9, 2]   -- ✓ resolved
  yield sorted ≡ [1, 2, 3, 4, 7, 9]       -- ■ frozen
  ⊨ permutation check ✓
  ⊨ ascending order ✓
```

---

## The Retort Schema

The existing Retort schema (from ericfode/cell `schema.go`) is the foundation,
with the following adaptations:

- `cells` table: add `model_hint`, `executor_type` columns
- `yields` table: unchanged — `value_text`, `value_json`, `is_frozen`, `is_bottom`
- `givens` table: unchanged — `source_cell`, `source_field`, `is_optional`, `guard_expr`
- `oracles` table: unchanged — `oracle_type`, `assertion`, `condition_expr`
- `ready_cells` VIEW: unchanged — already correctly computes Cell readiness
- `trace` table: unchanged — with `DoltIgnoreTrace` for performance
- NEW: stored procedures (`cell_pour`, `cell_eval_step`, `cell_submit`, `cell_status`)
- NEW: hard cell views (`cell_*` created by crystallization)

---

## Bootstrap: Rule of Five

### 1. The Schema + Procedures
Apply the Retort schema to a Dolt database. Write the core stored procedures:
`cell_eval_step`, `cell_submit`, `cell_status`. Write the `ready_cells` view.
Test by inserting rows manually and calling procedures.

**Demo**: Insert 3 hard cells as rows, run `cell_eval_step` in a loop, watch
views resolve and yields freeze via Dolt commits.

### 2. The Piston
Write the LLM piston instructions. A Claude Code session that loops
`cell_eval_step`, evaluates soft cells, calls `cell_submit`. Test with a
mixed hard/soft program.

**Demo**: A 5-cell program with 2 hard cells and 3 soft cells. The piston
evaluates soft cells, SQL handles hard cells, deterministic oracles verify
results. Show `cell_status` at each step.

### 3. The Oracle Loop
Add oracle checking to `cell_submit`. Deterministic oracles check in SQL.
Semantic oracles return to the piston for LLM judgment. Failures trigger
retry with context.

**Demo**: A soft cell fails an oracle, retries with feedback, succeeds.
Show the Dolt commit history as the execution trace.

### 4. `cell_pour` (Soft Parser)
The LLM-based parser. `cell_pour` sends turnstyle text to the LLM, gets
back structured cell definitions, inserts rows. Test with the 55 example
programs from ericfode/cell.

**Demo**: Load `sort-proof.cell` via `cell_pour`, run with the piston,
see results. Then load a complex program (code-review.cell) and run it.

### 5. `cell_pour` Crystallization
The parser hardens. SQL string parsing replaces LLM parsing for the core
syntax. The LLM-parsed version serves as the test oracle — both parsers
must produce identical row structures for all 55 example programs.

**Demo**: Parse all 55 programs with both soft and hard parsers. Diff the
results. Zero differences = crystallization complete.

---

## Key Design Decisions (Post-Adversarial Review)

### Why Dolt stored procedures, not Go code?
Go code couples Cell to a compiled binary. Stored procedures are data — stored
in Dolt, versionable, inspectable. The runtime IS the database.

### Why views for hard cells, not an expression evaluator?
A custom expression language couples Cell to its evaluator implementation.
SQL is universal, battle-tested, Turing complete (with recursive CTEs), and
already runs on Dolt. Views compose, evaluate lazily, and are inspectable
via INFORMATION_SCHEMA.

### Why multiple pistons, not one eval loop?
Confluence guarantees independent cells can be evaluated in any order by any
agent. The stored procedure handles atomic assignment. Scale by adding pistons.

### Why Retort schema, not bead metadata?
(Per Deng and Kai reviews) Normalized tables with indexed columns outperform
JSON metadata for every Cell-specific query: readiness, yield lookup, oracle
checking, status rendering. The Retort schema was designed for this.

### Why `cell_pour` bootstraps soft → hard?
The turnstyle syntax exists (17 evolution rounds). But building a parser first
means building a parser. Having the LLM parse means you can run Cell programs
TODAY. The deterministic parser crystallizes when it's ready.

### Why not programs as Go code?
Programs must be DATA. The `§` operator (quotation) requires inspecting cell
definitions at runtime. Compiled code is opaque. Database rows are transparent.
Metacircularity requires programs-as-data.

---

## Resolved Concerns from Adversarial Reviews

| Reviewer | Concern | Resolution |
|----------|---------|------------|
| Mara | No grammar, text-first is ambiguous | `cell_pour` bootstrap: LLM first, deterministic parser emerges |
| Mara | `⊢=` evaluator unspecified | Hard cells are SQL views. SQL IS the expression language. |
| Mara | Metacircular bootstrap circular | Stored procedures are the real evaluator. Cell-zero is specification. |
| Deng | JSON metadata unindexed | Using Retort schema with proper tables/indices |
| Deng | Commit overhead | Batch commits per eval round in `cell_eval_step` |
| Deng | ready_cells performance | Using Retort's `ready_cells` VIEW with indexed JOINs |
| Priya | Status is snapshot, not live | `cell_program_status` VIEW + Dolt time travel |
| Priya | Document-is-state violated | `cell_status` renders .cell with yields filled in |
| Ravi | LLM loses state, skips steps | LLM holds NO state. Procedure handles everything. |
| Ravi | LLM transcribes values incorrectly | LLM calls `cell_submit` with its output. Procedure writes to yields. |
| Ravi | Oracle cost doubles LLM calls | Deterministic oracles checked in SQL. Only semantic oracles use LLM. |
| Ravi | Invert control flow | Done. Procedure drives. LLM is piston, not orchestrator. |
| Kai | Formulas aren't functions | Not using formulas. Using stored procedures + CLI. |
| Kai | Polecat dispatch too slow | LLM evaluates inline. Polecat reserved for heavy isolation. |
| Kai | Beads namespace pollution | Using Retort (separate schema). Beads for coordination only. |
| Kai | Keep Retort schema | Kept. |

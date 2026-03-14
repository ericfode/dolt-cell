# Adversarial Review: Cell REPL Design (Database Architecture)

**Reviewer**: Deng (Database Architect)
**Date**: 2026-03-14
**Document under review**: `docs/plans/2026-03-14-cell-repl-design.md`
**Verdict**: Reject in current form. The design trades a working, indexed, normalized schema for JSON-in-metadata with no performance analysis and no concurrency model.

---

## 1. Bead Metadata as Cell State: A Regression

The design says:

> Yields, givens, body type stored in bead metadata

This means `body_type`, `yield_names`, individual yield values, yield frozen status, oracle assertions, guard expressions, optional/required flags on givens, and source cell references ALL live inside a JSON column on the beads `issues` table.

The Retort schema you already built has proper columns for every one of these. Compare:

**Retort (schema.go lines 19-37):**
```sql
CREATE TABLE cells (
    body_type ENUM('soft','hard','script','passthrough','spawner','evolution') NOT NULL,
    state ENUM('declared','computing','tentative','frozen','bottom','skipped') NOT NULL,
    KEY idx_state (state),
    ...
);
```

**Beads approach (from cell-sql-library-sketch.md):**
```sql
INSERT INTO issues (..., metadata)
VALUES (..., '{"cell_program":"sort-proof","body_type":"soft","yield_names":["sorted"]}');
```

The Retort `cells.state` column has an index. The Retort `cells.body_type` column has an index. The beads approach has `JSON_EXTRACT(metadata, '$.body_type')` which cannot use a B-tree index in MySQL/Dolt. You can create a generated column with an index on it, but the design does not propose this, and each new field you want to query requires another generated column -- at which point you are rebuilding the Retort schema with extra steps.

The `givens` table in Retort (schema.go lines 39-55) has dedicated columns for `source_cell`, `source_field`, `is_optional`, `guard_expr`, each individually queryable and joinable. In the beads approach, all of this lives in `JSON_OBJECT('source_field','items','is_optional',false)` inside the `dependencies.metadata` column. Every join that touches these values becomes a `JSON_EXTRACT` operation.

**This is not a hypothetical concern.** The design's own `mol-cell-ready` formula needs to answer: "For each given on this cell, is the upstream cell's yield frozen?" With the beads approach, that query must:

1. Find all dependencies where the issue has label `cell`
2. Extract `source_field` from each dependency's JSON metadata
3. Find the upstream issue
4. Extract `yield_{field}_frozen` from the upstream issue's JSON metadata
5. Check that ALL such extractions return true

Compare to the Retort `ready_cells` view (schema.go lines 142-170), which does this with a clean three-table JOIN on indexed columns:

```sql
SELECT c.* FROM cells c
WHERE c.state = 'declared'
  AND NOT EXISTS (
    SELECT 1 FROM givens g
    WHERE g.cell_id = c.id AND g.is_optional = 0 AND g.source_cell IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM cells src
        JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
        WHERE src.program_id = c.program_id AND src.name = g.source_cell
          AND y.is_frozen = 1
      )
  )
```

Every column in every predicate here is indexed or part of a primary/foreign key. The query planner can use index nested loop joins. The beads-based equivalent cannot.

---

## 2. Dolt Commit Overhead: 25-50 Seconds of Dead Time

The design says:

> mol-cell-freeze: Write yield values to cell bead metadata, close bead, **Dolt commit**

Look at what the existing engine already does (engine.go line 176):

```go
e.DB.DoltCommit(ctx, fmt.Sprintf("eval step %d: freeze %s", step, target.Name))
```

And on oracle failure (engine.go line 188):

```go
e.DB.DoltCommit(ctx, fmt.Sprintf("eval step %d: %s %s", step, decision.Action, target.Name))
```

And on guard-skip bottoming (engine.go line 265):

```go
e.DB.DoltCommit(ctx, fmt.Sprintf("eval: bottom %s (guard)", cell.Name))
```

A Dolt commit involves: serialize working set to Noms chunks, compute content hashes, update the commit graph, write to storage. Measured latency on local Dolt sql-server ranges from 50ms (trivial change, warm) to 500ms+ (multi-table change, cold). Call it 100-200ms per commit as a realistic average.

Back-of-envelope for a 50-cell program:

- Best case (all hard cells, no retries): 50 commits x 100ms = **5 seconds** pure commit overhead
- Typical case (mix of hard/soft, some retries, some guard skips): ~75 commits x 150ms = **11.25 seconds**
- Worst case (soft cells with oracle failures, retries at max_retries=3): up to 200 commits x 200ms = **40 seconds**

This is PURE OVERHEAD, on top of actual computation time. For hard cells that evaluate in microseconds, the commit is 1000x slower than the computation.

The design says:

> The execution trace IS the commit history.

This is elegant in theory but punishing in practice. You are forcing a disk-persistent version-control operation on every state transition. The Retort engine already has a `trace` table (schema.go lines 105-114) with `DoltIgnoreTrace` (line 173) -- the existing design recognized that not every state change deserves a commit.

**The design mentions batching but specifies nothing.** From the open questions:

> Concurrency model: When multiple cells are ready, does the LLM dispatch them in parallel? Who commits to Dolt?

This is not an open question. This is a load-bearing architectural decision that determines whether the system works at all. "We'll figure out batching later" is how you end up with a system that takes 40 seconds to run a 50-cell program.

**Concrete proposal:** Batch commits per eval-loop iteration, not per cell freeze. Freeze 5 cells, commit once. The trace table approach (write many rows, commit periodically) is the proven pattern.

---

## 3. The `ready_cells` Query: O(n * JSON_EXTRACT) vs O(n * index lookup)

The Retort `ready_cells` view operates on four indexed tables: `cells`, `givens`, `yields`, and an implicit self-join on `cells` for source lookups. Query plan for a 50-cell program with ~100 givens and ~80 yields:

- Outer scan: `cells WHERE state = 'declared'` -- index on `idx_state`, say 20 rows
- For each: correlated subquery on `givens WHERE cell_id = ?` -- index on `idx_cell_id`, 2-3 rows each
- For each given: lookup on `cells WHERE program_id = ? AND name = ?` -- index on `idx_program_id` + filter, 1 row
- For each source cell: lookup on `yields WHERE cell_id = ? AND field_name = ?` -- primary key, 1 row

Total index lookups: ~20 * (3 * 2) = ~120 index probes. At <1ms per probe, the whole query runs in single-digit milliseconds.

The beads-based equivalent:

- Scan `issues` with `labels` join for label = 'cell' -- fine, but now for each issue:
- Parse `dependencies.metadata` JSON to extract `source_field` and `is_optional`
- Parse upstream `issues.metadata` JSON to extract `yield_{field}_frozen`
- MySQL/Dolt `JSON_EXTRACT` is a full-value parse on every row access

For the same 50-cell program, you are now doing ~120 JSON parse operations per `mol-cell-ready` call. JSON parsing is CPU-bound string work -- not index-assisted. Even at 0.1ms per parse, that is 12ms just for JSON extraction, and JSON_EXTRACT on Dolt specifically is not optimized the way it is on MySQL 8.0+ (which has some JSON indexing support via generated columns).

But here is the real cost: `mol-cell-ready` is called on EVERY iteration of the eval loop. With 50 cells and sequential evaluation, that is 50 calls. So:

- Retort: 50 * ~5ms = 0.25 seconds total for all ready-checks
- Beads JSON: 50 * ~15ms = 0.75 seconds -- plus the query is harder to reason about and impossible to EXPLAIN cleanly

At 100 cells, at 500 cells (which the design should contemplate if Cell programs compose and spawn), the gap widens. JSON_EXTRACT does not benefit from index selectivity as programs grow.

---

## 4. Concurrent Polecat Writes: The Single-Writer Problem

The design says soft cells dispatch to polecats via `gt sling`. Multiple cells can be ready simultaneously. The design contemplates parallel dispatch (open question 2). Here is why this breaks.

Dolt's sql-server runs a single-writer model for commits. `DOLT_COMMIT()` takes a global write lock on the repository. Two concurrent transactions can READ in parallel, but only one can commit at a time. If polecat A and polecat B both finish evaluating their respective cells and try to freeze/commit:

1. Polecat A calls `UPDATE issues SET metadata = ... WHERE id = 'cell-a'` -- fine, takes row lock
2. Polecat B calls `UPDATE issues SET metadata = ... WHERE id = 'cell-b'` -- fine, different row
3. Polecat A calls `DOLT_COMMIT(...)` -- takes global write lock, commits
4. Polecat B calls `DOLT_COMMIT(...)` -- blocked on write lock, waits

This is the BEST case (no conflicts). With the beads approach where cells are rows in the `issues` table, the situation is worse if both polecats need to update the same table's metadata in overlapping transactions.

But the real problem is deeper: **who orchestrates the commits?** The design says the LLM drives the eval loop. If the LLM dispatches 3 soft cells in parallel, those polecats return at different times. Does each polecat commit independently? Then you have serialized commits negating the parallelism. Does the orchestrator wait for all 3 and batch-commit? Then you have head-of-line blocking -- the slowest polecat determines the commit latency for all 3.

The Retort engine (engine.go) solved this pragmatically: single-threaded eval loop, one cell at a time, commit after each step. Simple, correct, not parallel. The new design implies parallelism but has no concurrency protocol.

**Concrete proposal:** Separate the write path from the commit path. Polecats write tentative results to a staging table (no commit needed -- just SQL writes within a transaction). A single committer goroutine batches commits on a timer or threshold (every N freezes or every M seconds). This is the WAL-and-checkpoint pattern that every serious database uses internally.

---

## 5. Large Yield Values: JSON Column Limits

The design says yield values go into bead metadata JSON. From the beads substrate design:

```
bd update <id> --set-metadata '{"yield_sum": 8, "yield_count": 3}'
```

This works for `yield_sum = 8`. What about:

- A cell that yields generated source code (10KB-50KB per file)
- A cell that yields a design document (5KB-20KB of text)
- A cell that yields structured data from an LLM (multi-level JSON, 2KB-10KB)
- A spawner cell whose yield is a list of sub-cell definitions

JSON-in-metadata problems at scale:

1. **MySQL/Dolt TEXT column limit**: The `metadata` column is likely TEXT (64KB) or LONGTEXT (4GB). But practical limits are much lower -- Dolt's chunk size means large JSON values cause disproportionate I/O on every read of that row.

2. **JSON escaping overhead**: A 10KB code file stored in JSON metadata requires escaping all quotes, backslashes, and control characters. A Python file with docstrings and backslashes can inflate 30-50% in JSON representation. That 10KB file becomes 13-15KB of JSON.

3. **Full-value read on any metadata access**: When you `JSON_EXTRACT(metadata, '$.body_type')`, MySQL/Dolt parses the ENTIRE JSON value to find the key. If the metadata contains a 50KB yield value alongside the 4-byte body_type, you are parsing 50KB to read 4 bytes. Every time.

4. **Dolt diff amplification**: Every Dolt commit diffs the row. If the metadata JSON changes from `{"body_type":"soft","yield_names":["code"]}` to `{"body_type":"soft","yield_names":["code"],"yield_code":"... 50KB ...","yield_code_frozen":true}`, Dolt stores the entire new JSON value as a chunk. Content-addressing helps with deduplication across commits, but within a single commit the full value is serialized.

The Retort schema handles this cleanly:

```sql
CREATE TABLE yields (
    cell_id VARCHAR(64) NOT NULL,
    field_name VARCHAR(255) NOT NULL,
    value_text TEXT,          -- large values go here
    value_json JSON,          -- structured values go here
    is_frozen TINYINT(1),     -- queryable without parsing value
    PRIMARY KEY (cell_id, field_name)
);
```

The `is_frozen` flag is a 1-byte column with index potential. You never parse `value_text` to determine frozen status. You never read the 50KB value just to check if a downstream cell's given is satisfied. The ready_cells view only touches `is_frozen` and `is_bottom` -- it never reads the actual yield value.

In the beads approach, checking if `yield_code_frozen` is true requires parsing the entire metadata JSON, including the 50KB `yield_code` value sitting next to it.

---

## 6. Why Not Retort: The Design's Arguments Do Not Hold

The design gives five reasons for using beads instead of Retort (lines 218-224). I will address each.

> 1. Cell programs ARE work -- cells are tasks, evaluation is execution

True at the coordination layer. False at the computation layer. A cell's state machine (declared -> computing -> tentative -> frozen) is richer than a bead's (open -> in_progress -> closed). The Retort schema models this with a 6-value ENUM on an indexed column. Beads would need to encode this in metadata JSON or add custom labels per state transition.

> 2. Beads already handles dependencies, readiness, metadata, and dispatch

Beads handles GENERIC dependencies and readiness. Cell readiness is SPECIFIC: it requires checking that upstream yields (not just upstream beads) are frozen, that they are not bottom (unless the given is optional), and that guard expressions evaluate to true. The `bd ready` command computes "all blockers closed." Cell needs "all required source-cell givens have their upstream yields frozen." These are different predicates. The Retort `ready_cells` view (schema.go lines 142-170) encodes this exactly. Wrapping `bd ready` with "Cell-specific filtering" (the design's own words for `mol-cell-ready`) means reimplementing the Retort view's logic on top of JSON metadata parsing.

> 3. `bd ready` already computes the frontier

See above. `bd ready` computes the WRONG frontier for Cell. It gives you "unblocked beads." You need "cells whose givens are satisfied." These overlap but are not identical. A cell could have its bead dependencies satisfied but its guard expression evaluating to false. A cell could have an optional given whose upstream is bottom -- `bd ready` might exclude it, but Cell semantics say it is ready.

> 4. `gt sling` already dispatches to polecats

This is a dispatch mechanism argument, not a data model argument. Retort can use `gt sling` for dispatch. The `bead_bridge` table (schema.go lines 116-123) exists precisely for this: mapping Retort cells to beads for dispatch. You can have Retort for computation and beads for dispatch. The SQL library sketch (cell-sql-library-sketch.md, lines 346-355) explicitly designed this bridge:

> Dispatch: When Retort's eval-loop encounters a soft cell, it CAN create a bead in the Beads DB to dispatch work to a polecat.

The Retort design already solved the dispatch problem without abandoning normalized tables.

> 5. One system to reason about, not two

This is a simplicity argument, and I am sympathetic to it. But "one system" where Cell computation is crammed into JSON columns of a generic issue tracker is not simpler -- it is more complex to query, harder to debug, and impossible to optimize. Two systems with a clean bridge (Retort for computation, beads for coordination) is more components but less overall complexity, because each component has a coherent data model suited to its purpose.

The existing Retort codebase is not a prototype sketch. It is 725 lines of Go (db.go) with complete CRUD operations, a working evaluation engine (engine.go, 331 lines), oracle checking, recovery policies, guard evaluation, and a trace system. Throwing this away to store everything in JSON metadata is a downgrade, not a simplification.

---

## 7. Additional Database Architecture Concerns

### 7a. No Transaction Boundaries

The design does not mention transactions. The Retort engine wraps each eval step in an implicit transaction (Go's database/sql auto-commits each statement, and the `DoltCommit` at the end provides the durability boundary). But the beads approach, with formulas invoking `bd` CLI commands, has no transactional guarantees. If `mol-cell-freeze` writes yield values to metadata (one `bd update`) and then the `bd close` fails, you have a half-frozen cell: yields written but bead still open. The next `mol-cell-ready` call might see this cell as still evaluable and dispatch it again.

With the Retort schema, you can wrap the entire freeze operation (UPDATE yields, UPDATE cell state, INSERT trace) in a single SQL transaction before calling DOLT_COMMIT. With CLI `bd` commands, each command is its own transaction.

### 7b. Schema Evolution

The Retort schema has a `SchemaVersion` constant (schema.go line 4). When Cell semantics evolve (new oracle types, new cell states, new given properties), you bump the version and add migration DDL. With JSON metadata, schema evolution is invisible -- you just start writing new keys into the JSON blob. This sounds flexible until you have 500 cells across 20 programs and need to answer "which cells have guard expressions?" Without a column, you are scanning `JSON_EXTRACT(metadata, '$.guard_expr')` across every row. With a column and index, it is a filtered index scan.

### 7c. Dolt Branch Semantics

The design mentions using Dolt diffs for observability ("The execution trace IS the commit history"). But it does not address branching. Dolt's power is branching and merging. What happens when you want to fork a Cell program execution, try an alternative evaluation path, and merge back? With Retort's normalized tables, a `dolt checkout -b alt-eval` and subsequent `dolt merge` works cleanly because the tables have well-defined merge behavior (row-level, keyed by primary key). With JSON metadata, a merge conflict on the `issues.metadata` column is a FULL-VALUE conflict -- Dolt cannot merge two different JSON blobs at the field level. You lose one of Dolt's most powerful features.

### 7d. Observability Queries

The `mol-cell-status` formula needs to render:

```
[frozen]  data     └─ items = [4, 1, 7, 3, 9, 2]
[eval]    sort     ├─ given: data->items  resolved
                   └─ yield: sorted = (pending)
```

With Retort, this is three clean SELECTs: cells + givens + yields, joined on indexed foreign keys. With beads metadata, building this view requires parsing the JSON metadata of every cell bead, every dependency, and every upstream bead to extract yield values, given bindings, and frozen status. Each rendering of the status view does O(n) JSON parses where n is the total metadata size across all cells.

---

## Summary: What I Recommend

1. **Keep Retort for computation.** The normalized schema exists, is implemented, is tested, and is correct. Do not abandon it.

2. **Use beads for coordination only.** Dispatch soft cells to polecats via beads. Use `gt sling`. Use the `bead_bridge` table to map cells to beads.

3. **Batch Dolt commits.** Commit per eval-loop iteration (after all ready cells in a wavefront are processed), not per cell freeze. Amortize the 100-200ms commit cost across 5-10 cell state changes.

4. **Define the concurrency model before building.** Single-writer orchestrator with polecat workers is fine. Say so explicitly. Document who commits and when.

5. **Keep yield values in the `yields` table.** The `value_text` / `value_json` / `is_frozen` separation is correct database design. Do not flatten this into JSON metadata.

6. **If you must unify on beads, add generated columns.** Create indexed generated columns for every JSON field you need to query: `body_type`, yield frozen status, cell state. At that point you are rebuilding Retort's schema as virtual columns on a generic table, which is strictly worse than having the actual tables.

The formulas-as-toolkit idea is sound. The LLM-drives-the-loop idea is sound. The observability model is sound. The data layer is where this design breaks. Do not sacrifice a working normalized schema for the aesthetic appeal of "everything is beads."

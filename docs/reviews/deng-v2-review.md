# Adversarial Review: Cell Runtime Design v2 (Database Architecture)

**Reviewer**: Deng (Database Architect)
**Date**: 2026-03-14
**Document under review**: `docs/plans/2026-03-14-cell-repl-design-v2.md`
**Prior review**: `docs/reviews/deng-database-review.md` (v1 review)
**Verdict**: Conditional approve. v2 resolves the fatal data-layer issues from v1. Three new issues introduced, one of which is a blocker.

---

## 1. Resolution of v1 Concerns

### 1a. Retort Schema Retained -- RESOLVED

v1 proposed storing cell state, yields, givens, and oracle assertions in bead metadata JSON columns. I called this a regression. v2 explicitly retains the Retort schema:

> The existing Retort schema (from ericfode/cell `schema.go`) is the foundation

The `cells`, `givens`, `yields`, and `oracles` tables are kept with their indexed columns. The `ready_cells` view with its indexed three-table JOIN is preserved. The resolved-concerns table at the bottom of v2 directly references my review:

> Deng: JSON metadata unindexed -> Using Retort schema with proper tables/indices

This is the correct decision. No further concerns here.

### 1b. Proper Indices -- RESOLVED

The Retort schema has `idx_state` on `cells.state`, `idx_program_id` on `cells.program_id`, `idx_cell_id` on `givens.cell_id`, and a composite primary key `(cell_id, field_name)` on `yields`. All of these survive into v2 because the schema is reused wholesale. The `ready_cells` view's NOT EXISTS subqueries can leverage these indices for index nested loop joins, exactly as I described in the v1 review.

### 1c. No JSON Metadata for Cell State -- RESOLVED

v2 adds `model_hint` and `executor_type` as proper columns on the `cells` table, not JSON metadata fields. The Retort `cells` table already has a `metadata JSON` column (schema.go line 32) for genuinely schemaless data, which is fine -- the queryable fields (`state`, `body_type`, `program_id`) remain indexed columns.

### 1d. Commit Overhead -- PARTIALLY RESOLVED

v2 says:

> Deng: Commit overhead -> Batch commits per eval round in `cell_eval_step`

The resolved-concerns table claims this is addressed, but the design does not specify HOW batching works. The `cell_eval_step` procedure as described handles one cell at a time (claim one, return prompt or evaluate hard cell). The `cell_submit` procedure handles one cell at a time (write yield, check oracle, freeze). At what point does `DOLT_COMMIT` get called?

There are two possible interpretations:

1. **Commit inside `cell_submit`**: Each freeze triggers a commit. This is the v1 problem all over again -- 50 cells means 50 commits, 5-40 seconds of pure overhead.

2. **Commit outside both procedures**: The calling code (piston or orchestrator) calls `DOLT_COMMIT` after processing a batch of cells. This is the correct approach but is not documented. The piston loop shown in v2 is: `cell_eval_step` -> think -> `cell_submit` -> repeat. There is no `DOLT_COMMIT` call in that loop. Who commits? When?

This needs a concrete answer. See section 5 below.

### 1e. Concurrency Model -- PARTIALLY RESOLVED

v2 inverts control: the stored procedure assigns cells atomically, the LLM is a stateless piston. This is a better architecture than v1's "LLM drives the loop." But the atomic assignment mechanism relies on `SELECT ... FOR UPDATE`, which is a blocker. See section 4 below.

---

## 2. Stored Procedures as the Runtime

### 2a. Dolt Stored Procedure Support: Current State

Dolt rewrote its stored procedure engine in v1.53.0 (May 2025). Procedures are now compiled to OpCodes and run in an interpreter, which is a significant improvement. DDL inside procedures (including `CREATE TABLE` and likely `CREATE VIEW`) now works, where previously it threw Unresolved Table errors.

This means the v2 design -- where `cell_eval_step` and `cell_submit` are stored procedures, and crystallization creates views via DDL inside procedures -- is feasible on current Dolt.

### 2b. Known Limitation: Multiple Result Sets

Dolt stored procedures can contain multiple SELECT statements, but only the LAST SELECT's result set is returned to the client. The `cell_eval_step` procedure needs to return a prompt plus metadata (cell ID, givens, model hint). If this requires multiple result sets, it will not work. The procedure must pack everything into a single SELECT result row or use OUT parameters.

**Recommendation**: Design `cell_eval_step` to return a single result set with columns: `cell_id`, `cell_name`, `body_type`, `prompt_text`, `model_hint`, `status` (where `status` is 'dispatch', 'quiescent', or 'complete'). One row, one result set, no ambiguity.

### 2c. Performance of Stored Procedures vs. Go Code

The Retort engine (engine.go) runs the eval loop in compiled Go. Stored procedures run in Dolt's OpCode interpreter. Interpreted SQL is slower than compiled Go for control flow -- loops, conditionals, string operations. For the eval loop itself this is acceptable because the bottleneck is I/O (LLM calls, disk writes), not CPU in the control flow. But for `cell_pour` Phase B (SQL string parsing with `SUBSTRING_INDEX` and `REGEXP`), the performance difference could be noticeable on large programs. Parsing a 200-line Cell program with SQL string functions in an interpreted stored procedure will be significantly slower than doing it in Go.

This is not a blocker -- Phase B is optional, and Phase A (LLM parsing) handles the bootstrap. But set expectations: SQL string parsing in Dolt stored procedures is a slow path, not a fast path.

### 2d. Stored Procedure Versioning

The design says stored procedures are "data -- stored in Dolt, versionable, inspectable." This is correct. Dolt stores procedure definitions in the `dolt_procedures` system table, which is versioned like any other table. You can `AS OF` query procedure definitions, diff them across commits, and branch them. This is a genuine advantage over compiled Go code for the runtime.

---

## 3. Hard Cells as Views

### 3a. View Composition and Nesting

The design says:

> Views compose: a chain of 10 hard cells is a nested SQL query that resolves instantly.

This is true in principle but needs qualification. When you SELECT from view A which references view B which references view C, the query planner inlines the view definitions and optimizes the resulting query. For simple views (single-table SELECTs with WHERE clauses, as in the `cell_word_count` example), this works well. The planner can push predicates down and use indices.

### 3b. 50+ Views: Schema Overhead, Not Query Overhead

Having 50 or 100 views in the database is not a performance concern. Views are schema objects, not data objects. They consume negligible storage. The `INFORMATION_SCHEMA.VIEWS` table lists them, and Dolt versions them in `dolt_schemas`.

The concern is not the NUMBER of views but the COMPLEXITY of the query that results from deeply nested view chains. A chain of 10 views where each does a simple filter or computation will inline to a single query that the optimizer handles fine. A chain of 10 views where each does a JOIN, aggregate, and subquery will produce a query plan that the optimizer may struggle with -- Dolt's query planner (go-mysql-server) is less mature than MySQL's or PostgreSQL's, particularly for complex join reordering and subquery decorrelation.

**Practical limit**: Expect chains of 5-7 simple views to work well. Test chains longer than that against actual Dolt. If performance degrades, the mitigation is to materialize intermediate results into the `yields` table rather than chaining views indefinitely.

### 3c. No Materialized Views in Dolt

Dolt does not support `CREATE MATERIALIZED VIEW`. All views are computed on every access. For the Cell use case, this is acceptable IF hard cell evaluation writes the result into the `yields` table when the cell freezes. The view is then only evaluated ONCE (at freeze time), and subsequent reads come from `yields`. The design implies this but does not state it explicitly.

**Recommendation**: Make the flow explicit. When a hard cell (view) is evaluated:
1. `SELECT * FROM cell_view_name` -- evaluate the view
2. `INSERT INTO yields (cell_id, field_name, value_text, is_frozen) VALUES (...)` -- persist the result
3. Subsequent references to this cell's output read from `yields`, not from the view

This means the view is evaluated exactly once, at freeze time. The absence of materialized views is not a problem if this pattern is followed. If the design intends for downstream hard cells to reference upstream views directly (bypassing yields), then performance degrades as chain depth increases, because every downstream evaluation re-evaluates the entire upstream chain.

### 3d. Crystallization: DROP + CREATE VIEW in Production

The crystallization flow is:

> DROP the soft cell row, CREATE VIEW with the SQL

This is a DDL operation that changes the schema at runtime. In a running system with multiple pistons, a `CREATE VIEW` statement takes a schema lock. Other queries against `INFORMATION_SCHEMA.VIEWS` or against views being created/dropped will block. This is unlikely to be a problem in practice (crystallization is rare, schema locks are brief), but be aware that crystallization is NOT a hot-path operation. Do not attempt to crystallize cells during active evaluation of other cells on the same branch.

---

## 4. BLOCKER: `SELECT ... FOR UPDATE` Does Not Work in Dolt

The design specifies:

```sql
-- Inside cell_eval_step:
SELECT id INTO ready_id FROM ready_cells
WHERE program_id = ? AND state = 'declared'
LIMIT 1 FOR UPDATE;

UPDATE cells SET state = 'computing' WHERE id = ready_id;
```

**Dolt does not support `SELECT ... FOR UPDATE`.** Row-level locking is listed on the Dolt roadmap as unscheduled. It was considered for 2025 work but has no confirmed delivery date. As of early 2026, this syntax will either be silently ignored or will throw an error, depending on Dolt version.

This is the atomic cell-claiming mechanism that prevents two pistons from grabbing the same cell. Without it, the multiple-piston model breaks.

### Why This Matters

Dolt uses REPEATABLE READ isolation with merge-based conflict resolution, not lock-based. When two concurrent transactions both read `ready_cells` and both see cell X as ready:

1. Piston A: `SELECT id FROM ready_cells WHERE state = 'declared' LIMIT 1` -- gets cell X
2. Piston B: `SELECT id FROM ready_cells WHERE state = 'declared' LIMIT 1` -- also gets cell X (no lock)
3. Piston A: `UPDATE cells SET state = 'computing' WHERE id = X` -- succeeds
4. Piston B: `UPDATE cells SET state = 'computing' WHERE id = X` -- also succeeds (same row, same column, same value)
5. Both pistons now evaluate cell X

Step 4 may or may not conflict at commit time depending on timing. If Piston A commits first and Piston B's transaction merges cleanly (because the row converged to the same value), both pistons evaluated the same cell. Confluence means the result should be the same, but you wasted an LLM call and the oracle check runs twice.

### Alternatives That Work on Dolt

**Option A: Application-level locking with a claim table.**

```sql
CREATE TABLE cell_claims (
    cell_id VARCHAR(64) PRIMARY KEY,
    piston_id VARCHAR(64) NOT NULL,
    claimed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- In cell_eval_step:
INSERT INTO cell_claims (cell_id, piston_id) VALUES (?, ?);
-- If this succeeds (no duplicate key), the piston has the claim.
-- If it fails (duplicate key), another piston already claimed it.
```

This works because `INSERT` with a PRIMARY KEY constraint is atomic in Dolt -- the first inserter wins, the second gets a duplicate key error. No row-level locking needed.

**Option B: Optimistic concurrency with state transitions.**

```sql
UPDATE cells SET state = 'computing', claimed_by = ?
WHERE id = ? AND state = 'declared';
-- Check affected rows. If 0 rows affected, another piston got it.
```

In Dolt, if two transactions both attempt this UPDATE on the same row, one will succeed at commit and the other will hit a merge conflict (same cell, different `claimed_by` values). The conflict causes the second transaction to fail, which is the desired behavior.

**I recommend Option A** (claim table). It is explicit, the failure mode is a clean duplicate-key error rather than a merge conflict, and it leaves an audit trail of which piston evaluated which cell.

---

## 5. Dolt Commit Strategy: Unspecified

The design says "batch commits per eval round" but does not define what an "eval round" is, who calls `DOLT_COMMIT`, or how frequently.

### The Options

**Option 1: Commit per cell freeze (inside `cell_submit`)**
- Pro: Every freeze is durable, time travel has per-cell granularity
- Con: 50-cell program = 50 commits = 5-40 seconds overhead (my v1 concern, unchanged)

**Option 2: Commit per piston iteration (outside procedures, in the piston loop)**
- Pro: Amortizes commit cost if the piston processes multiple cells per round
- Con: A piston processes ONE soft cell per iteration (call procedure, think, submit). So this degenerates to option 1 for soft cells. For hard cells evaluated inside `cell_eval_step`, you could batch: evaluate 10 hard cells, commit once.

**Option 3: Commit per wavefront (after all ready cells in a generation are processed)**
- Pro: Maximum amortization. 50-cell program with 5 wavefronts = 5 commits = 0.5-1 second overhead
- Con: Requires a coordinator that knows when a wavefront is complete. With multiple pistons, this means a separate committer process.

**Option 4: Timer-based commits (every N seconds)**
- Pro: Predictable commit rate regardless of cell count
- Con: Durability gap -- if the process crashes between commits, uncommitted freezes are lost. Also, Dolt working set changes ARE durable within a sql-server session transaction even before `DOLT_COMMIT` -- the data is safe, but the Dolt commit history loses the fine-grained trace.

### My Recommendation

Use **Option 3 for hard cells** (batch all hard cells in a wavefront, commit once) and **Option 1 for soft cells** (commit after each freeze, because the LLM call dominates latency anyway -- the 100ms commit cost is noise next to a 2-10 second LLM call).

Concretely:
- `cell_eval_step` evaluates ALL ready hard cells in a single call, writes their yields, and calls `DOLT_COMMIT` once at the end.
- `cell_submit` (called by the piston after LLM evaluation) writes the yield, checks oracles, and calls `DOLT_COMMIT` once per soft cell freeze.
- This gives you per-cell commit granularity for soft cells (where it matters for observability -- you want to see the LLM's output in the commit history) and batched commits for hard cells (where commit overhead dominates).

The `cell_eval_step` procedure could have a `CALL DOLT_COMMIT(...)` at the end of its hard-cell evaluation batch. The `cell_submit` procedure could have a `CALL DOLT_COMMIT(...)` at the end of a successful freeze. Document this explicitly.

---

## 6. Cross-Branch Queries for Parallel Execution

The design proposes:

```sql
CALL DOLT_BRANCH('sort-proof/run-1');
CALL DOLT_BRANCH('sort-proof/run-2');
CALL DOLT_DIFF('sort-proof/run-1', 'sort-proof/run-2', 'yields');
```

### What Works

**Branch creation**: `DOLT_BRANCH` works as described. It creates a new branch from the current HEAD.

**Cross-branch reads**: Dolt supports reading from other branches using the `AS OF` syntax:
```sql
SELECT * FROM cells AS OF 'sort-proof/run-1';
```

Or using the database-qualified syntax in sql-server mode:
```sql
SELECT * FROM `mydb/sort-proof/run-1`.cells;
```

Both forms work. You can JOIN across branches in a single query.

**Diffing**: `DOLT_DIFF` between branches works and produces row-level diffs.

### What Does NOT Work

**The backtick syntax shown in the design review focus** (`SELECT * FROM \`branch\`.table`) is the database-qualified form. This requires the Dolt sql-server to expose each branch as a separate database. This is the default behavior in sql-server mode when `behavior.dolt_transaction_commit` is set appropriately, but it requires knowing the database name. The syntax is `\`dbname/branchname\`.tablename`, not `\`branchname\`.tablename`.

**Cross-branch writes**: A session is checked out to one branch at a time. You cannot write to a different branch without `DOLT_CHECKOUT` or starting a new session on that branch. This means two pistons doing parallel execution on two branches need two separate database connections, each checked out to their respective branch. This works, but the design should state it explicitly.

**Views across branches**: If you define a view on `main` and then `DOLT_CHECKOUT('feature')`, the view definition is on the `feature` branch too (if it existed when the branch was created). But a view that references `\`mydb/main\`.cells` embeds the branch name in the view definition, which is fragile. Use `AS OF` syntax in views for cross-branch references, or avoid cross-branch references in view definitions entirely.

### Merge After Parallel Execution

The design mentions forking execution into branches and comparing results. What it does not address: can you MERGE two execution branches? If `run-1` and `run-2` both freeze different cells (no overlap due to confluence), a `DOLT_MERGE` should succeed cleanly -- different rows modified on different branches merge without conflict. If they happen to both freeze the same cell (which confluence says should produce the same value), Dolt's merge will see same-cell-same-value as a no-conflict merge.

Where it breaks: if one branch freezes cell X with value "foo" and the other freezes cell X with value "bar" (an oracle failure on one branch, perhaps), the merge will produce a conflict on the `yields` row. This is actually CORRECT behavior -- you want to know about divergent results. But the design should document the expected merge behavior.

---

## 7. New Concerns Introduced by v2

### 7a. `exec:` Executor Is a Security Hole

The design says:

> `exec:` -> shell out to the executable (JSON in, JSON out)

A hard cell with body `exec:./tools/transform` causes the stored procedure to shell out. This means:

1. A stored procedure calls an external binary. Dolt does not have native `sys_exec()` or equivalent. You would need a UDF or the procedure would need to signal the piston to execute the binary. If the procedure itself shells out (via a hypothetical mechanism), any cell author can execute arbitrary commands on the database server.

2. If the piston handles `exec:` dispatch (the procedure returns `exec:./tools/transform` and the piston runs it), then security is the piston's responsibility. This is more reasonable but means the piston is no longer a pure LLM -- it is also an executor for arbitrary binaries.

**Recommendation**: Restrict `exec:` to a whitelist of approved executors, configured in the `config` table. The procedure should validate `exec:` targets against the whitelist before returning them to the piston. Do not allow arbitrary paths.

### 7b. `cell_program_status` View Cannot Use a Parameter

The design shows:

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

Views cannot have parameters. The `WHERE c.program_id = ?` is invalid in a `CREATE VIEW` statement. This must either:

- Be a view without the program_id filter (returns ALL cells across all programs, filtered by the caller with `WHERE program_id = ?` at query time), or
- Be a stored procedure that accepts `program_id` as an argument, or
- Be a view that uses a session variable: `WHERE c.program_id = @current_program_id` (set the variable before querying the view)

The session variable approach is fragile (requires discipline from all callers). The parameterless view is correct but returns more data than needed for multi-program databases. The stored procedure approach is cleanest for this use case.

### 7c. Schema Mutation as Runtime Operation

v2 treats `CREATE VIEW` as a runtime operation (crystallization creates views, hard cells ARE views). This means the database schema changes during program execution. This has implications:

- **Dolt diffing**: Schema changes show up in `dolt_schemas` diffs, interleaved with data changes in `cells`/`yields`. The commit history mixes DDL and DML, which complicates automated analysis of the execution trace.

- **Branch merging**: If branch A crystallizes cell X into a view and branch B crystallizes cell X into a DIFFERENT view (different SQL, same semantics), merging those branches produces a schema conflict on the view definition. Dolt schema merge is less mature than data merge.

- **Concurrent crystallization**: Two pistons cannot crystallize cells simultaneously without risking DDL contention. This is unlikely in practice (crystallization is rare) but should be documented as a constraint.

This is not a blocker. It is an inherent consequence of the "hard cells are views" design, and the benefits (composable, lazy, inspectable) outweigh the costs. But document the constraint: crystallization is a single-threaded, non-concurrent operation that should happen outside active evaluation.

### 7d. The `ready_cells` View and `state = 'declared'` Filter After UPDATE

When `cell_eval_step` claims a cell by updating `state` from `'declared'` to `'computing'`, the `ready_cells` view will exclude that cell on subsequent queries (because the view filters on `state = 'declared'`). This is correct. But with Dolt's REPEATABLE READ isolation, a concurrent piston's transaction may still see the old state (`'declared'`) in its snapshot if its transaction started before the claim was committed.

This reinforces the need for the claim-table approach (section 4, Option A). The `INSERT INTO cell_claims` approach works regardless of snapshot timing because the INSERT's uniqueness constraint is checked at commit time, not at read time.

---

## 8. Summary of Action Items

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 1 | `SELECT ... FOR UPDATE` not supported in Dolt | **BLOCKER** | Replace with claim-table pattern (section 4, Option A) |
| 2 | Commit strategy unspecified | HIGH | Define when `DOLT_COMMIT` is called: per soft cell freeze, batched for hard cell wavefronts (section 5) |
| 3 | `cell_program_status` view uses parameters | MEDIUM | Remove parameter; filter at query time or use stored procedure (section 7b) |
| 4 | `exec:` executor has no security boundary | MEDIUM | Add executor whitelist in config table (section 7a) |
| 5 | Multiple result sets not supported in Dolt procedures | MEDIUM | Design `cell_eval_step` to return single result set (section 2b) |
| 6 | Crystallization during active evaluation risks DDL contention | LOW | Document as constraint: crystallize outside active eval (section 7c) |
| 7 | View chain depth may degrade performance | LOW | Test chains > 5 views; materialize intermediate results to yields table (section 3b) |
| 8 | Cross-branch writes require separate connections | LOW | Document: parallel pistons on separate branches need separate DB connections (section 6) |

---

## 9. Overall Assessment

v2 is a substantial improvement over v1. The three fatal flaws I identified in v1 -- JSON metadata replacing indexed columns, no concurrency model, and unspecified commit batching -- are either resolved (JSON metadata) or partially resolved (concurrency, commit batching).

The architecture of "stored procedures as runtime, views as hard cells, LLM as piston" is sound from a database perspective. It leverages Dolt's strengths (versioning, branching, SQL) and keeps the data layer normalized and indexed.

The one blocker is the `SELECT ... FOR UPDATE` assumption. This is not a design flaw; it is a Dolt platform limitation. The claim-table workaround is straightforward and may actually be better than row-level locking for auditability.

The remaining issues are specification gaps (commit strategy, result set format) rather than architectural problems. Fill in the gaps, implement the claim table, and this design is ready for the bootstrap sequence.

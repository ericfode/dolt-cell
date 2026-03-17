# Design: Scale Dimension — Cell Next Phase

**Date:** 2026-03-17
**Bead:** do-1sv
**Author:** pearl (polecat)
**Sources:** `cmd/ct/eval.go`, `cmd/ct/pour.go`, `schema/retort-init.sql`,
`formal/Retort.lean`, `piston/system-prompt.md`, `examples/*.cell`,
`docs/plans/2026-03-17-bug-fix-analysis.md`,
`docs/plans/prd-review-integration.md`,
`docs/plans/prd-review-user-experience.md`,
`docs/plans/2026-03-16-cell-zero-bootstrap-design.md`,
`docs/plans/2026-03-17-frame-migration.md`

---

## Scope

This document addresses Cell's scale ceiling along four axes:
1. **Single-piston throughput** — how many cells/sec one piston can freeze
2. **Large programs** — behavior at 100+ cells per program
3. **Dolt query latency** — per-operation cost at the SQL layer
4. **Frame table growth** — storage and index pressure from the append-only model

For each axis: what breaks, where it breaks, and what to do about it.

---

## Axis 1: Single-Piston Throughput

### Current cost per eval cycle

A single `replEvalStep` → `replSubmit` round-trip executes these SQL operations:

| Phase | Operations | Queries |
|-------|-----------|---------|
| Completeness check | `SELECT COUNT(*) FROM cells WHERE program_id = ? AND body_type != 'stem' AND state NOT IN ('frozen','bottom')` | 1 |
| Find ready cell | `findReadyCell`: correlated subquery joining `cells`, `givens`, `cells` (as src), `yields` with `NOT IN` anti-join | 1 |
| Ensure frame | `SELECT ... FROM frames` + conditional `INSERT` | 1–2 |
| Resolve frame ID | `SELECT id FROM frames ORDER BY generation DESC LIMIT 1` | 1 |
| Atomic claim | `INSERT IGNORE INTO cell_claims` | 1 |
| Duplicate frame ensure | Same as above (redundant — called twice) | 1–2 |
| Resolve frame ID again | Same as above (redundant) | 1 |
| Claim log | `INSERT IGNORE INTO claim_log` | 1 |
| Bottom propagation check | `SELECT COUNT(*) FROM givens JOIN cells` | 1 |
| Set state computing | `UPDATE cells SET state = 'computing'` | 1 |
| Trace INSERT | 1 | 1 |
| DOLT_COMMIT | `CALL DOLT_COMMIT('-Am', ...)` | 1 |
| **Total (claim phase)** | | **12–14** |

Then for `replSubmit`:

| Phase | Operations | Queries |
|-------|-----------|---------|
| Find cell in computing | `SELECT id FROM cells WHERE state = 'computing'` | 1 |
| Resolve frame ID | `SELECT ... FROM frames` | 1 |
| Check already frozen | `SELECT COUNT(*) FROM yields` | 1 |
| Write yield value | `UPDATE yields SET value_text = ?` | 1 |
| Check deterministic oracles | `SELECT COUNT(*)` + `SELECT condition_expr` + per-oracle checks | 2–4 |
| Check semantic oracles | `SELECT COUNT(*)` + `SELECT assertion` + trace INSERTs | 2–4 |
| Freeze yield | `UPDATE yields SET is_frozen = TRUE` | 1 |
| Count unfrozen | `SELECT COUNT(*) FROM yields WHERE is_frozen = FALSE` | 1 |
| Update cell state | `UPDATE cells SET state = 'frozen'` | 1 |
| Get claim piston | `SELECT piston_id FROM cell_claims` | 1 |
| Delete claim | `DELETE FROM cell_claims` | 1 |
| Update piston stats | `UPDATE pistons SET cells_completed = ...` | 1 |
| Trace INSERT | 1 | 1 |
| Ensure frame (again) | 1–2 | 1–2 |
| Record bindings | `SELECT givens` + per-given: `SELECT yields JOIN frames` + I10/I11 checks + `INSERT IGNORE INTO bindings` | 1 + 4*N_givens |
| Claim log | `INSERT IGNORE INTO claim_log` | 1 |
| DOLT_COMMIT | `CALL DOLT_COMMIT('-Am', ...)` | 1 |
| Guard skip check | Conditional: scan oracles, scan sibling cells | 0–5 |
| Stem respawn | Conditional: `SELECT MAX(gen)` + `INSERT frame` + `UPDATE cells` + `INSERT yields` + `DOLT_COMMIT` | 0–5 |
| **Total (submit phase)** | | **18–30+** |

**Total per cycle: 30–44+ SQL round-trips**, plus **2 DOLT_COMMITs** (each
involves a Dolt chunk write to the noms store).

### What limits throughput

**DOLT_COMMIT is the bottleneck.** Each commit writes a new root hash to the
Dolt chunk store. On the current single-server setup, this is ~50–200ms
depending on working set. Two commits per cell means **2–5 cells/sec**
theoretical maximum for a single piston.

**The 50-attempt claim retry loop** (`replEvalStep` line 834) can amplify
this under contention: if another piston claims between `findReadyCell` and
the `INSERT IGNORE`, the loop re-queries. Each retry is 2–3 SQL round-trips.

### Recommendations

**S1.1: Batch operations per cycle.** Collapse the claim + compute + submit
into a single DOLT_COMMIT boundary. Today there are two commits: one for
claim, one for freeze. The claim commit is unnecessary — if the piston crashes
between claim and freeze, `cell_reap_stale` recovers the claim. Eliminating
the claim-phase commit cuts per-cell commit cost by 50%.

```go
// Before: 2 commits per cell
replEvalStep: ... DOLT_COMMIT("claim soft cell X")
replSubmit:   ... DOLT_COMMIT("freeze X.field")

// After: 1 commit per cell (claim is just an INSERT, no commit)
replEvalStep: ... INSERT claim (no DOLT_COMMIT)
replSubmit:   ... DOLT_COMMIT("freeze X.field")  // single commit includes claim
```

**S1.2: Eliminate redundant queries.** `ensureFrameForCell` is called twice in
`replEvalStep` (lines 844 and 867). `latestFrameID` is called twice (lines 847
and 870). These are idempotent but waste 2–4 round-trips per cycle. Cache the
result in Go memory.

**S1.3: Hard cell batching.** When `cmdPiston` hits a sequence of hard cells
(literal/SQL), it commits after each one. Batch N consecutive hard cells into
a single DOLT_COMMIT. This is especially impactful for programs with many
literal cells (e.g., the `data` cell pattern). A program with 20 hard literal
cells currently requires 20 commits; batched, it requires 1.

**S1.4: Deferred trace writes.** Trace INSERTs are fire-and-forget. The trace
table is already in `dolt_ignore` (not versioned). Move trace writes to a
buffered channel and flush asynchronously, removing them from the commit
critical path.

**Expected improvement:** S1.1 alone doubles throughput (2→1 commits/cell).
Combined with S1.2–S1.4, a single piston should reach **5–15 hard cells/sec**
and **2–4 soft cells/sec** (soft cells are LLM-bound, not SQL-bound).

---

## Axis 2: Large Programs (100+ cells)

### What happens at scale

A Cell program with N cells has:
- N rows in `cells`
- ~N rows in `yields` (1–3 per cell, scaling with yield count)
- ~N rows in `givens` (1–2 per cell on average)
- ~N rows in `frames` (1 per non-stem cell at gen 0)
- O(N) rows in `trace` (1–3 events per cell)
- O(N) rows in `bindings` (1 per given edge)

### Where it breaks

**findReadyCell is O(N²).** The readiness query (eval.go line 141) is:

```sql
SELECT c.* FROM cells c
WHERE c.state = 'declared'
  AND c.id NOT IN (
    SELECT g.cell_id FROM givens g
    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
    WHERE g.is_optional = FALSE AND y.id IS NULL
  )
```

This is a correlated anti-join: for each `declared` cell, Dolt scans its
givens, joins through source cells, and checks yield status. At 100 cells with
avg 2 givens each, this is 200 join lookups per scan. The NOT IN subquery may
also trigger Dolt's known correlated subquery performance issues.

**DOLT_COMMIT scales with working set.** Each commit hashes all dirty pages.
With 100 cells modifying yields, claims, and trace rows, the commit working
set grows. Dolt's prolly-tree chunking means each commit touches
O(log N) chunks per modified row, but the constant factor matters when
N is large.

**programComplete check scans the full table.** The `SELECT COUNT(*) FROM cells
WHERE program_id = ? AND body_type != 'stem' AND state NOT IN ('frozen','bottom')`
query at the top of `replEvalStep` runs on every cycle. At 100 cells, this
scans 100 rows per cycle even when only 1 cell is ready.

### Recommendations

**S2.1: Materialized ready-set.** Instead of re-computing readiness from scratch
each cycle, maintain a `ready_set` in Go memory. On program pour, compute the
initial ready set. After each freeze, update the set: for each cell that depends
on the just-frozen cell, check if all its givens are now satisfied. This turns
the readiness check from O(N²) SQL to O(degree) in-memory lookups per cycle.

```go
type ReadySet struct {
    mu       sync.Mutex
    ready    map[string]bool       // cellID → is ready
    depGraph map[string][]string   // cellName → downstream cell IDs
}

func (rs *ReadySet) OnFreeze(cellName string) {
    // Only recheck cells that have a given on cellName
    for _, downstream := range rs.depGraph[cellName] {
        if allGivensSatisfied(downstream) {
            rs.ready[downstream] = true
        }
    }
}
```

**S2.2: Replace programComplete scan with a counter.** Track `remaining` as
an integer in Go. Decrement on each freeze/bottom. Check `remaining == 0`
instead of querying the database.

**S2.3: Limit iteration expansion.** `recur (max N)` in the parser expands
stem cells into N concrete cells at pour time. For `recur (max 100)`, this
creates 100 cells + 100 judge cells = 200 cells just for one stem concept.
Instead of pre-expanding, keep the stem cell and create frames on demand.
The formal model already supports this (frames are append-only; generation
increments). Pre-expansion is a parser convenience that creates O(N) dead
cells when the guard fires early.

**S2.4: Per-program indexes.** `program_id` appears in every table as a filter.
The existing `idx_program_state` index on `cells(program_id, state)` helps,
but `givens`, `yields`, and `frames` lack program-scoped indexes. Add:
- `yields`: index on `(cell_id, is_frozen, field_name)` — covers the readiness
  anti-join
- `frames`: existing `idx_frames_cell_gen` on `(program_id, cell_name, generation)`
  is sufficient
- `givens`: index on `(cell_id, source_cell)` — covers the readiness join

**Expected improvement:** S2.1 + S2.2 eliminate the two most expensive
per-cycle queries for large programs. The system should handle 500+ cell
programs without degradation in per-cycle latency.

---

## Axis 3: Dolt Query Latency

### Current latency profile

Every SQL operation goes through the `database/sql` Go driver → TCP → Dolt
sql-server → Dolt's query engine → noms chunk store. The roundtrip cost is:

| Operation | Typical latency |
|-----------|----------------|
| Simple SELECT (point lookup by PK) | 1–5ms |
| JOIN (cells → givens → yields) | 5–20ms |
| Correlated subquery (ready_cells view) | 10–50ms |
| UPDATE + index maintenance | 2–10ms |
| INSERT with UNIQUE check | 2–10ms |
| DOLT_COMMIT (small working set) | 50–200ms |
| DOLT_COMMIT (large working set) | 200–500ms |

**Total per eval cycle at current query count (30–44 queries):**
Best case: ~200ms (mostly PK lookups + 1 commit)
Typical: ~400–800ms (readiness query + 2 commits + bindings)
Worst case: ~2–5s (large program + contention + bindings for many givens)

### Where it breaks

**DOLT_COMMIT dominates.** At 50–200ms per commit and 2 commits per cycle,
the commit overhead alone is 100–400ms per cell. No amount of query optimization
matters until commit count is reduced.

**Connection-per-query pattern.** `database/sql` reuses connections from a pool,
but Dolt's server-side session state (`@@dolt_transaction_commit = 0`) must be
set per connection. If the pool rotates connections, the SET must be re-issued.
The `mustExec(db, "SET @@dolt_transaction_commit = 0")` at the top of
`replSubmit` adds a round-trip every call.

**VARCHAR(4096) for yield values.** The `value_text VARCHAR(4096)` column in
yields stores the full yield value inline in the prolly tree. For large LLM
outputs (1–4K characters), every yield read/write moves a significant chunk of
data through the Dolt storage engine. The index on `(cell_id, field_name)`
includes these rows, making the index pages large.

### Recommendations

**S3.1: Reduce DOLT_COMMIT count.** (See S1.1.) This is the single
highest-leverage change for latency. Every commit eliminated saves 50–200ms.

**S3.2: Pin connection with session variables.** Use a dedicated `*sql.Conn`
(not `*sql.DB`) for the piston's eval loop. Set `@@dolt_transaction_commit = 0`
once at session start, not per query.

```go
conn, _ := db.Conn(ctx)
defer conn.Close()
conn.ExecContext(ctx, "SET @@dolt_transaction_commit = 0")
// Use conn for all subsequent queries in this piston session
```

**S3.3: Separate value storage for large yields.** For yields exceeding 256
bytes, store the value in a separate `yield_values` table (or a TEXT/BLOB column
outside the main index path). The yields table keeps only a hash or truncated
preview. This keeps the prolly-tree pages small and improves scan performance
for readiness checks.

Alternative (simpler): change `value_text` from `VARCHAR(4096)` to `TEXT`.
Dolt stores TEXT values out-of-line in the noms chunk store, which naturally
achieves the same separation without schema changes. However, this may affect
Dolt's ability to compare values inline (for oracle checks like
`length_matches`).

**S3.4: Prepared statements for hot queries.** The five most-executed queries
(findReadyCell, latestFrameID, ensureFrameForCell, completeness check,
yield freeze) are called every cycle with the same SQL text. Preparing them
once at piston startup avoids per-call parsing in Dolt's query engine.

```go
type pistonStmts struct {
    findReady    *sql.Stmt
    latestFrame  *sql.Stmt
    ensureFrame  *sql.Stmt
    countRemaining *sql.Stmt
    freezeYield  *sql.Stmt
}
```

**Expected improvement:** S3.1 + S3.2 should bring typical per-cycle latency
from 400–800ms to 150–400ms. S3.4 removes ~1ms per query (marginal but
free).

---

## Axis 4: Frame Table Growth

### Growth model

The `frames` table grows as:
- Non-stem cells: 1 row per cell per program (created at pour time, never changes)
- Stem cells: 1 row per generation (each freeze + respawn adds a row)

For a program with S stem cells and G average generations per stem:

| Table | Rows |
|-------|------|
| frames | N_regular + S × G |
| yields | N_regular × F_avg + S × G × F_avg (F_avg = fields per cell) |
| bindings | ~N_regular + S × G (1 per given edge, per generation) |
| claim_log | 2–3 × (N_regular + S × G) (claim + complete + optional release) |

For cell-zero-eval with its perpetual eval-one stem cell running continuously:
- 1 generation per eval cycle
- At 2 cells/min (soft-cell-bound): 120 generations/hour, 2880/day
- Each generation: 1 frame row + 3 yield rows + 1 claim_log row = 5 rows/cycle

**After 24 hours of continuous operation: ~14,400 rows** across frames + yields
+ claim_log, just for eval-one. This is manageable for one program, but if
cell-zero-eval evaluates cells from 10 programs, each with their own stem
cells, the growth is multiplicative.

### Where it breaks

**latestFrameID is O(G) without index.** The query
`SELECT id FROM frames WHERE program_id = ? AND cell_name = ? ORDER BY
generation DESC LIMIT 1` uses the `idx_frames_cell_gen` UNIQUE index, so it's
actually O(log G) — this is fine.

**resolveInputs scans all generations.** The query at eval.go:195 joins through
frames with `ORDER BY COALESCE(f.generation, 0) DESC` and deduplicates in Go
via `seen[qualified]`. For a stem cell with 1000 generations, this returns up
to 1000 rows per given, all but the first discarded. The query should LIMIT to
the latest generation per source cell.

**Yield index bloat.** The current UNIQUE index `idx_cell_field (cell_id,
field_name)` cannot hold multiple generations' yields for the same cell. This
is why stem cell respawn currently resets `cells.state` back to `declared` and
creates fresh yield rows — the UNIQUE constraint forces at most one unfrozen
yield slot per (cell_id, field_name). Once the frame migration completes
(re-keying to `(frame_id, field_name)`), this constraint is resolved, but the
index still grows with G.

**Dolt commit history grows linearly.** Each DOLT_COMMIT adds a commit to
Dolt's commit graph. At 2 commits per cell × 100 cells/day = 200 Dolt commits
per day. After a month: 6000 commits. Dolt's `dolt gc` handles garbage
collection, but the commit graph itself (used by `dolt log`, `dolt diff`) grows
unboundedly. This is a Dolt scalability concern, not Cell's, but it affects
operational tooling.

### Recommendations

**S4.1: Scope resolveInputs to latest generation.** Change the
`resolveInputs` query to use a subquery that gets the latest generation per
source cell, rather than fetching all generations and deduplicating in Go:

```sql
SELECT g.source_cell, g.source_field, y.value_text
FROM givens g
JOIN cells src ON src.program_id = ? AND src.name = g.source_cell
JOIN (
    SELECT cell_name, MAX(generation) AS max_gen
    FROM frames WHERE program_id = ?
    GROUP BY cell_name
) latest ON latest.cell_name = src.name
JOIN frames f ON f.program_id = ? AND f.cell_name = src.name
                 AND f.generation = latest.max_gen
JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
                 AND y.is_frozen = 1 AND y.frame_id = f.id
WHERE g.cell_id = ?
```

This returns exactly 1 row per given, regardless of generation count.

**S4.2: Yield UNIQUE index migration.** The frame migration must change the
UNIQUE index from `(cell_id, field_name)` to `(frame_id, field_name)`. This is
already planned (do-7i1.5 / do-7i1.16) but is also a scale prerequisite:
without it, stem cells with >1 generation break the uniqueness constraint.

**S4.3: Frame compaction for long-running stems.** For perpetual stem cells
like eval-one, generations accumulate indefinitely. Add a compaction operation
that:
1. Identifies generations where all downstream consumers have frozen
2. Marks those frames as `compacted` (metadata flag, no row deletion)
3. Excludes compacted frames from readiness and resolution queries

This keeps the active working set small while preserving the append-only
invariant. The compacted frames remain queryable for history/debugging but
are excluded from hot-path queries.

```sql
-- Add to frames table:
ALTER TABLE frames ADD COLUMN compacted BOOLEAN NOT NULL DEFAULT FALSE;

-- Compaction query (run periodically):
UPDATE frames SET compacted = TRUE
WHERE program_id = ? AND cell_name = ?
  AND generation < ? -- threshold: current_gen - 2
  AND compacted = FALSE;
```

**S4.4: claim_log rotation.** The claim_log table is append-only and grows
with every claim/release/complete event. For operational debugging, only
recent entries matter. Add a periodic cleanup that archives entries older
than 7 days to a `claim_log_archive` table (or simply DELETEs them — the
claim_log is not covered by formal invariants).

**Expected improvement:** S4.1 eliminates O(G) waste in resolveInputs. S4.3
keeps the frame working set bounded even for perpetual stems. Together they
ensure that programs with 1000+ stem generations don't degrade query
performance.

---

## Priority Matrix

| ID | Change | Impact | Effort | Priority |
|----|--------|--------|--------|----------|
| S1.1 | Eliminate claim-phase DOLT_COMMIT | 2× throughput | Low (remove 1 commit) | **P0** |
| S1.2 | Deduplicate ensureFrame/latestFrameID calls | Minor latency | Trivial | P1 |
| S1.3 | Batch consecutive hard cell commits | 5–20× for hard-heavy programs | Low | P1 |
| S2.1 | In-memory ready set | Eliminates O(N²) readiness query | Medium | **P0** |
| S2.2 | In-memory remaining counter | Eliminates per-cycle COUNT(*) | Trivial | P1 |
| S3.1 | = S1.1 | (same) | | |
| S3.2 | Pinned connection with session vars | ~5ms saved per cycle | Trivial | P2 |
| S3.4 | Prepared statements for hot queries | ~5ms saved per cycle | Low | P2 |
| S4.1 | Scope resolveInputs to latest gen | Fixes O(G) scan for stems | Low | **P0** |
| S4.2 | Yield UNIQUE index migration | Required for multi-gen stems | Medium (part of frame migration) | **P0** |
| S4.3 | Frame compaction for perpetual stems | Bounds working set | Medium | P1 |
| S4.4 | claim_log rotation | Storage hygiene | Low | P2 |
| S2.3 | Lazy iteration expansion | Eliminates dead cells from guard skip | Medium | P2 |
| S1.4 | Async trace writes | Minor latency | Low | P2 |
| S3.3 | Out-of-line yield values | Smaller index pages | Medium | P2 |

### Implementation order

**Phase 1 (unblock scale):** S1.1, S4.1, S1.2 — pure latency wins, no schema
changes, no architecture changes. Can be done in a single branch.

**Phase 2 (frame migration completion):** S4.2 — already planned as part of
do-7i1.5. Must land before multi-piston or serious stem cell workloads.

**Phase 3 (large program support):** S2.1, S2.2 — in-memory caching layer.
Requires careful invalidation but dramatically reduces SQL pressure for
programs with 50+ cells.

**Phase 4 (operational maturity):** S4.3, S4.4, S1.3, S3.2, S3.4 — polish.
Important for production but not blocking for the next development phase.

---

## Interaction with Multi-Piston

Multi-piston introduces claim contention. The current `INSERT IGNORE` claiming
is correct (atomic) but the retry loop (50 attempts in `replEvalStep`) can
waste cycles under contention. With the in-memory ready set (S2.1), each
piston can maintain its own view and avoid querying for cells that are already
claimed. The claim_log (S4.4) becomes more important for diagnosing contention
patterns.

Multi-piston also multiplies DOLT_COMMIT pressure: N pistons × 2 commits/cell
= 2N commits for N concurrent cells. With S1.1 (eliminate claim commit), this
drops to N commits. Dolt's single-writer commit serialization means commits
queue — this is the hard ceiling on multi-piston parallelism and requires
Dolt-level work (concurrent chunk stores or multi-DB sharding) to lift.

---

## Non-Goals

This design does **not** address:
- **Distributed Dolt** (multi-server replication) — outside Cell's control
- **LLM latency** — soft cells are fundamentally bound by model inference time
- **Language/syntax changes** — scale is orthogonal to the .cell format
- **Formal model updates** — the Lean model is correct; scale is an
  implementation concern

---

## Metrics to Track

Once these changes land, instrument:
1. **cells_per_second** — hard and soft, per piston
2. **dolt_commit_ms** — p50/p95 commit latency
3. **readiness_query_ms** — time to find a ready cell (should drop to ~0 with S2.1)
4. **frame_table_rows** — per program, with compaction stats
5. **claim_contention_rate** — INSERT IGNORE failures / total claim attempts

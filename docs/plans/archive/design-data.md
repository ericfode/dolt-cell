# Design: Data Dimension — Cell Next Phase

**Date:** 2026-03-17
**Status:** Design
**Bead:** do-vqn
**Author:** jade (polecat)

**Sources reviewed:** `formal/Retort.lean`, `schema/retort-init.sql`,
`schema/procedures.sql`, `cmd/ct/eval.go`, `cmd/ct/pour.go`,
`piston/system-prompt.md`, `examples/*.cell`,
`docs/plans/2026-03-17-bug-fix-analysis.md`,
`docs/plans/2026-03-17-frame-migration.md`,
`docs/plans/2026-03-16-full-migration-plan.md`,
`docs/plans/2026-03-14-retort-schema-v2.md`,
`docs/plans/2026-03-16-cell-zero-bootstrap-design.md`,
`docs/plans/prd-review-integration.md`,
`docs/plans/prd-review-user-experience.md`

---

## Overview

This document designs the data model changes for the Cell next phase. It covers
four areas:

1. **retort_meta table** — schema versioning and runtime metadata
2. **Frame-based claim lifecycle** — completing the cell_id → frame_id migration
3. **cell_create_frame stored procedure** — formalizing frame creation
4. **Backfill strategy for old programs** — migrating pre-frame-model data

The design follows a single principle: **align the SQL schema with the Lean
formal model**. The formal model (Retort.lean) defines 5 operations (pour,
claim, freeze, release, createFrame), all proven append-only. Every schema
change in this document maps to a formal type or invariant.

---

## 1. retort_meta Table

### Problem

There is no schema version tracking. The current `metadata` table (from v1)
stores arbitrary key-value pairs but has no structured schema version, no
migration history, and no runtime identity. When stored procedure signatures
change (as they will during the frame migration), running pistons have no way
to discover schema incompatibility. The integration review (prd-review-integration.md)
identified this as the "schema versioning" gap.

### Design

Replace the ad-hoc `metadata` table with a structured `retort_meta` table that
serves three purposes: schema versioning, instance identity, and migration
tracking.

```sql
CREATE TABLE IF NOT EXISTS retort_meta (
    key_name    VARCHAR(64) PRIMARY KEY,
    value_text  VARCHAR(4096) NOT NULL,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

Required rows (seeded at init time):

| key_name | value_text | Purpose |
|----------|-----------|---------|
| `schema_version` | `3` | Current schema version (integer string) |
| `schema_compat_min` | `2` | Minimum compatible client version |
| `instance_id` | `<uuid>` | Unique retort instance (generated once) |
| `created_at` | `<iso8601>` | When this retort was initialized |
| `formal_model_hash` | `<sha256>` | Hash of `formal/Retort.lean` at init |

**Version semantics:**
- `schema_version` increments on any DDL change (new table, new column, new procedure signature).
- `schema_compat_min` is the oldest client version that can safely call the stored procedures. Clients check `schema_compat_min <= client_version` at connect time.
- `ct` and pistons read `schema_version` at startup and refuse to operate if their compiled version is below `schema_compat_min`.

**Migration log** (append-only, one row per migration):

```sql
CREATE TABLE IF NOT EXISTS retort_migrations (
    version     INT PRIMARY KEY,
    description VARCHAR(256) NOT NULL,
    applied_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

Each schema migration INSERTs a row here. This provides an audit trail and
lets `ct doctor` verify that all migrations have been applied.

**Version timeline:**
- v1: Original schema (cells, yields, givens, oracles, trace)
- v2: Schema v2 additions (cell_claims, pistons, frames, bindings, claim_log)
- v3: Frame-based claim lifecycle (this design — yields re-keyed, cells.state dropped, retort_meta added)

### Formal correspondence

The formal model has no metadata — it's pure state. `retort_meta` is an
operational concern that exists outside the formal model. No invariant
references it. This is intentional: metadata is infrastructure, not semantics.

### Go implementation

```go
const SchemaVersion = 3
const SchemaCompatMin = 2

func checkSchemaVersion(db *sql.DB) {
    var v int
    err := db.QueryRow(
        "SELECT CAST(value_text AS UNSIGNED) FROM retort_meta WHERE key_name = 'schema_compat_min'",
    ).Scan(&v)
    if err != nil || SchemaVersion < v {
        fatal("schema incompatible: server requires v%d+, client is v%d", v, SchemaVersion)
    }
}
```

Called from `openDB()` in `db.go` before any operation.

---

## 2. Frame-Based Claim Lifecycle

### Problem

The formal model keys everything on `FrameId`. The Go implementation and stored
procedures still use `cell_id` as the primary key for most operations. This
is the root cause of 13 of 25 conformance bugs (Group A + most of Group B in
the bug-fix analysis). The current state is a hybrid: `cell_claims` already has
a `frame_id` column, but `yields` still has `UNIQUE(cell_id, field_name)`, and
`cells.state` is mutable.

### Target state

After this migration, the data model matches the formal `Retort` structure:

| Formal type | SQL table | Primary key / unique constraint |
|-------------|-----------|-------------------------------|
| `RCellDef` | `cells` | `(program_id, name)` — immutable after pour |
| `GivenSpec` | `givens` | `(cell_id)` — immutable after pour |
| `Frame` | `frames` | `(program_id, cell_name, generation)` |
| `Yield` | `yields` | `(frame_id, field_name)` — append-only |
| `Binding` | `bindings` | `(consumer_frame, producer_frame, field_name)` |
| `Claim` | `cell_claims` | `(frame_id)` — mutable lock table |

### Schema changes

#### 2.1 yields: re-key on (frame_id, field_name)

```sql
-- Step 1: Make frame_id NOT NULL (after backfill)
ALTER TABLE yields MODIFY COLUMN frame_id VARCHAR(64) NOT NULL;

-- Step 2: Replace the unique index
ALTER TABLE yields DROP INDEX idx_cell_field;
ALTER TABLE yields ADD UNIQUE INDEX idx_yield_frame_field (frame_id, field_name);
```

After this, the formal invariant I7 (yieldUnique: each `(frameId, field)` pair
has at most one yield) maps directly to the SQL UNIQUE constraint.

**cell_id is retained** as a denormalized column for backward compatibility
with existing queries and views. It is derivable from `frame_id → frames.cell_name → cells.id`
but keeping it avoids expensive JOINs in hot-path queries.

#### 2.2 cells: drop mutable state columns

The formal model derives frame status from yields + claims. `cells.state`,
`cells.computing_since`, `cells.assigned_piston`, `cells.claimed_by`,
`cells.claimed_at` are all mutable columns that violate the formal model's
principle that cell definitions are immutable after pour.

```sql
-- Drop mutable columns (after all queries migrated)
ALTER TABLE cells
    DROP COLUMN state,
    DROP COLUMN computing_since,
    DROP COLUMN assigned_piston,
    DROP COLUMN claimed_by,
    DROP COLUMN claimed_at;
```

Replace with a view that derives status from the frame model:

```sql
CREATE OR REPLACE VIEW cell_status_v AS
SELECT
    c.id AS cell_id,
    c.program_id,
    c.name AS cell_name,
    c.body_type,
    f.id AS frame_id,
    f.generation,
    CASE
        WHEN f.id IS NULL THEN 'declared'
        WHEN EXISTS (
            SELECT 1 FROM yields y
            WHERE y.frame_id = f.id AND y.is_bottom = TRUE
        ) THEN 'bottom'
        WHEN NOT EXISTS (
            SELECT 1 FROM yields y
            WHERE y.frame_id = f.id AND y.is_frozen = FALSE
        ) AND EXISTS (
            SELECT 1 FROM yields y WHERE y.frame_id = f.id
        ) THEN 'frozen'
        WHEN EXISTS (
            SELECT 1 FROM cell_claims cc WHERE cc.frame_id = f.id
        ) THEN 'computing'
        ELSE 'declared'
    END AS derived_state
FROM cells c
LEFT JOIN frames f ON f.program_id = c.program_id
    AND f.cell_name = c.name
    AND f.generation = (
        SELECT MAX(f2.generation) FROM frames f2
        WHERE f2.program_id = c.program_id AND f2.cell_name = c.name
    );
```

This matches `Retort.frameStatus` in the Lean model exactly:
- `frozen` = all yield fields present (line 125: `cd.fields.all (fun fld => frozenFields.contains fld)`)
- `computing` = claim exists (line 126: `(r.frameClaim f.id).isSome`)
- `declared` = otherwise

**Phasing:** Drop `cells.state` in a separate migration step after all Go code
and stored procedures stop reading/writing it. The view provides the same
information during the transition.

#### 2.3 cell_claims: frame_id becomes PRIMARY KEY

The current schema has `PRIMARY KEY (cell_id)` with a secondary `UNIQUE(frame_id)`.
The formal model keys claims on `FrameId` only (`Claim.frameId`).

```sql
-- Migrate PK from cell_id to frame_id
ALTER TABLE cell_claims DROP PRIMARY KEY;
ALTER TABLE cell_claims ADD PRIMARY KEY (frame_id);
ALTER TABLE cell_claims DROP INDEX idx_cell_claims_frame;
-- Keep cell_id as index for backward compat queries
ALTER TABLE cell_claims ADD INDEX idx_cell_claims_cell (cell_id);
```

This makes the formal claimMutex (I6: at most one claim per frame) directly
enforced by the PRIMARY KEY constraint.

#### 2.4 ready_cells view: rewrite for frame model

The current `ready_cells` view checks `c.state = 'declared'`. After dropping
`cells.state`, it must derive readiness from frames + yields:

```sql
CREATE OR REPLACE VIEW ready_frames AS
SELECT
    f.id AS frame_id,
    f.cell_name,
    f.program_id,
    f.generation,
    c.id AS cell_id,
    c.body_type,
    c.body,
    c.model_hint
FROM frames f
JOIN cells c ON c.program_id = f.program_id AND c.name = f.cell_name
WHERE
    -- Frame is in declared state (not frozen, not computing)
    NOT EXISTS (
        SELECT 1 FROM cell_claims cc WHERE cc.frame_id = f.id
    )
    -- Not all yields frozen (i.e., not already complete)
    AND (
        -- Either has unfrozen yields...
        EXISTS (
            SELECT 1 FROM yields y
            WHERE y.frame_id = f.id AND y.is_frozen = FALSE
        )
        -- ...or has no yields at all (fresh frame)
        OR NOT EXISTS (
            SELECT 1 FROM yields y WHERE y.frame_id = f.id AND y.is_frozen = TRUE
        )
    )
    -- Not bottomed
    AND NOT EXISTS (
        SELECT 1 FROM yields y
        WHERE y.frame_id = f.id AND y.is_bottom = TRUE
    )
    -- All non-optional givens satisfied by frozen yields from some frame
    AND NOT EXISTS (
        SELECT 1 FROM givens g
        JOIN cells c2 ON c2.id = g.cell_id
        WHERE c2.program_id = f.program_id
          AND c2.name = f.cell_name
          AND g.is_optional = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM frames pf
              JOIN yields py ON py.frame_id = pf.id
                  AND py.field_name = g.source_field
                  AND py.is_frozen = TRUE
              WHERE pf.program_id = f.program_id
                AND pf.cell_name = g.source_cell
          )
    );
```

This maps to `Retort.frameReady` (line 160-163): a frame is ready if its status
is `declared` AND all non-optional givens can be satisfied by frozen yields.

### Claim lifecycle (formal operations mapped to SQL)

The complete claim lifecycle maps to four of the five formal `RetortOp` variants:

```
┌─────────┐   claim    ┌───────────┐   freeze   ┌────────┐
│ declared │ ─────────► │ computing │ ──────────► │ frozen │
│ (ready)  │            │ (claimed) │             │        │
└─────────┘            └───────────┘             └────────┘
                             │
                    release / │
                    timeout   │
                             ▼
                      ┌─────────┐
                      │ declared │  (frame recycled)
                      │ (ready)  │
                      └─────────┘
```

| Transition | Formal op | SQL operations | Invariant |
|------------|-----------|---------------|-----------|
| declared → computing | `RetortOp.claim` | `INSERT INTO cell_claims (frame_id, ...)` | I6 claimMutex |
| computing → frozen | `RetortOp.freeze` | `INSERT yields`, `INSERT bindings`, `DELETE FROM cell_claims` | I7 yieldUnique |
| computing → declared | `RetortOp.release` | `DELETE FROM cell_claims`, reset cell | — |
| frozen → (new frame) | `RetortOp.createFrame` | `INSERT INTO frames` (stem cells only) | I2 framesUnique |

**Atomicity:** The freeze operation must atomically:
1. Write all yield values (`INSERT INTO yields` or `UPDATE yields SET is_frozen = TRUE`)
2. Write bindings (`INSERT INTO bindings`)
3. Remove the claim (`DELETE FROM cell_claims`)
4. Log to claim_log (`INSERT INTO claim_log`)

This matches `FreezeData` in the formal model, which bundles yields + bindings.
Currently, bindings are written AFTER the freeze (bug do-7i1.6). The fix is to
move `recordBindings()` into the same Dolt commit as the yield freeze.

### Go implementation changes

The main change is replacing `cells.state` reads with frame-based derivation.
Key functions affected:

| Function | Current | After |
|----------|---------|-------|
| `findReadyCell` | `WHERE c.state = 'declared'` | Use `ready_frames` view |
| `replEvalStep` | `c.state NOT IN ('frozen', 'bottom')` | Count frames not in terminal state |
| `replSubmit` | `UPDATE cells SET state = 'frozen'` | Remove; status derived from yields |
| `replRespawnStem` | `UPDATE cells SET state = 'declared'` | Create new frame via `cell_create_frame` |
| `checkGuardSkip` | `UPDATE cells SET state = 'bottom'` | `UPDATE yields SET is_bottom = TRUE` on frame |
| `bottomCell` | `UPDATE cells SET state = 'bottom'` | Same as checkGuardSkip |

---

## 3. cell_create_frame Stored Procedure

### Problem

Frame creation is currently ad-hoc: `ensureFrames()` in pour.go creates gen-0
frames, `replRespawnStem()` in eval.go creates next-gen frames. Neither
corresponds to a single formal operation. The formal model defines
`RetortOp.createFrame` as a first-class operation that appends one frame.

### Design

A single stored procedure that maps directly to `RetortOp.createFrame`:

```sql
DELIMITER //

DROP PROCEDURE IF EXISTS cell_create_frame //

CREATE PROCEDURE cell_create_frame(
    IN p_program_id VARCHAR(64),
    IN p_cell_name  VARCHAR(128),
    IN p_generation INT           -- NULL = auto-increment from max
)
BEGIN
    DECLARE v_cell_id VARCHAR(64);
    DECLARE v_max_gen INT DEFAULT -1;
    DECLARE v_gen INT;
    DECLARE v_frame_id VARCHAR(64);
    DECLARE v_body_type VARCHAR(8);

    -- Validate cell exists
    SELECT id, body_type INTO v_cell_id, v_body_type
      FROM cells
     WHERE program_id = p_program_id AND name = p_cell_name;

    IF v_cell_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cell not found';
    END IF;

    -- Determine generation
    SELECT COALESCE(MAX(generation), -1) INTO v_max_gen
      FROM frames
     WHERE program_id = p_program_id AND cell_name = p_cell_name;

    IF p_generation IS NOT NULL THEN
        SET v_gen = p_generation;
    ELSE
        SET v_gen = v_max_gen + 1;
    END IF;

    -- Enforce framesUnique (I2): reject duplicate (cell_name, generation)
    -- The UNIQUE index will also catch this, but explicit check gives a
    -- better error message.
    IF v_gen <= v_max_gen AND v_body_type != 'stem' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Non-stem cells cannot have multiple frames';
    END IF;

    -- Generate frame ID
    SET v_frame_id = CONCAT('f-', LEFT(p_program_id, 20), '-', p_cell_name, '-', v_gen);

    -- Create frame (formal: frames := r.frames ++ [cfd.frame])
    INSERT INTO frames (id, cell_name, program_id, generation)
    VALUES (v_frame_id, p_cell_name, p_program_id, v_gen);

    -- Create yield slots for the new frame (one per field in the cell def)
    -- Cell definitions store field names implicitly via existing yield rows.
    -- For stem cells respawning, copy field names from the previous frame.
    IF v_max_gen >= 0 THEN
        -- Copy yield field structure from previous generation
        INSERT INTO yields (id, cell_id, frame_id, field_name, is_frozen, is_bottom)
        SELECT
            CONCAT('y-', SUBSTR(MD5(RAND()), 1, 12)),
            v_cell_id,
            v_frame_id,
            y.field_name,
            FALSE,
            FALSE
        FROM yields y
        JOIN frames f ON f.id = y.frame_id
        WHERE f.program_id = p_program_id
          AND f.cell_name = p_cell_name
          AND f.generation = v_max_gen
        GROUP BY y.field_name;
    ELSE
        -- Gen-0: yield slots were already created by pour. No-op here.
        -- (Pour creates both the frame and its yield slots atomically.)
        SELECT 1;  -- Dolt needs a statement in each branch
    END IF;

    -- Return the new frame ID
    SELECT v_frame_id AS frame_id, v_gen AS generation;
END //

DELIMITER ;
```

### Formal correspondence

This maps to `applyOp r (.createFrame cfd)` (line 262-263):
```lean
| .createFrame cfd =>
    { r with frames := r.frames ++ [cfd.frame] }
```

**Preconditions enforced:**
- Cell must exist (`framesCellDefsExist`, I8)
- `(program_id, cell_name, generation)` must be unique (`framesUnique`, I2)
- Non-stem cells cannot have gen > 0 (no formal invariant, but structural: only stem cells cycle)

**What it does NOT do:**
- Does not create claims (that's `RetortOp.claim`)
- Does not write yields (that's `RetortOp.freeze`)
- Does not check readiness (that's derived state, computed by `frameReady`)

### Usage

**At pour time** (gen-0 frames for all cells):
```go
// In cellsToSQL or pourExecSQL:
for _, cell := range cells {
    db.Exec("CALL cell_create_frame(?, ?, 0)", progID, cell.Name)
}
```

**At stem cell respawn** (next-gen frame):
```go
// In replRespawnStem, replace the current ad-hoc INSERT:
func replRespawnStem(db *sql.DB, progID, cellName, frozenID string) {
    var frameID string
    var gen int
    db.QueryRow("CALL cell_create_frame(?, ?, NULL)", progID, cellName).
        Scan(&frameID, &gen)
    // ... log, commit
}
```

**From piston system-prompt** (pistons call stored procedures):
```sql
CALL cell_create_frame('my-program', 'my-stem-cell', NULL);
```

### Cell-zero-eval impact

The cell-zero-eval program's eval-one stem cell currently does manual SQL to
spawn successors (`INSERT INTO cells ... INSERT INTO yields ...`). With
`cell_create_frame`, the spawn step becomes:

```sql
-- Instead of raw INSERTs, the piston calls:
CALL cell_create_frame('cell-zero-eval', 'eval-one', NULL);
```

This resolves the integration review's concern (question 2): cell-zero-eval's
raw SQL will break when `frame_id` becomes a required FK on yields. Using the
stored procedure handles frame + yield slot creation atomically.

**However:** cell-zero-eval's successor spawn also creates a new `cells` row
(a copy of itself). This is NOT a createFrame — it's a pour operation
(adding a new cell definition). The correct path is:
1. Stem cells: use `replRespawnStem` → `cell_create_frame` (new frame, not new cell)
2. cell-zero-eval: refactor to use stem cell auto-respawn (which already works
   for all programs since do-7i1.10 removed the hard-coded check)

---

## 4. Backfill Strategy for Old Programs

### Problem

Programs poured before the frame migration have:
- Yields with `frame_id = NULL`
- No rows in the `frames` table
- No rows in the `bindings` table
- Mutable `cells.state` as the only status tracking

The frame migration cannot be a big-bang cutover. Old programs must continue
working during the transition, and there must be a path to backfill them
into the frame model.

### Strategy: Lazy backfill + explicit migration command

Three complementary mechanisms:

#### 4.1 Eager backfill at pour time (already implemented)

`ensureFrames()` in pour.go already creates gen-0 frames for all cells in a
newly poured program. This covers all NEW programs.

```go
// pour.go:311-326 — ensureFrames already handles this
func ensureFrames(db *sql.DB, progID string) {
    // Creates gen-0 frames for cells that don't have them
}
```

**No change needed.** This is the happy path.

#### 4.2 Lazy backfill at claim time (already partially implemented)

`replEvalStep` calls `ensureFrameForCell()` before claiming. This creates a
gen-0 frame on-demand when a piston first touches an old cell.

The yield backfill needs strengthening:

```go
func ensureFrameForCell(db *sql.DB, progID, cellName, cellID string) {
    frameID := "f-" + cellID + "-0"
    db.Exec(
        "INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, 0)",
        frameID, cellName, progID)

    // NEW: Backfill frame_id on existing yields for this cell
    db.Exec(
        "UPDATE yields SET frame_id = ? WHERE cell_id = ? AND frame_id IS NULL",
        frameID, cellID)
}
```

This ensures that when `frame_id` becomes `NOT NULL`, old yields won't violate
the constraint. The backfill is idempotent and safe to run multiple times.

#### 4.3 Explicit migration command: `ct migrate`

For bulk backfill of all old programs at once:

```go
func cmdMigrate(db *sql.DB) {
    // Step 1: Create gen-0 frames for all cells without frames
    db.Exec(`
        INSERT IGNORE INTO frames (id, cell_name, program_id, generation)
        SELECT CONCAT('f-', c.id, '-0'), c.name, c.program_id, 0
        FROM cells c
        WHERE NOT EXISTS (
            SELECT 1 FROM frames f
            WHERE f.program_id = c.program_id AND f.cell_name = c.name
        )
    `)

    // Step 2: Backfill frame_id on all yields
    db.Exec(`
        UPDATE yields y
        JOIN cells c ON y.cell_id = c.id
        SET y.frame_id = CONCAT('f-', c.id, '-0')
        WHERE y.frame_id IS NULL
    `)

    // Step 3: Backfill bindings for frozen cells that have givens
    // (Bindings record which frame read from which frame. For old programs,
    // the binding is gen-0 → gen-0 since there's only one generation.)
    db.Exec(`
        INSERT IGNORE INTO bindings (id, consumer_frame, producer_frame, field_name)
        SELECT
            CONCAT('b-', SUBSTR(MD5(RAND()), 1, 12)),
            CONCAT('f-', g.cell_id, '-0'),
            CONCAT('f-', src.id, '-0'),
            g.source_field
        FROM givens g
        JOIN cells consumer ON consumer.id = g.cell_id
        JOIN cells src ON src.program_id = consumer.program_id
            AND src.name = g.source_cell
        WHERE consumer.state = 'frozen'
          AND NOT EXISTS (
              SELECT 1 FROM bindings b
              WHERE b.consumer_frame = CONCAT('f-', g.cell_id, '-0')
                AND b.field_name = g.source_field
          )
    `)

    // Step 4: Verify
    var nullFrameYields int
    db.QueryRow("SELECT COUNT(*) FROM yields WHERE frame_id IS NULL").Scan(&nullFrameYields)
    if nullFrameYields > 0 {
        fmt.Printf("WARNING: %d yields still have NULL frame_id\n", nullFrameYields)
    }

    // Step 5: Record migration
    db.Exec(`
        INSERT IGNORE INTO retort_migrations (version, description)
        VALUES (3, 'Backfill frame_id on yields, create gen-0 frames')
    `)

    db.Exec("CALL DOLT_COMMIT('-Am', 'migrate: backfill frame model')")
    fmt.Println("Migration complete.")
}
```

#### 4.4 Migration phases

The migration is ordered to avoid breaking running pistons:

**Phase 1: Additive (no breaking changes)**
1. Add `retort_meta` and `retort_migrations` tables
2. Add `cell_create_frame` stored procedure
3. Strengthen lazy backfill in `ensureFrameForCell`
4. Add `ct migrate` command
5. All existing queries continue to work (dual-path: check frame_id if present, fall back to cell_id)

**Phase 2: Backfill (data migration)**
1. Run `ct migrate` on all active retort instances
2. Verify: `SELECT COUNT(*) FROM yields WHERE frame_id IS NULL` = 0
3. Verify: every cell with state != 'declared' has a frame in `frames`

**Phase 3: Cutover (breaking changes)**
1. `ALTER TABLE yields MODIFY frame_id VARCHAR(64) NOT NULL`
2. Replace `UNIQUE(cell_id, field_name)` with `UNIQUE(frame_id, field_name)`
3. Rewrite `ready_cells` → `ready_frames` view
4. Update all stored procedures to use frame_id only
5. Bump `schema_version` to 3, `schema_compat_min` to 3

**Phase 4: Cleanup (remove legacy)**
1. Drop `cells.state`, `cells.computing_since`, `cells.assigned_piston`, `cells.claimed_by`, `cells.claimed_at`
2. Remove COALESCE fallbacks from Go code
3. Remove `cell_id` from `cell_claims` PRIMARY KEY (frame_id is sole PK)
4. Drop old `metadata` table (replaced by `retort_meta`)

### COALESCE bridge pattern

During the transition (Phase 1-2), all frame_id queries use COALESCE to handle
NULL frame_id on old data:

```sql
-- Example: freeze yield for current frame
UPDATE yields
SET is_frozen = TRUE, frozen_at = NOW()
WHERE cell_id = ?
  AND field_name = ?
  AND COALESCE(frame_id, CONCAT('f-', cell_id, '-0')) = ?
```

This pattern is already used in `replSubmit` (eval.go:984, 1095). After Phase 3
(frame_id NOT NULL), the COALESCE can be removed in a cleanup pass.

### Stem cell backfill

Stem cells that have already cycled (gen-0 frozen, gen-1 in progress) need
special handling. `ct migrate` creates frames for gen-0 but cannot infer
higher generations from the current schema (the old model deleted and
recreated the cell row on respawn, losing generation history).

**Decision:** Stem cells that cycled under the old model get only a gen-0 frame.
Their history is lost (the old model destroyed it). This is acceptable because:
1. The Dolt commit history preserves the old state (recoverable via `dolt log`)
2. Going forward, `replRespawnStem` creates proper gen-N frames
3. No running program depends on historical stem generations

---

## Summary: Formal Model Alignment

After all four changes, the schema-to-formal mapping is:

| Formal concept | SQL implementation | Invariant enforced by |
|---------------|-------------------|---------------------|
| `Retort.cells` (immutable) | `cells` table (no mutable columns) | No UPDATE allowed post-pour |
| `Retort.givens` (immutable) | `givens` table | No UPDATE allowed post-pour |
| `Retort.frames` (append-only) | `frames` table | INSERT only, `cell_create_frame` proc |
| `Retort.yields` (append-only) | `yields` table, `UNIQUE(frame_id, field_name)` | I7 yieldUnique via SQL UNIQUE |
| `Retort.bindings` (append-only) | `bindings` table | INSERT only, recorded at freeze |
| `Retort.claims` (mutable lock) | `cell_claims` table, `PK(frame_id)` | I6 claimMutex via SQL PK |
| `FrameStatus` (derived) | `cell_status_v` view | Computed, never stored |
| `frameReady` (derived) | `ready_frames` view | Computed, never stored |

Mutable state is confined to exactly one table (`cell_claims`), matching the
formal model where only `claims` is filtered (not appended) on freeze/release.

---

## Bug Resolution

This design resolves or enables resolution of the following bugs:

| Bug | Resolution |
|-----|-----------|
| do-7i1.5 (cell_id vs frame_id) | Core migration: yields re-keyed on frame_id |
| do-7i1.3 (cells.state mutable) | Drop cells.state, derive from yields/claims |
| do-7i1.7 (status from cells.state) | Same as do-7i1.3 |
| do-7i1.8 (dual claim mechanism) | Single claim table keyed on frame_id |
| do-7i1.13 (cell-level readiness) | `ready_frames` view checks frame-level readiness |
| do-7i1.16 (yield uniqueness per-cell) | `UNIQUE(frame_id, field_name)` |
| do-7i1.17 (claims per-cell) | `PK(frame_id)` on cell_claims |
| do-7i1.21 (readiness from cells.state) | `ready_frames` derives from yields |
| do-7i1.1 (yields DELETE+INSERT) | Append-only: reject if frozen, no DELETE |
| do-7i1.2 (respawn deletes frozen) | `cell_create_frame` creates new gen, old frame preserved |
| do-7i1.6 (bindings not atomic) | `recordBindings` in same commit as freeze |
| do-7i1.10 (createFrame restricted) | `cell_create_frame` proc works for any program |
| do-7i1.15 (pour auto-reset) | Already fixed: pour rejects existing programs |

Remaining bugs not addressed by this design (require separate work):
- do-7i1.4 (bottom state in formal model)
- do-7i1.9 (generationOrdered enforcement — already implemented, needs test)
- do-7i1.14 (noSelfLoops guard — already implemented, needs test)
- do-7i1.12 (explicit release — `replRelease` already exists)
- do-7i1.24 (oracle atomicity — architectural decision needed)

# Retort Schema v2: Additions for Stored Procedure Runtime

**Date**: 2026-03-14
**Status**: Design
**Parent**: do-27k

## Base: Schema v1 (from ericfode/cell schema.go)

The existing v1 schema is retained as-is:
- `programs`, `cells`, `givens`, `yields`, `oracles`
- `recovery_policies`, `evolution_loops`
- `trace`, `bead_bridge`, `config`, `metadata`
- `ready_cells` VIEW
- `DoltIgnoreTrace`

---

## V2 Additions

### 1. cell_claims (Multi-Piston Atomic Claiming)

Dolt has no `SELECT ... FOR UPDATE`. This table provides atomic claiming
via INSERT-or-fail on PRIMARY KEY.

```sql
CREATE TABLE IF NOT EXISTS cell_claims (
  cell_id VARCHAR(64) PRIMARY KEY,
  piston_id VARCHAR(255) NOT NULL,
  claimed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  heartbeat_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_claims_cell FOREIGN KEY (cell_id) REFERENCES cells(id)
);
```

Claiming flow:
1. Piston queries `ready_cells` for a candidate
2. Piston attempts `INSERT INTO cell_claims (cell_id, piston_id) VALUES (?, ?)`
3. If INSERT succeeds: piston owns the cell. Update `cells.state = 'computing'`
4. If duplicate key error: another piston claimed it. Try next ready cell.
5. On freeze/bottom: DELETE from cell_claims.

Heartbeat: pistons update `heartbeat_at` periodically. `cell_reap_stale()`
deletes claims where `heartbeat_at < NOW() - INTERVAL 5 MINUTE` and resets
cells to `declared`.

### 2. cell_soft_bodies (Preserving Soft Versions)

When a cell crystallizes, the soft body is preserved here for fallback.

```sql
CREATE TABLE IF NOT EXISTS cell_soft_bodies (
  cell_id VARCHAR(64) PRIMARY KEY,
  soft_body TEXT NOT NULL,
  crystallized_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  crystallized_as TEXT,  -- 'view:cell_prog_name' or 'sql:...'
  CONSTRAINT fk_soft_cell FOREIGN KEY (cell_id) REFERENCES cells(id)
);
```

### 3. Columns Added to cells

```sql
ALTER TABLE cells
  ADD COLUMN model_hint VARCHAR(64) DEFAULT NULL
    COMMENT 'Preferred model tier: haiku, sonnet, opus, local',
  ADD COLUMN executor_type VARCHAR(32) DEFAULT 'soft'
    COMMENT 'How to evaluate: soft, view, sql, exec',
  ADD COLUMN executor_ref TEXT DEFAULT NULL
    COMMENT 'Reference: view name, SQL query, or exec path',
  ADD COLUMN claimed_by VARCHAR(255) DEFAULT NULL
    COMMENT 'Piston ID currently evaluating this cell',
  ADD COLUMN claimed_at TIMESTAMP NULL DEFAULT NULL
    COMMENT 'When the cell was claimed for evaluation';
```

Note: `claimed_by`/`claimed_at` on the cells table is a denormalization for
fast querying. The `cell_claims` table is the source of truth for atomic claiming.

### 4. Columns Added to programs

```sql
ALTER TABLE programs
  ADD COLUMN source_text TEXT DEFAULT NULL
    COMMENT 'Original source text (turnstyle syntax) for document-is-state rendering',
  ADD COLUMN lifecycle ENUM('active', 'quiescent', 'completed', 'archived')
    NOT NULL DEFAULT 'active'
    COMMENT 'Program lifecycle state';
```

### 5. piston_registry (Who Is Connected)

```sql
CREATE TABLE IF NOT EXISTS piston_registry (
  piston_id VARCHAR(255) PRIMARY KEY,
  model_tier VARCHAR(64),
  connected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_heartbeat TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  cells_evaluated INT DEFAULT 0,
  status ENUM('active', 'idle', 'dead') DEFAULT 'active'
);
```

Pistons register on connect, heartbeat periodically, deregister on exit.
`cell_reap_stale()` marks pistons as 'dead' when heartbeat expires.

### 6. program_lifecycle VIEW

```sql
CREATE OR REPLACE VIEW program_lifecycle AS
SELECT
  p.id,
  p.name,
  p.lifecycle,
  COUNT(c.id) as total_cells,
  SUM(CASE WHEN c.state = 'frozen' THEN 1 ELSE 0 END) as frozen_cells,
  SUM(CASE WHEN c.state = 'bottom' THEN 1 ELSE 0 END) as bottom_cells,
  SUM(CASE WHEN c.state = 'computing' THEN 1 ELSE 0 END) as computing_cells,
  SUM(CASE WHEN c.state = 'declared' THEN 1 ELSE 0 END) as declared_cells,
  CASE
    WHEN SUM(CASE WHEN c.state IN ('declared', 'computing') THEN 1 ELSE 0 END) = 0
    THEN 'quiescent'
    ELSE 'active'
  END as computed_lifecycle
FROM programs p
LEFT JOIN cells c ON c.program_id = p.id
GROUP BY p.id;
```

---

## Program Lifecycle

### States

| State | Meaning | Transition |
|-------|---------|------------|
| `active` | Cells are being evaluated (some declared/computing) | Automatic via eval loop |
| `quiescent` | No ready cells. All frozen, bottom, or blocked. | Automatic when ready_cells returns empty |
| `completed` | User/system marks program as done. | Manual: `CALL cell_complete(program_id)` |
| `archived` | Compressed, no longer in active query paths. | Manual: `CALL cell_archive(program_id)` |

### Quiescence Detection

After each `cell_eval_step` returns 'quiescent', the procedure checks:

```sql
-- Are there ANY declared cells left for this program?
SELECT COUNT(*) FROM cells
WHERE program_id = ? AND state = 'declared';

-- If 0: program is quiescent
UPDATE programs SET lifecycle = 'quiescent' WHERE id = ?;
```

### Quiescence Types

Not all quiescence is equal:

```sql
CREATE OR REPLACE VIEW quiescence_report AS
SELECT
  p.id, p.name,
  CASE
    WHEN bottom_cells = 0 AND declared_cells = 0 THEN 'clean'
    WHEN bottom_cells > 0 AND declared_cells = 0 THEN 'partial'
    WHEN declared_cells > 0 AND computing_cells = 0 THEN 'stuck'
    ELSE 'active'
  END as quiescence_type
FROM program_lifecycle p;
```

- **clean**: All cells frozen. Program ran to completion.
- **partial**: Some cells are ⊥. Program completed with failures.
- **stuck**: Declared cells exist but none are ready. Possible deadlock
  (circular deps, guard clauses blocking, etc.)

### Resumption

A quiescent program can become active again:
- New cells added (spawner fires, user adds cells)
- External input changes (upstream program provides new values)
- Manual: `CALL cell_resume(program_id)` resets lifecycle to 'active'

### Archival

Archiving compresses the program's execution history:
1. Squash intermediate Dolt commits into a single checkpoint
2. Remove trace entries older than the checkpoint
3. Mark program as 'archived'
4. Frozen yields remain queryable (they're just rows)

---

## Stored Procedures Summary

### Core Runtime

| Procedure | Purpose |
|-----------|---------|
| `cell_pour(name, source_text)` | Parse turnstyle text → create program + cells + givens + yields + oracles |
| `cell_eval_step(program_id)` | Find ready cell → claim → dispatch (hard: evaluate, soft: return prompt) |
| `cell_submit(cell_id, yields_json)` | Write tentative values → check oracles → freeze/retry/bottom |
| `cell_oracle_result(oracle_id, pass_fail, detail)` | Report semantic oracle result from piston |

### Lifecycle

| Procedure | Purpose |
|-----------|---------|
| `cell_complete(program_id)` | Mark program as completed |
| `cell_archive(program_id)` | Compress history, mark archived |
| `cell_resume(program_id)` | Reset to active |

### Reliability

| Procedure | Purpose |
|-----------|---------|
| `cell_reap_stale(timeout_minutes)` | Reset cells stuck in computing (dead pistons) |
| `cell_register_piston(piston_id, model_tier)` | Register a new piston |
| `cell_heartbeat(piston_id)` | Update heartbeat timestamp |

### Crystallization

| Procedure | Purpose |
|-----------|---------|
| `cell_crystallize(cell_id, proposed_sql)` | Test + create view + update cell |
| `cell_decrystallize(cell_id)` | Revert to soft version (fallback) |

### Observability

| Procedure/View | Purpose |
|----------------|---------|
| `cell_status(program_id)` | Render program state |
| `cell_history(program_id, n_steps)` | Recent execution steps from trace |
| `program_lifecycle` VIEW | Per-program summary |
| `quiescence_report` VIEW | Quiescence type classification |
| `ready_cells` VIEW | Frontier computation (from v1) |

---

## Schema Version

```sql
-- Update schema version
UPDATE metadata SET value_text = '2' WHERE key_name = 'schema_version';
-- Or if using the Go constant:
-- const SchemaVersion = 2
```

Migration from v1 → v2:
1. CREATE TABLE cell_claims
2. CREATE TABLE cell_soft_bodies
3. CREATE TABLE piston_registry
4. ALTER TABLE cells ADD COLUMN model_hint, executor_type, executor_ref, claimed_by, claimed_at
5. ALTER TABLE programs ADD COLUMN source_text, lifecycle
6. CREATE VIEW program_lifecycle
7. CREATE VIEW quiescence_report
8. Create stored procedures (cell_pour, cell_eval_step, cell_submit, etc.)
9. UPDATE metadata SET schema_version = 2

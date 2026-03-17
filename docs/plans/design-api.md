# Design: API Dimension — Cell Next Phase

**Author:** agate (polecat)
**Date:** 2026-03-17
**Bead:** do-8dx
**Sources:** `cmd/ct/*.go`, `piston/system-prompt.md`, `schema/*.sql`,
`formal/Retort.lean`, `examples/*.cell`, design docs in `docs/plans/`

---

## Overview

This document specifies the API surface changes for the Cell next phase:
the frame model migration, schema versioning, and piston prompt evolution.
Three interlocking pieces:

1. **ct command surface** — new commands (`ct thaw`, `ct version`), modified
   commands (`ct pour`, `ct submit`)
2. **Stored procedures** — `cell_create_frame`, updated `piston_register`
   with `schema_epoch`
3. **Piston prompt v2** — ct-only interface, ~80 lines, no raw SQL

---

## 1. ct Command Surface

### 1.1 Existing commands (no change)

| Command | Purpose |
|---------|---------|
| `ct pour <name> <file.cell>` | Load program (additive, errors on conflict) |
| `ct piston [<program-id>]` | Autonomous eval loop |
| `ct next [--wait] [--model M] [<prog>]` | Claim one cell, print prompt, exit |
| `ct submit <prog> <cell> <field> <value>` | Freeze a yield value |
| `ct status <prog>` | Cell states + yields |
| `ct frames <prog>` | Frame generations |
| `ct yields <prog>` | Frozen yields only |
| `ct history <prog>` | Execution trace + claim log |
| `ct graph <prog>` | Dependency DAG from bindings |
| `ct reset <prog>` | Destructive reset (formal deviation) |
| `ct eval <name> <file.cell>` | Submit to cell-zero-eval |
| `ct watch [<prog>]` | Live dashboard |
| `ct lint <file.cell>` | Syntax check |

### 1.2 New: `ct version`

Reports the schema epoch and runtime version. Pistons call this on startup
to verify compatibility.

```
ct version
```

Output:
```
ct 0.2.0
schema_epoch: 2
retort db: connected (127.0.0.1:3308)
tables: cells, yields, givens, oracles, frames, bindings, claim_log, pistons, cell_claims
procedures: cell_eval_step (v2), cell_submit (v2), piston_register (v2)
```

**Implementation:**

```go
func cmdVersion(db *sql.DB) {
    fmt.Println("ct 0.2.0")

    // Query schema_epoch from the retort_meta table
    var epoch int
    err := db.QueryRow("SELECT value_int FROM retort_meta WHERE key_name = 'schema_epoch'").Scan(&epoch)
    if err != nil {
        fmt.Printf("schema_epoch: unknown (retort_meta not found)\n")
    } else {
        fmt.Printf("schema_epoch: %d\n", epoch)
    }

    // Verify db connection
    if err := db.Ping(); err != nil {
        fmt.Printf("retort db: disconnected (%v)\n", err)
    } else {
        fmt.Printf("retort db: connected\n")
    }
}
```

Add to `main.go` switch:
```go
case "version":
    cmdVersion(db)
```

**Schema addition** (in `retort-init.sql`):
```sql
CREATE TABLE IF NOT EXISTS retort_meta (
    key_name   VARCHAR(64) PRIMARY KEY,
    value_int  INT,
    value_text VARCHAR(256)
);
INSERT IGNORE INTO retort_meta (key_name, value_int) VALUES ('schema_epoch', 2);
```

### 1.3 New: `ct thaw <program-id> <cell-name>`

Unfreezes a single cell's latest frame, returning it to `declared` state.
This enables the user-experience gap identified in `prd-review-user-experience.md`:
when a cell produces a bad result, the user can fix just that cell without
resetting the entire program.

```
ct thaw <program-id> <cell-name>
```

**Semantics:**
1. Find the latest frame for `<cell-name>` in `<program-id>`.
2. If the frame is not frozen, error: `cell not frozen`.
3. Delete the yield values for that frame (set `value_text=NULL`,
   `is_frozen=FALSE`, `frozen_at=NULL`).
4. Remove any bindings where this frame is the producer AND the
   downstream consumer is also frozen — those consumers must also
   be thawed (cascading thaw).
5. Commit with message `thaw: <cell-name> in <program-id>`.

**Cascading thaw rule:** When frame F is thawed, any frozen frame G
that has a binding `(consumer=G, producer=F)` must also be thawed.
This recurses until no more frozen dependents exist. This preserves
the `bindingsPointToFrozen` invariant (I11): every binding's producer
must be frozen.

**Formal model note:** `ct thaw` is a **formal deviation** (like `ct reset`)
— the Lean model has no thaw operation. Thaw violates `yieldsPreserved`
(yields are deleted) and `bindingsPreserved` (bindings of downstream
consumers are deleted). Like reset, thaw should log an epoch boundary
marker in the trace table, and Dolt history preserves the pre-thaw state.

```go
func cmdThaw(db *sql.DB, progID, cellName string) {
    fmt.Fprintf(os.Stderr,
        "⚠ thaw is outside the formal model (Retort.lean has no thaw operation).\n"+
        "  Yields and downstream bindings will be removed. Dolt history preserves pre-thaw state.\n")

    // Find latest frame
    frameID := latestFrameID(db, progID, cellName)
    if frameID == "" {
        fatal("no frame found for %s in %s", cellName, progID)
    }

    // Verify frozen
    // ... (check frameStatus == frozen via yield query)

    // Cascading thaw
    thawFrame(db, progID, frameID)

    mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
        fmt.Sprintf("thaw: %s in %s", cellName, progID))
    fmt.Printf("✓ Thawed %s (and downstream dependents)\n", cellName)
}

func thawFrame(db *sql.DB, progID, frameID string) {
    // Clear yields for this frame
    db.Exec("UPDATE yields SET value_text=NULL, value_json=NULL, is_frozen=FALSE, frozen_at=NULL "+
        "WHERE frame_id = ?", frameID)

    // Reset cell state to declared
    db.Exec("UPDATE cells c JOIN frames f ON f.program_id = c.program_id AND f.cell_name = c.name "+
        "SET c.state = 'declared', c.computing_since = NULL, c.assigned_piston = NULL "+
        "WHERE f.id = ?", frameID)

    // Log thaw event
    db.Exec("INSERT INTO trace (id, cell_id, event_type, detail) VALUES (?, ?, 'thaw', ?)",
        fmt.Sprintf("t-thaw-%s-%d", frameID, time.Now().UnixMilli()),
        frameID, "epoch boundary: frame thawed")

    // Cascade: find frozen downstream consumers
    rows, _ := db.Query(
        "SELECT DISTINCT b.consumer_frame FROM bindings b "+
        "JOIN frames f ON f.id = b.consumer_frame "+
        "WHERE b.producer_frame = ? AND f.program_id = ?", frameID, progID)
    defer rows.Close()
    for rows.Next() {
        var consumerFrame string
        rows.Scan(&consumerFrame)
        // Check if consumer is frozen
        var frozenCount int
        db.QueryRow("SELECT COUNT(*) FROM yields WHERE frame_id = ? AND is_frozen = TRUE",
            consumerFrame).Scan(&frozenCount)
        if frozenCount > 0 {
            thawFrame(db, progID, consumerFrame) // recurse
        }
    }

    // Remove bindings where this frame is producer (they're now invalid)
    db.Exec("DELETE FROM bindings WHERE producer_frame = ?", frameID)
}
```

Add to `main.go` switch:
```go
case "thaw":
    need(args, 2, "ct thaw <program-id> <cell-name>")
    cmdThaw(db, args[0], args[1])
```

### 1.4 Modified: `ct submit` — frame_id awareness

Currently `ct submit` finds the cell by `(program_id, name, state='computing')`.
After the frame migration, submit must also record bindings atomically with
the yield freeze. The signature stays the same:

```
ct submit <program-id> <cell-name> <field> <value>
```

**Changes in replSubmit (eval.go):**

1. **No DELETE before INSERT.** Yields are append-only per-frame. If a yield
   for `(frame_id, field_name)` already exists and is frozen, return error
   "yield already frozen" (fixes do-7i1.1, do-7i1.40).

2. **Record bindings atomically.** After freezing the last yield, call
   `recordBindings` in the same transaction before `DOLT_COMMIT`
   (fixes do-7i1.6).

3. **Stem cell respawn.** After freeze, if `body_type='stem'`, create a
   new frame at `gen+1` via `cell_create_frame` instead of deleting the
   frozen cell (fixes do-7i1.2). No program restriction
   (fixes do-7i1.10).

### 1.5 Modified: `ct pour` — schema_epoch check

Before pouring, verify the retort schema is at the expected epoch:

```go
var epoch int
db.QueryRow("SELECT value_int FROM retort_meta WHERE key_name = 'schema_epoch'").Scan(&epoch)
if epoch < REQUIRED_EPOCH {
    fatal("retort schema epoch %d < required %d. Run schema migration.", epoch, REQUIRED_EPOCH)
}
```

This prevents pouring programs against an outdated schema where the frame
model isn't in place.

---

## 2. Stored Procedures

### 2.1 New: `cell_create_frame`

Creates a new frame for a cell (typically after a stem cell freezes).
This is the Go-side implementation of the formal `RetortOp.createFrame`.

```sql
DELIMITER //

DROP PROCEDURE IF EXISTS cell_create_frame //

CREATE PROCEDURE cell_create_frame(
    IN p_program_id VARCHAR(255),
    IN p_cell_name  VARCHAR(128)
)
BEGIN
    DECLARE v_cell_id VARCHAR(255);
    DECLARE v_max_gen INT DEFAULT 0;
    DECLARE v_new_frame_id VARCHAR(64);

    -- Verify cell exists and is a stem cell
    SELECT id INTO v_cell_id
    FROM cells
    WHERE program_id = p_program_id AND name = p_cell_name AND body_type = 'stem';

    IF v_cell_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cell not found or not a stem cell';
    END IF;

    -- Find max generation
    SELECT COALESCE(MAX(generation), -1) INTO v_max_gen
    FROM frames
    WHERE program_id = p_program_id AND cell_name = p_cell_name;

    -- Create next-gen frame
    SET v_new_frame_id = CONCAT('f-', p_program_id, '-', p_cell_name, '-', v_max_gen + 1);

    INSERT INTO frames (id, cell_name, program_id, generation)
    VALUES (v_new_frame_id, p_cell_name, p_program_id, v_max_gen + 1);

    -- Create unfrozen yield slots for the new frame
    -- (mirrors the yield fields defined for this cell)
    INSERT INTO yields (id, cell_id, frame_id, field_name)
    SELECT CONCAT('y-', v_new_frame_id, '-', y.field_name),
           v_cell_id, v_new_frame_id, y.field_name
    FROM yields y
    WHERE y.cell_id = v_cell_id
      AND y.frame_id = (
          SELECT id FROM frames
          WHERE program_id = p_program_id AND cell_name = p_cell_name
          ORDER BY generation ASC LIMIT 1
      )
    GROUP BY y.field_name;

    SELECT v_new_frame_id AS frame_id, v_max_gen + 1 AS generation;
END //

DELIMITER ;
```

**Go-side equivalent** (already partially exists in `replRespawnStem`):

```go
func createFrame(db *sql.DB, progID, cellName string) (string, int, error) {
    var maxGen int
    db.QueryRow(
        "SELECT COALESCE(MAX(generation), -1) FROM frames WHERE program_id = ? AND cell_name = ?",
        progID, cellName).Scan(&maxGen)

    newGen := maxGen + 1
    frameID := fmt.Sprintf("f-%s-%s-%d", progID, cellName, newGen)

    _, err := db.Exec(
        "INSERT INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, ?)",
        frameID, cellName, progID, newGen)
    if err != nil {
        return "", 0, err
    }

    // Create yield slots from cell definition
    db.Exec(`INSERT INTO yields (id, cell_id, frame_id, field_name)
        SELECT CONCAT('y-', ?, '-', y.field_name), y.cell_id, ?, y.field_name
        FROM yields y
        JOIN cells c ON c.id = y.cell_id
        WHERE c.program_id = ? AND c.name = ?
        GROUP BY y.field_name`, frameID, frameID, progID, cellName)

    return frameID, newGen, nil
}
```

### 2.2 Modified: `piston_register` — schema_epoch parameter

Add a `p_schema_epoch` parameter. The procedure checks the expected epoch
against the retort_meta value and rejects mismatches. This prevents stale
pistons from writing to a schema they don't understand.

```sql
DELIMITER //

DROP PROCEDURE IF EXISTS piston_register //

CREATE PROCEDURE piston_register(
    IN p_id         VARCHAR(255),
    IN p_program_id VARCHAR(255),
    IN p_model_hint VARCHAR(64),
    IN p_schema_epoch INT
)
BEGIN
    DECLARE v_current_epoch INT DEFAULT 0;

    -- Check schema compatibility
    IF p_schema_epoch IS NOT NULL THEN
        SELECT COALESCE(value_int, 0) INTO v_current_epoch
        FROM retort_meta WHERE key_name = 'schema_epoch';

        IF p_schema_epoch != v_current_epoch THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Schema epoch mismatch: piston expects different schema version';
        END IF;
    END IF;

    INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status)
    VALUES (p_id, p_program_id, p_model_hint, NOW(), NOW(), 'active')
    ON DUPLICATE KEY UPDATE
        program_id = p_program_id,
        model_hint = p_model_hint,
        started_at = NOW(),
        last_heartbeat = NOW(),
        status = 'active',
        cells_completed = 0;
END //

DELIMITER ;
```

**Backward compatibility:** `p_schema_epoch = NULL` skips the check, so
existing pistons that call `piston_register(id, prog, hint)` with 3 args
would need updating. Two options:

- **Option A (recommended):** Keep the old 3-arg signature as a wrapper
  that calls the 4-arg version with `NULL`. This is a SQL overload.
  Dolt doesn't support procedure overloading, so use a default:
  make the Go code always pass the epoch and update the piston prompt
  to pass it too.

- **Option B:** Add the column to the `pistons` table and check on
  heartbeat instead. This avoids procedure signature changes but is
  less immediate.

**Chosen: Option A.** The 4th parameter is always passed. The piston
prompt v2 includes it. Old pistons with the 3-arg call will fail
(which is the desired behavior — they should upgrade).

### 2.3 Modified: `cell_eval_step` — frame-aware claiming

Key changes to `cell_eval_step` for the frame model:

1. **Claim by frame, not cell.** The INSERT goes into `cell_claims`
   with `frame_id` as the unique key (already has `idx_cell_claims_frame`).
   The claiming query scans `frames` joined with cell definitions and
   readiness checks, not the `ready_cells` view.

2. **Resolved inputs via bindings.** After claiming, record bindings
   for the claimed frame's givens (resolve each given to the latest
   frozen producer frame). Return `resolved_inputs` from the bindings.

3. **Remove `UPDATE cells SET state='computing'`.** State is derived
   from claims + yields. A frame is "computing" when it has a claim
   but not all yields are frozen.

These are implementation details for the frame migration (do-7i1.5).
The procedure interface stays the same:

```sql
CALL cell_eval_step('program-id', 'piston-id');
```

Returns the same columns: `action`, `cell_id`, `cell_name`, `body`,
`body_type`, `model_hint`, `resolved_inputs`.

### 2.4 Modified: `cell_submit` — append-only yields

Key changes:

1. **No DELETE.** Yields are inserted once per `(frame_id, field_name)`.
   If the yield already exists and `is_frozen=TRUE`, return error.

2. **Atomic bindings.** Record bindings in the same commit as the freeze.

3. **Auto-respawn.** After all yields frozen, if `body_type='stem'`,
   call `cell_create_frame` to create the next generation.

4. **Remove `UPDATE cells SET state='frozen'`.** State is derived.

The procedure interface stays the same:

```sql
CALL cell_submit('program-id', 'cell-name', 'field-name', 'value');
```

Returns the same columns: `result`, `message`, `field_name`.

---

## 3. Piston Prompt v2

The current piston prompt (187 lines) mixes raw SQL with ct commands and
documents both paths. The v2 prompt is ct-only: pistons never write raw
SQL. This addresses the integration gap (prd-review-integration.md Q2)
and the user experience question (prd-review-user-experience.md Q2).

### 3.1 Design principles

1. **ct is the sole interface.** No `dolt sql`, no raw INSERTs, no
   direct table access. This ensures the piston can never violate
   formal invariants because all mutations go through procedures
   (via ct) which enforce them.

2. **Schema version declared upfront.** The piston registers with
   `schema_epoch`, so stale prompts fail fast on startup.

3. **Narration via ct output.** Instead of the piston printing custom
   narration formats, ct commands produce structured output that the
   piston passes through. This decouples narration from the prompt.

4. **~80 lines.** Cut SQL documentation, collapse sections, remove
   duplicate guidance. Focus on the decision tree: what to do at each
   step of the eval loop.

### 3.2 Prompt text

```markdown
# Cell Piston v2

You are a Cell runtime piston. You evaluate soft cells in Cell programs.
Hard cells are evaluated automatically. You handle soft cells: read the
prompt, think, produce output, submit.

## Startup

1. Run `ct version` to verify schema compatibility.
2. Register: `ct piston <program-id>` (handles registration internally).
   Or for manual mode: `ct next [--wait] [<program-id>]`.

## The Eval Loop

Repeat until complete or quiescent:

### Step 1: Get work

```
ct next [--wait] [<program-id>]
```

Read the output. If `action=complete` or `action=quiescent`, stop.
If `action=dispatch`, continue.

### Step 2: Evaluate

The dispatch output includes:
- `cell_name`, `body` (the prompt), `resolved_inputs` (JSON)

Read `resolved_inputs` — these are frozen values from upstream cells.
References like «field» in the body refer to these values.

Think carefully. Use your tools (bash, file I/O, web search, code
execution) when the task requires it.

### Step 3: Submit

For each yield field listed in the dispatch output:

```
ct submit <program-id> <cell-name> <field> '<value>'
```

Handle the result:
- `ok` — yield accepted. Continue to Step 1.
- `oracle_fail` — deterministic check failed. Read the message,
  revise your answer, resubmit. Max 3 attempts.
- `error` — something went wrong. Print error, continue to Step 1.

### Step 4: Status

After each cycle:
```
ct status <program-id>
```

## Judge Cells

Judge cells have name pattern `{cell}-judge-{n}` and body starting
with "Judge whether...". Evaluate the assertion honestly — independent
verification, not rubber-stamping. Submit your verdict as the `verdict`
yield.

## Inspection

```
ct status <prog>    # Cell states + yields
ct yields <prog>    # Frozen yields only
ct frames <prog>    # Frame generations
ct graph <prog>     # Dependency DAG
ct history <prog>   # Execution trace
```

## Rules

1. No state between cells. Each eval step starts fresh.
2. No direct database writes. Only use ct commands.
3. Do not evaluate hard cells. Report if dispatched one.
4. Use your tools. You are a full Claude Code session.
5. Oracle failures are feedback. Revise, don't blindly retry.
6. One cell at a time. Submit all yields before requesting next.
```

### 3.3 Migration path

The v1 prompt stays as `piston/system-prompt.md`. The v2 prompt is
written to `piston/system-prompt-v2.md`. Once the frame migration
lands and all procedures are updated, swap:

```bash
mv piston/system-prompt.md piston/system-prompt-v1.md
mv piston/system-prompt-v2.md piston/system-prompt.md
```

The `ct piston` command should eventually inject the prompt version
based on schema_epoch, but for now the file swap is sufficient.

---

## 4. Schema Epoch Strategy

The schema epoch answers the integration review's Question 1: how do
running pistons discover a new schema?

### Epoch definitions

| Epoch | Schema state | Key changes |
|-------|-------------|-------------|
| 1 | Current (v1) | cell_id keyed, mutable state, DELETE+INSERT yields |
| 2 | Frame model (v2) | frame_id keyed, derived state, append-only yields |

### Enforcement points

1. **`piston_register`** — pistons declare their expected epoch.
   Mismatch = immediate failure with clear error message.

2. **`ct pour`** — checks epoch before inserting. Prevents pouring
   v2-syntax programs against v1 schema.

3. **`ct version`** — reports current epoch. Pistons can call this
   before any other operation.

4. **`retort_meta` table** — single row keyed on `'schema_epoch'`.
   Updated by migration scripts, never by runtime code.

### Migration protocol

When bumping the schema epoch (e.g., 1→2):

1. Stop all pistons (or let them fail on epoch mismatch).
2. Run migration SQL: `ALTER TABLE`, backfills, new procedures.
3. `UPDATE retort_meta SET value_int = 2 WHERE key_name = 'schema_epoch'`.
4. Start pistons with updated prompt (v2).

No rolling upgrade. The epoch is a hard gate. This is intentional:
schema changes affect stored procedure semantics, and a piston with
the wrong mental model will produce incorrect results.

---

## 5. cell-zero-eval Evolution

The integration review's Question 2 asks about cell-zero-eval's raw SQL
for spawning. With the frame model:

**Decision: cell-zero-eval uses `ct submit` for spawning.** The auto-respawn
mechanism in `cell_create_frame` handles stem cell generation cycling.
cell-zero-eval's `eval-one` and `pour-one` are stem cells. After their
yields freeze, `ct submit` (via the procedure) automatically creates the
next generation frame. No manual SQL INSERTs needed.

The cell-zero-eval.cell file needs updating to remove the "Step 4: Spawn
successor" section. The piston prompt v2 documents auto-respawn: "After
`ct submit` freezes a stem cell's last yield, the next generation is
created automatically."

---

## 6. Oracle Atomicity Decision

The integration review's Question 3 and bug do-7i1.24 ask about oracle
timing relative to freeze.

**Decision: Async oracles (option B).** Semantic oracles via judge cells
evaluate AFTER the original cell freezes. This is already the implemented
behavior and avoids the deadlock risk of blocking oracles (judge cells
depend on the original cell's yields).

**Formal model update:** The Lean model should allow `oraclePass = None`
(pending) as a valid state for frozen frames. A new invariant:
`frozenFrameOracleEventual` — every frozen frame with semantic oracles
must eventually have all judge cells frozen (liveness, not safety).

The downstream consumer of a judged cell should check the judge verdict
before proceeding. This is already supported by the `given` mechanism:
the consumer can have a `given judge-N.verdict` dependency, which blocks
it until the judge freezes.

---

## 7. Summary of Changes

### New files
- `docs/plans/design-api.md` — this document
- `piston/system-prompt-v2.md` — ct-only piston prompt (~80 lines)

### Schema changes
- `retort_meta` table (key-value, stores schema_epoch)
- `piston_register` procedure: 4th parameter `p_schema_epoch`
- `cell_create_frame` procedure: creates next-gen frames for stem cells
- `cell_eval_step` procedure: frame-aware claiming + binding resolution
- `cell_submit` procedure: append-only yields + atomic bindings + auto-respawn

### ct command changes
- New: `ct version` — reports schema epoch and runtime version
- New: `ct thaw <prog> <cell>` — unfreeze a cell with cascading thaw
- Modified: `ct submit` — append-only, atomic bindings, auto-respawn
- Modified: `ct pour` — schema_epoch check on startup

### Formal model notes
- `ct thaw` and `ct reset` are formal deviations (documented, logged)
- Oracle atomicity: async (judge cells post-freeze), eventual liveness
- `FrameStatus` remains `declared | computing | frozen` (no `bottom` change in this phase)

### Bug resolution enabled

These API changes, combined with the frame migration, enable resolution of:

| Group | Bugs | Mechanism |
|-------|------|-----------|
| A (cell→frame rekey) | do-7i1.5, .3, .7, .8, .13, .16, .17, .21 | cell_eval_step v2, frame-aware queries |
| B (append-only) | do-7i1.1, .2, .27, .32, .40 | cell_submit v2, cell_create_frame |
| C (atomic bindings) | do-7i1.6, .11, .33 | cell_submit v2 atomic freeze |
| E (missing ops) | do-7i1.10, .12, .28 | cell_create_frame, no program restriction |
| UX (user recovery) | prd-review Q1 | ct thaw |
| Integration (schema) | prd-review Q1 | ct version, schema_epoch |
| Integration (prompt) | prd-review Q2 | piston prompt v2 |

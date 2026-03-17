# Frame Migration: cell_id → frame_id (Revised)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Re-key the runtime from cell_id to frame_id. Fixes 13 of 25 conformance bugs.

**Architecture:** 2 phases (revised from 5 per critique). Phase A stops deleting rows. Phase B rekeys everything atomically.

---

## Phase A: Stop deleting rows (do-7i1.2, do-7i1.1)

**Precondition:** Tests green. e2e-piston.sh passes.

### Step 1: Rewrite replRespawnStem — create frame, don't delete cell

Instead of DELETE cells/yields/givens + INSERT new cell:
- Keep the frozen cell row (it's immutable per formal model)
- INSERT a new frame at gen+1 for the same cell name
- The new frame starts with fresh yield rows (frame_id = new frame)
- Cell row stays, givens stay, oracles stay

```go
func replRespawnStem(db *sql.DB, progID, cellName, frozenCellID string) {
    // Find current max generation
    var maxGen int
    db.QueryRow("SELECT COALESCE(MAX(generation), 0) FROM frames WHERE program_id = ? AND cell_name = ?",
        progID, cellName).Scan(&maxGen)

    // Create next-gen frame
    newFrameID := fmt.Sprintf("f-%s-%s-%d", progID[:min(20, len(progID))], cellName, maxGen+1)
    db.Exec("INSERT INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, ?)",
        newFrameID, cellName, progID, maxGen+1)

    // Create fresh yield slots for the new frame
    // (yields are per-frame, so the frozen frame's yields stay)
    ...
}
```

### Step 2: Make yields append-only in replSubmit

Remove `DELETE FROM yields WHERE cell_id = ? AND field_name = ?`.
Replace with: check if yield already exists and is frozen → return error.
Otherwise INSERT (not replace).

### Step 3: Test
- `grep -c 'DELETE FROM yields' cmd/ct/eval.go` → 0
- `grep -c 'DELETE FROM cells' cmd/ct/eval.go` → 0
- `grep -c 'DELETE FROM givens' cmd/ct/eval.go` → 0
- e2e test passes
- Stem cell respawn creates gen+1 frame, old frame stays frozen

---

## Phase B: Rekey yields/claims to frame_id (do-7i1.5, .3, .16, .17, .13)

**Precondition:** Phase A done. No more DELETEs.

### Step 1: Schema — add frame_id to yields, make NOT NULL for new rows
```sql
ALTER TABLE yields ADD COLUMN frame_id VARCHAR(64);
```

### Step 2: Backfill — set frame_id for all existing yields
```sql
UPDATE yields y
JOIN cells c ON y.cell_id = c.id
JOIN frames f ON f.program_id = c.program_id AND f.cell_name = c.name
SET y.frame_id = f.id
WHERE y.frame_id IS NULL;
```

### Step 3: Swap all queries atomically
Update every function that reads/writes yields to use frame_id:
- replSubmit: INSERT with frame_id
- resolveInputs: JOIN through frames
- getYieldFields: JOIN through frames
- findReadyCell: readiness check via frames
- cmdStatus, cmdYields, cmdHistory: display via frames
- recordBindings: already uses frame_id

Replace cell_claims with frame_claims (same swap).

### Step 4: Drop cells.state
Stop writing `UPDATE cells SET state = ...`. Derive from yields + claims.

### Step 5: Test
- All 78+ tests pass
- e2e piston test passes
- `SELECT COUNT(*) FROM yields WHERE frame_id IS NULL` → 0

---

## Bug resolution

| Phase | Bugs fixed |
|-------|-----------|
| A | do-7i1.1, do-7i1.2 |
| B | do-7i1.3, do-7i1.5, do-7i1.6, do-7i1.13, do-7i1.16, do-7i1.17 |

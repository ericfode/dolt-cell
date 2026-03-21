# Bug Fix Analysis: do-7i1 (Lean-to-Go Conformance True-Up)

25 bugs, analyzed by root cause. Many share the same underlying issue.

---

## Root Cause Groups

### Group A: cell_id-keyed data model vs frame_id-keyed formal model (8 bugs)

The formal model (Retort.lean) keys everything on `FrameId`. The Go implementation
keys on `cell_id`. This is the single deepest architectural mismatch. Yields,
claims, bindings, and readiness checks all use cell_id where the Lean spec uses
frame_id. This means stem cell generations share a single namespace, previous
generation data is overwritten instead of preserved, and frame-level parallelism
is impossible.

**Bugs in this group:**

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.5 | cell_id based data model vs frame_id based formal model | YES -- this IS the migration |
| do-7i1.16 | Yield uniqueness is per-cell not per-frame | YES -- re-key yields on (frame_id, field_name) |
| do-7i1.17 | Claims are per-cell not per-frame | YES -- re-key cell_claims on frame_id |
| do-7i1.13 | Readiness check is cell-level, not frame-level | YES -- findReadyCell queries frames not cells |
| do-7i1.21 | Readiness queries cells.state instead of deriving from frame model | YES -- derive from yields per-frame |
| do-7i1.7 | Frame status derived from cells.state, not from yields | YES -- drop cells.state, compute from yields |
| do-7i1.3 | FrameStatus stored as mutable column, not derived | YES -- drop cells.state, compute from yields |
| do-7i1.8 | Dual claim mechanism: cell_claims AND cells.state/assigned_piston | YES -- single claims list keyed on frame_id |

---

### Group B: Mutable operations where append-only is required (5 bugs)

The Lean model proves cellsPreserved, yieldsPreserved, givensPreserved -- these
lists only grow. The Go code does DELETE+INSERT (yields), destroys frozen data
(respawn), and destructively resets programs (pour).

**Bugs in this group:**

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.1 | Yields are DELETE+INSERT (mutable), violating append-only | PARTIALLY -- frame-keyed yields eliminate the need to delete, but replSubmit must be rewritten to INSERT not DELETE+INSERT |
| do-7i1.27 | yieldUnique violated -- replSubmit DELETEs before INSERT | DUPLICATE of do-7i1.1 -- same fix |
| do-7i1.40 | Claims.lean freezeStep rejects duplicates but Go allows overwrite | PARTIALLY -- frame-keyed yields make duplicates structurally impossible per-frame, but replSubmit logic still needs guard |
| do-7i1.2 | Stem respawn DELETES frozen cells/yields/givens | YES -- with frame model, respawn creates a new frame (gen N+1) instead of deleting the frozen cell |
| do-7i1.32 | Stem cell respawn violates cells immutability | DUPLICATE of do-7i1.2 -- same fix |
| do-7i1.15 | Pour auto-reset destroys existing program data | NO -- resetProgram is a UX feature not covered by the formal model; needs explicit versioning or conflict detection |

---

### Group C: Bindings not atomic with freeze (3 bugs)

The Lean model's FreezeData includes both yields AND bindings as an atomic
bundle. The Go code records bindings AFTER the freeze, as a best-effort
afterthought.

**Bugs in this group:**

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.6 | Bindings recorded AFTER freeze, not atomically WITH freeze | NO -- requires restructuring replSubmit to write yields+bindings in one transaction |
| do-7i1.11 | Bindings recorded ad-hoc at freeze time | DUPLICATE of do-7i1.6 -- same fix |
| do-7i1.33 | Bindings recorded AFTER freeze, not atomically WITH freeze | DUPLICATE of do-7i1.6 -- same fix |

---

### Group D: Missing formal invariant enforcement (3 bugs)

The Lean model proves invariants (noSelfLoops, generationOrdered,
bindingsPointToFrozen) that the Go code never checks.

**Bugs in this group:**

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.9 | No generationOrdered or bindingsPointToFrozen enforcement | PARTIALLY -- frame migration gives us frame IDs to compare, but the CHECK must be added explicitly |
| do-7i1.14 | No self-loop check on bindings (noSelfLoops) | NO -- needs explicit guard in recordBindings: `WHERE producer_frame != consumer_frame` |
| do-7i1.34 | No noSelfLoops enforcement in recordBindings | DUPLICATE of do-7i1.14 -- same fix |

---

### Group E: Missing formal operations (2 bugs)

The Lean model defines release and createFrame as first-class operations.
The Go code has ad-hoc cleanup and hard-coded respawn.

**Bugs in this group:**

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.12 | No explicit release operation matching formal RetortOp.release | NO -- needs a replRelease function that removes claims and logs to claim_log |
| do-7i1.28 | No release operation -- stale claims accumulate | DUPLICATE of do-7i1.12 -- same fix |
| do-7i1.10 | createFrame restricted to cell-zero-eval | NO -- remove hard-coded `progID == "cell-zero-eval"` check in replRespawnStem |

---

### Group F: Formal model gap (bottom state) (1 bug)

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.4 | bottom state exists in Go but missing from formal model | NO -- either add bottom to Lean FrameStatus or replace with a frame-level skip mechanism |

---

### Group G: Oracle checking not atomic with freeze (1 bug)

| ID | Title | Auto-fixed by frame migration? |
|----|-------|-------------------------------|
| do-7i1.24 | Oracle verdict not checked at freeze time | NO -- semantic oracles via judge cells evaluate AFTER the original cell freezes; needs architectural decision on blocking vs async oracles |

---

## Per-Bug Detail

### do-7i1.1 -- Yields are DELETE+INSERT (mutable)

1. **Root cause:** `replSubmit` (eval.go:907) does `DELETE FROM yields WHERE cell_id=? AND field_name=?` before `INSERT`, making yields mutable instead of append-only.
2. **Fix:** In `eval.go`, function `replSubmit` -- replace the DELETE+INSERT with a single `INSERT` keyed on `(frame_id, field_name)`. With frame-keyed yields, each generation gets its own yield row; no deletion needed. Add a `UNIQUE(frame_id, field_name)` constraint in `retort-init.sql` and use `INSERT ... ON DUPLICATE KEY` as a safety net that logs a warning (should never fire).
3. **Validation:** `SELECT COUNT(*) FROM yields WHERE cell_id = ? GROUP BY field_name HAVING COUNT(*) > 1` should return 0 rows for any cell. Grep for `DELETE FROM yields` -- should have zero hits in eval.go.
4. **Delegatable?** Yes, once the frame migration schema is in place.

### do-7i1.2 -- Stem respawn DELETES frozen data

1. **Root cause:** `replRespawnStem` (eval.go:1169-1173) deletes oracles, givens, yields, and the cell row when respawning a stem cell, destroying append-only data.
2. **Fix:** In `eval.go`, function `replRespawnStem` -- instead of deleting the frozen cell, leave it in place and create a new frame (gen N+1) for the same cell_name. The cell definition (body, givens, oracles) stays on the cells row; only a new frame is created. Requires the frame-keyed yield model from Group A.
3. **Validation:** After a stem respawn, `SELECT * FROM cells WHERE id = '<frozen_id>'` should still return the frozen cell. `SELECT COUNT(*) FROM frames WHERE cell_name = ? AND program_id = ?` should show generation count increasing.
4. **Delegatable?** No -- architectural; requires the frame migration to land first.

### do-7i1.3 -- FrameStatus stored as mutable column

1. **Root cause:** `cells.state` is a mutable `VARCHAR(16)` column that is directly `UPDATE`d throughout eval.go, instead of being derived from yields as the formal model specifies.
2. **Fix:** In `retort-init.sql`, drop the `state` column from `cells`. Create a `cell_status` view that derives status from yields: if all yield fields for the latest frame are frozen, status=frozen; if a claim exists, status=computing; else status=declared. Update all queries in eval.go that read `cells.state` to use the view or inline the derivation.
3. **Validation:** Grep for `cells.state` and `c.state` in eval.go -- should have zero hits. Grep for `UPDATE cells SET state` -- should have zero hits.
4. **Delegatable?** No -- touches every query in the eval loop.

### do-7i1.4 -- bottom state missing from formal model

1. **Root cause:** `checkGuardSkip` (eval.go:1123) sets `cells.state='bottom'` and `yields.is_bottom=TRUE`, but the Lean `FrameStatus` only has declared/computing/frozen.
2. **Fix:** Two options: (a) Add `bottom` to `FrameStatus` in `formal/Retort.lean` with a proof that bottom frames are monotone-safe, or (b) replace the Go bottom mechanism with a frame-level skip: instead of mutating state, mark the frame as skipped in the frames table (add a `skipped BOOLEAN` column) and exclude skipped frames from readiness checks.
3. **Validation:** If option (a): `lean_loogle` for `FrameStatus.bottom`. If option (b): grep for `state = 'bottom'` in eval.go -- should have zero hits; grep for `is_bottom` in retort-init.sql -- should be removed from yields.
4. **Delegatable?** No -- requires design decision.

### do-7i1.5 -- cell_id vs frame_id data model

1. **Root cause:** The Go schema keys yields, givens, claims, and bindings on `cell_id`, while the Lean model keys everything on `FrameId`. Stem cell generations share a single yield namespace.
2. **Fix:** In `retort-init.sql`: add `frame_id VARCHAR(64)` FK to `yields`, `cell_claims` (or replace with frame-level claims). Re-key the yields UNIQUE index from `(cell_id, field_name)` to `(frame_id, field_name)`. In `eval.go`: all yield INSERT/UPDATE/SELECT must include frame_id. `findReadyCell` must check frame-level readiness. `recordBindings` must use frame_id for resolution.
3. **Validation:** `SHOW CREATE TABLE yields` should show `UNIQUE(frame_id, field_name)`. Grep for `cell_id` in yield-related queries in eval.go -- should all have a corresponding frame_id join or filter.
4. **Delegatable?** No -- this is the core migration; all other Group A bugs depend on it.

### do-7i1.6 -- Bindings not atomic with freeze

1. **Root cause:** `recordBindings()` (eval.go:1032) is called AFTER `cells.state='frozen'` and `cell_claims.delete`, creating a window where the cell is frozen but has no bindings.
2. **Fix:** In `eval.go`, function `replSubmit` -- move the `recordBindings` call into the same transaction as the yield freeze. Specifically: after `UPDATE yields SET is_frozen=TRUE` and before `DOLT_COMMIT`, call `recordBindings`. Better: wrap yields+bindings+claim-delete in a single stored procedure that does all three atomically.
3. **Validation:** After any freeze, `SELECT COUNT(*) FROM bindings WHERE consumer_frame = ?` should equal the number of givens for that cell (for non-hard cells with givens). The `ct graph` command should never need to fall back to givens.
4. **Delegatable?** Yes, once the transaction boundaries are clear.

### do-7i1.7 -- Frame status derived from cells.state, not yields

1. **Root cause:** The eval loop reads `cells.state` as source of truth instead of deriving status from yields per-frame, as the Lean `frameStatus` function specifies.
2. **Fix:** Same as do-7i1.3. Drop `cells.state`, create a view or inline derivation.
3. **Validation:** Same as do-7i1.3.
4. **Delegatable?** No -- same fix as do-7i1.3 (duplicate root cause).

### do-7i1.8 -- Dual claim mechanism

1. **Root cause:** Claims are tracked in both `cell_claims` table (INSERT IGNORE for atomicity) and `cells.state='computing'` + `cells.assigned_piston`, creating consistency risks.
2. **Fix:** In `retort-init.sql` and `eval.go`: eliminate `cells.state`, `cells.assigned_piston`, `cells.computing_since`. Use only the `cell_claims` table (re-keyed on frame_id) as the single source of truth. Derive "is computing" from the existence of a claim row.
3. **Validation:** Grep for `assigned_piston` and `computing_since` in eval.go -- should have zero hits. `SHOW CREATE TABLE cells` should not have these columns.
4. **Delegatable?** Yes, once do-7i1.5 (frame migration) and do-7i1.3 (drop state) are done.

### do-7i1.9 -- No generationOrdered or bindingsPointToFrozen enforcement

1. **Root cause:** `recordBindings` (eval.go:286-329) finds the "latest frozen frame" for a source cell but does not verify that `producer.generation < consumer.generation` or that the producer frame is actually frozen.
2. **Fix:** In `eval.go`, function `recordBindings` -- add two guards: (1) after finding producerFrame, query its generation and compare with consumer frame's generation; skip if producer >= consumer. (2) The existing query already filters `y.is_frozen = 1`, so bindingsPointToFrozen is partially enforced; add an explicit `AND f.id IN (SELECT frame_id FROM ... WHERE status = 'frozen')` check once frame status is derived.
3. **Validation:** `SELECT b.* FROM bindings b JOIN frames fc ON fc.id = b.consumer_frame JOIN frames fp ON fp.id = b.producer_frame WHERE fp.generation >= fc.generation` should return 0 rows.
4. **Delegatable?** Yes -- mechanical guard addition in recordBindings.

### do-7i1.10 -- createFrame restricted to cell-zero-eval

1. **Root cause:** `replSubmit` (eval.go:1049) only respawns stem cells when `progID == "cell-zero-eval"`, hard-coding frame creation to one program.
2. **Fix:** In `eval.go`, line 1049 -- remove the `progID == "cell-zero-eval"` condition. Change to `if bodyType == "stem"` (already checked). This makes stem cell respawn work for any program.
3. **Validation:** Pour a test program with a stem cell (not cell-zero-eval), freeze it, and verify a new frame (gen 1) is created. `SELECT * FROM frames WHERE cell_name = '<stem>' ORDER BY generation` should show gen 0 and gen 1.
4. **Delegatable?** Yes -- single line change.

### do-7i1.11 -- Bindings recorded ad-hoc at freeze time (duplicate of do-7i1.6)

1. **Root cause:** Same as do-7i1.6 -- bindings are written after freeze, not atomically with it.
2. **Fix:** Same as do-7i1.6.
3. **Validation:** Same as do-7i1.6.
4. **Delegatable?** Yes.

### do-7i1.12 -- No explicit release operation

1. **Root cause:** The Lean model defines `RetortOp.release` as a first-class operation. The Go code only has ad-hoc cleanup in defer blocks (eval.go:470-471, 603-605) that delete claims and reset state.
2. **Fix:** In `eval.go`, add a `replRelease(db, progID, cellName, pistonID)` function that: (1) deletes the claim from cell_claims, (2) logs a "released" entry to claim_log, (3) does NOT modify cells.state (since state should be derived). Wire this into the interrupt handler and the `cell_reap_stale` stored procedure.
3. **Validation:** After a piston interrupt, `SELECT * FROM claim_log WHERE action = 'released' AND frame_id = ?` should have a row. `SELECT * FROM cell_claims WHERE cell_id = ?` should be empty.
4. **Delegatable?** Yes -- isolated function.

### do-7i1.13 -- Readiness check is cell-level, not frame-level

1. **Root cause:** `findReadyCell` (eval.go:141-153) checks `cells.state='declared'` and resolves givens by cell name, not frame ID. A stem cell's gen-1 might appear ready based on gen-0's yields.
2. **Fix:** In `eval.go`, function `findReadyCell` -- rewrite the query to join through frames: find frames whose generation has no claim and whose givens are all satisfied by frozen yields from specific producer frames (not just any frozen yield for the source cell name).
3. **Validation:** With a stem cell that has gen-0 frozen and gen-1 declared, gen-1 readiness should be checked against gen-0's yields specifically (via bindings), not against the cell-level yield.
4. **Delegatable?** No -- requires the frame migration to be in place.

### do-7i1.14 -- No self-loop check on bindings

1. **Root cause:** `recordBindings` (eval.go:286-329) has no check that `producerFrame != consumerFrame`.
2. **Fix:** In `eval.go`, function `recordBindings`, after line 319 (where producerFrame is found) -- add: `if producerFrame == consumerFrame { continue }`. Optionally also add a CHECK constraint in `retort-init.sql`: `CHECK (consumer_frame != producer_frame)` on the bindings table.
3. **Validation:** `SELECT * FROM bindings WHERE consumer_frame = producer_frame` should return 0 rows. Grep for `consumerFrame` in recordBindings -- should see the guard.
4. **Delegatable?** Yes -- single guard addition.

### do-7i1.15 -- Pour auto-reset destroys existing program data

1. **Root cause:** `cmdPour` (pour.go:22-27) calls `resetProgram()` which DELETEs all cells, yields, givens, oracles, frames, and bindings for the program, violating cellsPreserved.
2. **Fix:** In `pour.go`, function `cmdPour` -- instead of auto-reset, implement versioned pour: create a new program_id (e.g., `<name>-v2`) or use Dolt branching. If the user explicitly wants to reset, require `ct reset <program>` as a separate command (which already exists). Remove the auto-reset from cmdPour. Add a conflict check: if cells with conflicting names exist, error with guidance to run `ct reset` first.
3. **Validation:** Pour the same program twice without `ct reset` -- should error with "program already exists" instead of silently destroying data.
4. **Delegatable?** Yes -- isolated to pour.go.

### do-7i1.16 -- Yield uniqueness per-cell not per-frame

1. **Root cause:** The yields table UNIQUE index is `(cell_id, field_name)` instead of `(frame_id, field_name)`. Stem cell generations overwrite each other's yields.
2. **Fix:** Same as do-7i1.5 -- re-key yields on (frame_id, field_name).
3. **Validation:** Same as do-7i1.5.
4. **Delegatable?** No -- part of the core frame migration.

### do-7i1.17 -- Claims per-cell not per-frame

1. **Root cause:** `cell_claims` has `PRIMARY KEY (cell_id)`, preventing concurrent claims on different generations of the same stem cell.
2. **Fix:** Same as do-7i1.5 -- re-key cell_claims on frame_id. `PRIMARY KEY (frame_id)` instead of `PRIMARY KEY (cell_id)`.
3. **Validation:** Same as do-7i1.5.
4. **Delegatable?** No -- part of the core frame migration.

### do-7i1.21 -- Readiness queries cells.state instead of deriving

1. **Root cause:** `findReadyCell` and `ready_cells` view both read `c.state = 'declared'` from the stored column instead of deriving status from yields.
2. **Fix:** Same as do-7i1.3 and do-7i1.7 -- derive status from yields/claims.
3. **Validation:** Same as do-7i1.3.
4. **Delegatable?** No -- same fix as do-7i1.3.

### do-7i1.24 -- Oracle verdict not checked at freeze time

1. **Root cause:** Semantic oracles via judge cells evaluate AFTER the original cell freezes, so a frozen frame may have failing oracles. The formal model assumes frozen implies oraclePass.
2. **Fix:** Two options: (a) Make semantic oracles blocking -- the cell cannot freeze until judge cells have evaluated and produced a passing verdict. This requires the eval loop to create judge cells before freezing, wait for them, and only then freeze the original cell. (b) Accept async oracles as a valid extension and update the Lean model to allow `oraclePass = None` (pending) as a valid state. Option (a) is more correct but may create deadlocks if judge cells depend on the original cell's yields.
3. **Validation:** If option (a): after a freeze, `SELECT * FROM oracles o JOIN cells c ON c.id = o.cell_id WHERE c.state = 'frozen' AND o.oracle_type = 'semantic'` -- for each, verify a corresponding judge cell exists and is frozen with verdict=YES.
4. **Delegatable?** No -- requires architectural decision.

### do-7i1.27 -- yieldUnique violated (duplicate of do-7i1.1)

1. **Root cause:** Same as do-7i1.1 -- replSubmit DELETEs before INSERT.
2. **Fix:** Same as do-7i1.1.
3. **Validation:** Same as do-7i1.1.
4. **Delegatable?** Yes.

### do-7i1.28 -- No release operation (duplicate of do-7i1.12)

1. **Root cause:** Same as do-7i1.12 -- no structured release path.
2. **Fix:** Same as do-7i1.12.
3. **Validation:** Same as do-7i1.12.
4. **Delegatable?** Yes.

### do-7i1.32 -- Stem respawn violates cells immutability (duplicate of do-7i1.2)

1. **Root cause:** Same as do-7i1.2 -- replRespawnStem deletes frozen cell data.
2. **Fix:** Same as do-7i1.2.
3. **Validation:** Same as do-7i1.2.
4. **Delegatable?** No.

### do-7i1.33 -- Bindings not atomic with freeze (duplicate of do-7i1.6)

1. **Root cause:** Same as do-7i1.6.
2. **Fix:** Same as do-7i1.6.
3. **Validation:** Same as do-7i1.6.
4. **Delegatable?** Yes.

### do-7i1.34 -- No noSelfLoops enforcement (duplicate of do-7i1.14)

1. **Root cause:** Same as do-7i1.14.
2. **Fix:** Same as do-7i1.14.
3. **Validation:** Same as do-7i1.14.
4. **Delegatable?** Yes.

### do-7i1.40 -- freezeStep rejects duplicates but Go allows overwrite

1. **Root cause:** The Lean `freezeStep` rejects a yield if one already exists for that (frameId, field). The Go `replSubmit` deletes the existing yield and inserts a new one, allowing unlimited overwrites.
2. **Fix:** In `eval.go`, function `replSubmit` -- remove the DELETE on line 907. Change the INSERT to `INSERT IGNORE` or check for existing frozen yield first: `SELECT COUNT(*) FROM yields WHERE frame_id = ? AND field_name = ? AND is_frozen = 1` -- if > 0, return error "yield already frozen". This makes yields truly write-once.
3. **Validation:** Attempt to submit a yield twice for the same cell/field -- should get an error on the second attempt. Grep for `DELETE FROM yields` in eval.go -- should have zero hits.
4. **Delegatable?** Yes -- mechanical change in replSubmit.

---

## Summary: What the frame migration fixes automatically

The frame migration (do-7i1.5) -- re-keying yields, claims, and bindings on
frame_id instead of cell_id -- automatically resolves or enables resolution of
**13 of 25 bugs** (the entire Group A plus most of Group B):

| Auto-fixed | Bug IDs |
|------------|---------|
| YES (13) | do-7i1.5, .16, .17, .13, .21, .7, .3, .8, .2, .32, .1, .27, .40 |
| NO (12) | do-7i1.6, .11, .33, .9, .14, .34, .12, .28, .10, .4, .15, .24 |

## Deduplication

9 bugs are exact duplicates of others (same root cause, same fix):

| Duplicate | Primary |
|-----------|---------|
| do-7i1.27 | do-7i1.1 |
| do-7i1.32 | do-7i1.2 |
| do-7i1.7 | do-7i1.3 |
| do-7i1.21 | do-7i1.3 |
| do-7i1.8 | do-7i1.3 + do-7i1.17 |
| do-7i1.11 | do-7i1.6 |
| do-7i1.33 | do-7i1.6 |
| do-7i1.28 | do-7i1.12 |
| do-7i1.34 | do-7i1.14 |

After dedup, there are **16 distinct bugs** with **16 distinct fixes**.

## Recommended fix order

1. **do-7i1.5** (frame migration) -- unblocks 12 other bugs
2. **do-7i1.3** (drop cells.state, derive from yields) -- unblocks do-7i1.7, .21, .8
3. **do-7i1.1** (yield append-only) -- unblocks do-7i1.27, .40
4. **do-7i1.2** (respawn without delete) -- unblocks do-7i1.32
5. **do-7i1.6** (atomic bindings) -- unblocks do-7i1.11, .33
6. **do-7i1.14** (noSelfLoops guard) -- delegatable, mechanical
7. **do-7i1.9** (generationOrdered guard) -- delegatable after frame migration
8. **do-7i1.12** (replRelease function) -- delegatable, isolated
9. **do-7i1.10** (remove cell-zero-eval hard-code) -- delegatable, one line
10. **do-7i1.15** (pour conflict detection) -- delegatable, isolated to pour.go
11. **do-7i1.4** (bottom state) -- design decision needed
12. **do-7i1.24** (oracle atomicity) -- design decision needed

## Delegatable summary

| Delegatable? | Count | Bug IDs |
|-------------|-------|---------|
| Yes (mechanical/isolated) | 11 | do-7i1.1, .27, .40, .6, .11, .33, .9, .14, .34, .10, .12, .28, .15 |
| No (architectural) | 14 | do-7i1.5, .16, .17, .13, .21, .7, .3, .8, .2, .32, .4, .24 |

# NonReplayable Isolation Without Dolt Branches

**Bead**: dc-4ry
**Date**: 2026-03-20
**Author**: Alchemist (dolt-cell)
**Status**: Proposal — needs sussmind review for formal properties

## The Problem

NonReplayable cells mutate state: they INSERT data (Spawn), execute DML
(SQLExec), or call external APIs (ExtIO). Currently, Dolt provides two
isolation mechanisms:

1. **Transaction mode** (~1ms): `BEGIN → mutate → COMMIT/ROLLBACK`.
   For cells whose effects are confined to the retort (Spawn, SQLExec).
2. **Branch mode** (~500ms): Create a Dolt branch per piston, mutate on
   branch, merge on success, drop on failure. For cells with external
   effects (ExtIO).

With a log-structured store, there are no SQL transactions and no
branches. What's the isolation story?

## Key Insight from the Formal Model

EffectEval.lean proves cascade-thaw correctness. But **cascade-thaw
doesn't undo effects** — it creates new frames at higher generations.
The old effects remain in the log as dead events. The question isn't
"how do we undo?" but "how do we prevent partial effects from being
visible to other cells before the NonReplayable cell completes?"

The formal model's answer is **scope confinement**: a NonReplayable
cell's mutations are invisible until it successfully freezes.

## Proposal: Staged Log with Commit Barrier

### Architecture

```
Global Log (visible to all)
    │
    ├── POUR events
    ├── CLAIM events
    ├── SUBMIT events (frozen yields)
    ├── FAIL events
    └── THAW events

Pending Log (per-piston, invisible to others)
    │
    ├── Tentative SUBMIT for NonReplayable cell
    ├── Tentative SPAWN events (new cells)
    └── Tentative EFFECT records (for audit)
```

### How It Works

**For Spawn/Internal Mutations (was Transaction mode):**

1. Piston claims a NonReplayable cell.
2. Piston evaluates in a "pending" context — writes go to a per-piston
   pending log, not the global log.
3. On success: atomic **commit** — all pending events are appended to
   the global log as a single batch (one fsync). Other cells instantly
   see the new yields/spawned cells.
4. On failure: **discard** — pending log is dropped. Nothing was written
   to the global log. No cascade-thaw needed.

This is equivalent to `BEGIN/COMMIT/ROLLBACK` but at the log level.
The pending log is just a buffer in memory. The commit is a single
atomic append.

```go
func (s *Store) SubmitNonReplayable(frameID FrameID, yields map[string]Value, spawned []CellDef) error {
    s.mu.Lock()
    defer s.mu.Unlock()

    // Validate oracles (in memory, before any writes)
    if err := s.validateOracles(frameID, yields); err != nil {
        return err
    }

    // Build the batch: yields + spawned cells + release
    var batch []Event
    batch = append(batch, SubmitEvent{frameID, yields})
    for _, cell := range spawned {
        batch = append(batch, SpawnEvent{cell})
    }

    // Atomic append (single fsync)
    s.log.AppendBatch(batch)

    // Update in-memory state
    s.applyBatch(batch)
    return nil
}
```

**Key property**: The batch is all-or-nothing. Either all events land
in the global log, or none do. Partial writes are detected by CRC and
truncated on recovery.

**For ExtIO (was Branch mode):**

External effects (network calls, filesystem ops) cannot be buffered
or rolled back. The isolation story here is fundamentally different:

1. Piston claims the cell.
2. Piston executes external effect (API call, file write, etc.).
3. If the effect succeeds: commit yields to global log (same as above).
4. If the effect fails: **the external effect already happened.** We
   can't undo it.

This is the same situation as with Dolt branches — dropping a branch
doesn't undo the network call that was made on it. The branch only
isolated *retort-internal* state.

**Proposal for ExtIO**: Accept that external effects are not rollbackable.
The cell is responsible for making effects idempotent or compensatable.
The store's job is:

- Record what was attempted (in the pending log, committed on success).
- On failure, record the failure and what was attempted (for manual or
  automated compensation).
- Cascade-thaw creates a new generation — the compensation cell can
  check what the previous generation did and decide how to proceed.

```
cell send-notification
  given report.summary
  yield status
  ---
  effect: POST https://api.slack.com/... body=«report.summary»
  ---
  check status is not empty
```

On failure:
- Frame is bottomed at gen N.
- New frame created at gen N+1.
- Gen N+1 evaluation can check: "was gen N attempted? What happened?"
- The compensation logic lives in the cell body, not the store.

### Formal Properties Needed (for sussmind)

**P1: Batch atomicity** — A committed batch is either fully applied
or not applied at all (crash recovery truncates partial writes).

**P2: Invisible until commit** — No cell can observe yields from a
pending (uncommitted) NonReplayable evaluation.

**P3: Failure leaves no trace** — If a NonReplayable cell fails before
commit, the global log is unchanged (as if the evaluation never happened).

**P4: Cascade-thaw still correct** — Thaw of a committed NonReplayable
cell creates new generations for it and all dependents. The old committed
yields remain in the log (dead but auditable).

**P5: ExtIO compensation** — External effects are recorded. If thaw
occurs after commit, the new generation can access the record of what
the previous generation did.

### Comparison with Dolt Branches

| Property | Dolt Branch | Staged Log |
|----------|-------------|------------|
| Internal isolation | Full (COW branch) | Full (pending buffer) |
| External isolation | None (effects escape) | None (same) |
| Commit cost | ~500ms (merge) | ~1ms (batch append) |
| Failure cost | ~1ms (drop branch) | ~0 (discard buffer) |
| Audit trail | Branch history | Dead events in log |
| Implementation | Dolt-specific | Pure Go |

The staged log is strictly simpler and faster for internal isolation.
For external isolation, both approaches have the same fundamental
limitation: you can't un-send a network request.

### Open Question: Do We Need External Isolation At All?

Looking at the actual cell programs, no existing example uses ExtIO.
The formal model defines it, but no `.cell` file exercises it.

If ExtIO cells are rare and always idempotent (HTTP PUT, not POST),
the compensation approach is sufficient. If ExtIO cells are common and
non-idempotent, we need a saga/compensation pattern built into the
cell language.

**Recommendation**: Start with the staged log for internal isolation.
Defer ExtIO isolation to when we have actual ExtIO cell programs that
need it. The compensation pattern can be added later without changing
the store — it's a language-level concern, not a storage concern.

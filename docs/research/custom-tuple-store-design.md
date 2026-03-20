# Custom Tuple Store Design — From First Principles

**Bead**: dc-0db
**Date**: 2026-03-20
**Author**: Alchemist (dolt-cell)
**Status**: Draft

## The Question

What does the SIMPLEST possible tuple store for cell evaluation look like?

Cell evaluation needs exactly five operations — the Linda primitives:

| Op | Semantics | Mutates? |
|----|-----------|----------|
| **pour** | Append cell definitions (immutable after write) | Append-only |
| **claim** | Atomic mutex on a frame (linearizable, exactly-once) | CAS on lock |
| **submit** | Append yields (immutable after write), release claim | Append-only + lock release |
| **observe** | Read frozen yields matching a pattern | Read-only |
| **gather** | Bulk read across iterations | Read-only |

The current implementation uses Dolt (a versioned SQL database) for all of
this. But cells don't need SQL. They don't need versioned tables. They don't
need a server. They need a log, some indexes, and an atomic claim.

---

## Pass 1: DRAFT — Get the Shape Right

### Core Insight

There is exactly **one piece of mutable state** in the entire system: the
claim table. Everything else is append-only. This means the store is
fundamentally a **log** with one **lock map**.

### Data Structures

```
RetortStore {
    // The log — source of truth, on disk
    log: AppendOnlyFile

    // In-memory indexes — derived from log, rebuilt on startup
    cells:      map[CellID]*CellDef          // cell definitions
    frames:     map[FrameID]*Frame           // execution instances
    yields:     map[FrameID]map[Field]Value  // frozen yields
    givens:     map[CellID][]Given           // input dependencies
    bindings:   map[FrameID][]Binding        // resolved edges
    oracles:    map[CellID][]Oracle          // validation rules

    // The one mutable thing
    claims:     map[FrameID]*Claim           // active claims (in-memory)

    // Derived incrementally
    ready:      set[FrameID]                 // frames with all givens satisfied
}
```

### On-Disk Format

A single append-only file. Each entry is a length-prefixed, CRC32-checksummed
record:

```
[len:4][crc:4][type:1][payload:len-5]
```

Event types:

| Type | Payload | Effect |
|------|---------|--------|
| `POUR_CELL` | CellDef (name, body, body_type, model_hint) | Add to cells map |
| `POUR_GIVEN` | (cell_id, source_cell, source_field, optional?, guard?) | Add to givens map |
| `POUR_ORACLE` | (cell_id, oracle_type, assertion) | Add to oracles map |
| `CREATE_FRAME` | (frame_id, cell_name, program_id, generation) | Add to frames map |
| `CLAIM` | (frame_id, piston_id, timestamp) | Set claims[frame_id] |
| `RELEASE` | (frame_id, reason: timeout\|failure\|cancel) | Delete claims[frame_id] |
| `FREEZE_YIELD` | (frame_id, field_name, value_text, value_json) | Add to yields, update ready set |
| `BOTTOM` | (frame_id, reason: failure\|guard_skip) | Mark frame as bottom |
| `BIND` | (consumer_frame, producer_frame, field_name) | Add to bindings |
| `THAW` | (frame_id, new_generation) | Create new frame, bottom old |

### The Claim Mutex

Claims are the only contended resource. Multiple pistons may try to claim the
same ready frame simultaneously.

**Mechanism**: Go `sync.Mutex` protecting the claims map. The claim operation
is:

```go
func (s *RetortStore) Claim(frameID FrameID, pistonID PistonID) (bool, error) {
    s.mu.Lock()
    defer s.mu.Unlock()

    if _, held := s.claims[frameID]; held {
        return false, nil  // someone else got it
    }
    if !s.ready.Contains(frameID) {
        return false, nil  // not ready
    }

    // Write to log first (durability)
    s.log.Append(ClaimEvent{frameID, pistonID, time.Now()})

    // Then update in-memory state
    s.claims[frameID] = &Claim{PistonID: pistonID, At: time.Now()}
    s.ready.Remove(frameID)
    return true, nil
}
```

The mutex is per-store, not per-frame. This is fine because claim operations
are fast (one map lookup + one log append). The bottleneck is piston
evaluation, not claiming.

### The Ready Set

Instead of a SQL view that joins cells, givens, and yields on every query,
maintain the ready set incrementally:

```go
func (s *RetortStore) onYieldFrozen(frameID FrameID, field string) {
    // Find all frames that have a given pointing at this (cell, field)
    cellName := s.frames[frameID].CellName
    for _, consumer := range s.givenIndex[cellName][field] {
        if s.allGivensSatisfied(consumer) && !s.isClaimed(consumer) && !s.isBottom(consumer) {
            s.ready.Add(consumer)
        }
    }
}
```

This inverts the ready-cells computation: instead of scanning all cells to
find ready ones (O(n) per query), we push readiness updates when yields freeze
(O(dependents) per freeze). For a DAG with bounded fan-out, this is O(1)
amortized.

### The eval_step Loop

The current `cell_eval_step` stored procedure loops up to 50 times trying to
claim a ready cell. With the in-memory ready set, this simplifies to:

```go
func (s *RetortStore) EvalStep(pistonID PistonID) (*Frame, error) {
    s.mu.Lock()
    defer s.mu.Unlock()

    for frameID := range s.ready {
        // Try to claim it
        s.log.Append(ClaimEvent{frameID, pistonID, time.Now()})
        s.claims[frameID] = &Claim{PistonID: pistonID, At: time.Now()}
        s.ready.Remove(frameID)
        return s.frames[frameID], nil
    }
    return nil, ErrQuiescent
}
```

No retry loop. No race condition. The mutex serializes all claims. First
piston to enter the critical section gets the first ready frame.

### Go API Surface

```go
type RetortStore interface {
    // Pour — load a cell program
    Pour(program ProgramID, cells []CellDef) error

    // Claim — get a ready frame to evaluate
    Claim(pistonID PistonID) (*Frame, error)

    // Submit — freeze yields and release claim
    Submit(frameID FrameID, yields map[string]Value) error

    // Release — give up a claim without freezing
    Release(frameID FrameID, reason ReleaseReason) error

    // Observe — read frozen yields for a cell
    Observe(programID ProgramID, cellName string) (map[string]Value, error)

    // Gather — read all frozen yields across iterations of a stem cell
    Gather(programID ProgramID, cellName string) ([]map[string]Value, error)

    // Thaw — rewind a cell and its dependents to a new generation
    Thaw(frameID FrameID) error

    // Status — program state overview
    Status(programID ProgramID) (*ProgramStatus, error)
}
```

That's 8 methods. The current SQL schema has 10 tables, 6 stored procedures,
2 views, and a Dolt server. This is the reduction.

---

## Pass 2: CORRECTNESS — Is the Design Sound?

### Can it implement linearizable claims?

**Yes.** The Go mutex serializes all claim operations. The log records them
durably. On crash recovery, replay the log: any CLAIM without a matching
RELEASE or FREEZE_YIELD means the claim was held at crash time. The reaper
can release stale claims based on timestamps, exactly as the current SQL
reaper does.

**Stronger guarantee than SQL**: With Dolt, `INSERT IGNORE` provides
linearizability only within a single SQL connection. Two connections racing
require Dolt's internal row-level locking. Here, the Go mutex provides true
serialization — no race window at all.

### Is append-only really append-only?

**Almost.** The log file is strictly append-only. But:

- CLAIM/RELEASE events modify in-memory state (the claims map). This is fine —
  the claims map is ephemeral, reconstructed from the log on startup.
- THAW creates new frames and bottoms old ones. The old frames and yields
  remain in the log (they're just superseded by newer generations). Nothing
  is deleted from the log.

**Invariant**: Once a FREEZE_YIELD event is in the log, no subsequent event
can contradict it. The yield is frozen forever. (The thaw operation doesn't
delete yields — it creates *new* frames at a higher generation that will
produce *new* yields.)

### Crash recovery

On startup:

1. Open the log file.
2. Read all events sequentially, rebuilding in-memory state.
3. For any frame with a CLAIM event but no subsequent RELEASE/FREEZE_YIELD,
   check the timestamp. If older than the reaper TTL, emit a RELEASE event
   and release the claim. Otherwise, treat as a held claim (the piston may
   still be alive).
4. Rebuild the ready set from scratch (scan all frames, check all givens).
5. Ready to serve.

**Crash during append**: The CRC32 checksum detects partial writes. On
recovery, truncate the log at the last valid record. The partial event never
happened — the operation that wrote it will appear to have failed (which is
correct: it hadn't been acknowledged).

### DAG acyclicity

Validated at pour time. When `Pour()` is called, the cell definitions include
givens. The store builds the dependency graph and rejects cycles before writing
any events to the log. Same as current behavior, but in Go instead of SQL
constraints.

### Invariant mapping

| Formal Invariant | SQL Implementation | Log Implementation |
|-----------------|-------------------|-------------------|
| I1: Append-only frames/yields | INSERT only (convention) | Log is physically append-only |
| I5: DAG acyclicity | FK + validation at pour | Go validation at pour |
| I6: Claim mutex | UNIQUE(frame_id) + INSERT IGNORE | Go sync.Mutex |
| I7: Generation ordering | UNIQUE(program, cell, gen) | Map key constraint |
| I8: Yield immutability | Convention (never UPDATE) | Log-structural (no UPDATE event exists) |
| I9: Binding immutability | Convention (never UPDATE) | Log-structural (no UPDATE event exists) |

**Key insight**: Several invariants that are *conventions* in SQL (we agree
not to UPDATE/DELETE) become *structural* in the log store (the log format
literally cannot express those operations). This is a real correctness
improvement.

### Oracle validation ordering

The current SQL has a bug: `cell_submit()` writes yields, then checks oracles.
Failed oracles leave artifacts. In the log store, the fix is natural:

```go
func (s *RetortStore) Submit(frameID FrameID, yields map[string]Value) error {
    // 1. Validate oracles IN MEMORY first
    cell := s.cellForFrame(frameID)
    for _, oracle := range s.oracles[cell.ID] {
        if oracle.Type == PureCheck {
            if !oracle.Evaluate(yields) {
                return ErrOracleFailure{Oracle: oracle}
            }
        }
    }
    // 2. Only write to log if validation passes
    for field, value := range yields {
        s.log.Append(FreezeYieldEvent{frameID, field, value})
    }
    s.log.Append(ReleaseEvent{frameID, ReasonCompleted})
    // 3. Update in-memory state
    // ...
}
```

Validation before persistence. The log store makes this the natural path.

---

## Pass 3: CLARITY — Could Someone Implement This in a Weekend?

### What can we remove?

1. **Pistons table**: Not needed in the store. Piston registration is an
   orchestration concern, not a storage concern. The store just sees
   piston IDs as opaque strings in claim events.

2. **Trace table**: The log *is* the trace. Every event is a trace entry.
   No separate audit table needed.

3. **claim_log table**: Same — the log contains all claim/release/complete
   events. The audit trail is the log itself.

4. **cell_program_status view**: Derived by `Status()` method, scanning
   in-memory state. No materialized view needed.

5. **Separate oracles table in memory**: Oracles can be stored inline in
   the CellDef. They're always accessed together.

### Simplified data structures

```
RetortStore {
    log:     AppendOnlyFile
    mu:      sync.Mutex

    // Core state (rebuilt from log)
    programs: map[ProgramID]*Program

    // Per-program state
    Program {
        cells:    map[string]*CellDef      // name -> definition
        frames:   map[FrameID]*Frame       // all frames
        yields:   map[FrameID]map[string]Value
        claims:   map[FrameID]PistonID     // active claims
        ready:    set[FrameID]             // ready to claim

        // Reverse index: (cellName, field) -> []FrameID waiting on it
        waitingOn: map[string]map[string][]FrameID
    }
}
```

This nests state under programs, which is cleaner: programs are the unit of
isolation (one program's cells can't reference another's, except via
cross-program givens which are a future extension).

### File layout

```
retort/
  store.go          // RetortStore implementation (~300 lines)
  log.go            // AppendOnlyFile with CRC32 framing (~100 lines)
  events.go         // Event type definitions (~80 lines)
  recovery.go       // Log replay and crash recovery (~100 lines)
  ready.go          // Incremental ready-set maintenance (~80 lines)
  store_test.go     // Tests (~200 lines)
```

**Total**: ~660 lines of Go + 200 lines of tests. One package. No
dependencies beyond the standard library.

### The minimal API, refined

```go
// Open or create a retort store backed by a log file.
func Open(path string) (*Store, error)

// Pour loads a cell program into the store.
func (s *Store) Pour(id ProgramID, defs []CellDef) error

// Next claims the next ready frame for evaluation.
// Returns ErrQuiescent if nothing is ready, ErrComplete if program is done.
func (s *Store) Next(pistonID string) (*Frame, error)

// Submit freezes yields for a claimed frame.
func (s *Store) Submit(frameID FrameID, yields map[string]Value) error

// Fail releases a claim, marking the frame for retry or bottom.
func (s *Store) Fail(frameID FrameID, retry bool) error

// Observe reads the frozen yields of a cell (latest generation).
func (s *Store) Observe(prog ProgramID, cell string) (map[string]Value, bool)

// Gather reads frozen yields across all generations of a stem cell.
func (s *Store) Gather(prog ProgramID, cell string) []map[string]Value

// Thaw rewinds a cell and its transitive dependents.
func (s *Store) Thaw(frameID FrameID) error

// Status returns program state.
func (s *Store) Status(prog ProgramID) *ProgramStatus

// Close flushes the log and releases resources.
func (s *Store) Close() error
```

10 methods. `Open` and `Close` are lifecycle. The 8 in between are the
operations. A piston's entire interaction with the store is:

```go
for {
    frame, err := store.Next(myID)
    if err == ErrQuiescent { sleep; continue }
    if err == ErrComplete { break }

    result := evaluate(frame)  // LLM call, SQL, whatever

    if err := store.Submit(frame.ID, result); err != nil {
        store.Fail(frame.ID, true)  // retry
    }
}
```

That's the entire piston loop. Five lines.

---

## Pass 4: EDGE CASES

### Concurrent pistons racing to claim

**Scenario**: 10 pistons all call `Next()` simultaneously.

**Behavior**: The Go mutex serializes them. First piston gets the first ready
frame, second gets the second, etc. If there are fewer ready frames than
pistons, the rest get `ErrQuiescent`. No retries needed, no contention loop.

**Performance**: Mutex contention is negligible. The critical section is
~1us (one map lookup + one log append). Even at 100 pistons, total
serialization overhead is ~100us — invisible compared to LLM call latency
(seconds).

### Crash during submit

**Scenario**: Piston calls `Submit()`. Three yield events are appended to the
log. The process crashes before the release event is appended.

**On recovery**:
- The three yield events are in the log. They are valid (CRC32 checks pass).
- The frame has yields but no release event.
- The claim is still held (CLAIM event with no RELEASE).
- The store marks the frame as "claimed but potentially stale."
- The reaper TTL fires, releasing the claim.
- **Problem**: The frame now has partial yields from the crashed submit, and
  will be re-claimed for evaluation. The new piston will try to submit yields
  for fields that already have frozen values.

**Fix**: Make submit atomic in the log. Instead of N separate FREEZE_YIELD
events, write a single SUBMIT event that contains all yields:

```
SUBMIT { frame_id, yields: [(field, value), ...] }
```

On recovery, a SUBMIT event without fields means "submit started but wrote
nothing." A SUBMIT event with fields means "all yields frozen, claim released."
One event = atomic commit.

**Revised event types**:

| Type | Payload |
|------|---------|
| `POUR` | Full program definition (cells, givens, oracles, initial frames) |
| `CLAIM` | (frame_id, piston_id, timestamp) |
| `SUBMIT` | (frame_id, yields: [(field, value), ...]) |
| `FAIL` | (frame_id, retry: bool) |
| `THAW` | (frame_id, new_gen, dependent_frame_ids) |

Down to **5 event types**. Pour is one event (the program is poured
atomically). Submit is one event (yields are frozen atomically). Thaw is one
event (cascade is atomic).

### Disk full during pour

**Scenario**: `Pour()` tries to append a POUR event but the disk is full.

**Behavior**: `AppendOnlyFile.Append()` returns an IO error. `Pour()` returns
the error. No partial event in the log (the write was not fsync'd). The
in-memory state is unchanged (we only update in-memory state after successful
log append). The caller can retry after freeing disk space.

### Stale claims (piston death)

**Scenario**: A piston claims a frame and then its process is killed.

**Behavior**: The CLAIM event is in the log. The store has the claim
in-memory. But the piston will never submit or fail.

**Resolution**: Same as current system — a reaper goroutine:

```go
func (s *Store) reap(ttl time.Duration) {
    s.mu.Lock()
    defer s.mu.Unlock()
    now := time.Now()
    for frameID, claim := range s.claims {
        if now.Sub(claim.At) > ttl {
            s.log.Append(FailEvent{frameID, true})  // retry
            delete(s.claims, frameID)
            s.recalcReady(frameID)
        }
    }
}
```

### Concurrent thaw with overlapping dependents

**Scenario**: Two pistons fail on cells A and B, both of which depend on cell
C. Both try to thaw, which means cascading through C.

**Behavior**: Thaw takes the store mutex. First thaw runs: bottoms A + C,
creates new frames at gen+1. Second thaw runs: B is already at current gen
(not yet thawed), C is now at gen+1. Thaw bottoms B, and C is already at
a newer generation — skip it (idempotent).

**Key**: Because thaw is serialized by the mutex and creates new generations
monotonically, overlapping cascades compose correctly. The second thaw sees
the state left by the first.

### Log file grows unbounded

**Scenario**: Long-running retort accumulates thousands of events. Startup
replay takes too long.

**Resolution**: Periodic checkpointing. Snapshot the in-memory state to a
separate file. On startup, load the snapshot, then replay only events after
the snapshot. The snapshot is a consistent point-in-time image.

```
retort/
  data/
    log.bin             // append-only event log
    snapshot.bin        // latest checkpoint
    snapshot.offset     // byte offset in log.bin where snapshot was taken
```

Recovery: load snapshot, seek to snapshot.offset in log, replay remaining
events. Checkpointing can run in the background with a read lock (COW
snapshot or serialize under mutex — the mutex is held briefly).

### Program isolation

**Question**: Can one program's cells reference another program's yields?

**Current answer**: No. Programs are isolated. Cross-program givens are a
future extension. The store enforces this: `Pour()` validates that all givens
reference cells within the same program.

**Future extension point**: Add an `IMPORT` event that creates a read-only
binding from one program's yields to another's givens. This is straightforward
to add later without changing the core store.

---

## Pass 5: EXCELLENCE — Is This Actually Simpler?

### Complexity comparison

| Dimension | Dolt | SQLite | Log Store |
|-----------|------|--------|-----------|
| **Runtime dependency** | Dolt server (separate process) | CGo (libsqlite3) | None (pure Go) |
| **Schema** | 10 tables, 2 views, 6 procedures | 10 tables, 2 views | 0 tables |
| **Lines of SQL** | ~400 | ~300 | 0 |
| **Lines of Go** | ~200 (client) | ~200 (client) | ~660 (store) |
| **Total system lines** | ~600 + Dolt | ~500 | ~660 |
| **Claim mechanism** | INSERT IGNORE + UNIQUE | INSERT OR IGNORE + UNIQUE | sync.Mutex |
| **Ready-cells** | SQL view (O(n) join per query) | SQL view (O(n) join per query) | Incremental set (O(1) amortized) |
| **Crash recovery** | Dolt handles it | SQLite WAL | Log replay + checkpoint |
| **Invariant enforcement** | Convention (don't UPDATE/DELETE) | Convention | Structural (log format) |
| **Distribution** | Dolt push/pull (built-in) | None | None (future: log shipping) |
| **Ad-hoc queries** | Full SQL | Full SQL | None (need tooling) |
| **Time travel** | Dolt AS OF (built-in) | None | Log replay to any offset |

### What we gain

1. **Zero runtime dependencies.** No Dolt server to start, no CGo to compile.
   Pure Go. `go build` and done.

2. **Structural invariants.** The log format cannot express UPDATE or DELETE.
   Yield immutability and append-only semantics are enforced by the data
   structure, not by convention. This is a real correctness improvement that
   the Lean proofs can leverage.

3. **O(1) ready-cell lookup.** The incremental ready set eliminates the
   ready_cells view join. For programs with thousands of cells, this is a
   significant performance improvement.

4. **Simpler claim semantics.** A Go mutex is simpler and more correct than
   INSERT IGNORE racing through a SQL connection pool. No edge cases around
   connection-level vs. row-level locking.

5. **Natural oracle ordering.** Validate before write is the obvious path
   when you control the write path. The SQL bug (write-then-validate) simply
   can't happen.

6. **The log IS the trace.** No separate audit table. Every operation is
   recorded in order. `ct watch` can tail the log file.

### What we lose

1. **SQL queries for debugging.** Can't `SELECT * FROM cells WHERE state='computing'`.
   Need purpose-built tooling (`ct status`, `ct yields`, `ct watch`).
   **Mitigation**: The `ct` commands already exist and most operators use them,
   not raw SQL.

2. **Distribution.** Dolt's push/pull is free. Without it, we need to build
   log shipping or another replication mechanism.
   **Mitigation**: Distribution is a future concern. The log format is
   designed for shipping (append-only, self-describing events, CRC32 integrity
   checks). When we need it, the foundation is there.

3. **Time travel for debugging.** Dolt's `AS OF` lets you inspect any
   historical state.
   **Mitigation**: The log can be replayed to any offset. Build a `ct replay`
   command that reconstructs state at a given event number. This is actually
   more flexible than `AS OF` (which is timestamp-based).

4. **Existing ecosystem.** Dolt has a SQL client ecosystem, web UI, etc.
   **Mitigation**: We're building a domain-specific store for a domain-specific
   language. General-purpose tooling is nice but not necessary.

### The verdict

**The log store is simpler.** ~660 lines of self-contained Go with zero
dependencies. The invariants are structural rather than conventional. The
performance characteristics are better (O(1) ready-set vs O(n) join). The
claim mechanism is simpler and provably correct.

The trade-off is clear: we give up SQL queryability and Dolt distribution
in exchange for a smaller, faster, more correct store that does exactly
what cell evaluation needs and nothing more.

**Is building this actually simpler than using an existing store?** Yes.
The existing store (Dolt) requires a running server, SQL schema management,
stored procedures, and careful conventions to maintain invariants. The log
store is a single Go package with 10 methods and 5 event types.

### Recommendation

Build the log store as `pkg/retort` in the dolt-cell repo. Keep Dolt as the
beads data plane (issues, mail, work history) — it's good at that. But for
cell evaluation, the custom store is the right tool.

**Next steps:**
1. Prototype `pkg/retort` (~2-3 days for core + tests)
2. Wire into `ct` commands (~1 day)
3. Run existing cell programs against it (~1 day)
4. Formal verification: update Lean proofs to model log-structured store
5. If it works: migrate. If not: we learned where the floor is.

---

## Appendix A: Event Format (Binary)

```
┌─────────┬─────────┬──────┬─────────────────┐
│ len: u32│ crc: u32│ type │ payload: [u8]   │
│ (4 B)   │ (4 B)   │ (1 B)│ (len - 5 bytes) │
└─────────┴─────────┴──────┴─────────────────┘
```

- `len`: total payload length including type byte
- `crc`: CRC32 of type + payload (validates integrity)
- `type`: event discriminator (0x01=POUR, 0x02=CLAIM, 0x03=SUBMIT, 0x04=FAIL, 0x05=THAW)
- `payload`: MessagePack-encoded event data

### Event Payloads

```go
type PourEvent struct {
    ProgramID string
    Cells     []CellDef  // each includes givens, oracles, initial frame
}

type ClaimEvent struct {
    FrameID   string
    PistonID  string
    Timestamp time.Time
}

type SubmitEvent struct {
    FrameID string
    Yields  []struct {
        Field string
        Value string  // text representation
        JSON  []byte  // optional structured value
    }
}

type FailEvent struct {
    FrameID string
    Retry   bool
}

type ThawEvent struct {
    FrameID       string
    NewGeneration int
    Cascade       []string  // dependent frame IDs also thawed
}
```

## Appendix B: Ready-Set Maintenance

The ready set is the critical derived structure. Here's the complete
algorithm:

```
On POUR:
  For each cell with no non-optional givens:
    ready.Add(cell's initial frame)
  For each cell with givens:
    Check if all non-optional givens already have frozen yields
    If yes: ready.Add(cell's initial frame)

On SUBMIT (yields frozen):
  cell = frame's cell name
  For each (consumer_cell, field) that has a given pointing at cell:
    consumer_frame = latest non-bottom frame for consumer_cell
    If consumer_frame exists AND not claimed AND not bottom:
      If allGivensSatisfied(consumer_frame):
        ready.Add(consumer_frame)

On FAIL (retry=true):
  frame = the failed frame
  If allGivensSatisfied(frame) AND not bottom:
    ready.Add(frame)

On THAW:
  For each new frame created by thaw:
    If allGivensSatisfied(new_frame):
      ready.Add(new_frame)

On CLAIM:
  ready.Remove(claimed_frame)
```

The `allGivensSatisfied` check:
```
For each non-optional given of the frame's cell:
  source_cell = given.source_cell
  source_frame = latest frozen frame for source_cell
  If source_frame doesn't exist OR source_frame's yields don't include given.field:
    return false
return true
```

## Appendix C: Comparison with the Formal Model

The Lean proofs in `formal/` model the retort as a sequence of `RetortOp`
operations on a `Retort` state. The log store maps directly:

| Lean Concept | Log Store |
|-------------|-----------|
| `Retort` | In-memory state (programs, frames, yields, claims) |
| `RetortOp` | Log event |
| `valid_trace` | Well-formed log (CRC checks, type constraints) |
| `wellFormed` | In-memory invariants after replay |
| `Pour` op | POUR event |
| `Claim` op | CLAIM event |
| `Freeze` op | SUBMIT event |
| `Release` op | FAIL event |
| `Thaw` op | THAW event |

The log store is actually *closer* to the formal model than the SQL
implementation. The formal model is a sequence of operations on a state —
that's literally what the log is. The SQL implementation adds a layer of
indirection (tables, views, procedures) that the formal model doesn't have.

This means: any property proved about the formal model's operation sequence
transfers directly to the log store, with fewer mapping lemmas needed.

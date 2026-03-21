# dolt-cell Architecture

## Layer Model

The cell runtime is a **four-layer stack**. Each layer has a single
responsibility and communicates with adjacent layers through narrow
interfaces. Changes flow top-down (language → runtime → store → substrate).
Formal verification spans all layers but lives outside them.

```
┌─────────────────────────────────────────────────┐
│  L4  LANGUAGE        syntax, semantics, programs │
├─────────────────────────────────────────────────┤
│  L3  EVAL ENGINE     effect dispatch, oracles    │
├─────────────────────────────────────────────────┤
│  L2  RETORT STORE    tuple space operations      │
├─────────────────────────────────────────────────┤
│  L1  SUBSTRATE       Dolt (SQL, commits, repl)   │
└─────────────────────────────────────────────────┘

  FORMAL MODEL (Lean 4) — verification layer spanning L2–L4
```

## L4: Language Layer

**Owner**: alchemist (syntax design), sussmind (semantics)
**Artifacts**: `examples/*.cell`, parser (`cmd/ct/parse.go`), linter (`cmd/ct/lint.go`)

The cell language defines programs as DAGs of cells. Each cell declares
yields (outputs), givens (inputs from other cells), oracles (assertions),
and a body (the computation).

**Syntax constructs**:
- `cell NAME [(stem)]` — declaration with optional stem lifecycle
- `yield FIELD [= LITERAL] [annotation]` — output fields, annotations like `[autopour]`
- `given SOURCE.FIELD`, `given? SOURCE.FIELD`, `given SOURCE[*].FIELD`
- `recur until GUARD (max N)` — bounded iteration
- `iterate NAME N` — expansion into N numbered cells
- `check COND` / `check~ ASSERTION` — deterministic/semantic oracles
- `---` body delimiters, `sql:` / `literal:` prefixes for hard cells

**Parser**: Dual-mode. V2 (ASCII, deterministic) is primary. V1 (Unicode
turnstyle) is fallback. Both emit `[]parsedCell` → `cellsToSQL()`.

**Key invariant**: The parser is pure — no DB access, no side effects.
`ct lint` validates programs without a running retort.

## L3: Eval Engine Layer

**Owner**: glassblower
**Artifacts**: `cmd/ct/eval.go` (replEvalStep, replSubmit)

The eval engine implements the claim-evaluate-freeze cycle:

```
findReadyCell → claim (INSERT IGNORE mutex) → classify effect
  → Pure:           execute inline, freeze immediately
  → Replayable:     dispatch to piston, validate-before-write, retry on oracle fail
  → NonReplayable:  dispatch in transaction, atomic validate+freeze
```

**Effect lattice** (canonical, matches formal model):
```
Pure < Replayable < NonReplayable
```

**Key operations**:
- `replEvalStep()` — find next ready cell, claim it, handle hard cells inline
- `replSubmit()` — validate oracles, write yield, freeze when all yields done
- `replRespawnStem()` — demand-driven stem cell re-evaluation
- `bottomCell()` — error propagation through the DAG
- `checkGuardSkip()` — convergence guard for iteration cells

**Commands that use the eval engine**:
- `ct piston` — autonomous loop: claim → eval hard → dispatch soft → repeat
- `ct next` — claim one cell, print prompt for external piston
- `ct submit` — external piston submits a yield value

**Oracle ordering**: validate-before-write. Oracles are checked against the
submitted value BEFORE it is written. If validation fails, the tuple space
is unchanged. (Formal: EffectEval.lean vtw_preserves_yields)

## L2: Retort Store Layer

**Owner**: glassblower
**Artifacts**: `cmd/ct/db.go`, `cmd/ct/pour.go`, `schema/*.sql`

The retort is a tuple space with Linda-inspired operations:

| Operation | Linda | SQL primitive | Formal |
|-----------|-------|---------------|--------|
| Pour | out(program) | INSERT cells, givens, yields, frames | RetortOp.pour |
| Claim | in(ready) | INSERT IGNORE cell_claims | RetortOp.claim |
| Submit | out(yield) | UPDATE yields, freeze | RetortOp.freeze |
| Release | — | DELETE cell_claims | RetortOp.release |
| Observe | rd(cell) | SELECT yields WHERE frozen | observe |
| Gather | rd*(cell) | SELECT yields across generations | gather |
| Thaw | — | INSERT new frames for cell+deps | RetortOp.createFrame |
| Status | — | Derived from cell/yield state | frameStatus |

**Schema tables**:
- `cells` — immutable definitions (name, body_type, body, program_id)
- `frames` — append-only execution instances (cell_name, generation)
- `yields` — append-only output values (frame_id, field_name, value_text)
- `bindings` — append-only DAG edges (consumer_frame → producer_frame)
- `givens` — immutable dependency declarations
- `oracles` — immutable assertion declarations
- `cell_claims` — mutable mutex (the ONLY mutable state)
- `claim_log` — append-only audit trail
- `trace` — append-only event log

**Key invariant**: Everything is append-only except `cell_claims`. Yields
never change once frozen. Cells never change after pour. The claims table
is the only mutable state — it's a lock, not data.

**`ready_cells` view**: The heartbeat. A cell is ready when:
1. State = 'declared'
2. All non-optional givens have frozen yields
3. No existing claim

## L1: Substrate Layer

**Owner**: infrastructure (Dolt server)
**Artifacts**: Dolt database on port 3308

Dolt provides:
- **SQL engine**: MySQL-compatible queries
- **Commit history**: Every freeze/claim/pour is a Dolt commit
- **Branching** (future): Piston isolation via COW branches
- **Replication** (future): Distribution across Gas City towns
- **Time travel** (future): `AS OF` queries for thaw operations

**Current usage**: ~6% of Dolt capabilities (21 DOLT_COMMITs per
program, 240 SQL ops, zero branching/merge/time-travel). This is
intentional — the unused capabilities are the distribution roadmap.

## Formal Verification Layer

**Owner**: scribe (proofs), sussmind (design)
**Artifacts**: `formal/*.lean`

The formal model spans L2–L4 and proves safety properties:

| Property | File | Status |
|----------|------|--------|
| Claim mutual exclusion | Claims.lean | Proven |
| Yield immutability | Claims.lean | Proven |
| Effect lattice (join semilattice) | EffectEval.lean | Proven |
| Validate-before-write safety | EffectEval.lean | Proven |
| Replayable retry safety | EffectEval.lean | Proven |
| Bottom propagation correctness | Denotational.lean | Proven |
| Operational-denotational refinement | Refinement.lean | Proven |
| Autopour programs-as-values | Autopour.lean | Proven |
| Non-frozen monotonicity | EffectEval.lean | Sorry (library gap) |

**Effect taxonomy** (canonical):
```
Pure < Replayable < NonReplayable    (by recovery cost)
```

**Known formal divergences** (tracked for resolution):

| Divergence | Formal | Go | Status |
|-----------|--------|-----|--------|
| Effect taxonomy | Core.lean: pure/semantic/divergent | inferEffect: pure/replayable/nonreplayable | Pending unification — Core.lean EffectLevel is dead code, all files use EffectEval.EffLevel |
| classifyEffect granularity | EffectEval.lean: all hard→pure | inferEffect: literal→pure, sql SELECT→replayable, sql DML→nonreplayable | Go is operationally finer; formal model is correct but coarser |
| EvalAction constructors | 5 (execPure/dispatchReplayable/dispatchNonReplayable/quiescent/complete) | 4 constants (evaluated/dispatch/quiescent/complete) + effect field | Documented in evalStepResult comment |
| Release claim key | Retort.lean: filter by frameId | Go: DELETE by (cell_id, piston_id) | Equivalent under one-claim invariant; documented in replRelease |
| Bottom check | Denotational.lean: ys.all (·.isBottom) | Go: cells.state = 'bottom' | Equivalent; documented in hasBottomedDependency |

## Cross-Layer Contracts

### L4 → L3: Parser → Eval
- Parser emits `[]parsedCell` with classified body types (hard/soft/stem)
- `cellsToSQL()` generates INSERT statements consumed by L2
- Yield annotations (e.g. `[autopour]`) are preserved for L3 to act on

### L3 → L2: Eval → Store
- `replEvalStep` calls DB operations via `*sql.DB` (future: RetortStore interface)
- Effect classification determines dispatch path (inline vs piston vs transaction)
- Oracle validation happens in L3 BEFORE L2 writes

### L2 → L1: Store → Dolt
- All state changes go through SQL
- Every meaningful transition gets a DOLT_COMMIT
- Schema enforces structural invariants (UNIQUE constraints, NOT NULL)

### Formal → L2/L3/L4
- Lean types mirror Go types (CellName, FrameId, EffLevel)
- Proven properties are encoded as comments in Go code (e.g. "formal: claimMutex I6")
- Divergences are tracked and must be resolved

## Alignment Rules

When formal model and Go code diverge:

1. **Formal model is truth** for safety properties (mutex, immutability, ordering)
2. **Go code is truth** for operational details not modeled (SQL syntax, error messages)
3. **Spec documents** are truth for intent when both formal and code are silent
4. **Divergences must be filed** as beads and tracked to resolution

## Build and Verify

```bash
# Build
cd cmd/ct && go build -o ../../ct .

# Test
go test ./...                    # All tests
go test -run TestParseAllExamples  # Parser against all examples
go test -run TestE2E             # End-to-end with DB
go test -run TestConcurrency     # Multi-piston races

# Lint (no DB needed)
./ct lint examples/*.cell

# Formal verification
cd formal && lake build          # Build all Lean proofs
```

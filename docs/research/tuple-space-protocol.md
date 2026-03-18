# Tuple Space Protocol for the Cell Runtime

## 1. The Space

Let **S** be a Retort database state (Retort.lean `Retort`). Tuples in **S** are cells: structured records with a dependency DAG (givens to yields) and an effect classification.

```
Cell  ::= (name : CellName, body : Body, givens : [GivenSpec], yields : [FieldName])
Body  ::= hard(expr)          -- pure, deterministic
        | soft(prompt)        -- replayable LLM oracle
        | stem(prompt)        -- non-replayable, permanently soft
```

A cell is not a flat tuple. It is a *structured* tuple whose fields (yields) are typed by the dependency DAG: each yield slot is empty until frozen, and each given names a yield slot on another cell. The space **S** therefore carries invariant **I**: the givens form a DAG over cell names (Retort.lean `noSelfLoops`, `generationOrdered`).

## 2. Operations

### 2.1. Generative Communication

```
pour : PourData -> S -> S
pour(pd)(S) = S with { cells := S.cells ++ pd.cells,
                       givens := S.givens ++ pd.givens,
                       frames := S.frames ++ pd.frames }
```

Linda `out(tuple)`. Adds cells to the space. Append-only: `pour_appendOnly` proves `cellsPreserved /\ framesPreserved /\ yieldsPreserved`. Precondition `pourValid`: no name collisions within a program.

### 2.2. Destructive Read with Linear Token

```
claim : FrameId x PistonId -> S -> S x ClaimHandle
claim(fid, pid)(S) =
  require frameReady(S, fid) /\ frameClaim(S, fid) = None
  S with { claims := S.claims ++ [(fid, pid)] }, handle(fid, pid)
```

Linda `in(template)`, but the template is *semantic*: readiness is derived from the givens-yields DAG (`givenSatisfiable`), not structural field-type matching. The claim handle is a **linear token** -- it must be consumed exactly once by either `submit` or `release`. The `INSERT IGNORE` with `UNIQUE(frame_id)` implements the atomic mutex (Claims.lean `claimStep`). Proved: `claim_preserves_mutex`.

### 2.3. Token Consumption

```
submit : ClaimHandle x [Yield] x [Binding] -> S -> S
submit(handle(fid, pid), ys, bs)(S) =
  S with { yields := S.yields ++ ys,
           bindings := S.bindings ++ bs,
           claims := S.claims.filter(c => c.frameId != fid) }
```

Consumes the linear token. Appends yields (immutable once written: `yieldUnique`). Records bindings (which producer frames were read). Removes the claim -- the only mutable state transition in the entire protocol. Proved: `freeze_appendOnly`.

```
release : ClaimHandle -> S -> S
release(handle(fid, pid))(S) =
  S with { claims := S.claims.filter(c => c.frameId != fid) }
```

Alternative consumption path for timeouts or errors. Proved: `release_frees_frame` -- under mutex, the frame returns to `declared`.

### 2.4. Time-Travel Rewind

```
thaw : CellName x ProgramId -> S -> S
thaw(cell, prog)(S) =
  let affected = transitiveDependents(S.givens, cell)
  for each c in {cell} ++ affected:
    let g = maxGeneration(S, c) + 1
    S := S with { frames := S.frames ++ [Frame(c, g)],
                  yields := S.yields ++ [emptySlots(c, g)] }
    resetCellState(S, c)    -- cells.state := 'declared'
```

No Linda equivalent. Thaw creates gen N+1 frames for the target and all transitive dependents, preserving all prior generations (append-only). The cascade follows the givens DAG forward. The cell-level `state` column is reset (the one admitted mutation beyond claims). Dolt commit history preserves the pre-thaw snapshot.

### 2.5. Non-Destructive Read

```
observe : Query -> S -> [Yield]
observe(q)(S) = S.yields.filter(y => y.is_frozen /\ matches(q, y))
```

Linda `rd(template)`. Reads frozen yields without disturbing the space. The `ready_cells` view and `ct watch` are observe operations. Pattern matching is semantic: an LLM piston reads natural-language yields and decides what they mean.

## 3. Session Types for Piston Interaction

### 3.1. Pure Piston (hard cells)

```
PurePiston = claim(fid).eval_deterministic.submit(fid, ys).end
```

No session type needed in practice -- the runtime executes hard cells inline without pausing (`cmdRun` case `"evaluated"`). The claim-submit pair is atomic from the piston's perspective.

### 3.2. Replayable Piston (soft cells)

```
ReplayPiston = mu X.
  claim(fid) ;
  &{ dispatch(prompt, inputs) .
     rec { submit(fid, ys) . end
         + oracle_fail(reason) . release(fid) . X  -- retry
         }
   + complete . end
   }
```

The piston claims a frame, receives a resolved prompt (givens interpolated into body), invokes the LLM oracle, and submits. On oracle failure, the token is released and the loop restarts. The `replEvalStep` function implements this: claim via `INSERT IGNORE`, bottom propagation check, then dispatch or inline evaluation. Auto-retriable because the LLM oracle is stateless.

### 3.3. Non-Replayable Piston (stem cells)

```
StemPiston = mu X.
  claim(fid_at_gen_N) ;
  &{ dispatch(prompt, inputs) .
     submit(fid, ys) .
     if demand_exists then createFrame(gen_N+1) . X
     else end
   + complete . end
   }
```

Stem cells cycle: each completion may spawn a gen N+1 frame if demand persists. The key difference from replayable pistons: on failure, *thaw* is required rather than simple retry, because the stem cell's output may have been consumed by downstream cells that must also be invalidated.

## 4. Branching Discipline

### 4.1. Restriction as Branch Isolation

Each piston operates within a Dolt transaction scope. In pi-calculus terms:

```
(nu b_i)(Piston_i[b_i] | Space[main])
```

The restriction `(nu b_i)` creates a private channel (Dolt branch/transaction) for piston `i`. Within `b_i`, the piston can read and write without affecting other pistons' views. The `cell_claims` table with `UNIQUE(frame_id)` serves as the synchronization point -- it lives on `main` and is the rendezvous channel.

### 4.2. Merge Protocol

Merge is `DOLT_COMMIT` on the shared branch. Currently Cell runs on a single branch with transactional isolation:

```
merge(b_i, main) =
  DOLT_COMMIT('-Am', msg)   -- atomic: yields + bindings + claim removal
```

The commit is atomic: either all yields and bindings from a freeze appear, or none do. The `SET @@dolt_transaction_commit = 0` at the start of each eval step ensures transactional boundaries.

## 5. Protocol Properties

**P1. Linear Claim Tokens.** A claim on frame `fid` is consumed exactly once. `claimMutex` (I6): at most one claim per frame. `claim_preserves_mutex`: every valid trace maintains this. The `INSERT IGNORE` with `UNIQUE(frame_id)` is the implementation. Proved for all valid traces: `always_mutex_on_valid_trace`.

**P2. Yield Immutability.** Once `submit` writes a yield for `(frameId, fieldName)`, the value never changes. `yieldUnique` (I7): at most one yield per (frame, field). `freeze_rejects_duplicate`: re-freeze returns false. Proved: `always_yields_preserved_on_valid_trace`.

**P3. Time-Travel Safety.** Thaw preserves well-formedness: it creates new frames at gen N+1 without destroying gen 0..N. All append-only invariants hold for prior generations. The `generationOrdered` invariant (I10) ensures same-cell bindings point backward. The Dolt commit tagged `"thaw: ..."` marks the epoch boundary. One admitted deviation: `cells.state` is mutated (reset to `declared`), breaking the pure derived-state model. This is the pragmatic concession.

**P4. Branch Isolation.** Piston on branch X cannot observe uncommitted state from branch Y. Currently enforced by running on a single Dolt branch with `cell_claims` as the serialization point. Cross-branch reads would require `DOLT_MERGE` or `AS OF` queries, neither of which occurs during normal piston operation.

**P5. Progress.** `unclaimed_claim_succeeds`: if a frame is free and ready, a claim attempt succeeds. `release_frees_frame`: release always returns the frame to the pool. Together these guarantee no deadlock in the claim protocol, provided at least one piston is alive and polling.

**P6. DAG Preservation.** Bindings point only to frozen producer frames (`bindingsPointToFrozen`, I11). Same-cell edges go backward in generation (`generationOrdered`, I10). No self-loops (`noSelfLoops`, I9). Together these ensure the execution graph is acyclic.

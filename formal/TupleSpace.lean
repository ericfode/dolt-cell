/-
  Proof Obligations for the Cell Tuple Space

  The Cell runtime is a versioned tuple space (Dolt) with a deterministic
  executor.  This file states the proof obligations that arise from
  reframing the model in Linda terms, stratified by effect level.

  Three strata of effects form a lattice:
    Pure < Replayable < NonReplayable
  where Pure is deterministic SQL/literal evaluation, Replayable is
  bounded-nondeterministic LLM oracle invocation, and NonReplayable
  mutates the tuple space or the external world.

  Conventions below:
    {P} S {Q}           Hoare partial-correctness triple
    [P] S [Q]           Hoare total-correctness triple
    TS                   the tuple space (Retort database state)
    out(t)               insert tuple t into TS
    in(t)                destructively read tuple t from TS
    rd(t)                non-destructive read of tuple t
    thaw(cell,g)         rewind cell to generation g via Dolt time-travel
    branch(p)            create a COW branch for piston p
    merge(b)             merge branch b into main
-/

import Core

namespace TupleSpace

/-! ====================================================================
    SECTION 1: CARRIED FORWARD UNCHANGED

    These obligations from Retort.lean / Claims.lean hold as-is in the
    tuple-space reframing.  They need no new proof because the tuple
    space is implemented by the same Dolt tables.
    ==================================================================== -/

/-
  (a)  wellFormed_preserved
       Every RetortOp maps a wellFormed Retort to a wellFormed Retort.
       The tuple-space view adds no new state; it is an interpretation
       of the same tables.  Proof: Retort.lean, all_ops_preserve_wf.

  (b)  claim_mutex
       INSERT IGNORE + UNIQUE(frame_id) on active_claims ensures
       at most one piston holds a given frame.
       Proof: Claims.lean, always_mutex_on_valid_trace.

  (c)  yield_immutability
       Once a yield row exists for (frame_id, field), no operation
       changes or removes it.  freeze is append-only; other ops do
       not touch yields.
       Proof: Claims.lean, freeze_rejects_duplicate +
              always_yields_preserved_on_valid_trace.
-/

/-! ====================================================================
    SECTION 2: NEW OBLIGATIONS FROM THE TUPLE-SPACE REFRAMING
    ==================================================================== -/

/-! ### 2a  Linda Laws (out/in/rd consistency)

  Linda's foundational guarantee:  out(t) followed by in(t) retrieves
  the same tuple t, provided no intervening in(t) by another agent.

  In Cell, `out` is INSERT INTO yields and `in` is SELECT + DELETE
  (which only the thaw path performs — normal reads are `rd`).

  {t ∉ TS}  out(t)  {t ∈ TS}                               -- out-post
  {t ∈ TS ∧ mutex(t)}  in(t)  {t ∉ TS ∧ result = t}       -- in-post
  {t ∈ TS}  rd(t)  {t ∈ TS ∧ result = t}                   -- rd-post

  out-post is yield_immutability (append-only INSERT).
  rd-post holds because normal reads never DELETE.
  in-post requires mutex; the claim system provides it.
-/

/-! ### 2b  Time-Travel Safety (thaw preserves well-formedness)

  Dolt's `AS OF` / branch-reset gives destructive `in` its inverse.
  Thawing cell C to generation g means:
    (i)   DELETE yields WHERE cell = C AND gen > g
    (ii)  DELETE frames WHERE cell = C AND gen > g
    (iii) DELETE bindings whose consumer was one of those frames
  The resulting state must satisfy wellFormed.

  {wellFormed(TS) ∧ g ≤ currentGen(C)}
    thaw(C, g)
  {wellFormed(TS') ∧ TS'.currentGen(C) = g
   ∧ (∀ D ≠ C, TS'.yields(D) = TS.yields(D))}

  Key lemma: removing a suffix of frames/yields for a single cell
  preserves all nine invariants (I1--I9 of Retort.lean), because
  the removed rows form an upward-closed set in the generation order
  and no lower-generation row references a higher-generation row
  (ensured by generationOrdered).

  Cascade: if cell D depends on C at generation > g, then D must
  also be thawed.  The cascade terminates because the dependency
  DAG is finite and acyclic among non-divergent cells.
-/

/-! ### 2c  Branch Isolation

  Each piston operates on a Dolt branch (copy-on-write).  Operations
  on branch B are invisible to main until merge.

  Let TS_main and TS_B be the tuple spaces on main and branch B.

  {TS_main = S}  op_on_B(...)  {TS_main = S}        -- isolation

  Proof obligation: Dolt's branch mechanism ensures COW semantics.
  Within the formal model this is an axiom about the storage layer.
  The Cell-level consequence: piston P literally cannot read data
  outside its branch — scope confinement becomes a theorem of
  branch isolation rather than an unverifiable runtime assertion.
-/

/-! ### 2d  Merge Correctness

  When branch B merges into main, the well-formedness of main is
  preserved provided B's new yields do not violate yieldUnique on
  main.

  {wellFormed(TS_main) ∧ wellFormed(TS_B)
   ∧ disjointYields(TS_main, TS_B)}
    merge(B)
  {wellFormed(TS_main')}

  disjointYields means: for every (frame_id, field) in TS_B's new
  yields, no yield with the same key exists in TS_main.  The claim
  mutex guarantees this — only one piston claims a frame, so only
  one branch writes yields for it.
-/

/-! ====================================================================
    SECTION 3: NEW OBLIGATIONS FROM THE EFFECT DISTINCTION
    ==================================================================== -/

/-- The effect lattice. -/
inductive Effect where
  | pure          -- deterministic: SQL, literal, arithmetic
  | replayable    -- bounded nondeterminism: LLM oracle, can auto-retry
  | nonReplayable -- world-mutating: cascade-thaw, external side-effect
  deriving Repr, DecidableEq, BEq

def Effect.le : Effect -> Effect -> Bool
  | .pure, _               => true
  | .replayable, .replayable    => true
  | .replayable, .nonReplayable => true
  | .nonReplayable, .nonReplayable => true
  | _, _                   => false

/-! ### 3a  Pure Cell Determinism

  A cell declared Pure contains no oracle call and no branch mutation.
  Same inputs must produce same outputs.  This is the strongest
  guarantee and carries zero proof obligation on external agents.

  {inputs = I ∧ effect(cell) = Pure}
    eval(cell)
  {outputs = f(I)}

  where f is the cell's body interpreted as a total function.
  Proof: the body is a SQL query or literal expression executed by
  the deterministic runtime; the runtime does not pause or consult
  any oracle.  Formally: pure_deterministic in Denotational.lean.
-/

/-! ### 3b  Replayable Cell Bounded Retry

  A Replayable cell invokes an LLM oracle that may return different
  values on each call.  The runtime may auto-retry up to N times.
  After N failures the cell is bottomed.

  [inputs_resolved ∧ retryBudget = N ∧ N > 0]
    eval_replayable(cell)
  [frozen(cell) ∨ (bottom(cell) ∧ retryBudget = 0)]

  This is total correctness: the square brackets assert termination.
  The bounded retry budget is the variant that decreases.
  No cascade-thaw is needed because the runtime can re-request
  without affecting any other cell's state.
-/

/-! ### 3c  NonReplayable Cascade-Thaw Correctness

  A NonReplayable cell mutates the tuple space (e.g., thaw, external
  write).  If it fails, recovery requires cascade-thaw: rewinding the
  cell and all downstream dependents to a prior generation.

  {wellFormed(TS) ∧ frozen(cell, g) ∧ dependents(cell) = DS}
    thaw(cell, g-1)
  {wellFormed(TS') ∧ currentGen(cell) = g-1
   ∧ ∀ d ∈ DS, currentGen(d) ≤ prior_gen(d)}

  The cascade terminates because the dependency DAG is finite and
  acyclic (among non-divergent cells), so the set DS is finite and
  the recursion bottoms out at cells with no dependents.
-/

/-! ### 3d  Effect Monotonicity

  A cell declared at effect level E cannot perform operations that
  require level E' > E.  The runtime's effect handler rejects them.

  ∀ cell, ∀ op performed by cell,
    effect(op) ≤ declaredEffect(cell)

  Enforcement: the piston dispatch table maps each cell to a handler
  that only exposes operations at or below the declared level.  A
  Pure handler has no oracle call and no branch-mutation primitive.
  A Replayable handler adds oracle calls but no branch mutation.
  A NonReplayable handler adds branch mutation.

  In the formal model this is a typing judgment on the handler, not
  a runtime check — the handler literally lacks the forbidden operations.
-/

/-! ====================================================================
    SECTION 4: WHAT CANNOT BE PROVED (RUNTIME ASSUMPTIONS)
    ==================================================================== -/

/-
  (a)  bodiesFaithful for LLM pistons.
       The oracle may return any string.  The assumption that it
       satisfies the cell's oracles is EXTERNAL to the formal model.
       (Refinement.lean, bodiesFaithful — an axiom, not a theorem.)

  (b)  Oracle semantic correctness.
       An LLM judge evaluating "is this a valid summary?" may be wrong.
       The formal model treats oracle predicates as ground truth; their
       actual fidelity is outside the proof boundary.

  (c)  Scope confinement — NOW PROVABLE.
       Under branch isolation (Section 2c), a piston on branch B
       cannot read tuples from main or from another piston's branch.
       Confinement follows from the branch-isolation axiom and the
       fact that the piston's SQL connection is scoped to its branch.
       This was previously an unverifiable runtime assertion; the
       tuple-space + branch model makes it a theorem.
-/

/-! ====================================================================
    SECTION 5: WEAKEST PRECONDITIONS
    ==================================================================== -/

/-
  wp(pure_cell) =
      inputs_resolved(cell)
    ∧ body_deterministic(cell)

    -- The runtime runs the body to completion without pausing.
    -- No external interaction.  Termination is guaranteed by the
    -- finite SQL evaluation or literal substitution.

  wp(replayable_cell) =
      inputs_resolved(cell)
    ∧ retryBudget > 0

    -- The runtime may invoke the oracle up to retryBudget times.
    -- Each invocation either produces a value that passes all
    -- oracles (success) or fails.  After exhaustion, the cell
    -- is bottomed.  No cascade-thaw needed.

  wp(nonReplayable_cell) =
      inputs_resolved(cell)
    ∧ authorized(cell)
    ∧ branch_created(cell)

    -- The piston must have an active branch.  The authorization
    -- check confirms the piston is permitted to perform the
    -- mutation.  On failure, cascade-thaw is the recovery path.
-/

end TupleSpace

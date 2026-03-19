/-
  EffectEval: Effect-Aware Eval Loop for the Cell Tuple Space Runtime

  This module formalizes the effect-stratified execution model described in
  cell-tuple-space-spec.md, Section 3 and Section 4.  It defines:

    1. EffLevel: Pure < Replayable < NonReplayable with join (max)
    2. effectEvalStep: the scheduler that classifies cells and returns actions
    3. Retry safety: retrying a Replayable cell preserves the tuple space
    4. Validate-then-write: the oracle-before-write protocol
    5. Effect monotonicity: join is monotone under composition
    6. Progressive trace: effect-aware eval still decreases nonFrozenCount

  Self-contained: imports only Core.lean (identity types + BodyType).
  Mirrors the subset of Retort types needed here to avoid depending on
  Retort.lean (which has known Lean 4.28 compat issues in this repo).
-/

import Core

namespace EffectEval

/-! ====================================================================
    LOCAL COPIES OF RETORT TYPES (minimal subset for this module)

    These are structurally identical to the types in Retort.lean.
    We duplicate rather than import to keep the build independent.
    ==================================================================== -/

structure RCellDef' where
  name      : CellName
  program   : ProgramId
  bodyType  : BodyType
  body      : String
  fields    : List FieldName
  deriving Repr, DecidableEq

structure Frame' where
  id         : FrameId
  cellName   : CellName
  program    : ProgramId
  generation : Nat
  deriving Repr, DecidableEq, BEq

structure Yield' where
  frameId  : FrameId
  field    : FieldName
  value    : String
  isBottom : Bool := false
  deriving Repr, DecidableEq, BEq

structure Binding' where
  consumerFrame : FrameId
  producerFrame : FrameId
  givenField    : FieldName
  deriving Repr, DecidableEq, BEq

structure GivenSpec' where
  owner       : CellName
  sourceCell  : CellName
  sourceField : FieldName
  optional    : Bool
  deriving Repr, DecidableEq, BEq

structure Claim' where
  frameId  : FrameId
  pistonId : PistonId
  deriving Repr, DecidableEq, BEq

/-- The retort state (local copy). -/
structure RS where
  cells    : List RCellDef'
  givens   : List GivenSpec'
  frames   : List Frame'
  yields   : List Yield'
  bindings : List Binding'
  claims   : List Claim'
  deriving Repr

def RS.empty : RS :=
  { cells := [], givens := [], frames := [], yields := [], bindings := [], claims := [] }

/-- Derived frame status. -/
inductive FStatus where
  | declared | computing | frozen
  deriving Repr, DecidableEq, BEq

def RS.frameYields (r : RS) (fid : FrameId) : List Yield' :=
  r.yields.filter (fun y => y.frameId == fid)

def RS.frameClaim (r : RS) (fid : FrameId) : Option Claim' :=
  r.claims.find? (fun c => c.frameId == fid)

def RS.cellDef (r : RS) (name : CellName) : Option RCellDef' :=
  r.cells.find? (fun c => c.name == name)

def RS.frameStatus (r : RS) (f : Frame') : FStatus :=
  match r.cellDef f.cellName with
  | none => .declared
  | some cd =>
    let frozenFields := (r.frameYields f.id).map (·.field)
    if cd.fields.all (fun fld => frozenFields.contains fld) then .frozen
    else if (r.frameClaim f.id).isSome then .computing
    else .declared

/-- Yields-preserved predicate. -/
def yieldsPreserved' (before after : RS) : Prop :=
  ∀ (y : Yield'), y ∈ before.yields -> y ∈ after.yields

/-! ====================================================================
    SECTION 1: EFFECT LEVEL — Total Order and Join
    ==================================================================== -/

/-- The three effect levels, ordered by recovery cost. -/
inductive EffLevel where
  | pure          -- deterministic: literal, SQL query
  | replayable    -- bounded nondeterminism: LLM oracle, auto-retry
  | nonReplayable -- world-mutating: SQL exec, spawn, thaw
  deriving Repr, DecidableEq, BEq

/-- Numeric encoding for the total order. -/
def EffLevel.toNat : EffLevel -> Nat
  | .pure          => 0
  | .replayable    => 1
  | .nonReplayable => 2

/-- LE instance via toNat. -/
instance : LE EffLevel where
  le a b := a.toNat <= b.toNat

instance : LT EffLevel where
  lt a b := a.toNat < b.toNat

instance (a b : EffLevel) : Decidable (a <= b) :=
  inferInstanceAs (Decidable (a.toNat <= b.toNat))

instance (a b : EffLevel) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- Helper to unfold LE for EffLevel in proofs. -/
private theorem EffLevel.le_def (a b : EffLevel) : (a <= b) = (a.toNat <= b.toNat) := rfl

/-- Join = max of two effect levels. -/
def EffLevel.join (a b : EffLevel) : EffLevel :=
  if b.toNat <= a.toNat then a else b

private theorem toNat_injective (a b : EffLevel) (h : a.toNat = b.toNat) : a = b := by
  cases a <;> cases b <;> simp [EffLevel.toNat] at h <;> rfl

/-! ### Join algebraic laws -/

theorem join_comm (a b : EffLevel) : EffLevel.join a b = EffLevel.join b a := by
  simp only [EffLevel.join]
  split <;> split
  · rename_i h1 h2
    exact toNat_injective a b (Nat.le_antisymm h2 h1)
  · rfl
  · rfl
  · rename_i h1 h2; omega

theorem join_assoc (a b c : EffLevel) :
    EffLevel.join (EffLevel.join a b) c = EffLevel.join a (EffLevel.join b c) := by
  simp only [EffLevel.join]
  cases a <;> cases b <;> cases c <;> simp [EffLevel.toNat]

theorem join_idem (a : EffLevel) : EffLevel.join a a = a := by
  simp only [EffLevel.join, EffLevel.toNat]
  cases a <;> simp

/-! ### Order interaction with join -/

theorem join_le_left (a b : EffLevel) : a <= EffLevel.join a b := by
  simp only [EffLevel.join]
  show a.toNat <= (if b.toNat <= a.toNat then a else b).toNat
  split
  · exact Nat.le_refl a.toNat
  · rename_i h; omega

theorem join_le_right (a b : EffLevel) : b <= EffLevel.join a b := by
  simp only [EffLevel.join]
  show b.toNat <= (if b.toNat <= a.toNat then a else b).toNat
  split
  · rename_i h; exact h
  · exact Nat.le_refl b.toNat

theorem join_lub (a b c : EffLevel) (ha : a <= c) (hb : b <= c) :
    EffLevel.join a b <= c := by
  simp only [EffLevel.join, EffLevel.le_def]
  split
  · exact ha
  · exact hb

/-- Pure is the bottom of the lattice. -/
theorem pure_le_all (e : EffLevel) : EffLevel.pure <= e := by
  show EffLevel.pure.toNat <= e.toNat
  simp [EffLevel.toNat]

/-- Join with pure is identity. -/
theorem join_pure_left (e : EffLevel) : EffLevel.join .pure e = e := by
  simp only [EffLevel.join, EffLevel.toNat]
  cases e <;> simp

theorem join_pure_right (e : EffLevel) : EffLevel.join e .pure = e := by
  rw [join_comm]; exact join_pure_left e

/-! ====================================================================
    SECTION 2: EFFECT CLASSIFICATION OF CELLS
    ==================================================================== -/

/-- Classify a cell definition's effect level from its body type. -/
def classifyEffect (cd : RCellDef') : EffLevel :=
  match cd.bodyType with
  | .hard => .pure
  | .soft => .replayable
  | .stem => .replayable

/-! ====================================================================
    SECTION 3: THE EFFECT-AWARE EVAL STEP
    ==================================================================== -/

/-- The possible actions the effect-aware scheduler can return. -/
inductive EvalAction where
  | execPure              : Frame' -> RCellDef' -> EvalAction
  | dispatchReplayable    : Frame' -> RCellDef' -> Nat -> EvalAction
  | dispatchNonReplayable : Frame' -> RCellDef' -> EvalAction
  | quiescent             : EvalAction
  | complete              : EvalAction
  deriving Repr

/-- Given satisfiable check. -/
def RS.givenSatisfiable (r : RS) (g : GivenSpec') : Bool :=
  g.optional ||
  r.frames.any (fun f =>
    f.cellName == g.sourceCell &&
    r.frameStatus f == .frozen &&
    r.yields.any (fun y => y.frameId == f.id && y.field == g.sourceField))

/-- Frame ready check. -/
def RS.frameReady (r : RS) (f : Frame') : Bool :=
  r.frameStatus f == .declared &&
  let cellGivens := r.givens.filter (fun g => g.owner == f.cellName)
  cellGivens.all (fun g => r.givenSatisfiable g)

/-- Program complete check. -/
def RS.programComplete (r : RS) (prog : ProgramId) : Bool :=
  let progCells := r.cells.filter (fun c => c.program == prog)
  let progFrames := r.frames.filter (fun f => f.program == prog)
  progCells.all (fun cd =>
    cd.bodyType == .stem ||
    progFrames.any (fun f => f.cellName == cd.name && r.frameStatus f == .frozen))

/-- Ready frames. -/
def RS.readyFrames (r : RS) : List Frame' :=
  r.frames.filter (fun f => r.frameReady f)

/-- Bottomed dependency check. -/
def RS.isBottomFrame (r : RS) (f : Frame') : Bool :=
  r.frameStatus f == .frozen &&
  let ys := r.frameYields f.id
  !ys.isEmpty && ys.all (·.isBottom)

def RS.latestFrozenFrame (r : RS) (cell : CellName) : Option Frame' :=
  let frames := r.frames.filter (fun f => f.cellName == cell && r.frameStatus f == .frozen)
  frames.foldl (fun acc f => match acc with
    | none => some f
    | some best => if f.generation > best.generation then some f else acc) none

def RS.hasBottomedDep (r : RS) (f : Frame') : Bool :=
  let cellGivens := r.givens.filter (fun g => g.owner == f.cellName && !g.optional)
  cellGivens.any (fun g =>
    match r.latestFrozenFrame g.sourceCell with
    | some srcFrame => r.isBottomFrame srcFrame
    | none => false)

/-- Find a ready cell, classify its effect, and return the appropriate action. -/
def effectEvalStep (r : RS) (prog : ProgramId) (defaultRetries : Nat := 3) : EvalAction :=
  if r.programComplete prog then .complete
  else
    let readyFrames := r.readyFrames.filter (fun f => f.program == prog)
    let viable := readyFrames.filter (fun f => !r.hasBottomedDep f)
    match viable.head? with
    | none => .quiescent
    | some f =>
      match r.cellDef f.cellName with
      | none => .quiescent
      | some cd =>
        match classifyEffect cd with
        | .pure          => .execPure f cd
        | .replayable    => .dispatchReplayable f cd defaultRetries
        | .nonReplayable => .dispatchNonReplayable f cd

/-! ====================================================================
    SECTION 4: RETRY SAFETY — Replayable retries preserve the tuple space
    ==================================================================== -/

/-- A replayable attempt: the piston produces a candidate value, the
    runtime validates it BEFORE writing.  On failure, nothing is written. -/
structure ReplayableAttempt where
  frameId     : FrameId
  candidate   : List Yield'
  oraclePass  : Bool

/-- Apply a replayable attempt: write yields only if oracle passed.
    On failure, the RS is returned unchanged. -/
def applyReplayableAttempt (r : RS) (att : ReplayableAttempt) : RS :=
  if att.oraclePass then
    { r with yields := r.yields ++ att.candidate,
             claims := r.claims.filter (fun c => c.frameId != att.frameId) }
  else
    r

/-- KEY THEOREM: A failed replayable attempt leaves the tuple space unchanged. -/
theorem replayable_retry_preserves_state (r : RS) (att : ReplayableAttempt)
    (hFail : att.oraclePass = false) :
    applyReplayableAttempt r att = r := by
  unfold applyReplayableAttempt
  simp [hFail]

/-- Corollary: yields are identical after a failed attempt. -/
theorem replayable_retry_yields_unchanged (r : RS) (att : ReplayableAttempt)
    (hFail : att.oraclePass = false) :
    (applyReplayableAttempt r att).yields = r.yields := by
  rw [replayable_retry_preserves_state r att hFail]

/-- Corollary: claims are identical after a failed attempt. -/
theorem replayable_retry_claims_unchanged (r : RS) (att : ReplayableAttempt)
    (hFail : att.oraclePass = false) :
    (applyReplayableAttempt r att).claims = r.claims := by
  rw [replayable_retry_preserves_state r att hFail]

/-- Multiple failed retries still preserve state (induction on retry count). -/
def applyRetries (r : RS) : List ReplayableAttempt -> RS
  | []        => r
  | att :: rest => applyRetries (applyReplayableAttempt r att) rest

theorem all_failed_retries_preserve_state (r : RS) (atts : List ReplayableAttempt)
    (hAllFail : ∀ (a : ReplayableAttempt), a ∈ atts -> a.oraclePass = false) :
    applyRetries r atts = r := by
  induction atts generalizing r with
  | nil => rfl
  | cons att rest ih =>
    simp only [applyRetries]
    have hFail : att.oraclePass = false := hAllFail att (List.mem_cons_self ..)
    rw [replayable_retry_preserves_state r att hFail]
    exact ih r (fun a ha => hAllFail a (List.mem_cons_of_mem _ ha))

/-! ====================================================================
    SECTION 5: VALIDATE-THEN-WRITE (Oracle-Before-Write Correctness)
    ==================================================================== -/

/-- The correct protocol: validate in memory, then write. -/
structure ValidateThenWrite where
  frameId    : FrameId
  candidate  : List Yield'
  bindings   : List Binding'
  validated  : Bool

/-- Apply validate-then-write: only writes when validated = true. -/
def applyValidateThenWrite (r : RS) (vtw : ValidateThenWrite) : RS :=
  if vtw.validated then
    { r with yields := r.yields ++ vtw.candidate,
             bindings := r.bindings ++ vtw.bindings,
             claims := r.claims.filter (fun c => c.frameId != vtw.frameId) }
  else
    r

/-- Validate-then-write preserves yields (append-only). -/
theorem vtw_preserves_yields (r : RS) (vtw : ValidateThenWrite) :
    yieldsPreserved' r (applyValidateThenWrite r vtw) := by
  unfold applyValidateThenWrite yieldsPreserved'
  split
  · intro y hy; exact List.mem_append_left _ hy
  · intro y hy; exact hy

/-- When validation fails, the entire state is unchanged. -/
theorem vtw_fail_preserves_state (r : RS) (vtw : ValidateThenWrite)
    (hFail : vtw.validated = false) :
    applyValidateThenWrite r vtw = r := by
  unfold applyValidateThenWrite; simp [hFail]

/-- The write-then-validate anti-pattern. -/
structure WriteThenValidate where
  frameId   : FrameId
  candidate : List Yield'
  bindings  : List Binding'
  validated : Bool

/-- Write-then-validate: writes first, then deletes on failure. -/
def applyWriteThenValidate (r : RS) (wtv : WriteThenValidate) : RS :=
  let written := { r with yields := r.yields ++ wtv.candidate,
                          bindings := r.bindings ++ wtv.bindings,
                          claims := r.claims.filter (fun c => c.frameId != wtv.frameId) }
  if wtv.validated then written
  else
    { written with yields := written.yields.filter (fun y => y.frameId != wtv.frameId) }

/-- Write-then-validate can remove pre-existing yields on failure.
    Specifically: a yield y that was in r.yields BEFORE the operation
    can be absent AFTER if y.frameId matches the operation's frameId. -/
theorem wtv_can_remove_yields (r : RS) (wtv : WriteThenValidate)
    (hFail : wtv.validated = false)
    (y : Yield') (_hy : y ∈ r.yields) (hSameFrame : y.frameId = wtv.frameId) :
    y ∉ (applyWriteThenValidate r wtv).yields := by
  -- Directly unfold and show the contradiction: y is filtered out because
  -- y.frameId = wtv.frameId, but the filter keeps only frameId != wtv.frameId.
  simp only [applyWriteThenValidate, hFail]
  -- Now the goal should involve membership in a structure with a filter.
  -- We simplify the if-then-else: false = true is False
  simp only [Bool.false_eq_true, ite_false]
  -- Now goal is: y ∉ (filtered yields).  The filter is frameId != wtv.frameId.
  rw [List.mem_filter]
  intro ⟨_, hne⟩
  simp only [bne_iff_ne, ne_eq] at hne
  exact hne hSameFrame

/-! ====================================================================
    SECTION 6: EFFECT MONOTONICITY
    ==================================================================== -/

/-- An operation's effect level. -/
inductive OpEffect where
  | lookup   | yieldVal | sqlQuery   -- Pure
  | llmCall  | llmJudge              -- Replayable
  | sqlExec  | spawn    | thaw       -- NonReplayable
  deriving Repr, DecidableEq, BEq

/-- Classify an operation. -/
def OpEffect.level : OpEffect -> EffLevel
  | .lookup   => .pure
  | .yieldVal => .pure
  | .sqlQuery => .pure
  | .llmCall  => .replayable
  | .llmJudge => .replayable
  | .sqlExec  => .nonReplayable
  | .spawn    => .nonReplayable
  | .thaw     => .nonReplayable

/-- A cell's composite effect level = join of all its operations' levels. -/
def compositeLevel (ops : List OpEffect) : EffLevel :=
  ops.foldl (fun acc op => EffLevel.join acc op.level) .pure

/-- Helper: foldl with join stays bounded when every element is bounded. -/
private theorem foldl_join_bounded (ops : List OpEffect) (acc e : EffLevel)
    (hacc : acc <= e) (hAll : ∀ (op : OpEffect), op ∈ ops -> op.level <= e) :
    ops.foldl (fun a op => EffLevel.join a op.level) acc <= e := by
  induction ops generalizing acc with
  | nil => simpa [List.foldl] using hacc
  | cons op rest ih =>
    simp only [List.foldl]
    exact ih (EffLevel.join acc op.level)
      (join_lub acc op.level e hacc (hAll op (List.mem_cons_self ..)))
      (fun op' hop' => hAll op' (List.mem_cons_of_mem _ hop'))

/-- Effect monotonicity: if every operation is at or below level e,
    then the composite is at or below e. -/
theorem effect_monotone (ops : List OpEffect) (e : EffLevel)
    (hAll : ∀ (op : OpEffect), op ∈ ops -> op.level <= e) :
    compositeLevel ops <= e := by
  unfold compositeLevel
  exact foldl_join_bounded ops .pure e (pure_le_all e) hAll

/-- Adding an operation at level <= e keeps the composite at level <= e. -/
theorem composite_extend (ops : List OpEffect) (op : OpEffect) (e : EffLevel)
    (hOps : compositeLevel ops <= e) (hOp : op.level <= e) :
    compositeLevel (ops ++ [op]) <= e := by
  unfold compositeLevel at *
  rw [List.foldl_append]
  simp only [List.foldl]
  exact join_lub (ops.foldl (fun a o => EffLevel.join a o.level) .pure) op.level e hOps hOp

/-- Join is monotone in each argument. -/
theorem join_mono_left (a b c : EffLevel) (h : a <= b) :
    EffLevel.join a c <= EffLevel.join b c := by
  cases a <;> cases b <;> cases c <;> simp_all [EffLevel.join, EffLevel.toNat, EffLevel.le_def]

theorem join_mono_right (a b c : EffLevel) (h : b <= c) :
    EffLevel.join a b <= EffLevel.join a c := by
  rw [join_comm a b, join_comm a c]
  exact join_mono_left b c a h

/-! ====================================================================
    SECTION 7: EFFECT-AWARE EVAL CYCLE AND APPEND-ONLY
    ==================================================================== -/

/-- Freeze data (local). -/
structure FreezeData' where
  frameId  : FrameId
  yields   : List Yield'
  bindings : List Binding'

/-- Claim data (local). -/
structure ClaimData' where
  frameId  : FrameId
  pistonId : PistonId

/-- Apply a claim: add a claim entry. -/
def applyClaim (r : RS) (cd : ClaimData') : RS :=
  { r with claims := r.claims ++ [⟨cd.frameId, cd.pistonId⟩] }

/-- Apply a freeze: add yields/bindings, remove claim. -/
def applyFreeze (r : RS) (fd : FreezeData') : RS :=
  { r with yields := r.yields ++ fd.yields,
           bindings := r.bindings ++ fd.bindings,
           claims := r.claims.filter (fun c => c.frameId != fd.frameId) }

/-- Append-only for RS (everything except claims). -/
def appendOnly' (before after : RS) : Prop :=
  (∀ (c : RCellDef'), c ∈ before.cells -> c ∈ after.cells) ∧
  (∀ (f : Frame'), f ∈ before.frames -> f ∈ after.frames) ∧
  (∀ (y : Yield'), y ∈ before.yields -> y ∈ after.yields) ∧
  (∀ (b : Binding'), b ∈ before.bindings -> b ∈ after.bindings) ∧
  (∀ (g : GivenSpec'), g ∈ before.givens -> g ∈ after.givens)

theorem appendOnly'_refl (r : RS) : appendOnly' r r :=
  ⟨fun _ h => h, fun _ h => h, fun _ h => h, fun _ h => h, fun _ h => h⟩

theorem appendOnly'_trans (r1 r2 r3 : RS)
    (h12 : appendOnly' r1 r2) (h23 : appendOnly' r2 r3) : appendOnly' r1 r3 :=
  ⟨fun x hx => h23.1 x (h12.1 x hx),
   fun x hx => h23.2.1 x (h12.2.1 x hx),
   fun x hx => h23.2.2.1 x (h12.2.2.1 x hx),
   fun x hx => h23.2.2.2.1 x (h12.2.2.2.1 x hx),
   fun x hx => h23.2.2.2.2 x (h12.2.2.2.2 x hx)⟩

theorem claim_appendOnly' (r : RS) (cd : ClaimData') : appendOnly' r (applyClaim r cd) := by
  unfold appendOnly' applyClaim
  exact ⟨fun _ h => h, fun _ h => h, fun _ h => h, fun _ h => h, fun _ h => h⟩

theorem freeze_appendOnly' (r : RS) (fd : FreezeData') : appendOnly' r (applyFreeze r fd) := by
  unfold appendOnly' applyFreeze
  refine ⟨fun _ h => h, fun _ h => h, ?_, ?_, fun _ h => h⟩
  · intro y hy; exact List.mem_append_left _ hy
  · intro b hb; exact List.mem_append_left _ hb

/-- An effect-aware eval cycle: effectEvalStep picks the action,
    then the runtime executes claim + freeze. -/
structure EffectEvalCycle where
  claimOp  : ClaimData'
  freezeOp : FreezeData'

/-- Apply an effect eval cycle: claim then freeze. -/
def applyEffectEvalCycle (r : RS) (eec : EffectEvalCycle) : RS :=
  applyFreeze (applyClaim r eec.claimOp) eec.freezeOp

/-- An effect eval cycle preserves append-only. -/
theorem effectEvalCycle_appendOnly (r : RS) (eec : EffectEvalCycle) :
    appendOnly' r (applyEffectEvalCycle r eec) := by
  unfold applyEffectEvalCycle
  exact appendOnly'_trans r (applyClaim r eec.claimOp) _
    (claim_appendOnly' r eec.claimOp)
    (freeze_appendOnly' (applyClaim r eec.claimOp) eec.freezeOp)

/-- Frames are unchanged by an effect eval cycle. -/
theorem effectEvalCycle_frames_stable (r : RS) (eec : EffectEvalCycle) :
    (applyEffectEvalCycle r eec).frames = r.frames := by
  unfold applyEffectEvalCycle applyFreeze applyClaim; rfl

/-- Yields only grow during an effect eval cycle. -/
theorem effectEvalCycle_yields_grow (r : RS) (eec : EffectEvalCycle)
    (y : Yield') (hy : y ∈ r.yields) :
    y ∈ (applyEffectEvalCycle r eec).yields :=
  (effectEvalCycle_appendOnly r eec).2.2.1 y hy

/-! ====================================================================
    SECTION 8: PROGRESSIVE TRACE — nonFrozenCount decreases
    ==================================================================== -/

/-- Count of non-frozen frames for a program. -/
def nonFrozenCount (r : RS) (prog : ProgramId) : Nat :=
  (r.frames.filter (fun f => f.program == prog && r.frameStatus f != .frozen)).length

/-- A valid effect-aware trace. -/
structure EffectTrace where
  trace    : Nat -> RS
  cycles   : Nat -> EffectEvalCycle
  init     : trace 0 = RS.empty
  step     : ∀ (n : Nat), trace (n + 1) = applyEffectEvalCycle (trace n) (cycles n)

/-- Append-only holds at every step of an effect trace. -/
theorem effect_trace_appendOnly (et : EffectTrace) (n : Nat) :
    appendOnly' (et.trace n) (et.trace (n + 1)) := by
  rw [et.step n]
  exact effectEvalCycle_appendOnly (et.trace n) (et.cycles n)

/-- Frames are stable across an effect trace. -/
theorem effect_trace_frames_stable (et : EffectTrace) (n : Nat) :
    (et.trace (n + 1)).frames = (et.trace n).frames := by
  rw [et.step n]
  exact effectEvalCycle_frames_stable (et.trace n) (et.cycles n)

/-- Data persists across an effect trace (transitive append-only). -/
theorem effect_trace_data_persists (et : EffectTrace) (n m : Nat) (h : n <= m) :
    appendOnly' (et.trace n) (et.trace m) := by
  induction m with
  | zero =>
    have : n = 0 := Nat.eq_zero_of_le_zero h
    subst this; exact appendOnly'_refl _
  | succ k ih =>
    by_cases hk : n <= k
    · exact appendOnly'_trans _ _ _ (ih hk) (effect_trace_appendOnly et k)
    · have : n = k + 1 := by omega
      subst this; exact appendOnly'_refl _

/-- Frames at time T equal frames at time 0 (stable through entire trace). -/
theorem effect_trace_frames_always_eq (et : EffectTrace) (n : Nat) :
    (et.trace n).frames = (et.trace 0).frames := by
  induction n with
  | zero => rfl
  | succ k ih => rw [effect_trace_frames_stable et k]; exact ih

/-- nonFrozenCount is monotonically non-increasing across the trace.
    Each eval cycle can only freeze frames (moving them OUT of the
    non-frozen set); it cannot unfreeze or add frames.

    The proof uses: (1) frames are stable, (2) yields only grow,
    so frameStatus can only transition toward frozen, never away. -/
theorem nonFrozen_mono (et : EffectTrace) (n : Nat) (prog : ProgramId) :
    nonFrozenCount (et.trace (n + 1)) prog <=
    nonFrozenCount (et.trace n) prog := by
  sorry
  -- This sorry depends on showing that frameStatus is monotone under
  -- yield-growth: more yields => more fields covered => frozen status
  -- can only become true, never revert to false.  Specifically:
  --   (a) frames are unchanged (effectEvalCycle_frames_stable)
  --   (b) yields only grow (effectEvalCycle_yields_grow)
  --   (c) frameYields is monotone under yield-append
  --   (d) "all fields covered" can only go from false to true
  -- This is the same "frozen is monotone" property needed by
  -- Retort.lean's demandFromGivens_monotone (also sorry there).
  -- The mathematical content is sound; the gap is a missing library
  -- lemma about List.filter length under predicate weakening.

/-! ====================================================================
    SECTION 9: BOUNDED RETRY TERMINATION
    ==================================================================== -/

/-- A replayable cell evaluation with bounded retries. -/
structure BoundedRetry where
  attempts   : List ReplayableAttempt
  budget     : Nat
  budgetEq   : attempts.length = budget

/-- After exhausting the retry budget, either some attempt succeeded
    or the cell is bottomed.  Total: the budget is the variant. -/
def retryOutcome (br : BoundedRetry) : Bool :=
  br.attempts.any (fun a => a.oraclePass)

/-- Helper: if List.any returns false then no element satisfies the predicate. -/
private theorem not_any_means_all_neg {α : Type} (l : List α) (p : α -> Bool)
    (h : l.any p = false) : ∀ (a : α), a ∈ l -> p a = false := by
  intro a ha
  cases hp : p a with
  | false => rfl
  | true =>
    have hany : l.any p = true := List.any_eq_true.mpr ⟨a, ha, hp⟩
    rw [h] at hany
    exact absurd hany Bool.false_ne_true

/-- If no attempt succeeded, all attempts failed, state is unchanged. -/
theorem no_success_means_unchanged (r : RS) (br : BoundedRetry)
    (hNoSuccess : retryOutcome br = false) :
    applyRetries r br.attempts = r := by
  apply all_failed_retries_preserve_state
  exact not_any_means_all_neg br.attempts (fun a => a.oraclePass) hNoSuccess

/-! ====================================================================
    VERDICT: Effect-Aware Eval Loop Properties
    ====================================================================

    PROVEN (no sorry):

    1. join_comm, join_assoc, join_idem
       The effect lattice join is a commutative, associative, idempotent
       operation (i.e., EffLevel forms a join-semilattice).

    2. join_le_left, join_le_right, join_lub
       Join computes the least upper bound.

    3. pure_le_all, join_pure_left, join_pure_right
       Pure is the lattice bottom; join with pure is identity.

    4. replayable_retry_preserves_state
       A failed replayable attempt leaves the RS completely unchanged.
       This is THE key safety property of validate-before-write.

    5. all_failed_retries_preserve_state
       Multiple failed retries (any number) leave the RS unchanged.
       Proved by induction on the retry list.

    6. vtw_preserves_yields
       Validate-then-write never removes yields (append-only preserved).

    7. vtw_fail_preserves_state
       Failed validation leaves state completely unchanged.

    8. wtv_can_remove_yields
       Write-then-validate CAN remove pre-existing yields (the current bug
       in procedures.sql Section 4.2 of the spec).

    9. effect_monotone
       A cell using only operations at level <= e has composite level <= e.

    10. composite_extend
        Adding an operation at level <= e preserves the bound.

    11. join_mono_left, join_mono_right
        Join is monotone in each argument.

    12. effectEvalCycle_appendOnly
        Effect-aware eval cycles preserve append-only.

    13. effectEvalCycle_frames_stable
        Effect-aware eval cycles don't change the frames list.

    14. effectEvalCycle_yields_grow
        Yields are monotonically growing through eval cycles.

    15. no_success_means_unchanged
        Exhausting the retry budget with no success leaves state unchanged.

    16. effect_trace_appendOnly, effect_trace_data_persists
        Temporal properties: data is monotonically preserved across traces.

    17. effect_trace_frames_always_eq
        Frames at any time T equal frames at time 0.

    SORRY (1 total, with justification):

    1. nonFrozen_mono — The proof that nonFrozenCount is non-increasing
       requires showing that frameStatus is monotone under yield-growth
       (more yields => more fields covered => frozen status can only
       become true, never revert to false).  This depends on a
       monotonicity lemma on List.filter length under predicate weakening,
       combined with the fact that frameYields is a subset-growing function.
       This is the same "frozen is monotone" property needed by
       Retort.lean's demandFromGivens_monotone (also sorry there).
       The mathematical content is sound; the gap is purely a missing
       library lemma about List.filter monotonicity under predicate
       implication.
-/

end EffectEval

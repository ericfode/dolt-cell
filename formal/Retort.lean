/-
  Retort: Full Formal Model of the Cell Runtime

  This formalizes the complete system:
  - Cell definitions (immutable after pour)
  - Frames (append-only execution instances)
  - Yields (append-only outputs)
  - Givens (dependency specifications)
  - Bindings (resolved givens, the DAG edges)
  - Claims (mutable lock + append-only log)
  - Readiness (derived from givens + yields)
  - The eval loop (claim → evaluate → freeze)
  - Pour (loading programs)
  - Stem cell lifecycle (demand-driven generation cycling)
  - DAG properties (acyclicity, content-addressing)
-/

/-! ====================================================================
    BASIC TYPES
    ==================================================================== -/

-- Identity types (all strings in SQL, opaque here)
structure CellName where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure ProgramId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure FrameId where
  val : String
  deriving Repr, DecidableEq, BEq, Hashable

structure PistonId where
  val : String
  deriving Repr, DecidableEq, BEq

structure FieldName where
  val : String
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    LAWFUL BEQ INSTANCES (needed for precondition proofs)
    ==================================================================== -/

instance : LawfulBEq CellName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq ProgramId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq FrameId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq PistonId where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

instance : LawfulBEq FieldName where
  eq_of_beq {a b} h := by
    have : a.val = b.val := eq_of_beq (α := String) h
    cases a; cases b; simp_all
  rfl {a} := beq_self_eq_true a.val

/-! ====================================================================
    CELL DEFINITIONS (immutable after pour)
    ==================================================================== -/

inductive BodyType where
  | hard     -- evaluated by SQL/literal inline
  | soft     -- evaluated by LLM piston
  | stem     -- permanently soft, cycles through generations
  deriving Repr, DecidableEq, BEq

structure CellDef where
  name      : CellName
  program   : ProgramId
  bodyType  : BodyType
  body      : String
  fields    : List FieldName    -- yield field names this cell produces
  deriving Repr, DecidableEq

-- A dependency specification (abstract, defined at pour time)
structure GivenSpec where
  cellName    : CellName        -- which cell we depend on
  sourceCell  : CellName        -- the cell whose yield we read
  sourceField : FieldName       -- which field we read
  optional    : Bool
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    FRAMES (append-only execution instances)
    ==================================================================== -/

structure Frame where
  id         : FrameId
  cellName   : CellName
  program    : ProgramId
  generation : Nat              -- 0 for non-stem, incrementing for stem
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    YIELDS (append-only outputs)
    ==================================================================== -/

structure Yield where
  frameId : FrameId
  field   : FieldName
  value   : String
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    BINDINGS (append-only resolved givens — the DAG edges)
    ==================================================================== -/

-- Records: "frame X read field F from frame Y"
structure Binding where
  consumerFrame : FrameId       -- the frame that READ
  producerFrame : FrameId       -- the frame whose yield was READ
  givenField    : FieldName     -- the field that was read
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    CLAIMS (mutable lock)
    ==================================================================== -/

structure Claim where
  frameId  : FrameId
  pistonId : PistonId
  deriving Repr, DecidableEq, BEq

-- Claim log entry (append-only audit trail)
inductive ClaimAction where
  | claimed | released | completed | timedOut
  deriving Repr, DecidableEq, BEq

structure ClaimLogEntry where
  frameId  : FrameId
  pistonId : PistonId
  action   : ClaimAction
  deriving Repr, DecidableEq

/-! ====================================================================
    THE RETORT DATABASE STATE
    ==================================================================== -/

structure Retort where
  cells    : List CellDef          -- immutable after pour
  givens   : List GivenSpec        -- immutable after pour
  frames   : List Frame            -- append-only
  yields   : List Yield            -- append-only
  bindings : List Binding          -- append-only
  claims   : List Claim            -- mutable (lock table)
  claimLog : List ClaimLogEntry    -- append-only (audit trail)
  deriving Repr

def Retort.empty : Retort :=
  { cells := [], givens := [], frames := [], yields := [],
    bindings := [], claims := [], claimLog := [] }

/-! ====================================================================
    DERIVED STATE (never stored, always computed)
    ==================================================================== -/

-- Frame status: derived from yields + claims
inductive FrameStatus where
  | declared   -- frame exists, no yields yet, not claimed
  | computing  -- frame claimed by a piston
  | frozen     -- all yields present
  deriving Repr, DecidableEq, BEq

def Retort.frameYields (r : Retort) (fid : FrameId) : List Yield :=
  r.yields.filter (fun y => y.frameId == fid)

def Retort.frameClaim (r : Retort) (fid : FrameId) : Option Claim :=
  r.claims.find? (fun c => c.frameId == fid)

def Retort.cellDef (r : Retort) (name : CellName) : Option CellDef :=
  r.cells.find? (fun c => c.name == name)

def Retort.frameStatus (r : Retort) (f : Frame) : FrameStatus :=
  match r.cellDef f.cellName with
  | none => .declared
  | some cd =>
    let frozenFields := (r.frameYields f.id).map (·.field)
    if cd.fields.all (fun fld => frozenFields.contains fld) then .frozen
    else if (r.frameClaim f.id).isSome then .computing
    else .declared

-- Current generation: highest generation with a frame for this cell
def Retort.currentGen (r : Retort) (cell : CellName) : Nat :=
  let gens := (r.frames.filter (fun f => f.cellName == cell)).map (·.generation)
  gens.foldl max 0

-- Latest frozen frame for a cell
def Retort.latestFrozenFrame (r : Retort) (cell : CellName) : Option Frame :=
  let frames := r.frames.filter (fun f => f.cellName == cell && r.frameStatus f == .frozen)
  -- Return the one with the highest generation
  frames.foldl (fun acc f => match acc with
    | none => some f
    | some best => if f.generation > best.generation then some f else acc) none

/-! ====================================================================
    READINESS (when can a frame be claimed?)
    ==================================================================== -/

-- A given is satisfiable if SOME frozen frame exists for the source cell
-- that has the required yield.  This is a readiness check only — it does NOT
-- resolve which specific frame supplies the value.  Actual resolution goes
-- through the bindings table (see resolveBindings below).
def Retort.givenSatisfiable (r : Retort) (g : GivenSpec) : Bool :=
  g.optional ||
  r.frames.any (fun f =>
    f.cellName == g.sourceCell &&
    r.frameStatus f == .frozen &&
    r.yields.any (fun y => y.frameId == f.id && y.field == g.sourceField))

-- A frame is ready if: declared AND all non-optional givens CAN be satisfied
-- (i.e. a frozen source exists for each given).  The actual binding is
-- recorded at claim/freeze time and is immutable thereafter.
def Retort.frameReady (r : Retort) (f : Frame) : Bool :=
  r.frameStatus f == .declared &&
  let cellGivens := r.givens.filter (fun g => g.cellName == f.cellName)
  cellGivens.all (fun g => r.givenSatisfiable g)

-- All ready frames in the retort
def Retort.readyFrames (r : Retort) : List Frame :=
  r.frames.filter (fun f => r.frameReady f)

/-! ====================================================================
    BINDING-BASED RESOLUTION (monotonic input lookup)
    ==================================================================== -/

-- Resolve a frame's inputs via the bindings table.
-- Bindings are recorded at claim/freeze time and are immutable, so a
-- frame's resolved inputs never change — unlike latestFrozenFrame which
-- returns a moving target.
def Retort.resolveBindings (r : Retort) (frameId : FrameId) : List (FieldName × String) :=
  r.bindings.filter (fun b => b.consumerFrame == frameId) |>.filterMap (fun b =>
    match r.yields.find? (fun y => y.frameId == b.producerFrame && y.field == b.givenField) with
    | some y => some (b.givenField, y.value)
    | none => none)

-- Monotonicity property: once a frame is frozen, every binding that
-- references it as a consumer has a corresponding producer yield that
-- exists and will never change (because yields are append-only and
-- unique per (frame, field)).
def bindingsMonotone (r : Retort) : Prop :=
  ∀ f ∈ r.frames, ∀ b ∈ r.bindings,
    b.consumerFrame = f.id →
    -- the producer frame's yield exists and won't change
    ∃ y ∈ r.yields, y.frameId = b.producerFrame ∧ y.field = b.givenField

-- Key consequence: resolveBindings returns the same values at any
-- later time, because:
--  1. bindings are append-only (never removed)
--  2. yields are append-only (never removed)
--  3. yieldUnique guarantees the value per (frame, field) is unique
-- Together these ensure the List (FieldName × String) only grows
-- (new bindings can appear) but never changes existing entries.

/-! ====================================================================
    OPERATIONS (the valid transitions)
    ==================================================================== -/

-- Pour: add cell definitions, givens, and initial frames
structure PourData where
  cells  : List CellDef
  givens : List GivenSpec
  frames : List Frame            -- gen-0 frames for non-stem cells
  deriving Repr

-- Claim: piston takes a ready frame
structure ClaimData where
  frameId  : FrameId
  pistonId : PistonId
  deriving Repr

-- Freeze: piston produces yields and records bindings
structure FreezeData where
  frameId  : FrameId
  yields   : List Yield
  bindings : List Binding
  deriving Repr

-- CreateFrame: demand detected, create next-gen frame for stem cell
structure CreateFrameData where
  frame : Frame
  deriving Repr

-- Release: piston gives up or times out
structure ReleaseData where
  frameId  : FrameId
  pistonId : PistonId
  reason   : ClaimAction         -- released | timedOut
  deriving Repr

inductive RetortOp where
  | pour        : PourData → RetortOp
  | claim       : ClaimData → RetortOp
  | freeze      : FreezeData → RetortOp
  | release     : ReleaseData → RetortOp
  | createFrame : CreateFrameData → RetortOp
  deriving Repr

def applyOp (r : Retort) : RetortOp → Retort
  | .pour pd =>
    { r with cells := r.cells ++ pd.cells,
             givens := r.givens ++ pd.givens,
             frames := r.frames ++ pd.frames }

  | .claim cd =>
    { r with claims := r.claims ++ [⟨cd.frameId, cd.pistonId⟩],
             claimLog := r.claimLog ++ [⟨cd.frameId, cd.pistonId, .claimed⟩] }

  | .freeze fd =>
    { r with yields := r.yields ++ fd.yields,
             bindings := r.bindings ++ fd.bindings,
             -- Remove claim (the only mutable operation)
             claims := r.claims.filter (fun c => c.frameId != fd.frameId),
             claimLog := r.claimLog ++ [⟨fd.frameId, ⟨"system"⟩, .completed⟩] }

  | .release rd =>
    { r with claims := r.claims.filter (fun c => c.frameId != rd.frameId),
             claimLog := r.claimLog ++ [⟨rd.frameId, rd.pistonId, rd.reason⟩] }

  | .createFrame cfd =>
    { r with frames := r.frames ++ [cfd.frame] }

/-! ====================================================================
    WELL-FORMEDNESS INVARIANTS
    ==================================================================== -/

-- I1: Cell names are unique within a program
def cellNamesUnique (r : Retort) : Prop :=
  ∀ c1 c2, c1 ∈ r.cells → c2 ∈ r.cells →
    c1.program = c2.program → c1.name = c2.name → c1 = c2

-- I2: Frame (cell, generation) pairs are unique
def framesUnique (r : Retort) : Prop :=
  ∀ f1 f2, f1 ∈ r.frames → f2 ∈ r.frames →
    f1.cellName = f2.cellName → f1.generation = f2.generation → f1 = f2

-- I3: Yields reference existing frames
def yieldsWellFormed (r : Retort) : Prop :=
  ∀ y ∈ r.yields, ∃ f ∈ r.frames, f.id = y.frameId

-- I4: Bindings reference existing frames
def bindingsWellFormed (r : Retort) : Prop :=
  ∀ b ∈ r.bindings,
    (∃ f ∈ r.frames, f.id = b.consumerFrame) ∧
    (∃ f ∈ r.frames, f.id = b.producerFrame)

-- I5: Claims reference existing frames
def claimsWellFormed (r : Retort) : Prop :=
  ∀ c ∈ r.claims, ∃ f ∈ r.frames, f.id = c.frameId

-- I6: At most one claim per frame (mutual exclusion)
def claimMutex (r : Retort) : Prop :=
  ∀ c1 c2, c1 ∈ r.claims → c2 ∈ r.claims →
    c1.frameId = c2.frameId → c1 = c2

-- I7: Each (frameId, field) pair has at most one yield (immutability)
def yieldUnique (r : Retort) : Prop :=
  ∀ y1 y2, y1 ∈ r.yields → y2 ∈ r.yields →
    y1.frameId = y2.frameId → y1.field = y2.field → y1.value = y2.value

-- I8: Stem cells have no gen-0 frame at pour time (demand-driven)
def stemCellsDemandDriven (r : Retort) : Prop :=
  ∀ f ∈ r.frames, ∀ cd ∈ r.cells,
    f.cellName = cd.name → cd.bodyType = .stem → f.generation > 0
    -- (stem cells only get frames when demand appears, starting at gen 1)
    -- Actually, gen 0 is fine if demand exists at pour time. Let's relax:
    -- The point is that stem frames are created on demand, not at pour time.
    -- We model this as: pour doesn't create frames for stem cells.

-- The complete well-formedness predicate
def wellFormed (r : Retort) : Prop :=
  cellNamesUnique r ∧ framesUnique r ∧ yieldsWellFormed r ∧
  bindingsWellFormed r ∧ claimsWellFormed r ∧ claimMutex r ∧ yieldUnique r

/-! ====================================================================
    IMMUTABILITY / APPEND-ONLY PROPERTIES
    ==================================================================== -/

-- Cells never change after pour
def cellsPreserved (before after : Retort) : Prop :=
  ∀ c ∈ before.cells, c ∈ after.cells

-- Frames only grow
def framesPreserved (before after : Retort) : Prop :=
  ∀ f ∈ before.frames, f ∈ after.frames

-- Yields only grow
def yieldsPreserved (before after : Retort) : Prop :=
  ∀ y ∈ before.yields, y ∈ after.yields

-- Bindings only grow
def bindingsPreserved (before after : Retort) : Prop :=
  ∀ b ∈ before.bindings, b ∈ after.bindings

-- Givens never change after pour
def givensPreserved (before after : Retort) : Prop :=
  ∀ g ∈ before.givens, g ∈ after.givens

-- Claim log only grows
def claimLogPreserved (before after : Retort) : Prop :=
  ∀ e ∈ before.claimLog, e ∈ after.claimLog

-- The full append-only invariant (everything except claims)
def appendOnly (before after : Retort) : Prop :=
  cellsPreserved before after ∧ framesPreserved before after ∧
  yieldsPreserved before after ∧ bindingsPreserved before after ∧
  givensPreserved before after ∧ claimLogPreserved before after

/-! ====================================================================
    PROOFS: Operations preserve append-only invariant
    ==================================================================== -/

theorem pour_appendOnly (r : Retort) (pd : PourData) :
    appendOnly r (applyOp r (.pour pd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact List.mem_append_left _ hx  -- cells
  · exact List.mem_append_left _ hx  -- frames
  · exact hx                          -- yields unchanged
  · exact hx                          -- bindings unchanged
  · exact List.mem_append_left _ hx  -- givens
  · exact hx                          -- claimLog unchanged

theorem claim_appendOnly (r : Retort) (cd : ClaimData) :
    appendOnly r (applyOp r (.claim cd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact List.mem_append_left _ hx

theorem freeze_appendOnly (r : Retort) (fd : FreezeData) :
    appendOnly r (applyOp r (.freeze fd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact List.mem_append_left _ hx   -- yields grow
  · exact List.mem_append_left _ hx   -- bindings grow
  · exact hx
  · exact List.mem_append_left _ hx   -- claimLog grows

theorem release_appendOnly (r : Retort) (rd : ReleaseData) :
    appendOnly r (applyOp r (.release rd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact List.mem_append_left _ hx

theorem createFrame_appendOnly (r : Retort) (cfd : CreateFrameData) :
    appendOnly r (applyOp r (.createFrame cfd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact List.mem_append_left _ hx  -- frames grow
  · exact hx
  · exact hx
  · exact hx
  · exact hx

-- ALL operations preserve append-only
theorem all_ops_appendOnly (r : Retort) (op : RetortOp) :
    appendOnly r (applyOp r op) := by
  cases op with
  | pour pd => exact pour_appendOnly r pd
  | claim cd => exact claim_appendOnly r cd
  | freeze fd => exact freeze_appendOnly r fd
  | release rd => exact release_appendOnly r rd
  | createFrame cfd => exact createFrame_appendOnly r cfd

/-! ====================================================================
    OPERATION PRECONDITIONS
    ==================================================================== -/

-- Precondition: a pour is valid if new cell names don't conflict with existing
-- ones within the same program.
def pourValid (r : Retort) (pd : PourData) : Prop :=
  ∀ c ∈ pd.cells, ∀ ec ∈ r.cells, c.program = ec.program → c.name ≠ ec.name

-- Precondition: new cells among themselves also have unique (program, name) pairs.
def pourInternallyUnique (_r : Retort) (pd : PourData) : Prop :=
  ∀ c1 c2, c1 ∈ pd.cells → c2 ∈ pd.cells →
    c1.program = c2.program → c1.name = c2.name → c1 = c2

-- Precondition: a claim is valid if the frame exists, is ready, and not already claimed.
def claimValid (r : Retort) (cd : ClaimData) : Prop :=
  (∃ f ∈ r.frames, f.id = cd.frameId ∧ r.frameReady f) ∧
  (r.frameClaim cd.frameId).isNone

-- Precondition: a freeze is valid if the frame is currently claimed.
def freezeValid (r : Retort) (fd : FreezeData) : Prop :=
  (r.frameClaim fd.frameId).isSome ∧
  -- yields reference the right frame
  fd.yields.all (fun y => y.frameId == fd.frameId) ∧
  -- bindings reference existing frames as consumers
  fd.bindings.all (fun b => b.consumerFrame == fd.frameId)

-- Precondition: every binding in a freeze has a matching yield in the
-- same freeze (the piston already read from a frozen producer frame, and the
-- yield must exist in the retort OR be produced by this freeze).
def freezeBindingsWitnessed (r : Retort) (fd : FreezeData) : Prop :=
  ∀ b ∈ fd.bindings,
    ∃ y ∈ r.yields ++ fd.yields,
      y.frameId = b.producerFrame ∧ y.field = b.givenField

/-! ====================================================================
    PROOFS: Well-formedness preservation
    ==================================================================== -/

-- Helper: membership in appended lists
private theorem mem_append_of_mem_left {α : Type} {x : α} {l1 l2 : List α}
    (h : x ∈ l1) : x ∈ l1 ++ l2 :=
  List.mem_append_left l2 h

private theorem mem_append_of_mem_right {α : Type} {x : α} {l1 l2 : List α}
    (h : x ∈ l2) : x ∈ l1 ++ l2 :=
  List.mem_append_right l1 h

-- Pour preserves cellNamesUnique when the pour is valid and internally unique.
theorem pour_preserves_cellNamesUnique (r : Retort) (pd : PourData)
    (hWF : cellNamesUnique r)
    (hValid : pourValid r pd)
    (hInternal : pourInternallyUnique r pd) :
    cellNamesUnique (applyOp r (.pour pd)) := by
  unfold cellNamesUnique applyOp at *
  simp only
  intro c1 c2 hc1 hc2 hProg hName
  -- c1 and c2 are each in r.cells ++ pd.cells
  rw [List.mem_append] at hc1 hc2
  cases hc1 with
  | inl hc1L =>
    cases hc2 with
    | inl hc2L =>
      -- Both from original cells: use existing wellFormedness
      exact hWF c1 c2 hc1L hc2L hProg hName
    | inr hc2R =>
      -- c1 from original, c2 from new: violates pourValid
      exfalso
      have := hValid c2 hc2R c1 hc1L (hProg.symm)
      exact this hName.symm
  | inr hc1R =>
    cases hc2 with
    | inl hc2L =>
      -- c1 from new, c2 from original: violates pourValid
      exfalso
      have := hValid c1 hc1R c2 hc2L hProg
      exact this hName
    | inr hc2R =>
      -- Both from new cells: use pourInternallyUnique
      exact hInternal c1 c2 hc1R hc2R hProg hName

-- Non-pour operations trivially preserve cellNamesUnique (cells list unchanged).
theorem non_pour_preserves_cellNamesUnique (r : Retort) (op : RetortOp)
    (hWF : cellNamesUnique r)
    (hNotPour : ∀ pd, op ≠ .pour pd) :
    cellNamesUnique (applyOp r op) := by
  -- Prove cells are unchanged by case analysis (same proof as cells_stable_non_pour)
  have hEq : (applyOp r op).cells = r.cells := by
    cases op with
    | pour pd => exact absurd rfl (hNotPour pd)
    | claim _ => rfl
    | freeze _ => rfl
    | release _ => rfl
    | createFrame _ => rfl
  unfold cellNamesUnique at *
  intro c1 c2 h1 h2
  have h1' : c1 ∈ r.cells := hEq ▸ h1
  have h2' : c2 ∈ r.cells := hEq ▸ h2
  exact hWF c1 c2 h1' h2'

-- Helper: if List.find? returns none, no element satisfies the predicate.
private theorem find?_isNone_forall_neg {α : Type} {p : α → Bool} {l : List α}
    (h : (l.find? p).isNone = true) :
    ∀ x ∈ l, p x ≠ true := by
  intro x hx hpx
  have : (l.find? p).isSome = true := by
    rw [List.find?_isSome]
    exact ⟨x, hx, hpx⟩
  cases hopt : l.find? p <;> simp_all

-- Claim adds exactly one entry to the claims list.  If claimValid ensures
-- no existing claim has the same frameId, the mutex is preserved.
theorem claim_preserves_claimMutex (r : Retort) (cd : ClaimData)
    (hWF : claimMutex r)
    (hValid : claimValid r cd) :
    claimMutex (applyOp r (.claim cd)) := by
  unfold claimMutex applyOp at *
  simp only
  intro c1 c2 hc1 hc2 hSameFrame
  rw [List.mem_append] at hc1 hc2
  -- Extract the isNone hypothesis from claimValid
  have hNoClaim : (r.claims.find? (fun c => c.frameId == cd.frameId)).isNone = true := by
    unfold claimValid Retort.frameClaim at hValid
    exact hValid.2
  have hNoPrev := find?_isNone_forall_neg hNoClaim
  cases hc1 with
  | inl hc1L =>
    cases hc2 with
    | inl hc2L =>
      exact hWF c1 c2 hc1L hc2L hSameFrame
    | inr hc2R =>
      -- c1 is old, c2 is the new claim
      exfalso
      simp at hc2R
      -- c2.frameId = cd.frameId
      have hc2fid : c2.frameId = cd.frameId := by rw [hc2R]
      -- c1.frameId = cd.frameId (via hSameFrame)
      have hc1fid : c1.frameId = cd.frameId := hSameFrame ▸ hc2fid
      -- But no old claim has frameId == cd.frameId
      exact hNoPrev c1 hc1L (by rw [hc1fid]; exact beq_self_eq_true cd.frameId)
  | inr hc1R =>
    cases hc2 with
    | inl hc2L =>
      -- c1 is new, c2 is old (symmetric)
      exfalso
      simp at hc1R
      have hc1fid : c1.frameId = cd.frameId := by rw [hc1R]
      have hc2fid : c2.frameId = cd.frameId := hSameFrame.symm ▸ hc1fid
      exact hNoPrev c2 hc2L (by rw [hc2fid]; exact beq_self_eq_true cd.frameId)
    | inr hc2R =>
      -- Both are the new claim
      simp at hc1R hc2R
      rw [hc1R, hc2R]

-- Freeze preserves bindingsMonotone: newly added bindings have witnessed yields.
theorem freeze_preserves_bindingsMonotone (r : Retort) (fd : FreezeData)
    (hWF : bindingsMonotone r)
    (hWitnessed : freezeBindingsWitnessed r fd) :
    bindingsMonotone (applyOp r (.freeze fd)) := by
  unfold bindingsMonotone applyOp at *
  simp only
  intro f hf b hb hConsumer
  rw [List.mem_append] at hb
  cases hb with
  | inl hbOld =>
    -- Old binding: use existing monotonicity, yields only grew
    obtain ⟨y, hy, hfid, hfield⟩ := hWF f hf b hbOld hConsumer
    exact ⟨y, List.mem_append_left _ hy, hfid, hfield⟩
  | inr hbNew =>
    -- New binding from this freeze: use freezeBindingsWitnessed
    unfold freezeBindingsWitnessed at hWitnessed
    obtain ⟨y, hy, hfid, hfield⟩ := hWitnessed b hbNew
    exact ⟨y, hy, hfid, hfield⟩

-- Release and createFrame trivially preserve claimMutex and bindingsMonotone,
-- since they don't add claims or bindings (release only removes claims).

-- Release preserves claimMutex (it only removes claims via filter).
theorem release_preserves_claimMutex (r : Retort) (rd : ReleaseData)
    (hWF : claimMutex r) :
    claimMutex (applyOp r (.release rd)) := by
  unfold claimMutex applyOp at *
  simp only
  intro c1 c2 hc1 hc2 hSameFrame
  rw [List.mem_filter] at hc1 hc2
  exact hWF c1 c2 hc1.1 hc2.1 hSameFrame

-- Freeze preserves claimMutex (it only removes claims via filter).
theorem freeze_preserves_claimMutex (r : Retort) (fd : FreezeData)
    (hWF : claimMutex r) :
    claimMutex (applyOp r (.freeze fd)) := by
  unfold claimMutex applyOp at *
  simp only
  intro c1 c2 hc1 hc2 hSameFrame
  rw [List.mem_filter] at hc1 hc2
  exact hWF c1 c2 hc1.1 hc2.1 hSameFrame

/-! ====================================================================
    PROOFS: Remaining invariant preservation (I2, I3, I4, I5, I7)
    ==================================================================== -/

/-! I2: framesUnique preservation -/

-- Precondition: poured frames don't conflict with existing frames on (cell, gen),
-- and are internally unique on (cell, gen).
def pourFramesUnique (r : Retort) (pd : PourData) : Prop :=
  -- New frames don't conflict with existing
  (∀ nf ∈ pd.frames, ∀ ef ∈ r.frames,
    nf.cellName = ef.cellName → nf.generation = ef.generation → nf = ef) ∧
  -- New frames are internally unique
  (∀ f1 f2, f1 ∈ pd.frames → f2 ∈ pd.frames →
    f1.cellName = f2.cellName → f1.generation = f2.generation → f1 = f2)

-- Precondition: created frame doesn't conflict with existing frames on (cell, gen).
def createFrameUnique (r : Retort) (cfd : CreateFrameData) : Prop :=
  ∀ ef ∈ r.frames,
    cfd.frame.cellName = ef.cellName → cfd.frame.generation = ef.generation → cfd.frame = ef

-- Pour preserves framesUnique when poured frames are compatible.
theorem pour_preserves_framesUnique (r : Retort) (pd : PourData)
    (hWF : framesUnique r)
    (hCompat : pourFramesUnique r pd) :
    framesUnique (applyOp r (.pour pd)) := by
  unfold framesUnique applyOp at *
  simp only
  intro f1 f2 hf1 hf2 hCell hGen
  rw [List.mem_append] at hf1 hf2
  cases hf1 with
  | inl hf1L =>
    cases hf2 with
    | inl hf2L => exact hWF f1 f2 hf1L hf2L hCell hGen
    | inr hf2R => exact (hCompat.1 f2 hf2R f1 hf1L hCell.symm hGen.symm).symm
  | inr hf1R =>
    cases hf2 with
    | inl hf2L => exact hCompat.1 f1 hf1R f2 hf2L hCell hGen
    | inr hf2R => exact hCompat.2 f1 f2 hf1R hf2R hCell hGen

-- CreateFrame preserves framesUnique when the new frame is compatible.
theorem createFrame_preserves_framesUnique (r : Retort) (cfd : CreateFrameData)
    (hWF : framesUnique r)
    (hCompat : createFrameUnique r cfd) :
    framesUnique (applyOp r (.createFrame cfd)) := by
  unfold framesUnique applyOp at *
  simp only
  intro f1 f2 hf1 hf2 hCell hGen
  rw [List.mem_append] at hf1 hf2
  cases hf1 with
  | inl hf1L =>
    cases hf2 with
    | inl hf2L => exact hWF f1 f2 hf1L hf2L hCell hGen
    | inr hf2R =>
      simp at hf2R
      subst hf2R
      exact (hCompat f1 hf1L hCell.symm hGen.symm).symm
  | inr hf1R =>
    cases hf2 with
    | inl hf2L =>
      simp at hf1R
      subst hf1R
      exact hCompat f2 hf2L hCell hGen
    | inr hf2R =>
      simp at hf1R hf2R
      rw [hf1R, hf2R]

-- Non-frame-adding operations trivially preserve framesUnique.
theorem claim_preserves_framesUnique (r : Retort) (cd : ClaimData)
    (hWF : framesUnique r) :
    framesUnique (applyOp r (.claim cd)) := by
  unfold framesUnique applyOp at *; simp only; exact hWF

theorem freeze_preserves_framesUnique (r : Retort) (fd : FreezeData)
    (hWF : framesUnique r) :
    framesUnique (applyOp r (.freeze fd)) := by
  unfold framesUnique applyOp at *; simp only; exact hWF

theorem release_preserves_framesUnique (r : Retort) (rd : ReleaseData)
    (hWF : framesUnique r) :
    framesUnique (applyOp r (.release rd)) := by
  unfold framesUnique applyOp at *; simp only; exact hWF

/-! I3: yieldsWellFormed preservation -/

-- Freeze adds yields. The freezeValid precondition ensures all new yields
-- reference fd.frameId, and the frame must exist (it's claimed).
-- We need: the claimed frame exists in r.frames.
def freezeFrameExists (r : Retort) (fd : FreezeData) : Prop :=
  ∃ f ∈ r.frames, f.id = fd.frameId

theorem freeze_preserves_yieldsWellFormed (r : Retort) (fd : FreezeData)
    (hWF : yieldsWellFormed r)
    (hValid : freezeValid r fd)
    (hExists : freezeFrameExists r fd) :
    yieldsWellFormed (applyOp r (.freeze fd)) := by
  unfold yieldsWellFormed applyOp at *
  simp only
  intro y hy
  rw [List.mem_append] at hy
  cases hy with
  | inl hyOld =>
    -- Old yield: frame still exists (frames unchanged by freeze)
    obtain ⟨f, hf, hfid⟩ := hWF y hyOld
    exact ⟨f, hf, hfid⟩
  | inr hyNew =>
    -- New yield from this freeze: its frameId = fd.frameId (by freezeValid)
    unfold freezeValid at hValid
    have hAll := hValid.2.1
    rw [List.all_eq_true] at hAll
    have hBeq := hAll y hyNew
    simp at hBeq
    obtain ⟨f, hf, hfid⟩ := hExists
    exact ⟨f, hf, hBeq ▸ hfid⟩

-- Non-yield-adding operations trivially preserve yieldsWellFormed.
-- (pour adds frames but not yields, claim/release/createFrame don't add yields)
theorem pour_preserves_yieldsWellFormed (r : Retort) (pd : PourData)
    (hWF : yieldsWellFormed r) :
    yieldsWellFormed (applyOp r (.pour pd)) := by
  unfold yieldsWellFormed applyOp at *
  simp only
  intro y hy
  obtain ⟨f, hf, hfid⟩ := hWF y hy
  exact ⟨f, List.mem_append_left _ hf, hfid⟩

theorem claim_preserves_yieldsWellFormed (r : Retort) (cd : ClaimData)
    (hWF : yieldsWellFormed r) :
    yieldsWellFormed (applyOp r (.claim cd)) := by
  unfold yieldsWellFormed applyOp at *; simp only; exact hWF

theorem release_preserves_yieldsWellFormed (r : Retort) (rd : ReleaseData)
    (hWF : yieldsWellFormed r) :
    yieldsWellFormed (applyOp r (.release rd)) := by
  unfold yieldsWellFormed applyOp at *; simp only; exact hWF

theorem createFrame_preserves_yieldsWellFormed (r : Retort) (cfd : CreateFrameData)
    (hWF : yieldsWellFormed r) :
    yieldsWellFormed (applyOp r (.createFrame cfd)) := by
  unfold yieldsWellFormed applyOp at *
  simp only
  intro y hy
  obtain ⟨f, hf, hfid⟩ := hWF y hy
  exact ⟨f, List.mem_append_left _ hf, hfid⟩

/-! I4: bindingsWellFormed preservation -/

-- Freeze adds bindings. freezeValid ensures consumer = fd.frameId.
-- We also need producer frames to exist: freezeBindingsWitnessed guarantees
-- a yield exists for each producer, and yieldsWellFormed ensures those
-- yields reference existing frames. But for a direct proof, we ask that
-- the producer frames exist in r.frames.
def freezeBindingsRefFrames (r : Retort) (fd : FreezeData) : Prop :=
  ∀ b ∈ fd.bindings,
    (∃ f ∈ r.frames, f.id = b.producerFrame)

theorem freeze_preserves_bindingsWellFormed (r : Retort) (fd : FreezeData)
    (hWF : bindingsWellFormed r)
    (hValid : freezeValid r fd)
    (hFrameExists : freezeFrameExists r fd)
    (hProducers : freezeBindingsRefFrames r fd) :
    bindingsWellFormed (applyOp r (.freeze fd)) := by
  unfold bindingsWellFormed applyOp at *
  simp only
  intro b hb
  rw [List.mem_append] at hb
  cases hb with
  | inl hbOld =>
    obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF b hbOld
    exact ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩
  | inr hbNew =>
    constructor
    · -- Consumer frame exists: b.consumerFrame = fd.frameId (by freezeValid)
      unfold freezeValid at hValid
      have hAll := hValid.2.2
      rw [List.all_eq_true] at hAll
      have hBeq := hAll b hbNew
      simp at hBeq
      obtain ⟨f, hf, hfid⟩ := hFrameExists
      exact ⟨f, hf, hBeq ▸ hfid⟩
    · -- Producer frame exists: by freezeBindingsRefFrames
      exact hProducers b hbNew

-- Non-binding-adding operations trivially preserve bindingsWellFormed.
theorem pour_preserves_bindingsWellFormed (r : Retort) (pd : PourData)
    (hWF : bindingsWellFormed r) :
    bindingsWellFormed (applyOp r (.pour pd)) := by
  unfold bindingsWellFormed applyOp at *
  simp only
  intro b hb
  obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF b hb
  exact ⟨⟨fc, List.mem_append_left _ hfc, hfcid⟩, ⟨fp, List.mem_append_left _ hfp, hfpid⟩⟩

theorem claim_preserves_bindingsWellFormed (r : Retort) (cd : ClaimData)
    (hWF : bindingsWellFormed r) :
    bindingsWellFormed (applyOp r (.claim cd)) := by
  unfold bindingsWellFormed applyOp at *; simp only; exact hWF

theorem release_preserves_bindingsWellFormed (r : Retort) (rd : ReleaseData)
    (hWF : bindingsWellFormed r) :
    bindingsWellFormed (applyOp r (.release rd)) := by
  unfold bindingsWellFormed applyOp at *; simp only; exact hWF

theorem createFrame_preserves_bindingsWellFormed (r : Retort) (cfd : CreateFrameData)
    (hWF : bindingsWellFormed r) :
    bindingsWellFormed (applyOp r (.createFrame cfd)) := by
  unfold bindingsWellFormed applyOp at *
  simp only
  intro b hb
  obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF b hb
  exact ⟨⟨fc, List.mem_append_left _ hfc, hfcid⟩, ⟨fp, List.mem_append_left _ hfp, hfpid⟩⟩

/-! I5: claimsWellFormed preservation -/

-- Claim adds one claim. claimValid ensures the frame exists.
theorem claim_preserves_claimsWellFormed (r : Retort) (cd : ClaimData)
    (hWF : claimsWellFormed r)
    (hValid : claimValid r cd) :
    claimsWellFormed (applyOp r (.claim cd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  intro c hc
  rw [List.mem_append] at hc
  cases hc with
  | inl hcOld => exact hWF c hcOld
  | inr hcNew =>
    simp at hcNew
    rw [hcNew]
    unfold claimValid at hValid
    obtain ⟨⟨f, hf, hfid, _⟩, _⟩ := hValid
    exact ⟨f, hf, hfid⟩

-- Freeze removes claims via filter: subset of original claims.
theorem freeze_preserves_claimsWellFormed (r : Retort) (fd : FreezeData)
    (hWF : claimsWellFormed r) :
    claimsWellFormed (applyOp r (.freeze fd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  intro c hc
  rw [List.mem_filter] at hc
  exact hWF c hc.1

-- Release removes claims via filter.
theorem release_preserves_claimsWellFormed (r : Retort) (rd : ReleaseData)
    (hWF : claimsWellFormed r) :
    claimsWellFormed (applyOp r (.release rd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  intro c hc
  rw [List.mem_filter] at hc
  exact hWF c hc.1

-- Pour doesn't change claims; frames grow so references still valid.
theorem pour_preserves_claimsWellFormed (r : Retort) (pd : PourData)
    (hWF : claimsWellFormed r) :
    claimsWellFormed (applyOp r (.pour pd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  intro c hc
  obtain ⟨f, hf, hfid⟩ := hWF c hc
  exact ⟨f, List.mem_append_left _ hf, hfid⟩

-- CreateFrame doesn't change claims; frames grow.
theorem createFrame_preserves_claimsWellFormed (r : Retort) (cfd : CreateFrameData)
    (hWF : claimsWellFormed r) :
    claimsWellFormed (applyOp r (.createFrame cfd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  intro c hc
  obtain ⟨f, hf, hfid⟩ := hWF c hc
  exact ⟨f, List.mem_append_left _ hf, hfid⟩

/-! I7: yieldUnique preservation -/

-- Precondition: freeze yields are internally unique (no duplicate frame/field pairs)
-- and don't conflict with existing yields.
def freezeYieldsUnique (r : Retort) (fd : FreezeData) : Prop :=
  -- New yields are internally unique on (frameId, field)
  (∀ y1 y2, y1 ∈ fd.yields → y2 ∈ fd.yields →
    y1.frameId = y2.frameId → y1.field = y2.field → y1.value = y2.value) ∧
  -- New yields don't conflict with existing yields
  (∀ ny ∈ fd.yields, ∀ ey ∈ r.yields,
    ny.frameId = ey.frameId → ny.field = ey.field → ny.value = ey.value)

theorem freeze_preserves_yieldUnique (r : Retort) (fd : FreezeData)
    (hWF : yieldUnique r)
    (hFresh : freezeYieldsUnique r fd) :
    yieldUnique (applyOp r (.freeze fd)) := by
  unfold yieldUnique applyOp at *
  simp only
  intro y1 y2 hy1 hy2 hfid hfield
  rw [List.mem_append] at hy1 hy2
  cases hy1 with
  | inl hy1Old =>
    cases hy2 with
    | inl hy2Old => exact hWF y1 y2 hy1Old hy2Old hfid hfield
    | inr hy2New => exact (hFresh.2 y2 hy2New y1 hy1Old hfid.symm hfield.symm).symm
  | inr hy1New =>
    cases hy2 with
    | inl hy2Old => exact hFresh.2 y1 hy1New y2 hy2Old hfid hfield
    | inr hy2New => exact hFresh.1 y1 y2 hy1New hy2New hfid hfield

-- Non-yield-adding operations trivially preserve yieldUnique.
theorem pour_preserves_yieldUnique (r : Retort) (pd : PourData)
    (hWF : yieldUnique r) :
    yieldUnique (applyOp r (.pour pd)) := by
  unfold yieldUnique applyOp at *; simp only; exact hWF

theorem claim_preserves_yieldUnique (r : Retort) (cd : ClaimData)
    (hWF : yieldUnique r) :
    yieldUnique (applyOp r (.claim cd)) := by
  unfold yieldUnique applyOp at *; simp only; exact hWF

theorem release_preserves_yieldUnique (r : Retort) (rd : ReleaseData)
    (hWF : yieldUnique r) :
    yieldUnique (applyOp r (.release rd)) := by
  unfold yieldUnique applyOp at *; simp only; exact hWF

theorem createFrame_preserves_yieldUnique (r : Retort) (cfd : CreateFrameData)
    (hWF : yieldUnique r) :
    yieldUnique (applyOp r (.createFrame cfd)) := by
  unfold yieldUnique applyOp at *; simp only; exact hWF

/-! ====================================================================
    POSTCONDITION THEOREMS
    ==================================================================== -/

-- Claim actually adds a claim (claims list grows by exactly one).
theorem claim_adds_claim (r : Retort) (cd : ClaimData) :
    (applyOp r (.claim cd)).claims.length = r.claims.length + 1 := by
  simp [applyOp, List.length_append]

-- Freeze actually removes the claim: if a claim existed for that frame,
-- the resulting claims list is strictly shorter.
-- Helper: List.filter removing at least one element decreases length.
private theorem filter_remove_decreases {α : Type} (p : α → Bool) (l : List α) (x : α)
    (hx : x ∈ l) (hpx : p x = false) :
    (l.filter p).length < l.length := by
  induction l generalizing x with
  | nil => simp at hx
  | cons a t ih =>
    cases hpa : p a with
    | false =>
      simp [List.filter, hpa]
      exact Nat.lt_succ_of_le (List.length_filter_le p t)
    | true =>
      rcases List.mem_cons.mp hx with heq | ht
      · subst heq; simp [hpx] at hpa
      · have ihResult := ih x ht hpx
        show (List.filter p (a :: t)).length < (a :: t).length
        rw [List.filter_cons, if_pos hpa]
        simp only [List.length_cons]
        omega

theorem freeze_removes_claim (r : Retort) (fd : FreezeData)
    (hClaimed : (r.frameClaim fd.frameId).isSome) :
    (applyOp r (.freeze fd)).claims.length < r.claims.length := by
  unfold applyOp
  simp only
  unfold Retort.frameClaim at hClaimed
  have hSome := List.find?_isSome.mp hClaimed
  obtain ⟨c, hc, hpc⟩ := hSome
  apply filter_remove_decreases _ r.claims c hc
  have hEq : c.frameId = fd.frameId := eq_of_beq hpc
  simp [hEq]

-- CreateFrame adds exactly one frame, and that frame is in the result.
theorem createFrame_adds_frame (r : Retort) (cfd : CreateFrameData) :
    cfd.frame ∈ (applyOp r (.createFrame cfd)).frames := by
  unfold applyOp
  simp only
  exact List.mem_append_right _ (List.mem_singleton.mpr rfl)

/-! ====================================================================
    PROGRESS THEOREM (liveness: ready frames can always be claimed)
    ==================================================================== -/

-- Well-formedness condition: every frame has a cell definition.
-- This is a natural invariant: frames are created from cell definitions.
def framesCellDefsExist (r : Retort) : Prop :=
  ∀ f ∈ r.frames, (r.cellDef f.cellName).isSome

-- Helper: when cellDef is some, frameStatus = declared implies frameClaim is none.
-- This is because the 'some cd' branch of frameStatus returns .declared only
-- when (a) not all fields are frozen AND (b) frameClaim is none.
private theorem declared_of_some_implies_no_claim (r : Retort) (f : Frame) (cd : CellDef)
    (hCellDef : r.cellDef f.cellName = some cd)
    (hStatus : r.frameStatus f = .declared) :
    (r.frameClaim f.id).isNone = true := by
  -- Expand frameStatus and substitute the cellDef
  unfold Retort.frameStatus at hStatus
  rw [hCellDef] at hStatus
  -- Now hStatus has the form: (if allFrozen then .frozen else if claimed then .computing else .declared) = .declared
  -- Case split on frameClaim
  cases hClaim : r.frameClaim f.id with
  | none => rfl
  | some c =>
    -- frameClaim is some c, so isSome = true
    -- In the `some cd` branch of frameStatus, if not all fields frozen, we'd get .computing
    -- If all fields frozen, we'd get .frozen
    -- Neither is .declared, so hStatus is contradictory
    exfalso
    simp only [hClaim, Option.isSome] at hStatus
    -- After simp, hStatus should have the if-then-else with isSome resolved to true
    -- so we get: if allFrozen then .frozen else .computing = .declared
    split at hStatus <;> simp at hStatus

-- Helper: FrameStatus BEq equality to Prop equality.
-- The derived BEq on FrameStatus uses DecidableEq, so we use that.
private theorem FrameStatus.eq_of_beq_true : ∀ (a b : FrameStatus),
    (a == b) = true → a = b := by
  intro a b h
  have : DecidableEq FrameStatus := inferInstance
  cases a <;> cases b <;> first | rfl | (revert h; decide)

-- Key liveness result: if readyFrames is non-empty, there exists a valid ClaimData.
-- Requires that every frame has a cell definition (natural well-formedness).
theorem progress (r : Retort) (f : Frame)
    (hReady : f ∈ r.readyFrames)
    (hCellDefs : framesCellDefsExist r) :
    ∃ cd : ClaimData, claimValid r cd := by
  -- Decompose readyFrames membership: f ∈ r.frames and frameReady f = true
  unfold Retort.readyFrames at hReady
  rw [List.mem_filter] at hReady
  obtain ⟨hMem, hFrameReady⟩ := hReady
  -- frameReady f = true means frameStatus f == .declared ∧ all givens satisfied
  unfold Retort.frameReady at hFrameReady
  have hStatusBool : (r.frameStatus f == FrameStatus.declared) = true := by
    revert hFrameReady
    simp only [Bool.and_eq_true]
    exact fun ⟨h, _⟩ => h
  have hStatus : r.frameStatus f = .declared :=
    FrameStatus.eq_of_beq_true _ _ hStatusBool
  -- Since f ∈ r.frames and framesCellDefsExist, cellDef exists
  have hCellDefSome := hCellDefs f hMem
  obtain ⟨cd, hCd⟩ := Option.isSome_iff_exists.mp hCellDefSome
  -- Since cellDef is some and frameStatus is declared, frameClaim is none
  have hNoClaim := declared_of_some_implies_no_claim r f cd hCd hStatus
  -- Construct the witness: use f.id as frameId, any pistonId
  refine ⟨⟨f.id, ⟨"progress_witness"⟩⟩, ?_⟩
  unfold claimValid
  constructor
  · -- The frame exists and is ready
    exact ⟨f, hMem, rfl, hFrameReady⟩
  · -- frameClaim is none
    exact hNoClaim

/-! ====================================================================
    REMAINING POSTCONDITIONS
    ==================================================================== -/

-- Postcondition: poured cells are in the result.
theorem pour_adds_cells (r : Retort) (pd : PourData) (c : CellDef)
    (hc : c ∈ pd.cells) :
    c ∈ (applyOp r (.pour pd)).cells := by
  unfold applyOp
  simp only
  exact List.mem_append_right _ hc

-- Postcondition: poured frames are in the result.
theorem pour_adds_frames (r : Retort) (pd : PourData) (f : Frame)
    (hf : f ∈ pd.frames) :
    f ∈ (applyOp r (.pour pd)).frames := by
  unfold applyOp
  simp only
  exact List.mem_append_right _ hf

-- Postcondition: after freeze, if the cell definition exists and the freeze
-- yields cover all fields of the cell, the frame's status is frozen.
theorem freeze_makes_frozen (r : Retort) (fd : FreezeData) (f : Frame) (cd : CellDef)
    (_hFrame : f ∈ r.frames)
    (_hFrameId : f.id = fd.frameId)
    (hCellDef : (applyOp r (.freeze fd)).cellDef f.cellName = some cd)
    (hCovers : cd.fields.all (fun fld =>
      ((r.yields ++ fd.yields).filter (fun y => y.frameId == f.id)).map (·.field)
        |>.contains fld)) :
    (applyOp r (.freeze fd)).frameStatus f = .frozen := by
  unfold Retort.frameStatus
  -- cellDef for applyOp (.freeze fd) is the same as r's (cells unchanged)
  rw [hCellDef]
  -- The frameYields of the result = r.yields ++ fd.yields, filtered by frameId
  unfold Retort.frameYields applyOp
  simp only
  -- Goal: if (cd.fields.all ...) then .frozen else ... = .frozen
  -- The condition matches hCovers exactly
  rw [if_pos hCovers]

/-! ====================================================================
    COMPOSITE WELL-FORMEDNESS PRESERVATION
    ==================================================================== -/

-- Aggregate precondition: what makes an operation valid for wellFormed preservation.
def validOp (r : Retort) : RetortOp → Prop
  | .pour pd =>
    pourValid r pd ∧ pourInternallyUnique r pd ∧ pourFramesUnique r pd
  | .claim cd =>
    claimValid r cd
  | .freeze fd =>
    freezeValid r fd ∧ freezeBindingsWitnessed r fd ∧
    freezeFrameExists r fd ∧ freezeBindingsRefFrames r fd ∧
    freezeYieldsUnique r fd
  | .release _ => True
  | .createFrame cfd => createFrameUnique r cfd

-- The master preservation theorem: any valid operation preserves wellFormed.
theorem wellFormed_preserved (r : Retort) (op : RetortOp)
    (hWF : wellFormed r)
    (hValid : validOp r op) :
    wellFormed (applyOp r op) := by
  unfold wellFormed at *
  obtain ⟨hI1, hI2, hI3, hI4, hI5, hI6, hI7⟩ := hWF
  cases op with
  | pour pd =>
    unfold validOp at hValid
    obtain ⟨hPourValid, hPourInternal, hPourFrames⟩ := hValid
    exact ⟨pour_preserves_cellNamesUnique r pd hI1 hPourValid hPourInternal,
           pour_preserves_framesUnique r pd hI2 hPourFrames,
           pour_preserves_yieldsWellFormed r pd hI3,
           pour_preserves_bindingsWellFormed r pd hI4,
           pour_preserves_claimsWellFormed r pd hI5,
           -- pour doesn't add claims, claimMutex trivially preserved
           (by unfold claimMutex applyOp at *; simp only; exact hI6),
           pour_preserves_yieldUnique r pd hI7⟩
  | claim cd =>
    unfold validOp at hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           claim_preserves_framesUnique r cd hI2,
           claim_preserves_yieldsWellFormed r cd hI3,
           claim_preserves_bindingsWellFormed r cd hI4,
           claim_preserves_claimsWellFormed r cd hI5 hValid,
           claim_preserves_claimMutex r cd hI6 hValid,
           claim_preserves_yieldUnique r cd hI7⟩
  | freeze fd =>
    unfold validOp at hValid
    obtain ⟨hFreezeValid, hWitnessed, hFrameExists, hProducers, hYieldsUnique⟩ := hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           freeze_preserves_framesUnique r fd hI2,
           freeze_preserves_yieldsWellFormed r fd hI3 hFreezeValid hFrameExists,
           freeze_preserves_bindingsWellFormed r fd hI4 hFreezeValid hFrameExists hProducers,
           freeze_preserves_claimsWellFormed r fd hI5,
           freeze_preserves_claimMutex r fd hI6,
           freeze_preserves_yieldUnique r fd hI7 hYieldsUnique⟩
  | release rd =>
    unfold validOp at hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           release_preserves_framesUnique r rd hI2,
           release_preserves_yieldsWellFormed r rd hI3,
           release_preserves_bindingsWellFormed r rd hI4,
           release_preserves_claimsWellFormed r rd hI5,
           release_preserves_claimMutex r rd hI6,
           release_preserves_yieldUnique r rd hI7⟩
  | createFrame cfd =>
    unfold validOp at hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           createFrame_preserves_framesUnique r cfd hI2 hValid,
           createFrame_preserves_yieldsWellFormed r cfd hI3,
           createFrame_preserves_bindingsWellFormed r cfd hI4,
           createFrame_preserves_claimsWellFormed r cfd hI5,
           -- createFrame doesn't change claims
           (by unfold claimMutex applyOp at *; simp only; exact hI6),
           createFrame_preserves_yieldUnique r cfd hI7⟩

/-! ====================================================================
    PROOFS: Cells are stable after pour
    ==================================================================== -/

-- Non-pour operations never change the cells list
theorem cells_stable_non_pour (r : Retort) (op : RetortOp)
    (hNotPour : ∀ pd, op ≠ .pour pd) :
    (applyOp r op).cells = r.cells := by
  cases op with
  | pour pd => exact absurd rfl (hNotPour pd)
  | claim _ => rfl
  | freeze _ => rfl
  | release _ => rfl
  | createFrame _ => rfl

-- Non-pour operations never change the givens list
theorem givens_stable_non_pour (r : Retort) (op : RetortOp)
    (hNotPour : ∀ pd, op ≠ .pour pd) :
    (applyOp r op).givens = r.givens := by
  cases op with
  | pour pd => exact absurd rfl (hNotPour pd)
  | claim _ => rfl
  | freeze _ => rfl
  | release _ => rfl
  | createFrame _ => rfl

/-! ====================================================================
    THE DAG: Acyclicity of Bindings
    ==================================================================== -/

-- A binding edge goes from consumer to producer.
-- The DAG property: no frame transitively depends on itself.

-- Simple acyclicity: no self-loops
def noSelfLoops (r : Retort) : Prop :=
  ∀ b ∈ r.bindings, b.consumerFrame ≠ b.producerFrame

-- Stronger: for same-cell bindings (stem cells reading own previous gen),
-- the producer must have a strictly lower generation
def generationOrdered (r : Retort) : Prop :=
  ∀ b ∈ r.bindings,
    ∀ cf ∈ r.frames, ∀ pf ∈ r.frames,
      cf.id = b.consumerFrame → pf.id = b.producerFrame →
      cf.cellName = pf.cellName →
      pf.generation < cf.generation

-- Bindings only point to frozen frames (can't read from the future)
def bindingsPointToFrozen (r : Retort) : Prop :=
  ∀ b ∈ r.bindings,
    ∃ f ∈ r.frames, f.id = b.producerFrame ∧ r.frameStatus f = .frozen

-- freeze creates well-formed bindings (producer frames must be frozen)
-- This is enforced by construction: at freeze time, the piston has
-- already read the producer's yields (which means they're frozen).

/-! ====================================================================
    THE EVAL LOOP (as a state machine)
    ==================================================================== -/

-- The eval loop for a single cycle:
-- 1. Find a ready frame
-- 2. Claim it
-- 3. Evaluate (external — the piston does this)
-- 4. Freeze yields + record bindings
-- 5. If stem cell AND more demand: create next-gen frame

-- We model this as a sequence of RetortOps
structure EvalCycle where
  claimOp   : ClaimData
  freezeOp  : FreezeData
  nextFrame : Option CreateFrameData  -- Some if stem cell with more demand
  deriving Repr

def applyEvalCycle (r : Retort) (ec : EvalCycle) : Retort :=
  let r1 := applyOp r (.claim ec.claimOp)
  let r2 := applyOp r1 (.freeze ec.freezeOp)
  match ec.nextFrame with
  | none => r2
  | some cfd => applyOp r2 (.createFrame cfd)

-- An eval cycle preserves append-only
theorem evalCycle_appendOnly (r : Retort) (ec : EvalCycle) :
    appendOnly r (applyEvalCycle r ec) := by
  unfold applyEvalCycle
  have h1 := all_ops_appendOnly r (.claim ec.claimOp)
  have h2 := all_ops_appendOnly (applyOp r (.claim ec.claimOp)) (.freeze ec.freezeOp)
  -- Transitivity of appendOnly
  cases ec.nextFrame with
  | none =>
    simp
    unfold appendOnly at *
    obtain ⟨hc1, hf1, hy1, hb1, hg1, hl1⟩ := h1
    obtain ⟨hc2, hf2, hy2, hb2, hg2, hl2⟩ := h2
    exact ⟨fun x hx => hc2 x (hc1 x hx), fun x hx => hf2 x (hf1 x hx),
           fun x hx => hy2 x (hy1 x hx), fun x hx => hb2 x (hb1 x hx),
           fun x hx => hg2 x (hg1 x hx), fun x hx => hl2 x (hl1 x hx)⟩
  | some cfd =>
    simp
    have h3 := all_ops_appendOnly
      (applyOp (applyOp r (.claim ec.claimOp)) (.freeze ec.freezeOp))
      (.createFrame cfd)
    unfold appendOnly at *
    obtain ⟨hc1, hf1, hy1, hb1, hg1, hl1⟩ := h1
    obtain ⟨hc2, hf2, hy2, hb2, hg2, hl2⟩ := h2
    obtain ⟨hc3, hf3, hy3, hb3, hg3, hl3⟩ := h3
    exact ⟨fun x hx => hc3 x (hc2 x (hc1 x hx)),
           fun x hx => hf3 x (hf2 x (hf1 x hx)),
           fun x hx => hy3 x (hy2 x (hy1 x hx)),
           fun x hx => hb3 x (hb2 x (hb1 x hx)),
           fun x hx => hg3 x (hg2 x (hg1 x hx)),
           fun x hx => hl3 x (hl2 x (hl1 x hx))⟩

/-! ====================================================================
    PROGRAM SEMANTICS
    ==================================================================== -/

-- A program is complete when all its non-stem frames are frozen
def Retort.programComplete (r : Retort) (prog : ProgramId) : Bool :=
  let progFrames := r.frames.filter (fun f => f.program == prog)
  let progCells := r.cells.filter (fun c => c.program == prog)
  -- Every non-stem cell has a frozen frame
  progCells.all (fun cd =>
    cd.bodyType == .stem ||
    progFrames.any (fun f => f.cellName == cd.name && r.frameStatus f == .frozen))

-- A program is quiescent when: complete OR no ready frames
def Retort.programQuiescent (r : Retort) (prog : ProgramId) : Bool :=
  r.programComplete prog ||
  (r.readyFrames.filter (fun f => f.program == prog)).isEmpty

/-! ====================================================================
    STEM CELL LIFECYCLE
    ==================================================================== -/

-- Stem cell demand: is there work for this stem cell?
-- For eval-one: any non-cell-zero-eval ready frame exists
-- For pour-one: any pour-request frame exists

-- Abstract: a stem cell has demand if its query predicate is true
def Retort.stemHasDemand (r : Retort) (_cell : CellName) (demandPred : Retort → Bool) : Bool :=
  demandPred r

-- After an eval cycle on a stem cell:
-- 1. Its frame is frozen (yields written)
-- 2. If demand still exists, a new frame is created at gen+1
-- 3. The new frame starts as declared
-- 4. It becomes ready when demand exists (query given satisfied)

-- The stem cell generation sequence
def stemGenerations (r : Retort) (cell : CellName) : List Nat :=
  (r.frames.filter (fun f => f.cellName == cell)).map (·.generation)

-- Each generation has at most one frame (content-addressed)
def stemFrameUnique (r : Retort) (cell : CellName) : Prop :=
  ∀ f1 f2, f1 ∈ r.frames → f2 ∈ r.frames →
    f1.cellName = cell → f2.cellName = cell →
    f1.generation = f2.generation → f1 = f2

/-! ====================================================================
    CONTENT ADDRESSING
    ==================================================================== -/

-- A yield is addressed by (cellName, generation, field)
structure ContentAddr where
  cellName   : CellName
  generation : Nat
  field      : FieldName
  deriving Repr, DecidableEq, BEq

-- Resolve a content address to a value
def Retort.resolve (r : Retort) (addr : ContentAddr) : Option String :=
  -- Find the frame for this cell at this generation
  match r.frames.find? (fun f => f.cellName == addr.cellName && f.generation == addr.generation) with
  | none => none
  | some frame =>
    -- Find the yield for this frame and field
    match r.yields.find? (fun y => y.frameId == frame.id && y.field == addr.field) with
    | none => none
    | some yield => some yield.value

-- Content addresses from different generations never collide
-- (because the frame lookup filters by generation)
-- Helper: BEq → Prop equality for CellName (derived BEq compares the inner String)
private theorem CellName.eq_of_beq (a b : CellName) (h : (a == b) = true) : a = b := by
  cases a with | mk va => cases b with | mk vb =>
  exact congrArg CellName.mk (beq_iff_eq.mp (show (va == vb) = true from h))

theorem content_addr_distinct_gens (r : Retort)
    (cell : CellName) (field : FieldName) (g1 g2 : Nat) (v1 v2 : String)
    (h1 : r.resolve ⟨cell, g1, field⟩ = some v1)
    (h2 : r.resolve ⟨cell, g2, field⟩ = some v2)
    (hDiff : g1 ≠ g2)
    (_hUnique : framesUnique r) :
    -- The values come from different frames
    ∃ f1 f2 : Frame, f1 ∈ r.frames ∧ f2 ∈ r.frames ∧
      f1.cellName = cell ∧ f2.cellName = cell ∧
      f1.generation = g1 ∧ f2.generation = g2 ∧ f1 ≠ f2 := by
  unfold Retort.resolve at h1 h2
  -- Split on the outer find? (frame lookup) in h1
  split at h1
  · exact absurd h1 (by simp)
  · rename_i frame1 hfind1
    -- Split on the inner find? (yield lookup) in h1
    split at h1
    · exact absurd h1 (by simp)
    · -- Both finds succeeded for h1; now split h2 the same way
      split at h2
      · exact absurd h2 (by simp)
      · rename_i frame2 hfind2
        split at h2
        · exact absurd h2 (by simp)
        · -- Extract membership and predicate info from both find? results
          have hmem1 := List.mem_of_find?_eq_some hfind1
          have hpred1 := List.find?_some hfind1
          have hmem2 := List.mem_of_find?_eq_some hfind2
          have hpred2 := List.find?_some hfind2
          -- The predicates are (cellName == cell && generation == gN) = true
          simp only [Bool.and_eq_true] at hpred1 hpred2
          obtain ⟨hcell1_beq, hgen1_beq⟩ := hpred1
          obtain ⟨hcell2_beq, hgen2_beq⟩ := hpred2
          -- Convert BEq equalities to Prop equalities
          have hcell1 := CellName.eq_of_beq _ _ hcell1_beq
          have hgen1 := beq_iff_eq.mp hgen1_beq
          have hcell2 := CellName.eq_of_beq _ _ hcell2_beq
          have hgen2 := beq_iff_eq.mp hgen2_beq
          -- Build the existential witness
          exact ⟨frame1, frame2, hmem1, hmem2, hcell1, hcell2, hgen1, hgen2,
            fun heq => hDiff (hgen1 ▸ hgen2 ▸ heq ▸ rfl)⟩

/-! ====================================================================
    VALID TRACES (temporal model)
    ==================================================================== -/

abbrev Trace := Nat → Retort

def always' (P : Retort → Prop) (t : Trace) : Prop :=
  ∀ n : Nat, P (t n)

structure ValidTrace where
  trace : Trace
  ops   : Nat → RetortOp
  init  : trace 0 = Retort.empty
  step  : ∀ n, trace (n + 1) = applyOp (trace n) (ops n)

-- □appendOnly: every step preserves all existing data
theorem always_appendOnly (vt : ValidTrace) :
    ∀ n, appendOnly (vt.trace n) (vt.trace (n + 1)) := by
  intro n
  rw [vt.step n]
  exact all_ops_appendOnly (vt.trace n) (vt.ops n)

-- Transitive: data from time T exists at all times T' > T
theorem data_persists (vt : ValidTrace) (n m : Nat) (h : n ≤ m) :
    appendOnly (vt.trace n) (vt.trace m) := by
  induction m with
  | zero =>
    have : n = 0 := Nat.eq_zero_of_le_zero h
    subst this
    unfold appendOnly cellsPreserved framesPreserved yieldsPreserved
           bindingsPreserved givensPreserved claimLogPreserved
    exact ⟨fun _ h => h, fun _ h => h, fun _ h => h,
           fun _ h => h, fun _ h => h, fun _ h => h⟩
  | succ k ih =>
    by_cases hk : n ≤ k
    · have ihk := ih hk
      have step := always_appendOnly vt k
      unfold appendOnly at *
      obtain ⟨c1, f1, y1, b1, g1, l1⟩ := ihk
      obtain ⟨c2, f2, y2, b2, g2, l2⟩ := step
      exact ⟨fun x hx => c2 x (c1 x hx), fun x hx => f2 x (f1 x hx),
             fun x hx => y2 x (y1 x hx), fun x hx => b2 x (b1 x hx),
             fun x hx => g2 x (g1 x hx), fun x hx => l2 x (l1 x hx)⟩
    · -- n = k + 1 = m, so we need appendOnly (trace n) (trace n), which is reflexive
      have hEq : n = k + 1 := by omega
      subst hEq
      unfold appendOnly cellsPreserved framesPreserved yieldsPreserved
             bindingsPreserved givensPreserved claimLogPreserved
      exact ⟨fun _ h => h, fun _ h => h, fun _ h => h,
             fun _ h => h, fun _ h => h, fun _ h => h⟩

/-! ====================================================================
    GRAPH GROWTH: Stem cells produce unbounded frames
    ==================================================================== -/

-- The frames list grows when createFrame operations occur
-- For non-stem cells: exactly one frame per cell (created at pour)
-- For stem cells: one frame per generation (created on demand)

-- Frames only grow (never shrink)
theorem frames_monotonic (vt : ValidTrace) (n : Nat) :
    (vt.trace n).frames.length ≤ (vt.trace (n + 1)).frames.length := by
  rw [vt.step n]
  cases vt.ops n <;> simp [applyOp, List.length_append] <;> omega

-- Non-stem cell: at most one frame across the entire trace
def nonStemBounded (r : Retort) (cell : CellName) : Prop :=
  (∀ cd ∈ r.cells, cd.name = cell → cd.bodyType ≠ .stem) →
  (r.frames.filter (fun f => f.cellName == cell)).length ≤ 1

-- Stem cell: frames grow linearly with generations
def stemFrameCount (r : Retort) (cell : CellName) : Nat :=
  (r.frames.filter (fun f => f.cellName == cell)).length

-- Each createFrame increases the stem cell's frame count by 1
theorem createFrame_grows (r : Retort) (cfd : CreateFrameData) :
    (applyOp r (.createFrame cfd)).frames.length = r.frames.length + 1 := by
  simp [applyOp, List.length_append]

-- Pour grows frames by the number of initial frames
theorem pour_grows (r : Retort) (pd : PourData) :
    (applyOp r (.pour pd)).frames.length = r.frames.length + pd.frames.length := by
  simp [applyOp, List.length_append]

-- Other operations don't change frame count
theorem claim_frames_stable (r : Retort) (cd : ClaimData) :
    (applyOp r (.claim cd)).frames.length = r.frames.length := by
  rfl

theorem freeze_frames_stable (r : Retort) (fd : FreezeData) :
    (applyOp r (.freeze fd)).frames.length = r.frames.length := by
  rfl

theorem release_frames_stable (r : Retort) (rd : ReleaseData) :
    (applyOp r (.release rd)).frames.length = r.frames.length := by
  rfl

-- Yields grow monotonically (append-only)
theorem yields_monotonic (vt : ValidTrace) (n : Nat) :
    (vt.trace n).yields.length ≤ (vt.trace (n + 1)).yields.length := by
  rw [vt.step n]
  cases vt.ops n <;> simp [applyOp, List.length_append] <;> omega

-- Bindings grow monotonically (append-only)
theorem bindings_monotonic (vt : ValidTrace) (n : Nat) :
    (vt.trace n).bindings.length ≤ (vt.trace (n + 1)).bindings.length := by
  rw [vt.step n]
  cases vt.ops n <;> simp [applyOp, List.length_append] <;> omega

-- The total graph size (frames + yields + bindings) grows monotonically
def graphSize (r : Retort) : Nat :=
  r.frames.length + r.yields.length + r.bindings.length

theorem graph_monotonic (vt : ValidTrace) (n : Nat) :
    graphSize (vt.trace n) ≤ graphSize (vt.trace (n + 1)) := by
  unfold graphSize
  have hf := frames_monotonic vt n
  have hy := yields_monotonic vt n
  have hb := bindings_monotonic vt n
  omega

/-! ====================================================================
    SUMMARY: The Complete Formal Model
    ====================================================================

  TYPES:
  - CellDef, GivenSpec: immutable definitions (set at pour time)
  - Frame: immutable execution instances (append-only)
  - Yield: immutable outputs (append-only)
  - Binding: immutable resolved givens (append-only, DAG edges)
  - Claim: mutable lock (the ONLY mutable component)
  - ClaimLogEntry: append-only audit trail

  DERIVED STATE (never stored):
  - FrameStatus: declared | computing | frozen
  - Ready frames: declared + all givens satisfied
  - Program complete: all non-stem cells have frozen frames
  - Content address: (cellName, generation, field) → value

  INVARIANTS:
  - I1: cellNamesUnique — cell names unique per program
  - I2: framesUnique — (cell, generation) pairs unique
  - I3-I5: referential integrity (yields, bindings, claims → frames)
  - I6: claimMutex — at most one claim per frame
  - I7: yieldUnique — each (frame, field) has at most one value

  OPERATION PRECONDITIONS:
  - pourValid: new cell (program, name) pairs don't conflict with existing
  - pourInternallyUnique: new cells among themselves are unique
  - pourFramesUnique: new frames don't conflict on (cell, generation)
  - claimValid: frame exists, is ready, and not already claimed
  - freezeValid: frame is claimed, yields/bindings reference correct frame
  - freezeBindingsWitnessed: every binding has a matching yield
  - freezeFrameExists: the frozen frame exists in retort
  - freezeBindingsRefFrames: binding producer frames exist
  - freezeYieldsUnique: new yields don't conflict on (frame, field)
  - createFrameUnique: new frame doesn't conflict on (cell, generation)
  - validOp: composite precondition dispatching per operation

  PROVEN PROPERTIES:
  Append-only:
  - all_ops_appendOnly: every operation preserves append-only
  - cells_stable_non_pour: cell defs never change after pour
  - givens_stable_non_pour: givens never change after pour
  - evalCycle_appendOnly: full eval cycles preserve append-only
  - always_appendOnly: □appendOnly on valid traces
  - data_persists: data from time T exists at all T' > T (transitive)

  Invariant preservation (all 7 invariants, all 5 operations):
  - I1 cellNamesUnique: pour (with precond), non-pour (trivial)
  - I2 framesUnique: pour, createFrame (with precond), others (trivial)
  - I3 yieldsWellFormed: freeze (with precond), pour/createFrame (frames grow),
      claim/release (trivial)
  - I4 bindingsWellFormed: freeze (with precond), pour/createFrame (frames grow),
      claim/release (trivial)
  - I5 claimsWellFormed: claim (with precond), freeze/release (filter),
      pour/createFrame (frames grow)
  - I6 claimMutex: claim (with precond), freeze/release (filter),
      pour/createFrame (trivial)
  - I7 yieldUnique: freeze (with precond), others (trivial)

  Postconditions:
  - claim_adds_claim: claims.length grows by 1
  - freeze_removes_claim: claims.length strictly decreases
  - createFrame_adds_frame: new frame is in result
  - pour_adds_cells: poured cells are in the result
  - pour_adds_frames: poured frames are in the result
  - freeze_makes_frozen: after freeze, if all fields covered, status is frozen

  Progress (liveness):
  - progress: if readyFrames is non-empty, there exists a valid ClaimData
      (requires framesCellDefsExist — every frame has a cell definition)

  Composite:
  - wellFormed_preserved: validOp + wellFormed => wellFormed after applyOp

  Monotonicity:
  - freeze_preserves_bindingsMonotone: freeze with witnessed bindings
      preserves the invariant that every binding has a matching yield

  THE EVAL LOOP (EvalCycle):
  1. claim → adds to claims + claimLog
  2. freeze → adds yields + bindings, removes claim
  3. createFrame → adds next-gen frame (if stem + demand)

  STEM CELL LIFECYCLE:
  - No frame at pour time (demand-driven)
  - Frame created when demand detected
  - After freeze: frame is frozen (yields immutable)
  - If more demand: next-gen frame created
  - Generation sequence is monotonically increasing

  DAG STRUCTURE:
  - Bindings table = edges
  - noSelfLoops: no frame depends on itself
  - generationOrdered: same-cell deps go backward in generation
  - bindingsPointToFrozen: can only read from frozen frames
-/

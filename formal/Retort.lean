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
  - claimValid: frame exists, is ready, and not already claimed
  - freezeValid: frame is claimed, yields/bindings reference correct frame
  - freezeBindingsWitnessed: every binding has a matching yield

  PROVEN PROPERTIES:
  - all_ops_appendOnly: every operation preserves append-only
  - cells_stable_non_pour: cell defs never change after pour
  - givens_stable_non_pour: givens never change after pour
  - evalCycle_appendOnly: full eval cycles preserve append-only
  - always_appendOnly: □appendOnly on valid traces
  - data_persists: data from time T exists at all T' > T (transitive)
  - pour_preserves_cellNamesUnique: valid pour preserves I1
  - non_pour_preserves_cellNamesUnique: non-pour ops preserve I1
  - claim_preserves_claimMutex: valid claim preserves I6
  - freeze_preserves_claimMutex: freeze preserves I6 (filter only removes)
  - release_preserves_claimMutex: release preserves I6 (filter only removes)
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

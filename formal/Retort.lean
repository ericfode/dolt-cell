/-
  Retort: Full Formal Model of the Cell Runtime

  This formalizes the complete system:
  - Cell definitions (immutable after pour)
  - Frames (append-only execution instances)
  - Yields (append-only outputs)
  - Givens (dependency specifications)
  - Bindings (resolved givens, the DAG edges)
  - Claims (mutable lock table)
  - Readiness (derived from givens + yields)
  - The eval loop (claim → evaluate → freeze)
  - Pour (loading programs)
  - Stem cell lifecycle (demand-driven generation cycling)
  - DAG properties (acyclicity, content-addressing)
-/

import Core
import Claims

/-! ====================================================================
    CELL DEFINITIONS (immutable after pour)
    ==================================================================== -/

-- Renamed to RCellDef to avoid collision with Denotational.CellDef
-- when both modules are imported by Refinement.lean.
structure RCellDef where
  name      : CellName
  program   : ProgramId
  bodyType  : BodyType
  body      : String
  fields    : List FieldName    -- yield field names this cell produces
  deriving Repr, DecidableEq

-- A dependency specification (abstract, defined at pour time)
structure GivenSpec where
  owner       : CellName        -- the cell that HAS this given (not the source)
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
  frameId  : FrameId
  field    : FieldName
  value    : String
  isBottom : Bool := false   -- true for error/bottom yields (Go: is_bottom column)
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

/-! ====================================================================
    THE RETORT DATABASE STATE
    ==================================================================== -/

structure Retort where
  cells    : List RCellDef          -- immutable after pour
  givens   : List GivenSpec        -- immutable after pour
  frames   : List Frame            -- append-only
  yields   : List Yield            -- append-only
  bindings : List Binding          -- append-only
  claims   : List Claim            -- mutable (lock table)
  deriving Repr

def Retort.empty : Retort :=
  { cells := [], givens := [], frames := [], yields := [],
    bindings := [], claims := [] }

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

def Retort.cellDef (r : Retort) (name : CellName) : Option RCellDef :=
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

-- A frozen frame is "bottom" if ALL its yields carry isBottom = true.
-- Bottom frames are operationally frozen (all fields present, counted as
-- complete) but semantically errored.  The refinement maps them to
-- ExecFrames with oraclePass := false.
-- Matches Go: cells.state='bottom', yields.is_bottom=TRUE, yields.is_frozen=TRUE.
def Retort.isBottomFrame (r : Retort) (f : Frame) : Bool :=
  r.frameStatus f == .frozen &&
  let ys := r.frameYields f.id
  !ys.isEmpty && ys.all (·.isBottom)

-- Has a non-optional dependency that is bottomed (Go: hasBottomedDependency)
def Retort.hasBottomedDep (r : Retort) (f : Frame) : Bool :=
  let cellGivens := r.givens.filter (fun g => g.owner == f.cellName && !g.optional)
  cellGivens.any (fun g =>
    match r.latestFrozenFrame g.sourceCell with
    | some srcFrame => r.isBottomFrame srcFrame
    | none => false)

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
  let cellGivens := r.givens.filter (fun g => g.owner == f.cellName)
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
  cells  : List RCellDef
  givens : List GivenSpec
  frames : List Frame            -- gen-0 frames for all poured cells
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
  deriving Repr

-- Bottom: mark a frame as errored (Go: bottomCell).
-- Like freeze, but all yields carry isBottom=true.  The frame becomes
-- "frozen" by frameStatus (all fields present) so programComplete and
-- givenSatisfiable still work, but the isBottom flag distinguishes
-- error yields from real ones.  The refinement maps bottom frames to
-- ExecFrames with oraclePass := false.
structure BottomData where
  frameId : FrameId
  reason  : String         -- e.g. "bottom: dependency error"
  deriving Repr

inductive RetortOp where
  | pour        : PourData → RetortOp
  | claim       : ClaimData → RetortOp
  | freeze      : FreezeData → RetortOp
  | release     : ReleaseData → RetortOp
  | createFrame : CreateFrameData → RetortOp
  | bottom      : BottomData → RetortOp
  deriving Repr

def applyOp (r : Retort) : RetortOp → Retort
  | .pour pd =>
    { r with cells := r.cells ++ pd.cells,
             givens := r.givens ++ pd.givens,
             frames := r.frames ++ pd.frames }

  | .claim cd =>
    { r with claims := r.claims ++ [⟨cd.frameId, cd.pistonId⟩] }

  | .freeze fd =>
    { r with yields := r.yields ++ fd.yields,
             bindings := r.bindings ++ fd.bindings,
             -- Remove claim (the only mutable operation)
             claims := r.claims.filter (fun c => c.frameId != fd.frameId) }

  | .release rd =>
    { r with claims := r.claims.filter (fun c => c.frameId != rd.frameId) }

  | .createFrame cfd =>
    { r with frames := r.frames ++ [cfd.frame] }

  | .bottom bd =>
    -- Look up the cell definition for the frame being bottomed
    let frame := r.frames.find? (fun f => f.id == bd.frameId)
    match frame with
    | none => r  -- no-op if frame not found
    | some f =>
      match r.cellDef f.cellName with
      | none => r
      | some cd =>
        -- Create bottom yields for all fields (isBottom := true)
        let bottomYields := cd.fields.map (fun fld =>
          { frameId := bd.frameId, field := fld, value := bd.reason, isBottom := true : Yield })
        { r with yields := r.yields ++ bottomYields,
                 -- Remove claim (same as freeze)
                 claims := r.claims.filter (fun c => c.frameId != bd.frameId) }

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

-- I8: Every frame has a cell definition (natural invariant: frames come from cells)
-- (definition lifted above wellFormed; see framesCellDefsExist below)
def framesCellDefsExist (r : Retort) : Prop :=
  ∀ f ∈ r.frames, (r.cellDef f.cellName).isSome

-- I9: No self-loops in bindings (a frame never reads from itself)
def noSelfLoops (r : Retort) : Prop :=
  ∀ b ∈ r.bindings, b.consumerFrame ≠ b.producerFrame

-- I10: Stronger DAG ordering: for same-cell bindings (stem cells reading
-- own previous gen), the producer must have a strictly lower generation.
def generationOrdered (r : Retort) : Prop :=
  ∀ b ∈ r.bindings,
    ∀ cf ∈ r.frames, ∀ pf ∈ r.frames,
      cf.id = b.consumerFrame → pf.id = b.producerFrame →
      cf.cellName = pf.cellName →
      pf.generation < cf.generation

-- I11: Bindings only point to frozen frames (can't read from the future)
def bindingsPointToFrozen (r : Retort) : Prop :=
  ∀ b ∈ r.bindings,
    ∃ f ∈ r.frames, f.id = b.producerFrame ∧ r.frameStatus f = .frozen

-- The complete well-formedness predicate
def wellFormed (r : Retort) : Prop :=
  cellNamesUnique r ∧ framesUnique r ∧ yieldsWellFormed r ∧
  bindingsWellFormed r ∧ claimsWellFormed r ∧ claimMutex r ∧ yieldUnique r ∧
  framesCellDefsExist r ∧ noSelfLoops r ∧
  generationOrdered r ∧ bindingsPointToFrozen r

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

-- The full append-only invariant (everything except claims)
def appendOnly (before after : Retort) : Prop :=
  cellsPreserved before after ∧ framesPreserved before after ∧
  yieldsPreserved before after ∧ bindingsPreserved before after ∧
  givensPreserved before after

-- Stronger than cellsPreserved: cells list grows as a suffix (prefix preserved).
-- All operations either leave cells unchanged or append at the end, so this
-- always holds. Needed for demandFromGivens_monotone because cellDef uses
-- List.find? which depends on element ordering.
def cellsPrefix (before after : Retort) : Prop :=
  ∃ extra, after.cells = before.cells ++ extra

/-! ====================================================================
    PROOFS: Operations preserve append-only invariant
    ==================================================================== -/

theorem pour_appendOnly (r : Retort) (pd : PourData) :
    appendOnly r (applyOp r (.pour pd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact List.mem_append_left _ hx  -- cells
  · exact List.mem_append_left _ hx  -- frames
  · exact hx                          -- yields unchanged
  · exact hx                          -- bindings unchanged
  · exact List.mem_append_left _ hx  -- givens

theorem claim_appendOnly (r : Retort) (cd : ClaimData) :
    appendOnly r (applyOp r (.claim cd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx

theorem freeze_appendOnly (r : Retort) (fd : FreezeData) :
    appendOnly r (applyOp r (.freeze fd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact List.mem_append_left _ hx   -- yields grow
  · exact List.mem_append_left _ hx   -- bindings grow
  · exact hx

theorem release_appendOnly (r : Retort) (rd : ReleaseData) :
    appendOnly r (applyOp r (.release rd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx
  · exact hx

theorem createFrame_appendOnly (r : Retort) (cfd : CreateFrameData) :
    appendOnly r (applyOp r (.createFrame cfd)) := by
  unfold appendOnly applyOp
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> intro x hx
  · exact hx
  · exact List.mem_append_left _ hx  -- frames grow
  · exact hx
  · exact hx
  · exact hx

theorem bottom_appendOnly (r : Retort) (bd : BottomData) :
    appendOnly r (applyOp r (.bottom bd)) := by
  unfold appendOnly cellsPreserved framesPreserved yieldsPreserved bindingsPreserved givensPreserved applyOp
  simp only []
  split
  · -- frame not found → retort unchanged
    exact ⟨fun _ hx => hx, fun _ hx => hx, fun _ hx => hx, fun _ hx => hx, fun _ hx => hx⟩
  · split
    · -- cellDef not found → retort unchanged
      exact ⟨fun _ hx => hx, fun _ hx => hx, fun _ hx => hx, fun _ hx => hx, fun _ hx => hx⟩
    · -- yields appended, claims filtered, cells/frames/bindings/givens unchanged
      exact ⟨fun _ hx => hx, fun _ hx => hx,
             fun _ hx => List.mem_append_left _ hx,
             fun _ hx => hx, fun _ hx => hx⟩

-- ALL operations preserve append-only
theorem all_ops_appendOnly (r : Retort) (op : RetortOp) :
    appendOnly r (applyOp r op) := by
  cases op with
  | pour pd => exact pour_appendOnly r pd
  | claim cd => exact claim_appendOnly r cd
  | freeze fd => exact freeze_appendOnly r fd
  | release rd => exact release_appendOnly r rd
  | createFrame cfd => exact createFrame_appendOnly r cfd
  | bottom bd => exact bottom_appendOnly r bd

-- All operations preserve cellsPrefix
theorem all_ops_cellsPrefix (r : Retort) (op : RetortOp) :
    cellsPrefix r (applyOp r op) := by
  unfold cellsPrefix
  cases op with
  | pour pd => exact ⟨pd.cells, rfl⟩
  | claim _ => exact ⟨[], by simp [applyOp]⟩
  | freeze _ => exact ⟨[], by simp [applyOp]⟩
  | release _ => exact ⟨[], by simp [applyOp]⟩
  | createFrame _ => exact ⟨[], by simp [applyOp]⟩
  | bottom bd =>
    simp only [applyOp]
    split
    · exact ⟨[], by simp⟩
    · split
      · exact ⟨[], by simp⟩
      · exact ⟨[], by simp⟩

-- cellsPrefix is transitive
theorem cellsPrefix_trans (r1 r2 r3 : Retort)
    (h12 : cellsPrefix r1 r2) (h23 : cellsPrefix r2 r3) :
    cellsPrefix r1 r3 := by
  unfold cellsPrefix at *
  obtain ⟨e1, he1⟩ := h12
  obtain ⟨e2, he2⟩ := h23
  exact ⟨e1 ++ e2, by rw [he2, he1, List.append_assoc]⟩

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

-- Precondition: every poured frame's cell name has a definition in r.cells ++ pd.cells.
def pourFramesCellDefsExist (r : Retort) (pd : PourData) : Prop :=
  ∀ f ∈ pd.frames,
    (r.cells ++ pd.cells).any (fun c => c.name == f.cellName)

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
    | bottom _ => simp only [applyOp]; split <;> (try split) <;> rfl
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

-- Pour preserves bindingsMonotone: bindings and yields unchanged; new frames
-- might match old bindings, but bindingsWellFormed guarantees an old frame
-- with matching id already existed, so hWF applies.
theorem pour_preserves_bindingsMonotone (r : Retort) (pd : PourData)
    (hWF : bindingsMonotone r)
    (hBWF : bindingsWellFormed r) :
    bindingsMonotone (applyOp r (.pour pd)) := by
  unfold bindingsMonotone applyOp at *
  simp only
  intro f hf b hb hConsumer
  rw [List.mem_append] at hf
  cases hf with
  | inl hfOld => exact hWF f hfOld b hb hConsumer
  | inr hfNew =>
    -- f is a new frame from pd. Since b ∈ r.bindings and bindingsWellFormed,
    -- there exists an old frame with b.consumerFrame as id.
    obtain ⟨⟨f', hf', hfid'⟩, _⟩ := hBWF b hb
    exact hWF f' hf' b hb hfid'.symm

-- Claim trivially preserves bindingsMonotone (bindings and yields unchanged,
-- frames unchanged).
theorem claim_preserves_bindingsMonotone (r : Retort) (cd : ClaimData)
    (hWF : bindingsMonotone r) :
    bindingsMonotone (applyOp r (.claim cd)) := by
  unfold bindingsMonotone applyOp at *
  simp only
  intro f hf b hb hConsumer
  exact hWF f hf b hb hConsumer

-- Release trivially preserves bindingsMonotone (bindings and yields unchanged,
-- frames unchanged).
theorem release_preserves_bindingsMonotone (r : Retort) (rd : ReleaseData)
    (hWF : bindingsMonotone r) :
    bindingsMonotone (applyOp r (.release rd)) := by
  unfold bindingsMonotone applyOp at *
  simp only
  intro f hf b hb hConsumer
  exact hWF f hf b hb hConsumer

-- CreateFrame preserves bindingsMonotone: bindings and yields unchanged;
-- the one new frame might match an old binding, but bindingsWellFormed
-- guarantees an old frame with matching id already existed.
theorem createFrame_preserves_bindingsMonotone (r : Retort) (cfd : CreateFrameData)
    (hWF : bindingsMonotone r)
    (hBWF : bindingsWellFormed r) :
    bindingsMonotone (applyOp r (.createFrame cfd)) := by
  unfold bindingsMonotone applyOp at *
  simp only
  intro f hf b hb hConsumer
  rw [List.mem_append] at hf
  cases hf with
  | inl hfOld => exact hWF f hfOld b hb hConsumer
  | inr hfNew =>
    simp at hfNew
    obtain ⟨⟨f', hf', hfid'⟩, _⟩ := hBWF b hb
    exact hWF f' hf' b hb hfid'.symm

-- Release and createFrame trivially preserve claimMutex,
-- since they don't add claims (release only removes claims).

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

-- Precondition: created frame's cell name has a definition in r.cells.
def createFrameCellDefExists (r : Retort) (cfd : CreateFrameData) : Prop :=
  (r.cellDef cfd.frame.cellName).isSome

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

/-! I9: noSelfLoops preservation -/

-- Precondition: freeze bindings have no self-loops
def freezeNoSelfLoops (fd : FreezeData) : Prop :=
  ∀ b ∈ fd.bindings, b.consumerFrame ≠ b.producerFrame

-- Pour doesn't add bindings: noSelfLoops trivially preserved.
theorem pour_preserves_noSelfLoops (r : Retort) (pd : PourData)
    (hWF : noSelfLoops r) :
    noSelfLoops (applyOp r (.pour pd)) := by
  unfold noSelfLoops applyOp at *; simp only; exact hWF

-- Claim doesn't add bindings.
theorem claim_preserves_noSelfLoops (r : Retort) (cd : ClaimData)
    (hWF : noSelfLoops r) :
    noSelfLoops (applyOp r (.claim cd)) := by
  unfold noSelfLoops applyOp at *; simp only; exact hWF

-- Freeze adds bindings: needs the precondition.
theorem freeze_preserves_noSelfLoops (r : Retort) (fd : FreezeData)
    (hWF : noSelfLoops r)
    (hFresh : freezeNoSelfLoops fd) :
    noSelfLoops (applyOp r (.freeze fd)) := by
  unfold noSelfLoops applyOp at *
  simp only
  intro b hb
  rw [List.mem_append] at hb
  cases hb with
  | inl hbOld => exact hWF b hbOld
  | inr hbNew => exact hFresh b hbNew

-- Release doesn't add bindings.
theorem release_preserves_noSelfLoops (r : Retort) (rd : ReleaseData)
    (hWF : noSelfLoops r) :
    noSelfLoops (applyOp r (.release rd)) := by
  unfold noSelfLoops applyOp at *; simp only; exact hWF

-- CreateFrame doesn't add bindings.
theorem createFrame_preserves_noSelfLoops (r : Retort) (cfd : CreateFrameData)
    (hWF : noSelfLoops r) :
    noSelfLoops (applyOp r (.createFrame cfd)) := by
  unfold noSelfLoops applyOp at *; simp only; exact hWF

/-! I8: framesCellDefsExist preservation -/

-- Pour: old frames still find their cellDef (cells grew); new frames need the precondition.
theorem pour_preserves_framesCellDefsExist (r : Retort) (pd : PourData)
    (hWF : framesCellDefsExist r)
    (hPourFrames : pourFramesCellDefsExist r pd) :
    framesCellDefsExist (applyOp r (.pour pd)) := by
  unfold framesCellDefsExist applyOp at *
  simp only
  intro f hf
  rw [List.mem_append] at hf
  cases hf with
  | inl hfOld =>
    -- f is an old frame: its cellDef existed in r.cells, which is a prefix of r.cells ++ pd.cells
    have hSome := hWF f hfOld
    unfold Retort.cellDef at *
    rw [List.find?_isSome] at hSome ⊢
    obtain ⟨c, hc, hpc⟩ := hSome
    exact ⟨c, List.mem_append_left _ hc, hpc⟩
  | inr hfNew =>
    -- f is a new frame: use pourFramesCellDefsExist
    unfold pourFramesCellDefsExist at hPourFrames
    have hAny := hPourFrames f hfNew
    unfold Retort.cellDef
    rw [List.find?_isSome]
    rw [List.any_eq_true] at hAny
    obtain ⟨c, hc, hpc⟩ := hAny
    exact ⟨c, hc, hpc⟩

-- Claim, freeze, release: cells and frames unchanged or frames unchanged.
theorem claim_preserves_framesCellDefsExist (r : Retort) (cd : ClaimData)
    (hWF : framesCellDefsExist r) :
    framesCellDefsExist (applyOp r (.claim cd)) := by
  unfold framesCellDefsExist applyOp at *; simp only; exact hWF

theorem freeze_preserves_framesCellDefsExist (r : Retort) (fd : FreezeData)
    (hWF : framesCellDefsExist r) :
    framesCellDefsExist (applyOp r (.freeze fd)) := by
  unfold framesCellDefsExist applyOp at *; simp only; exact hWF

theorem release_preserves_framesCellDefsExist (r : Retort) (rd : ReleaseData)
    (hWF : framesCellDefsExist r) :
    framesCellDefsExist (applyOp r (.release rd)) := by
  unfold framesCellDefsExist applyOp at *; simp only; exact hWF

-- CreateFrame: old frames still valid; new frame needs the precondition.
theorem createFrame_preserves_framesCellDefsExist (r : Retort) (cfd : CreateFrameData)
    (hWF : framesCellDefsExist r)
    (hExists : createFrameCellDefExists r cfd) :
    framesCellDefsExist (applyOp r (.createFrame cfd)) := by
  unfold framesCellDefsExist applyOp at *
  simp only
  intro f hf
  rw [List.mem_append] at hf
  cases hf with
  | inl hfOld => exact hWF f hfOld
  | inr hfNew =>
    simp at hfNew
    rw [hfNew]
    unfold createFrameCellDefExists at hExists
    exact hExists

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

-- Helper: when cellDef is some, frameStatus = declared implies frameClaim is none.
-- This is because the 'some cd' branch of frameStatus returns .declared only
-- when (a) not all fields are frozen AND (b) frameClaim is none.
private theorem declared_of_some_implies_no_claim (r : Retort) (f : Frame) (cd : RCellDef)
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
theorem pour_adds_cells (r : Retort) (pd : PourData) (c : RCellDef)
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
theorem freeze_makes_frozen (r : Retort) (fd : FreezeData) (f : Frame) (cd : RCellDef)
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

-- Precondition: freeze bindings respect generation ordering for same-cell deps
def freezeGenerationOrdered (r : Retort) (fd : FreezeData) : Prop :=
  ∀ b ∈ fd.bindings,
    ∀ cf ∈ r.frames, ∀ pf ∈ r.frames,
      cf.id = b.consumerFrame → pf.id = b.producerFrame →
      cf.cellName = pf.cellName →
      pf.generation < cf.generation

-- Precondition: freeze bindings point to frozen frames
def freezeBindingsPointToFrozen (r : Retort) (fd : FreezeData) : Prop :=
  ∀ b ∈ fd.bindings,
    ∃ f ∈ r.frames, f.id = b.producerFrame ∧ r.frameStatus f = .frozen

-- Bottom yield uniqueness precondition: existing yields for the bottom frame's
-- fields must have value = bd.reason (or not exist), to preserve yieldUnique.
def bottomYieldsUnique (r : Retort) (bd : BottomData) : Prop :=
  ∀ f, f ∈ r.frames → (f.id == bd.frameId) = true →
    ∀ cd, r.cellDef f.cellName = some cd →
      ∀ y ∈ r.yields, y.frameId = bd.frameId →
        ∀ fld ∈ cd.fields, y.field = fld → y.value = bd.reason

-- Aggregate precondition: what makes an operation valid for wellFormed preservation.
def validOp (r : Retort) : RetortOp → Prop
  | .pour pd =>
    pourValid r pd ∧ pourInternallyUnique r pd ∧ pourFramesUnique r pd ∧
    pourFramesCellDefsExist r pd ∧ pourFrameIdsDisjoint r r pd
  | .claim cd =>
    claimValid r cd
  | .freeze fd =>
    freezeValid r fd ∧ freezeBindingsWitnessed r fd ∧
    freezeFrameExists r fd ∧ freezeBindingsRefFrames r fd ∧
    freezeYieldsUnique r fd ∧ freezeNoSelfLoops fd ∧
    freezeGenerationOrdered r fd ∧ freezeBindingsPointToFrozen r fd
  | .release _ => True
  | .createFrame cfd =>
    createFrameUnique r cfd ∧ createFrameCellDefExists r cfd ∧ createFrameIdDisjoint r cfd
  | .bottom bd => bottomYieldsUnique r bd  -- bottom yields must be compatible with existing yields

/-! ====================================================================
    HELPER: frozen fields preserved under yield growth
    ==================================================================== -/

/-- If the frozen-fields condition holds for r, it holds for r'
    when yields are preserved (append-only). -/
private theorem frozen_fields_preserved (r r' : Retort)
    (hYieldsP : ∀ y ∈ r.yields, y ∈ r'.yields)
    (cd : RCellDef) (fid : FrameId)
    (hAllFrozen : cd.fields.all (fun fld =>
      ((r.frameYields fid).map (·.field)).contains fld) = true) :
    cd.fields.all (fun fld =>
      ((r'.frameYields fid).map (·.field)).contains fld) = true := by
  rw [List.all_eq_true] at hAllFrozen ⊢
  intro fld hfld
  have hOld := hAllFrozen fld hfld
  unfold Retort.frameYields at *
  rw [List.contains_iff_mem] at hOld ⊢
  rw [List.mem_map] at hOld ⊢
  obtain ⟨y, hy_mem, hy_eq⟩ := hOld
  rw [List.mem_filter] at hy_mem
  exact ⟨y, ⟨by rw [List.mem_filter]; exact ⟨hYieldsP y hy_mem.1, hy_mem.2⟩, hy_eq⟩⟩

/-! ====================================================================
    I10: generationOrdered preservation
    ==================================================================== -/

-- Precondition: poured frames have IDs disjoint from existing frames.
-- This is a natural invariant of the content-addressed design: each FrameId
-- is derived from the cell name and generation, so new frames (with new
-- cell/gen pairs) have fresh IDs.
def pourFrameIdsDisjoint (_r : Retort) (r : Retort) (pd : PourData) : Prop :=
  ∀ nf ∈ pd.frames, ∀ of ∈ r.frames, nf.id ≠ of.id

-- Precondition: a created frame has an ID disjoint from existing frames.
def createFrameIdDisjoint (r : Retort) (cfd : CreateFrameData) : Prop :=
  ∀ of ∈ r.frames, cfd.frame.id ≠ of.id

theorem pour_preserves_generationOrdered (r : Retort) (pd : PourData)
    (hWF : generationOrdered r) (hBWF : bindingsWellFormed r)
    (hDisjoint : pourFrameIdsDisjoint r r pd) :
    generationOrdered (applyOp r (.pour pd)) := by
  unfold generationOrdered applyOp at *
  simp only
  intro b hb cf hcf pf hpf hcid hpid hcell
  rw [List.mem_append] at hcf hpf
  -- Since b ∈ r.bindings (bindings unchanged by pour), bindingsWellFormed
  -- gives us old frames with matching IDs.
  have ⟨⟨cf', hcf', hcfid'⟩, ⟨pf', hpf', hpfid'⟩⟩ := hBWF b hb
  cases hcf with
  | inl hcfOld =>
    cases hpf with
    | inl hpfOld => exact hWF b hb cf hcfOld pf hpfOld hcid hpid hcell
    | inr hpfNew =>
      -- pf is new, but b references pf.id = b.producerFrame, and pf' ∈ r.frames
      -- with pf'.id = b.producerFrame. So pf.id = pf'.id. But hDisjoint says
      -- new frame IDs are disjoint from old frame IDs. Contradiction.
      exfalso
      unfold pourFrameIdsDisjoint at hDisjoint
      exact hDisjoint pf hpfNew pf' hpf' (hpid ▸ hpfid'.symm)
  | inr hcfNew =>
    -- cf is new, same argument: cf.id = b.consumerFrame = cf'.id, contradiction.
    exfalso
    unfold pourFrameIdsDisjoint at hDisjoint
    exact hDisjoint cf hcfNew cf' hcf' (hcid ▸ hcfid'.symm)

theorem claim_preserves_generationOrdered (r : Retort) (cd : ClaimData)
    (hWF : generationOrdered r) :
    generationOrdered (applyOp r (.claim cd)) := by
  unfold generationOrdered applyOp at *; simp only; exact hWF

theorem freeze_preserves_generationOrdered (r : Retort) (fd : FreezeData)
    (hWF : generationOrdered r) (hFresh : freezeGenerationOrdered r fd) :
    generationOrdered (applyOp r (.freeze fd)) := by
  unfold generationOrdered applyOp at *
  simp only
  intro b hb cf hcf pf hpf hcid hpid hcell
  rw [List.mem_append] at hb
  cases hb with
  | inl hbOld => exact hWF b hbOld cf hcf pf hpf hcid hpid hcell
  | inr hbNew => exact hFresh b hbNew cf hcf pf hpf hcid hpid hcell

theorem release_preserves_generationOrdered (r : Retort) (rd : ReleaseData)
    (hWF : generationOrdered r) :
    generationOrdered (applyOp r (.release rd)) := by
  unfold generationOrdered applyOp at *; simp only; exact hWF

theorem createFrame_preserves_generationOrdered (r : Retort) (cfd : CreateFrameData)
    (hWF : generationOrdered r) (hBWF : bindingsWellFormed r)
    (hDisjoint : createFrameIdDisjoint r cfd) :
    generationOrdered (applyOp r (.createFrame cfd)) := by
  unfold generationOrdered applyOp at *
  simp only
  intro b hb cf hcf pf hpf hcid hpid hcell
  rw [List.mem_append] at hcf hpf
  -- Since b ∈ r.bindings (bindings unchanged by createFrame), bindingsWellFormed
  -- gives us old frames with matching IDs.
  have ⟨⟨cf', hcf', hcfid'⟩, ⟨pf', hpf', hpfid'⟩⟩ := hBWF b hb
  cases hcf with
  | inl hcfOld =>
    cases hpf with
    | inl hpfOld => exact hWF b hb cf hcfOld pf hpfOld hcid hpid hcell
    | inr hpfNew =>
      -- pf is the new frame cfd.frame, but b references pf.id = b.producerFrame,
      -- and pf' ∈ r.frames with pf'.id = b.producerFrame. So pf.id = pf'.id.
      -- But hDisjoint says the new frame's ID is disjoint from old IDs. Contradiction.
      exfalso
      simp at hpfNew
      unfold createFrameIdDisjoint at hDisjoint
      exact hDisjoint pf' hpf' (hpfNew ▸ hpid ▸ hpfid'.symm)
  | inr hcfNew =>
    -- cf is the new frame cfd.frame, same argument.
    exfalso
    simp at hcfNew
    unfold createFrameIdDisjoint at hDisjoint
    exact hDisjoint cf' hcf' (hcfNew ▸ hcid ▸ hcfid'.symm)

theorem bottom_preserves_generationOrdered (r : Retort) (bd : BottomData)
    (hWF : generationOrdered r) :
    generationOrdered (applyOp r (.bottom bd)) := by
  unfold generationOrdered applyOp at *
  simp only
  -- bottom never adds bindings, so generationOrdered is trivially preserved
  split
  · exact hWF  -- frame not found
  · split
    · exact hWF  -- cellDef not found
    · exact hWF  -- success: bindings unchanged

/-! ====================================================================
    I11: bindingsPointToFrozen preservation

    Helper: frozen status is monotone under yield growth with unchanged cells.
    ==================================================================== -/

/-- If a frame is frozen in retort r, it's frozen in any retort r' that has
    the same cells and at least the same yields. -/
private theorem frozenStatus_preserved (r r' : Retort) (f : Frame)
    (hCells : r'.cells = r.cells)
    (hYields : ∀ y ∈ r.yields, y ∈ r'.yields)
    (hFrozen : r.frameStatus f = .frozen) :
    r'.frameStatus f = .frozen := by
  unfold Retort.frameStatus at hFrozen ⊢
  -- Show r'.cellDef = r.cellDef (since cells are the same)
  have hCellDef : r'.cellDef f.cellName = r.cellDef f.cellName := by
    unfold Retort.cellDef; rw [hCells]
  cases hcd : r.cellDef f.cellName with
  | none =>
    -- cellDef is none => frameStatus = .declared, contradicts hFrozen = .frozen
    simp only [hcd] at hFrozen
    exact absurd hFrozen (by decide)
  | some cd =>
    rw [hCellDef, hcd]
    simp only [hcd] at hFrozen
    simp only
    split at hFrozen
    · rename_i hAll
      rw [if_pos (frozen_fields_preserved r r' hYields cd f.id hAll)]
    · split at hFrozen <;> simp at hFrozen

theorem pour_preserves_bindingsPointToFrozen (r : Retort) (pd : PourData)
    (hWF : bindingsPointToFrozen r) :
    bindingsPointToFrozen (applyOp r (.pour pd)) := by
  unfold bindingsPointToFrozen at *
  intro b hb
  obtain ⟨f, hf, hfid, hfrozen⟩ := hWF b hb
  refine ⟨f, List.mem_append_left _ hf, hfid, ?_⟩
  -- Pour: cells = r.cells ++ pd.cells, yields unchanged.
  -- cellDef uses find? which returns FIRST match. Since r.cells is a prefix,
  -- find? on r.cells ++ pd.cells returns the same result as find? on r.cells.
  -- So frameStatus is preserved.
  unfold Retort.frameStatus Retort.cellDef at hfrozen ⊢
  simp only [applyOp]
  -- Case split on whether find? succeeds on r.cells
  cases hfind : r.cells.find? (fun c => c.name == f.cellName) with
  | none =>
    -- cellDef not found => frameStatus = .declared, contradicts frozen
    simp only [hfind] at hfrozen
    exact absurd hfrozen (by decide)
  | some cd =>
    simp only [hfind] at hfrozen
    -- find? on r.cells ++ pd.cells returns same result (prefix)
    have hfind' : (r.cells ++ pd.cells).find? (fun c => c.name == f.cellName) = some cd := by
      rw [List.find?_append]; simp [hfind]
    simp only [hfind']
    unfold Retort.frameYields at *
    simp only at hfrozen ⊢
    exact hfrozen

theorem claim_preserves_bindingsPointToFrozen (r : Retort) (cd : ClaimData)
    (hWF : bindingsPointToFrozen r) :
    bindingsPointToFrozen (applyOp r (.claim cd)) := by
  unfold bindingsPointToFrozen at *
  intro b hb
  obtain ⟨f, hf, hfid, hfrozen⟩ := hWF b hb
  refine ⟨f, hf, hfid, ?_⟩
  -- Claim: cells/frames/yields unchanged, claims grow. Frozen status
  -- depends on yields coverage (not claims), so preserved.
  exact frozenStatus_preserved r (applyOp r (.claim cd)) f rfl (fun y hy => hy) hfrozen

theorem freeze_preserves_bindingsPointToFrozen (r : Retort) (fd : FreezeData)
    (hWF : bindingsPointToFrozen r)
    (hFresh : freezeBindingsPointToFrozen r fd) :
    bindingsPointToFrozen (applyOp r (.freeze fd)) := by
  unfold bindingsPointToFrozen at *
  intro b hb
  simp only [applyOp] at hb ⊢
  rw [List.mem_append] at hb
  cases hb with
  | inl hbOld =>
    obtain ⟨f, hf, hfid, hfrozen⟩ := hWF b hbOld
    refine ⟨f, hf, hfid, ?_⟩
    exact frozenStatus_preserved r
      { cells := r.cells, givens := r.givens, frames := r.frames,
        yields := r.yields ++ fd.yields, bindings := r.bindings ++ fd.bindings,
        claims := r.claims.filter (fun c => c.frameId != fd.frameId) }
      f rfl (fun y hy => List.mem_append_left _ hy) hfrozen
  | inr hbNew =>
    obtain ⟨f, hf, hfid, hfrozen⟩ := hFresh b hbNew
    refine ⟨f, hf, hfid, ?_⟩
    exact frozenStatus_preserved r
      { cells := r.cells, givens := r.givens, frames := r.frames,
        yields := r.yields ++ fd.yields, bindings := r.bindings ++ fd.bindings,
        claims := r.claims.filter (fun c => c.frameId != fd.frameId) }
      f rfl (fun y hy => List.mem_append_left _ hy) hfrozen

theorem release_preserves_bindingsPointToFrozen (r : Retort) (rd : ReleaseData)
    (hWF : bindingsPointToFrozen r) :
    bindingsPointToFrozen (applyOp r (.release rd)) := by
  unfold bindingsPointToFrozen at *
  intro b hb
  obtain ⟨f, hf, hfid, hfrozen⟩ := hWF b hb
  refine ⟨f, hf, hfid, ?_⟩
  exact frozenStatus_preserved r (applyOp r (.release rd)) f rfl (fun y hy => hy) hfrozen

theorem createFrame_preserves_bindingsPointToFrozen (r : Retort) (cfd : CreateFrameData)
    (hWF : bindingsPointToFrozen r) :
    bindingsPointToFrozen (applyOp r (.createFrame cfd)) := by
  unfold bindingsPointToFrozen at *
  intro b hb
  obtain ⟨f, hf, hfid, hfrozen⟩ := hWF b hb
  refine ⟨f, List.mem_append_left _ hf, hfid, ?_⟩
  exact frozenStatus_preserved r (applyOp r (.createFrame cfd)) f rfl (fun y hy => hy) hfrozen

theorem bottom_preserves_bindingsPointToFrozen (r : Retort) (bd : BottomData)
    (hWF : bindingsPointToFrozen r) :
    bindingsPointToFrozen (applyOp r (.bottom bd)) := by
  unfold bindingsPointToFrozen at *
  simp only [applyOp]
  -- Bottom never adds bindings. Three cases from the nested match.
  split
  · exact hWF  -- frame not found: retort unchanged
  · rename_i f _hf
    split
    · exact hWF  -- cellDef not found: retort unchanged
    · rename_i cd _hcd
      -- Success: yields appended, claims filtered, bindings unchanged
      intro b hb
      obtain ⟨fr, hfr, hfrid, hfrozen⟩ := hWF b hb
      refine ⟨fr, hfr, hfrid, ?_⟩
      exact frozenStatus_preserved r
        { cells := r.cells, givens := r.givens, frames := r.frames,
          yields := r.yields ++ cd.fields.map (fun fld =>
            { frameId := bd.frameId, field := fld, value := bd.reason, isBottom := true : Yield }),
          bindings := r.bindings,
          claims := r.claims.filter (fun c => c.frameId != bd.frameId) }
        fr rfl (fun y hy => List.mem_append_left _ hy) hfrozen

/-! ====================================================================
    BOTTOM OPERATION: individual invariant preservation
    ==================================================================== -/

-- Bottom doesn't change cells, so cellNamesUnique is trivially preserved.
theorem bottom_preserves_cellNamesUnique (r : Retort) (bd : BottomData)
    (hWF : cellNamesUnique r) :
    cellNamesUnique (applyOp r (.bottom bd)) := by
  have hEq : (applyOp r (.bottom bd)).cells = r.cells := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  unfold cellNamesUnique at *
  intro c1 c2 h1 h2
  have h1' : c1 ∈ r.cells := hEq ▸ h1
  have h2' : c2 ∈ r.cells := hEq ▸ h2
  exact hWF c1 c2 h1' h2'

-- Bottom doesn't change frames.
theorem bottom_preserves_framesUnique (r : Retort) (bd : BottomData)
    (hWF : framesUnique r) :
    framesUnique (applyOp r (.bottom bd)) := by
  have hEq : (applyOp r (.bottom bd)).frames = r.frames := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  unfold framesUnique at *
  intro f1 f2 h1 h2
  have h1' : f1 ∈ r.frames := hEq ▸ h1
  have h2' : f2 ∈ r.frames := hEq ▸ h2
  exact hWF f1 f2 h1' h2'

-- Bottom adds yields with frameId = bd.frameId. The frame must exist
-- (applyOp checks this). When the frame exists:
theorem bottom_preserves_yieldsWellFormed (r : Retort) (bd : BottomData)
    (hWF : yieldsWellFormed r) :
    yieldsWellFormed (applyOp r (.bottom bd)) := by
  unfold yieldsWellFormed applyOp at *
  simp only
  split
  · exact hWF  -- frame not found
  · rename_i f hf
    split
    · exact hWF  -- cellDef not found
    · rename_i cd _hcd
      intro y hy
      rw [List.mem_append] at hy
      cases hy with
      | inl hyOld =>
        obtain ⟨fr, hfr, hfrid⟩ := hWF y hyOld
        exact ⟨fr, hfr, hfrid⟩
      | inr hyNew =>
        -- y is a bottom yield with frameId = bd.frameId
        rw [List.mem_map] at hyNew
        obtain ⟨fld, _, hyEq⟩ := hyNew
        -- The frame f has f.id == bd.frameId (from the find?)
        have hfMem := List.mem_of_find?_eq_some hf
        have hfPred := List.find?_some hf
        simp at hfPred
        rw [← hyEq]
        simp only
        exact ⟨f, hfMem, hfPred⟩

-- Bottom doesn't change bindings.
theorem bottom_preserves_bindingsWellFormed (r : Retort) (bd : BottomData)
    (hWF : bindingsWellFormed r) :
    bindingsWellFormed (applyOp r (.bottom bd)) := by
  have hEq : (applyOp r (.bottom bd)).bindings = r.bindings := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  have hFEq : (applyOp r (.bottom bd)).frames = r.frames := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  unfold bindingsWellFormed at *
  intro b hb
  have hb' : b ∈ r.bindings := hEq ▸ hb
  obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF b hb'
  exact ⟨⟨fc, hFEq ▸ hfc, hfcid⟩, ⟨fp, hFEq ▸ hfp, hfpid⟩⟩

-- Bottom filters claims (subset of original).
theorem bottom_preserves_claimsWellFormed (r : Retort) (bd : BottomData)
    (hWF : claimsWellFormed r) :
    claimsWellFormed (applyOp r (.bottom bd)) := by
  unfold claimsWellFormed applyOp at *
  simp only
  split
  · exact hWF  -- frame not found
  · rename_i f _hf
    split
    · exact hWF  -- cellDef not found
    · intro c hc
      rw [List.mem_filter] at hc
      obtain ⟨fr, hfr, hfrid⟩ := hWF c hc.1
      exact ⟨fr, hfr, hfrid⟩

-- Bottom filters claims (subset).
theorem bottom_preserves_claimMutex (r : Retort) (bd : BottomData)
    (hWF : claimMutex r) :
    claimMutex (applyOp r (.bottom bd)) := by
  unfold claimMutex applyOp at *
  simp only
  split
  · exact hWF  -- frame not found
  · rename_i f _hf
    split
    · exact hWF  -- cellDef not found
    · intro c1 c2 hc1 hc2 hSame
      rw [List.mem_filter] at hc1 hc2
      exact hWF c1 c2 hc1.1 hc2.1 hSame

-- Bottom preserves yieldUnique when the precondition holds.
-- We prove this via a helper that works on the concrete yields list.
private theorem bottom_yieldUnique_aux (r : Retort) (bd : BottomData)
    (hWF : yieldUnique r)
    (hBYU : bottomYieldsUnique r bd)
    (fr : Frame) (hfrMem : fr ∈ r.frames) (hfrPred : (fr.id == bd.frameId) = true)
    (cdef : RCellDef) (hcdefProp : r.cellDef fr.cellName = some cdef) :
    yieldUnique { r with
      yields := r.yields ++ cdef.fields.map (fun fld =>
        { frameId := bd.frameId, field := fld, value := bd.reason, isBottom := true : Yield }),
      claims := r.claims.filter (fun c => c.frameId != bd.frameId) } := by
  -- Pre-compute the key helper from hBYU before any unfolds.
  have hBYU' : ∀ y ∈ r.yields, y.frameId = bd.frameId →
      ∀ fld ∈ cdef.fields, y.field = fld → y.value = bd.reason := by
    have h := hBYU
    unfold bottomYieldsUnique at h
    exact h fr hfrMem hfrPred cdef hcdefProp
  unfold yieldUnique
  intro y1 y2 hy1 hy2 hfid hfield
  simp only at hy1 hy2
  rw [List.mem_append] at hy1 hy2
  cases hy1 with
  | inl hy1Old =>
    cases hy2 with
    | inl hy2Old => exact hWF y1 y2 hy1Old hy2Old hfid hfield
    | inr hy2New =>
      rw [List.mem_map] at hy2New
      obtain ⟨fld2, hfld2, hy2Eq⟩ := hy2New
      have hy2fid : y2.frameId = bd.frameId := by rw [← hy2Eq]
      have hy2val : y2.value = bd.reason := by rw [← hy2Eq]
      have hy2fld : y2.field = fld2 := by rw [← hy2Eq]
      have hy1fid : y1.frameId = bd.frameId := hfid ▸ hy2fid
      have hy1fld : y1.field = fld2 := hfield ▸ hy2fld
      have := hBYU' y1 hy1Old hy1fid fld2 hfld2 hy1fld
      rw [this, hy2val]
  | inr hy1New =>
    rw [List.mem_map] at hy1New
    obtain ⟨fld1, hfld1, hy1Eq⟩ := hy1New
    have hy1fid : y1.frameId = bd.frameId := by rw [← hy1Eq]
    have hy1val : y1.value = bd.reason := by rw [← hy1Eq]
    have hy1fld : y1.field = fld1 := by rw [← hy1Eq]
    cases hy2 with
    | inl hy2Old =>
      have hy2fid : y2.frameId = bd.frameId := hfid.symm ▸ hy1fid
      have hy2fld : y2.field = fld1 := hfield.symm ▸ hy1fld
      have := hBYU' y2 hy2Old hy2fid fld1 hfld1 hy2fld
      rw [hy1val, this]
    | inr hy2New =>
      rw [List.mem_map] at hy2New
      obtain ⟨_fld2, _, hy2Eq⟩ := hy2New
      rw [← hy1Eq, ← hy2Eq]

theorem bottom_preserves_yieldUnique (r : Retort) (bd : BottomData)
    (hWF : yieldUnique r)
    (hBYU : bottomYieldsUnique r bd) :
    yieldUnique (applyOp r (.bottom bd)) := by
  simp only [applyOp]
  split
  · exact hWF  -- frame not found
  · rename_i fr hfr
    split
    · exact hWF  -- cellDef not found
    · rename_i cdef hcdef
      have hfrPred : (fr.id == bd.frameId) = true := by
        have := List.find?_some hfr
        simp only at this
        exact this
      exact bottom_yieldUnique_aux r bd hWF hBYU fr
        (List.mem_of_find?_eq_some hfr)
        hfrPred
        cdef (by unfold Retort.cellDef; exact hcdef)

-- Bottom doesn't change cells, so framesCellDefsExist is trivially preserved.
theorem bottom_preserves_framesCellDefsExist (r : Retort) (bd : BottomData)
    (hWF : framesCellDefsExist r) :
    framesCellDefsExist (applyOp r (.bottom bd)) := by
  have hCEq : (applyOp r (.bottom bd)).cells = r.cells := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  have hFEq : (applyOp r (.bottom bd)).frames = r.frames := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  unfold framesCellDefsExist Retort.cellDef at *
  intro f hf
  have hf' : f ∈ r.frames := hFEq ▸ hf
  have hSome := hWF f hf'
  rw [List.find?_isSome] at hSome ⊢
  obtain ⟨c, hc, hpc⟩ := hSome
  exact ⟨c, hCEq ▸ hc, hpc⟩

-- Bottom doesn't change bindings.
theorem bottom_preserves_noSelfLoops (r : Retort) (bd : BottomData)
    (hWF : noSelfLoops r) :
    noSelfLoops (applyOp r (.bottom bd)) := by
  have hEq : (applyOp r (.bottom bd)).bindings = r.bindings := by
    simp only [applyOp]; split <;> (try split) <;> rfl
  unfold noSelfLoops at *
  intro b hb
  exact hWF b (hEq ▸ hb)

-- The master preservation theorem: any valid operation preserves wellFormed.
theorem wellFormed_preserved (r : Retort) (op : RetortOp)
    (hWF : wellFormed r)
    (hValid : validOp r op) :
    wellFormed (applyOp r op) := by
  unfold wellFormed at *
  obtain ⟨hI1, hI2, hI3, hI4, hI5, hI6, hI7, hI8, hI9, hI10, hI11⟩ := hWF
  cases op with
  | pour pd =>
    unfold validOp at hValid
    obtain ⟨hPourValid, hPourInternal, hPourFrames, hPourCellDefs, hPourDisjoint⟩ := hValid
    exact ⟨pour_preserves_cellNamesUnique r pd hI1 hPourValid hPourInternal,
           pour_preserves_framesUnique r pd hI2 hPourFrames,
           pour_preserves_yieldsWellFormed r pd hI3,
           pour_preserves_bindingsWellFormed r pd hI4,
           pour_preserves_claimsWellFormed r pd hI5,
           -- pour doesn't add claims, claimMutex trivially preserved
           (by unfold claimMutex applyOp at *; simp only; exact hI6),
           pour_preserves_yieldUnique r pd hI7,
           pour_preserves_framesCellDefsExist r pd hI8 hPourCellDefs,
           pour_preserves_noSelfLoops r pd hI9,
           pour_preserves_generationOrdered r pd hI10 hI4 hPourDisjoint,
           pour_preserves_bindingsPointToFrozen r pd hI11⟩
  | claim cd =>
    unfold validOp at hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           claim_preserves_framesUnique r cd hI2,
           claim_preserves_yieldsWellFormed r cd hI3,
           claim_preserves_bindingsWellFormed r cd hI4,
           claim_preserves_claimsWellFormed r cd hI5 hValid,
           claim_preserves_claimMutex r cd hI6 hValid,
           claim_preserves_yieldUnique r cd hI7,
           claim_preserves_framesCellDefsExist r cd hI8,
           claim_preserves_noSelfLoops r cd hI9,
           claim_preserves_generationOrdered r cd hI10,
           claim_preserves_bindingsPointToFrozen r cd hI11⟩
  | freeze fd =>
    unfold validOp at hValid
    obtain ⟨hFreezeValid, hWitnessed, hFrameExists, hProducers, hYieldsUnique,
            hNoSelfLoops, hGenOrdered, hBindFrozen⟩ := hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           freeze_preserves_framesUnique r fd hI2,
           freeze_preserves_yieldsWellFormed r fd hI3 hFreezeValid hFrameExists,
           freeze_preserves_bindingsWellFormed r fd hI4 hFreezeValid hFrameExists hProducers,
           freeze_preserves_claimsWellFormed r fd hI5,
           freeze_preserves_claimMutex r fd hI6,
           freeze_preserves_yieldUnique r fd hI7 hYieldsUnique,
           freeze_preserves_framesCellDefsExist r fd hI8,
           freeze_preserves_noSelfLoops r fd hI9 hNoSelfLoops,
           freeze_preserves_generationOrdered r fd hI10 hGenOrdered,
           freeze_preserves_bindingsPointToFrozen r fd hI11 hBindFrozen⟩
  | release rd =>
    unfold validOp at hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           release_preserves_framesUnique r rd hI2,
           release_preserves_yieldsWellFormed r rd hI3,
           release_preserves_bindingsWellFormed r rd hI4,
           release_preserves_claimsWellFormed r rd hI5,
           release_preserves_claimMutex r rd hI6,
           release_preserves_yieldUnique r rd hI7,
           release_preserves_framesCellDefsExist r rd hI8,
           release_preserves_noSelfLoops r rd hI9,
           release_preserves_generationOrdered r rd hI10,
           release_preserves_bindingsPointToFrozen r rd hI11⟩
  | createFrame cfd =>
    unfold validOp at hValid
    obtain ⟨hCfUnique, hCfCellDef, hCfDisjoint⟩ := hValid
    exact ⟨by { unfold cellNamesUnique applyOp at *; simp only; exact hI1 },
           createFrame_preserves_framesUnique r cfd hI2 hCfUnique,
           createFrame_preserves_yieldsWellFormed r cfd hI3,
           createFrame_preserves_bindingsWellFormed r cfd hI4,
           createFrame_preserves_claimsWellFormed r cfd hI5,
           -- createFrame doesn't change claims
           (by unfold claimMutex applyOp at *; simp only; exact hI6),
           createFrame_preserves_yieldUnique r cfd hI7,
           createFrame_preserves_framesCellDefsExist r cfd hI8 hCfCellDef,
           createFrame_preserves_noSelfLoops r cfd hI9,
           createFrame_preserves_generationOrdered r cfd hI10 hI4 hCfDisjoint,
           createFrame_preserves_bindingsPointToFrozen r cfd hI11⟩
  | bottom bd =>
    unfold validOp at hValid
    exact ⟨bottom_preserves_cellNamesUnique r bd hI1,
           bottom_preserves_framesUnique r bd hI2,
           bottom_preserves_yieldsWellFormed r bd hI3,
           bottom_preserves_bindingsWellFormed r bd hI4,
           bottom_preserves_claimsWellFormed r bd hI5,
           bottom_preserves_claimMutex r bd hI6,
           bottom_preserves_yieldUnique r bd hI7 hValid,
           bottom_preserves_framesCellDefsExist r bd hI8,
           bottom_preserves_noSelfLoops r bd hI9,
           bottom_preserves_generationOrdered r bd hI10,
           bottom_preserves_bindingsPointToFrozen r bd hI11⟩

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
  | bottom _ => simp only [applyOp]; split <;> (try split) <;> rfl

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
  | bottom _ => simp only [applyOp]; split <;> (try split) <;> rfl

/-! ====================================================================
    INDEPENDENT CLAIM COMMUTATIVITY
    ==================================================================== -/

-- Two claims on different frames commute: they produce states that agree
-- on all append-only fields and differ only in claims list order.

-- Helper: claims list is a permutation
theorem independent_claim_cells (r : Retort) (a b : ClaimData) :
    (applyOp (applyOp r (.claim a)) (.claim b)).cells =
    (applyOp (applyOp r (.claim b)) (.claim a)).cells := by
  simp [applyOp]

theorem independent_claim_givens (r : Retort) (a b : ClaimData) :
    (applyOp (applyOp r (.claim a)) (.claim b)).givens =
    (applyOp (applyOp r (.claim b)) (.claim a)).givens := by
  simp [applyOp]

theorem independent_claim_frames (r : Retort) (a b : ClaimData) :
    (applyOp (applyOp r (.claim a)) (.claim b)).frames =
    (applyOp (applyOp r (.claim b)) (.claim a)).frames := by
  simp [applyOp]

theorem independent_claim_yields (r : Retort) (a b : ClaimData) :
    (applyOp (applyOp r (.claim a)) (.claim b)).yields =
    (applyOp (applyOp r (.claim b)) (.claim a)).yields := by
  simp [applyOp]

theorem independent_claim_bindings (r : Retort) (a b : ClaimData) :
    (applyOp (applyOp r (.claim a)) (.claim b)).bindings =
    (applyOp (applyOp r (.claim b)) (.claim a)).bindings := by
  simp [applyOp]

-- The claims lists are permutations of each other:
-- r.claims ++ [a_claim, b_claim] vs r.claims ++ [b_claim, a_claim]
-- Both contain exactly the same elements.
theorem independent_claim_claims_perm (r : Retort) (a b : ClaimData)
    (_hDiff : a.frameId ≠ b.frameId) :
    ∀ c, c ∈ (applyOp (applyOp r (.claim a)) (.claim b)).claims ↔
         c ∈ (applyOp (applyOp r (.claim b)) (.claim a)).claims := by
  intro c
  simp only [applyOp]
  simp only [List.mem_append, List.mem_singleton]
  constructor
  · intro h
    rcases h with (h | h) | h
    · exact Or.inl (Or.inl h)
    · exact Or.inr h
    · exact Or.inl (Or.inr h)
  · intro h
    rcases h with (h | h) | h
    · exact Or.inl (Or.inl h)
    · exact Or.inr h
    · exact Or.inl (Or.inr h)

-- Corollary: for any membership-based property P, P holds on one state
-- iff it holds on the other. This means all our Prop-based invariants
-- (which quantify over ∈) are agnostic to claim order.
theorem independent_claims_preserve_membership_props
    (r : Retort) (a b : ClaimData) (hDiff : a.frameId ≠ b.frameId)
    (P : Claim → Prop)
    (hP : ∀ c ∈ (applyOp (applyOp r (.claim a)) (.claim b)).claims, P c) :
    ∀ c ∈ (applyOp (applyOp r (.claim b)) (.claim a)).claims, P c := by
  intro c hc
  exact hP c ((independent_claim_claims_perm r a b hDiff c).mpr hc)

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

-- appendOnly is reflexive.
theorem appendOnly_refl (r : Retort) : appendOnly r r := by
  unfold appendOnly cellsPreserved framesPreserved yieldsPreserved
         bindingsPreserved givensPreserved
  exact ⟨fun _ h => h, fun _ h => h, fun _ h => h,
         fun _ h => h, fun _ h => h⟩

-- appendOnly is transitive: if data grew from r1 to r2 and from r2 to r3,
-- then data grew from r1 to r3.
theorem appendOnly_trans (r1 r2 r3 : Retort)
    (h12 : appendOnly r1 r2) (h23 : appendOnly r2 r3) :
    appendOnly r1 r3 := by
  unfold appendOnly at *
  obtain ⟨c1, f1, y1, b1, g1⟩ := h12
  obtain ⟨c2, f2, y2, b2, g2⟩ := h23
  exact ⟨fun x hx => c2 x (c1 x hx), fun x hx => f2 x (f1 x hx),
         fun x hx => y2 x (y1 x hx), fun x hx => b2 x (b1 x hx),
         fun x hx => g2 x (g1 x hx)⟩

-- An eval cycle preserves append-only
theorem evalCycle_appendOnly (r : Retort) (ec : EvalCycle) :
    appendOnly r (applyEvalCycle r ec) := by
  unfold applyEvalCycle
  have h1 := all_ops_appendOnly r (.claim ec.claimOp)
  have h2 := all_ops_appendOnly (applyOp r (.claim ec.claimOp)) (.freeze ec.freezeOp)
  cases ec.nextFrame with
  | none =>
    simp
    exact appendOnly_trans _ _ _ h1 h2
  | some cfd =>
    simp
    have h3 := all_ops_appendOnly
      (applyOp (applyOp r (.claim ec.claimOp)) (.freeze ec.freezeOp))
      (.createFrame cfd)
    exact appendOnly_trans _ _ _ h1 (appendOnly_trans _ _ _ h2 h3)

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

/-! ## Monotone Demand Predicates

  A demand predicate is monotone if: once true, it stays true as the
  retort grows (append-only). This ensures a stem cell that has demand
  will continue to have demand even as other operations occur.
-/

-- A demand predicate is monotone w.r.t. appendOnly
def MonotoneDemand (demandPred : Retort → Bool) : Prop :=
  ∀ r r', appendOnly r r' → demandPred r = true → demandPred r' = true

-- With a monotone predicate, stemHasDemand is preserved by all operations.
theorem stemHasDemand_preserved (r : Retort) (op : RetortOp)
    (cell : CellName) (demandPred : Retort → Bool)
    (hMono : MonotoneDemand demandPred)
    (hDemand : r.stemHasDemand cell demandPred = true) :
    (applyOp r op).stemHasDemand cell demandPred = true := by
  unfold Retort.stemHasDemand at *
  exact hMono r (applyOp r op) (all_ops_appendOnly r op) hDemand

-- Demand based on "any ready frame exists for a given cell" is monotone:
-- ready frames come from the frames list, which only grows. New frames
-- can become ready, but existing ready frames don't become unready
-- (their givens remain satisfied because yields only grow).
-- This justifies constraining stemHasDemand to monotone predicates.

/-! ## Lazy (Demand-Driven) Stem Cell Spawning

  A stem cell should only spawn gen N+1 when at least one given's source
  has a yield frozen AFTER the stem's last frozen frame.  No new data =
  no spawn = no computation.  This is call-by-need / lazy evaluation.

  `demandFromGivens` is the concrete demand predicate:
    "some source cell referenced by a given has a frozen yield that did
     not exist at the time of the stem's last freeze."

  Because yields are append-only, once a new yield appears it never
  disappears, so `demandFromGivens` is monotone: once true it stays true.
-/

/-- A source cell has a frozen yield for the required field. -/
def Retort.sourceHasFrozenYield (r : Retort) (g : GivenSpec) : Bool :=
  r.frames.any (fun f =>
    f.cellName == g.sourceCell &&
    r.frameStatus f == .frozen &&
    r.yields.any (fun y => y.frameId == f.id && y.field == g.sourceField))

/-- Lazy demand: does any given of `cell` have a source with a frozen yield
    at a generation strictly higher than what was available when the stem
    last froze?

    In the formal model we approximate the temporal "frozen after" check
    with a structural one: a source frame at generation > 0 exists with a
    frozen yield that was not bound by the stem's latest frozen frame.
    This matches the Go implementation's `frozen_at > lastFreezeTime` check
    because each new generation's freeze creates a new frozen yield (new row
    in the append-only yields table).

    The simple version used here: any given whose source has a frozen yield
    at a generation higher than the stem's own current (latest frozen)
    generation.  Because the stem just froze at gen G, a source at gen > G
    means new data arrived after the stem's definition was established.

    For the common case (non-stem sources): they have exactly one frame
    at gen 0, so this reduces to "any given is satisfiable" -- which is
    the existing eager semantics.  The lazy aspect kicks in for stem-to-stem
    dependencies where the source is also cycling.

    Simplest correct formulation: at least one given's source has a frozen
    yield that the stem hasn't consumed yet.  Since yields are append-only,
    we can check: does the set of frozen source yields in the current retort
    strictly exceed what was available at the stem's last freeze?

    We use the simplest monotone approximation: the given is satisfiable
    (there exists SOME frozen yield for it).  This is sound because:
    - If no frozen yield exists for a given, there's nothing to consume.
    - If a frozen yield exists, spawning is justified.
    The Go implementation refines this with the temporal frozen_at check.
-/
def Retort.demandFromGivens (r : Retort) (cell : CellName) : Bool :=
  let cellGivens := r.givens.filter (fun g => g.owner == cell)
  -- No givens = no demand (matches Go: givenCount == 0 → return)
  !cellGivens.isEmpty &&
  -- At least one given's source has a frozen yield
  cellGivens.any (fun g => r.sourceHasFrozenYield g)

/-- `demandFromGivens` is monotone under `appendOnly` + `cellsPrefix`:
    once true, it stays true.

    The proof works as follows:
    1. `cellGivens` is a filtered subset of `givens`, which only grows.
       So `!cellGivens.isEmpty` is preserved (non-empty subset of growing list).
    2. `cellGivens.any (sourceHasFrozenYield)`: the witness given `g` still
       exists in `r'.givens` (givens append-only). For `sourceHasFrozenYield g`:
       a. The witness frame `f` still exists (frames append-only).
       b. `frameStatus f == .frozen` is preserved because `cellDef` is stable
          (cells grow as a suffix, so `find?` returns the same result) and
          frozen field coverage is monotone under yield growth.
       c. The witness yield `y` still exists (yields append-only).

    Step 2b uses `frozenStatus_preserved` which requires `r'.cells = r.cells`.
    Under `cellsPrefix`, `r'.cells = r.cells ++ extra`, so `cellDef` (which uses
    `List.find?`) returns the same result because `find?` on a prefix-extended
    list returns the same first match. All concrete operations satisfy `cellsPrefix`
    (see `all_ops_cellsPrefix`).
-/
theorem demandFromGivens_monotone (cell : CellName) :
    ∀ r r', appendOnly r r' → cellsPrefix r r' →
    r.demandFromGivens cell = true → r'.demandFromGivens cell = true := by
  intro r r' hAppend hPrefix hDemand
  unfold Retort.demandFromGivens at hDemand ⊢
  simp only [Bool.and_eq_true] at hDemand ⊢
  obtain ⟨hNE, hAny⟩ := hDemand
  have hGivensP := hAppend.2.2.2.2  -- givensPreserved
  unfold givensPreserved at hGivensP
  have hCellGivensSub : ∀ g ∈ r.givens.filter (fun g => g.owner == cell),
      g ∈ r'.givens.filter (fun g => g.owner == cell) := by
    intro g hg
    rw [List.mem_filter] at hg ⊢
    exact ⟨hGivensP g hg.1, hg.2⟩
  -- Extract witness from hAny first (needed for both sub-goals)
  rw [List.any_eq_true] at hAny
  obtain ⟨g, hg, hSrc⟩ := hAny
  constructor
  · -- Non-emptiness: g is in the r' filtered list, so it's non-empty
    have hgr' := hCellGivensSub g hg
    have hne : (r'.givens.filter (fun g => g.owner == cell)) ≠ [] :=
      List.ne_nil_of_mem hgr'
    cases hl : r'.givens.filter (fun g => g.owner == cell) with
    | nil => exact absurd hl hne
    | cons _ _ => rfl
  · -- sourceHasFrozenYield preserved
    rw [List.any_eq_true]
    refine ⟨g, hCellGivensSub g hg, ?_⟩
    unfold Retort.sourceHasFrozenYield at hSrc ⊢
    rw [List.any_eq_true] at hSrc ⊢
    obtain ⟨f, hf, hPred⟩ := hSrc
    simp only [Bool.and_eq_true] at hPred ⊢
    obtain ⟨⟨hCell, hFrozen⟩, hYield⟩ := hPred
    have hFramesP := hAppend.2.1  -- framesPreserved
    have hYieldsP := hAppend.2.2.1  -- yieldsPreserved
    unfold framesPreserved at hFramesP
    unfold yieldsPreserved at hYieldsP
    refine ⟨f, hFramesP f hf, ?_, ?_⟩
    · constructor
      · exact hCell
      · -- Frozen status preserved under appendOnly + cellsPrefix.
        -- cellsPrefix gives r'.cells = r.cells ++ extra, so cellDef (List.find?)
        -- returns the same result. frozenStatus_preserved then applies.
        have hFrozenProp : r.frameStatus f = .frozen :=
          FrameStatus.eq_of_beq_true _ _ hFrozen
        -- Derive cells equality for frozenStatus_preserved via cellsPrefix:
        -- find? on r.cells ++ extra returns the same as find? on r.cells
        -- when a match exists in r.cells.
        obtain ⟨extra, hCellsEq⟩ := hPrefix
        have hFrozenProp' : r'.frameStatus f = .frozen := by
          -- Use frozenStatus_preserved with the cellDef stability from prefix.
          -- We need r'.cells = r.cells for frozenStatus_preserved, but we have
          -- r'.cells = r.cells ++ extra. Unfold directly instead.
          unfold Retort.frameStatus at hFrozenProp ⊢
          unfold Retort.cellDef at *
          -- Case split on whether find? succeeds on r.cells
          cases hfind : r.cells.find? (fun c => c.name == f.cellName) with
          | none =>
            -- cellDef not found => frameStatus = .declared, contradicts frozen
            simp only [hfind] at hFrozenProp
            exact absurd hFrozenProp (by decide)
          | some cd =>
            simp only [hfind] at hFrozenProp
            -- find? on r'.cells = r.cells ++ extra returns same result (prefix)
            have hfind' : r'.cells.find? (fun c => c.name == f.cellName) = some cd := by
              rw [hCellsEq, List.find?_append]; simp [hfind]
            simp only [hfind']
            -- Now both have `some cd`; frozen field condition is preserved
            -- because yields only grew.
            simp only at hFrozenProp
            split at hFrozenProp
            · rename_i hAll
              rw [if_pos (frozen_fields_preserved r r' hYieldsP cd f.id hAll)]
            · split at hFrozenProp <;> simp at hFrozenProp
        have : (r'.frameStatus f == FrameStatus.frozen) = true := by
          rw [hFrozenProp']; decide
        exact this
    · rw [List.any_eq_true] at hYield ⊢
      obtain ⟨y, hy, hyPred⟩ := hYield
      exact ⟨y, hYieldsP y hy, hyPred⟩

/-- The lazy eval cycle: like EvalCycle, but nextFrame is gated by demandFromGivens. -/
structure LazyEvalCycle where
  claimOp   : ClaimData
  freezeOp  : FreezeData
  cellName  : CellName
  deriving Repr

/-- Apply a lazy eval cycle: claim, freeze, then create next-gen frame
    ONLY if demandFromGivens is true after the freeze. -/
def applyLazyEvalCycle (r : Retort) (lec : LazyEvalCycle) : Retort :=
  let r1 := applyOp r (.claim lec.claimOp)
  let r2 := applyOp r1 (.freeze lec.freezeOp)
  -- Lazy: only create next frame if there's demand from givens
  if r2.demandFromGivens lec.cellName then
    let nextGen := r2.currentGen lec.cellName + 1
    let newFrame : Frame := {
      id := ⟨s!"f-{lec.cellName.val}-{nextGen}"⟩,
      cellName := lec.cellName,
      program := r2.frames.head?.map (·.program) |>.getD ⟨""⟩,
      generation := nextGen
    }
    applyOp r2 (.createFrame ⟨newFrame⟩)
  else
    r2  -- No demand → no spawn → quiescent

/-- A lazy eval cycle preserves append-only (regardless of whether spawn happens).
    Uses sorry because the if-let reduction through applyLazyEvalCycle requires
    unfolding past nested let-bindings. The proof follows directly from
    evalCycle_appendOnly's structure (claim → freeze → optional createFrame). -/
theorem lazyEvalCycle_appendOnly (r : Retort) (lec : LazyEvalCycle) :
    appendOnly r (applyLazyEvalCycle r lec) := by
  unfold applyLazyEvalCycle
  have h1 := all_ops_appendOnly r (.claim lec.claimOp)
  have h2 := all_ops_appendOnly (applyOp r (.claim lec.claimOp)) (.freeze lec.freezeOp)
  have h12 := appendOnly_trans _ _ _ h1 h2
  -- Both branches (with or without createFrame) compose append-only operations.
  simp only
  split
  · -- demand exists → claim, freeze, createFrame
    exact appendOnly_trans _ _ _ h12
      (all_ops_appendOnly _ (.createFrame _))
  · -- no demand → claim, freeze only
    exact h12

/-- When demandFromGivens is false, the lazy cycle produces no new frame.
    This is the key "no new data = no spawn" property. -/
theorem lazy_no_demand_no_spawn (r : Retort) (lec : LazyEvalCycle)
    (hNoDemand : (applyOp (applyOp r (.claim lec.claimOp))
                   (.freeze lec.freezeOp)).demandFromGivens lec.cellName = false) :
    (applyLazyEvalCycle r lec).frames =
    (applyOp (applyOp r (.claim lec.claimOp)) (.freeze lec.freezeOp)).frames := by
  simp only [applyLazyEvalCycle, hNoDemand]
  -- After simp, the if-condition is `false = true`, which is `if False then ... else ...`
  simp

/-- When demandFromGivens is true, the lazy cycle creates exactly one new frame. -/
theorem lazy_demand_spawns (r : Retort) (lec : LazyEvalCycle)
    (hDemand : (applyOp (applyOp r (.claim lec.claimOp))
                 (.freeze lec.freezeOp)).demandFromGivens lec.cellName = true) :
    (applyLazyEvalCycle r lec).frames.length =
    (applyOp (applyOp r (.claim lec.claimOp)) (.freeze lec.freezeOp)).frames.length + 1 := by
  simp only [applyLazyEvalCycle, hDemand]
  simp [applyOp, List.length_append]

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
    exact appendOnly_refl _
  | succ k ih =>
    by_cases hk : n ≤ k
    · exact appendOnly_trans _ _ _ (ih hk) (always_appendOnly vt k)
    · have hEq : n = k + 1 := by omega
      subst hEq
      exact appendOnly_refl _

/-! ====================================================================
    WELL-FORMED TRACES (wellFormed preserved across all time)
    ==================================================================== -/

-- A ValidWFTrace extends ValidTrace: every operation is valid,
-- and the initial state is well-formed (vacuously for Retort.empty).
structure ValidWFTrace extends ValidTrace where
  validOps : ∀ n, validOp (toValidTrace.trace n) (toValidTrace.ops n)

-- Retort.empty is well-formed (all lists are empty, so all invariants hold vacuously).
theorem empty_wellFormed : wellFormed Retort.empty := by
  unfold wellFormed
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · -- I1: cellNamesUnique
    unfold cellNamesUnique; intro c1 _ h; simp [Retort.empty] at h
  · -- I2: framesUnique
    unfold framesUnique; intro f1 _ h; simp [Retort.empty] at h
  · -- I3: yieldsWellFormed
    unfold yieldsWellFormed; intro y h; simp [Retort.empty] at h
  · -- I4: bindingsWellFormed
    unfold bindingsWellFormed; intro b h; simp [Retort.empty] at h
  · -- I5: claimsWellFormed
    unfold claimsWellFormed; intro c h; simp [Retort.empty] at h
  · -- I6: claimMutex
    unfold claimMutex; intro c1 _ h; simp [Retort.empty] at h
  · -- I7: yieldUnique
    unfold yieldUnique; intro y1 _ h; simp [Retort.empty] at h
  · -- I8: framesCellDefsExist
    unfold framesCellDefsExist; intro f h; simp [Retort.empty] at h
  · -- I9: noSelfLoops
    unfold noSelfLoops; intro b h; simp [Retort.empty] at h
  · -- I10: generationOrdered
    unfold generationOrdered; intro b h; simp [Retort.empty] at h
  · -- I11: bindingsPointToFrozen
    unfold bindingsPointToFrozen; intro b h; simp [Retort.empty] at h

-- The main induction: wellFormed is an invariant of well-formed traces.
theorem always_wellFormed (vt : ValidWFTrace) :
    ∀ n, wellFormed (vt.trace n) := by
  intro n
  induction n with
  | zero =>
    rw [vt.init]
    exact empty_wellFormed
  | succ k ih =>
    rw [vt.step k]
    exact wellFormed_preserved (vt.trace k) (vt.ops k) ih (vt.validOps k)

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
  cases vt.ops n with
  | bottom _ => simp only [applyOp]; split <;> (try split) <;> simp_all
  | _ => simp [applyOp, List.length_append]; try omega

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
  cases vt.ops n with
  | bottom _ =>
    simp only [applyOp]; split <;> (try split) <;> simp_all [List.length_append]
    all_goals omega
  | _ => simp [applyOp, List.length_append]; try omega

-- Bindings grow monotonically (append-only)
theorem bindings_monotonic (vt : ValidTrace) (n : Nat) :
    (vt.trace n).bindings.length ≤ (vt.trace (n + 1)).bindings.length := by
  rw [vt.step n]
  cases vt.ops n with
  | bottom _ => simp only [applyOp]; split <;> (try split) <;> simp_all
  | _ => simp [applyOp, List.length_append]; try omega

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
    MULTI-PROGRAM COMPOSITION
    ==================================================================== -/

/-- Two retorts with disjoint program IDs can be merged. The merge
    concatenates all append-only fields and the mutable claims list. -/
def Retort.merge (r1 r2 : Retort) : Retort :=
  { cells    := r1.cells ++ r2.cells
    givens   := r1.givens ++ r2.givens
    frames   := r1.frames ++ r2.frames
    yields   := r1.yields ++ r2.yields
    bindings := r1.bindings ++ r2.bindings
    claims   := r1.claims ++ r2.claims }

/-- Programs are disjoint: no cell definition's program ID appears in both retorts. -/
def programsDisjoint (r1 r2 : Retort) : Prop :=
  ∀ c1 ∈ r1.cells, ∀ c2 ∈ r2.cells, c1.program ≠ c2.program

/-- Frames are disjoint: no frame ID appears in both retorts. -/
def framesDisjoint (r1 r2 : Retort) : Prop :=
  ∀ f1 ∈ r1.frames, ∀ f2 ∈ r2.frames, f1.id ≠ f2.id

/-- Frame IDs in yields are disjoint between the two retorts. -/
def yieldFramesDisjoint (r1 r2 : Retort) : Prop :=
  ∀ y1 ∈ r1.yields, ∀ y2 ∈ r2.yields, y1.frameId ≠ y2.frameId

/-- Frame IDs in claims are disjoint between the two retorts. -/
def claimFramesDisjoint (r1 r2 : Retort) : Prop :=
  ∀ c1 ∈ r1.claims, ∀ c2 ∈ r2.claims, c1.frameId ≠ c2.frameId

/-- Full merge compatibility: programs, frames, yields, and claims are disjoint. -/
structure MergeCompatible (r1 r2 : Retort) : Prop where
  progDisjoint   : programsDisjoint r1 r2
  frameDisjoint  : framesDisjoint r1 r2
  yieldDisjoint  : yieldFramesDisjoint r1 r2
  claimDisjoint  : claimFramesDisjoint r1 r2

/-- Merge preserves cellNamesUnique when programs are disjoint. -/
theorem merge_preserves_cellNamesUnique (r1 r2 : Retort)
    (hWF1 : cellNamesUnique r1) (hWF2 : cellNamesUnique r2)
    (hDisjoint : programsDisjoint r1 r2) :
    cellNamesUnique (Retort.merge r1 r2) := by
  unfold cellNamesUnique Retort.merge at *
  simp only
  intro c1 c2 hc1 hc2 hProg hName
  rw [List.mem_append] at hc1 hc2
  cases hc1 with
  | inl h1L =>
    cases hc2 with
    | inl h2L => exact hWF1 c1 c2 h1L h2L hProg hName
    | inr h2R => exact absurd hProg (hDisjoint c1 h1L c2 h2R)
  | inr h1R =>
    cases hc2 with
    | inl h2L => exact absurd hProg.symm (hDisjoint c2 h2L c1 h1R)
    | inr h2R => exact hWF2 c1 c2 h1R h2R hProg hName

/-- Frame cell names from r1 and r2 are disjoint. -/
def frameCellNamesDisjoint (r1 r2 : Retort) : Prop :=
  ∀ f1 ∈ r1.frames, ∀ f2 ∈ r2.frames, f1.cellName ≠ f2.cellName

/-- Merge preserves framesUnique when frame cell names are disjoint. -/
theorem merge_preserves_framesUnique' (r1 r2 : Retort)
    (hWF1 : framesUnique r1) (hWF2 : framesUnique r2)
    (hDisjoint : frameCellNamesDisjoint r1 r2) :
    framesUnique (Retort.merge r1 r2) := by
  unfold framesUnique Retort.merge at *
  simp only
  intro f1 f2 hf1 hf2 hCell hGen
  rw [List.mem_append] at hf1 hf2
  cases hf1 with
  | inl h1L =>
    cases hf2 with
    | inl h2L => exact hWF1 f1 f2 h1L h2L hCell hGen
    | inr h2R => exact absurd hCell (hDisjoint f1 h1L f2 h2R)
  | inr h1R =>
    cases hf2 with
    | inl h2L => exact absurd hCell.symm (hDisjoint f2 h2L f1 h1R)
    | inr h2R => exact hWF2 f1 f2 h1R h2R hCell hGen

/-- Merge preserves yieldsWellFormed: each yield's frame exists in the
    merged frame list. -/
theorem merge_preserves_yieldsWellFormed (r1 r2 : Retort)
    (hWF1 : yieldsWellFormed r1) (hWF2 : yieldsWellFormed r2) :
    yieldsWellFormed (Retort.merge r1 r2) := by
  unfold yieldsWellFormed Retort.merge at *
  simp only
  intro y hy
  rw [List.mem_append] at hy
  cases hy with
  | inl hyL =>
    obtain ⟨f, hf, hfid⟩ := hWF1 y hyL
    exact ⟨f, List.mem_append_left _ hf, hfid⟩
  | inr hyR =>
    obtain ⟨f, hf, hfid⟩ := hWF2 y hyR
    exact ⟨f, List.mem_append_right _ hf, hfid⟩

/-- Merge preserves bindingsWellFormed. -/
theorem merge_preserves_bindingsWellFormed (r1 r2 : Retort)
    (hWF1 : bindingsWellFormed r1) (hWF2 : bindingsWellFormed r2) :
    bindingsWellFormed (Retort.merge r1 r2) := by
  unfold bindingsWellFormed Retort.merge at *
  simp only
  intro b hb
  rw [List.mem_append] at hb
  cases hb with
  | inl hbL =>
    obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF1 b hbL
    exact ⟨⟨fc, List.mem_append_left _ hfc, hfcid⟩,
           ⟨fp, List.mem_append_left _ hfp, hfpid⟩⟩
  | inr hbR =>
    obtain ⟨⟨fc, hfc, hfcid⟩, ⟨fp, hfp, hfpid⟩⟩ := hWF2 b hbR
    exact ⟨⟨fc, List.mem_append_right _ hfc, hfcid⟩,
           ⟨fp, List.mem_append_right _ hfp, hfpid⟩⟩

/-- Merge preserves claimsWellFormed. -/
theorem merge_preserves_claimsWellFormed (r1 r2 : Retort)
    (hWF1 : claimsWellFormed r1) (hWF2 : claimsWellFormed r2) :
    claimsWellFormed (Retort.merge r1 r2) := by
  unfold claimsWellFormed Retort.merge at *
  simp only
  intro c hc
  rw [List.mem_append] at hc
  cases hc with
  | inl hcL =>
    obtain ⟨f, hf, hfid⟩ := hWF1 c hcL
    exact ⟨f, List.mem_append_left _ hf, hfid⟩
  | inr hcR =>
    obtain ⟨f, hf, hfid⟩ := hWF2 c hcR
    exact ⟨f, List.mem_append_right _ hf, hfid⟩

/-- Merge preserves claimMutex when claim frame IDs are disjoint. -/
theorem merge_preserves_claimMutex (r1 r2 : Retort)
    (hWF1 : claimMutex r1) (hWF2 : claimMutex r2)
    (hDisjoint : claimFramesDisjoint r1 r2) :
    claimMutex (Retort.merge r1 r2) := by
  unfold claimMutex Retort.merge at *
  simp only
  intro c1 c2 hc1 hc2 hSameFrame
  rw [List.mem_append] at hc1 hc2
  cases hc1 with
  | inl h1L =>
    cases hc2 with
    | inl h2L => exact hWF1 c1 c2 h1L h2L hSameFrame
    | inr h2R => exact absurd hSameFrame (hDisjoint c1 h1L c2 h2R)
  | inr h1R =>
    cases hc2 with
    | inl h2L => exact absurd hSameFrame.symm (hDisjoint c2 h2L c1 h1R)
    | inr h2R => exact hWF2 c1 c2 h1R h2R hSameFrame

/-- Merge preserves yieldUnique when yield frame IDs are disjoint. -/
theorem merge_preserves_yieldUnique (r1 r2 : Retort)
    (hWF1 : yieldUnique r1) (hWF2 : yieldUnique r2)
    (hDisjoint : yieldFramesDisjoint r1 r2) :
    yieldUnique (Retort.merge r1 r2) := by
  unfold yieldUnique Retort.merge at *
  simp only
  intro y1 y2 hy1 hy2 hfid hfield
  rw [List.mem_append] at hy1 hy2
  cases hy1 with
  | inl h1L =>
    cases hy2 with
    | inl h2L => exact hWF1 y1 y2 h1L h2L hfid hfield
    | inr h2R => exact absurd hfid (hDisjoint y1 h1L y2 h2R)
  | inr h1R =>
    cases hy2 with
    | inl h2L => exact absurd hfid.symm (hDisjoint y2 h2L y1 h1R)
    | inr h2R => exact hWF2 y1 y2 h1R h2R hfid hfield

/-- Merge preserves noSelfLoops. -/
theorem merge_preserves_noSelfLoops (r1 r2 : Retort)
    (hWF1 : noSelfLoops r1) (hWF2 : noSelfLoops r2) :
    noSelfLoops (Retort.merge r1 r2) := by
  unfold noSelfLoops Retort.merge at *
  simp only
  intro b hb
  rw [List.mem_append] at hb
  cases hb with
  | inl hbL => exact hWF1 b hbL
  | inr hbR => exact hWF2 b hbR

/-- Merge preserves generationOrdered when frames are disjoint. -/
theorem merge_preserves_generationOrdered (r1 r2 : Retort)
    (hWF1 : generationOrdered r1) (hWF2 : generationOrdered r2)
    (hBWF1 : bindingsWellFormed r1) (hBWF2 : bindingsWellFormed r2) :
    generationOrdered (Retort.merge r1 r2) := by
  unfold generationOrdered Retort.merge at *
  simp only
  intro b hb cf hcf pf hpf hcid hpid hcell
  rw [List.mem_append] at hb
  cases hb with
  | inl hbL =>
    -- b from r1: consumer and producer frames exist in r1 (by bindingsWellFormed)
    obtain ⟨⟨cf', hcf', hcf'id⟩, ⟨pf', hpf', hpf'id⟩⟩ := hBWF1 b hbL
    exact hWF1 b hbL cf' hcf' pf' hpf' (hcf'id.symm ▸ hcid) (hpf'id.symm ▸ hpid) hcell
  | inr hbR =>
    obtain ⟨⟨cf', hcf', hcf'id⟩, ⟨pf', hpf', hpf'id⟩⟩ := hBWF2 b hbR
    exact hWF2 b hbR cf' hcf' pf' hpf' (hcf'id.symm ▸ hcid) (hpf'id.symm ▸ hpid) hcell

/-- The full merge disjointness condition for framesCellDefsExist:
    each retort's cellDef lookup must still work in the merged cells list.
    Since find? returns the FIRST match, and r1.cells is a prefix,
    old lookups from r1 still work. For r2, we need that r2 cells are
    still findable (which they are, since they're in the suffix). -/
theorem merge_preserves_framesCellDefsExist (r1 r2 : Retort)
    (hWF1 : framesCellDefsExist r1) (hWF2 : framesCellDefsExist r2) :
    framesCellDefsExist (Retort.merge r1 r2) := by
  unfold framesCellDefsExist Retort.merge Retort.cellDef at *
  simp only
  intro f hf
  rw [List.mem_append] at hf
  cases hf with
  | inl hfL =>
    -- f from r1: cellDef exists in r1.cells, so find? on r1.cells ++ r2.cells succeeds
    have hSome := hWF1 f hfL
    rw [List.find?_isSome] at hSome ⊢
    obtain ⟨c, hc, hpc⟩ := hSome
    exact ⟨c, List.mem_append_left _ hc, hpc⟩
  | inr hfR =>
    have hSome := hWF2 f hfR
    rw [List.find?_isSome] at hSome ⊢
    obtain ⟨c, hc, hpc⟩ := hSome
    exact ⟨c, List.mem_append_right _ hc, hpc⟩

/-- Cell names are globally disjoint: no cell name appears in both retorts.
    This is needed because cellDef uses find? by name (not by program),
    so same-name cells from different programs would cause lookup confusion. -/
def cellNamesDisjoint (r1 r2 : Retort) : Prop :=
  ∀ c1 ∈ r1.cells, ∀ c2 ∈ r2.cells, c1.name ≠ c2.name

/-- The composite merge disjointness condition. -/
structure MergeDisjoint (r1 r2 : Retort) extends MergeCompatible r1 r2 : Prop where
  frameCellDisjoint : frameCellNamesDisjoint r1 r2
  cellNameDisjoint  : cellNamesDisjoint r1 r2

/-- Helper: find? on l1 ++ l2 where find? on l1 = none returns find? on l2. -/
private theorem find?_append_none {α : Type} {p : α → Bool} {l1 l2 : List α}
    (h : l1.find? p = none) :
    (l1 ++ l2).find? p = l2.find? p := by
  rw [List.find?_append, h]; simp

/-- Helper: cellNamesDisjoint implies no r1 cell name matches any r2 frame cellName
    (when combined with framesCellDefsExist from r2). -/
private theorem cellName_not_in_r1_cells (r1 r2 : Retort) (f : Frame)
    (hf : f ∈ r2.frames) (hCDE : framesCellDefsExist r2)
    (hCND : cellNamesDisjoint r1 r2) :
    r1.cells.find? (fun c => c.name == f.cellName) = none := by
  rw [List.find?_eq_none]
  intro c hc hbeq
  -- c is in r1.cells, and c.name == f.cellName
  -- f is in r2.frames, so by framesCellDefsExist, there exists a cell in r2.cells
  -- with name == f.cellName
  have hSome := hCDE f hf
  unfold Retort.cellDef at hSome
  rw [List.find?_isSome] at hSome
  obtain ⟨c2, hc2, hc2name⟩ := hSome
  -- c.name == f.cellName and c2.name == f.cellName
  -- so c.name = c2.name, contradicting cellNamesDisjoint
  have hceq : c.name = f.cellName := eq_of_beq hbeq
  have hc2eq : c2.name = f.cellName := eq_of_beq hc2name
  exact absurd (hceq ▸ hc2eq ▸ rfl : c.name = c2.name) (hCND c hc c2 hc2)

/-- Merge preserves wellFormed when all disjointness conditions hold. -/
theorem merge_preserves_wellFormed (r1 r2 : Retort)
    (hWF1 : wellFormed r1) (hWF2 : wellFormed r2)
    (hDisjoint : MergeDisjoint r1 r2) :
    wellFormed (Retort.merge r1 r2) := by
  unfold wellFormed at *
  obtain ⟨h1I1, h1I2, h1I3, h1I4, h1I5, h1I6, h1I7, h1I8, h1I9, h1I10, h1I11⟩ := hWF1
  obtain ⟨h2I1, h2I2, h2I3, h2I4, h2I5, h2I6, h2I7, h2I8, h2I9, h2I10, h2I11⟩ := hWF2
  refine ⟨merge_preserves_cellNamesUnique r1 r2 h1I1 h2I1 hDisjoint.progDisjoint,
         merge_preserves_framesUnique' r1 r2 h1I2 h2I2 hDisjoint.frameCellDisjoint,
         merge_preserves_yieldsWellFormed r1 r2 h1I3 h2I3,
         merge_preserves_bindingsWellFormed r1 r2 h1I4 h2I4,
         merge_preserves_claimsWellFormed r1 r2 h1I5 h2I5,
         merge_preserves_claimMutex r1 r2 h1I6 h2I6 hDisjoint.claimDisjoint,
         merge_preserves_yieldUnique r1 r2 h1I7 h2I7 hDisjoint.yieldDisjoint,
         merge_preserves_framesCellDefsExist r1 r2 h1I8 h2I8,
         merge_preserves_noSelfLoops r1 r2 h1I9 h2I9,
         merge_preserves_generationOrdered r1 r2 h1I10 h2I10 h1I4 h2I4,
         ?_⟩
  -- I11: bindingsPointToFrozen for merge
  unfold bindingsPointToFrozen Retort.merge at *
  simp only
  intro b hb
  rw [List.mem_append] at hb
  cases hb with
  | inl hbL =>
    -- b from r1: producer frame exists and is frozen in r1
    obtain ⟨f, hf, hfid, hfrozen⟩ := h1I11 b hbL
    refine ⟨f, List.mem_append_left _ hf, hfid, ?_⟩
    -- frameStatus in merge: cellDef on r1.cells ++ r2.cells
    -- For f from r1, find? on r1.cells succeeds, so find? on merged
    -- returns the same result.
    unfold Retort.frameStatus at hfrozen ⊢
    unfold Retort.cellDef at *
    cases hcd : r1.cells.find? (fun c => c.name == f.cellName) with
    | none => rw [hcd] at hfrozen; exact absurd hfrozen (by decide)
    | some cd =>
      rw [hcd] at hfrozen
      have hcd' : (r1.cells ++ r2.cells).find? (fun c => c.name == f.cellName)
          = some cd := by
        rw [List.find?_append]; simp [hcd]
      rw [hcd']
      unfold Retort.frameYields at *
      simp only at hfrozen ⊢
      exact frozen_fields_preserved
        { cells := r1.cells, givens := r1.givens, frames := r1.frames,
          yields := r1.yields, bindings := r1.bindings, claims := r1.claims }
        { cells := r1.cells ++ r2.cells, givens := r1.givens ++ r2.givens,
          frames := r1.frames ++ r2.frames,
          yields := r1.yields ++ r2.yields,
          bindings := r1.bindings ++ r2.bindings,
          claims := r1.claims ++ r2.claims }
        (fun y hy => List.mem_append_left _ hy) cd f.id
        (by split at hfrozen
            · rename_i h; exact h
            · split at hfrozen <;> simp at hfrozen)
  | inr hbR =>
    -- b from r2: producer frame exists and is frozen in r2
    obtain ⟨f, hf, hfid, hfrozen⟩ := h2I11 b hbR
    refine ⟨f, List.mem_append_right _ hf, hfid, ?_⟩
    unfold Retort.frameStatus at hfrozen ⊢
    unfold Retort.cellDef at *
    cases hcd : r2.cells.find? (fun c => c.name == f.cellName) with
    | none => rw [hcd] at hfrozen; exact absurd hfrozen (by decide)
    | some cd =>
      rw [hcd] at hfrozen
      -- No r1 cell has f's cellName (by cellNamesDisjoint + framesCellDefsExist)
      have hNoR1 : r1.cells.find? (fun c => c.name == f.cellName) = none :=
        cellName_not_in_r1_cells r1 r2 f hf h2I8 hDisjoint.cellNameDisjoint
      have hcd' : (r1.cells ++ r2.cells).find? (fun c => c.name == f.cellName)
          = some cd := by
        rw [find?_append_none hNoR1, hcd]
      rw [hcd']
      unfold Retort.frameYields at *
      simp only at hfrozen ⊢
      exact frozen_fields_preserved
        { cells := r2.cells, givens := r2.givens, frames := r2.frames,
          yields := r2.yields, bindings := r2.bindings, claims := r2.claims }
        { cells := r1.cells ++ r2.cells, givens := r1.givens ++ r2.givens,
          frames := r1.frames ++ r2.frames,
          yields := r1.yields ++ r2.yields,
          bindings := r1.bindings ++ r2.bindings,
          claims := r1.claims ++ r2.claims }
        (fun y hy => List.mem_append_right _ hy) cd f.id
        (by split at hfrozen
            · rename_i h; exact h
            · split at hfrozen <;> simp at hfrozen)

/-! ====================================================================
    PROJECTION TO CLAIMS STATE
    ==================================================================== -/

/-- Project a Retort state to the Claims.State model. This bridges the
    operational model (Retort) with the temporal logic model (Claims).

    The mapping is:
    - Retort.claims  -> Claims.State.holders (active locks)
    - Retort.yields  -> Claims.State.yieldStore (frozen values)

    This allows Claims-level theorems (mutual exclusion, yield immutability)
    to be applied to Retort states. -/
def Retort.toClaimsState (r : Retort) : Claims.State :=
  { holders    := r.claims.map (fun c => (c.frameId, c.pistonId))
    yieldStore := r.yields.map (fun y => ⟨y.frameId, y.field.val, y.value⟩) }

/-- The projection preserves the mutual exclusion property:
    if claimMutex holds in the Retort, then Claims.mutualExclusion holds
    in the projected Claims.State. -/
theorem toClaimsState_preserves_mutex (r : Retort) (hMutex : claimMutex r) :
    Claims.mutualExclusion (r.toClaimsState) := by
  unfold Claims.mutualExclusion Retort.toClaimsState
  intro f p1 p2 h1 h2
  simp [List.mem_map] at h1 h2
  obtain ⟨c1, hc1mem, hc1f, hc1p⟩ := h1
  obtain ⟨c2, hc2mem, hc2f, hc2p⟩ := h2
  have hSameFrame : c1.frameId = c2.frameId := by rw [hc1f, hc2f]
  have hEq := hMutex c1 c2 hc1mem hc2mem hSameFrame
  rw [← hc1p, ← hc2p, hEq]

/-- The projection preserves yield membership: a yield in the Retort
    appears as a StoredYield in the Claims state. -/
theorem toClaimsState_yields_correspond (r : Retort) (y : Yield) (hy : y ∈ r.yields) :
    (⟨y.frameId, y.field.val, y.value⟩ : Claims.StoredYield) ∈ r.toClaimsState.yieldStore := by
  unfold Retort.toClaimsState
  simp [List.mem_map]
  exact ⟨y, hy, rfl, rfl, rfl⟩

/-! ====================================================================
    MERGE IS ASSOCIATIVE AND COMMUTATIVE (on disjoint programs)
    ==================================================================== -/

/-- Merge is associative. -/
theorem merge_assoc (r1 r2 r3 : Retort) :
    Retort.merge (Retort.merge r1 r2) r3 = Retort.merge r1 (Retort.merge r2 r3) := by
  unfold Retort.merge
  simp [List.append_assoc]

/-- Merge data contains both inputs: r1's data is in r1.merge r2. -/
theorem merge_contains_left (r1 r2 : Retort) :
    appendOnly r1 (Retort.merge r1 r2) := by
  unfold appendOnly cellsPreserved framesPreserved yieldsPreserved
         bindingsPreserved givensPreserved Retort.merge
  simp only
  exact ⟨fun x hx => List.mem_append_left _ hx,
         fun x hx => List.mem_append_left _ hx,
         fun x hx => List.mem_append_left _ hx,
         fun x hx => List.mem_append_left _ hx,
         fun x hx => List.mem_append_left _ hx⟩

theorem merge_contains_right (r1 r2 : Retort) :
    appendOnly r2 (Retort.merge r1 r2) := by
  unfold appendOnly cellsPreserved framesPreserved yieldsPreserved
         bindingsPreserved givensPreserved Retort.merge
  simp only
  exact ⟨fun x hx => List.mem_append_right _ hx,
         fun x hx => List.mem_append_right _ hx,
         fun x hx => List.mem_append_right _ hx,
         fun x hx => List.mem_append_right _ hx,
         fun x hx => List.mem_append_right _ hx⟩

/-! ====================================================================
    SUMMARY: The Complete Formal Model
    ====================================================================

  TYPES:
  - RCellDef, GivenSpec: immutable definitions (set at pour time)
  - Frame: immutable execution instances (append-only)
  - Yield: immutable outputs (append-only), with isBottom flag for error values
  - Binding: immutable resolved givens (append-only, DAG edges)
  - Claim: mutable lock (the ONLY mutable component)

  DERIVED STATE (never stored):
  - FrameStatus: declared | computing | frozen
  - isBottomFrame: frozen frame where ALL yields carry isBottom=true
  - hasBottomedDep: non-optional dependency on a bottom frame
  - Ready frames: declared + all givens satisfied
  - Program complete: all non-stem cells have frozen frames
    (includes bottom frames — they are terminal)
  - Content address: (cellName, generation, field) → value

  INVARIANTS:
  - I1: cellNamesUnique — cell names unique per program
  - I2: framesUnique — (cell, generation) pairs unique
  - I3-I5: referential integrity (yields, bindings, claims → frames)
  - I6: claimMutex — at most one claim per frame
  - I7: yieldUnique — each (frame, field) has at most one value
  - I8: framesCellDefsExist — every frame has a cell definition
  - I9: noSelfLoops — no binding has consumerFrame = producerFrame

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
  - appendOnly_refl: reflexivity of append-only
  - appendOnly_trans: transitivity of append-only (factored lemma)
  - cells_stable_non_pour: cell defs never change after pour
  - givens_stable_non_pour: givens never change after pour
  - evalCycle_appendOnly: full eval cycles preserve append-only (via appendOnly_trans)
  - always_appendOnly: □appendOnly on valid traces
  - data_persists: data from time T exists at all T' > T (via appendOnly_trans)

  Invariant preservation (all 11 invariants, all 6 operations):
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
  - I8 framesCellDefsExist: pour (with precond), createFrame (with precond),
      claim/freeze/release (trivial)
  - I9 noSelfLoops: freeze (with precond), others (trivial)
  - I10 generationOrdered: freeze (with freezeGenerationOrdered),
      pour/createFrame (with bindingsWellFormed), claim/release (trivial)
  - I11 bindingsPointToFrozen: freeze (with freezeBindingsPointToFrozen),
      pour (yields preserved), claim/release (trivial),
      createFrame (yields preserved)

  Multi-program composition:
  - Retort.merge: concatenation of all fields
  - merge_preserves_wellFormed: merge of two well-formed retorts with
      disjoint programs/cells/frames produces a well-formed retort
  - merge_assoc: merge is associative
  - merge_contains_left, merge_contains_right: appendOnly embeddings

  Claims projection:
  - Retort.toClaimsState: project to Claims.State
  - toClaimsState_preserves_mutex: claimMutex -> mutualExclusion
  - toClaimsState_yields_correspond: yield membership preserved

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
  - bindingsMonotone preservation (all 5 operations):
      pour (with bindingsWellFormed), claim (trivial), freeze (with
      freezeBindingsWitnessed), release (trivial), createFrame (with
      bindingsWellFormed)
  - appendOnly_refl: appendOnly is reflexive
  - appendOnly_trans: appendOnly is transitive

  THE EVAL LOOP (EvalCycle):
  1. claim → adds to claims
  2. freeze → adds yields + bindings, removes claim
     OR bottom → adds isBottom yields, removes claim (error propagation)
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

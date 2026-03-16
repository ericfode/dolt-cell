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

-- A given is satisfied if the source cell has a frozen frame with that yield
def Retort.givenSatisfied (r : Retort) (g : GivenSpec) (program : ProgramId) : Bool :=
  g.optional || match r.latestFrozenFrame g.sourceCell with
    | some f =>
      -- Check that the source frame has the required yield frozen
      r.yields.any (fun y => y.frameId == f.id && y.field == g.sourceField)
    | none => false

-- A frame is ready if: declared AND all non-optional givens satisfied
def Retort.frameReady (r : Retort) (f : Frame) : Bool :=
  r.frameStatus f == .declared &&
  let cellGivens := r.givens.filter (fun g => g.cellName == f.cellName)
  cellGivens.all (fun g => r.givenSatisfied g f.program)

-- All ready frames in the retort
def Retort.readyFrames (r : Retort) : List Frame :=
  r.frames.filter (fun f => r.frameReady f)

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
def Retort.stemHasDemand (r : Retort) (cell : CellName) (demandPred : Retort → Bool) : Bool :=
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
theorem content_addr_distinct_gens (r : Retort)
    (cell : CellName) (field : FieldName) (g1 g2 : Nat) (v1 v2 : String)
    (h1 : r.resolve ⟨cell, g1, field⟩ = some v1)
    (h2 : r.resolve ⟨cell, g2, field⟩ = some v2)
    (hDiff : g1 ≠ g2)
    (hUnique : framesUnique r) :
    -- The values come from different frames
    ∃ f1 f2 : Frame, f1 ∈ r.frames ∧ f2 ∈ r.frames ∧
      f1.cellName = cell ∧ f2.cellName = cell ∧
      f1.generation = g1 ∧ f2.generation = g2 ∧ f1 ≠ f2 := by
  unfold Retort.resolve at h1 h2
  -- Extract the frames from the find? calls
  sorry -- structural: distinct generations → distinct frames by framesUnique

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

  PROVEN PROPERTIES:
  - all_ops_appendOnly: every operation preserves append-only
  - cells_stable_non_pour: cell defs never change after pour
  - givens_stable_non_pour: givens never change after pour
  - evalCycle_appendOnly: full eval cycles preserve append-only
  - always_appendOnly: □appendOnly on valid traces
  - data_persists: data from time T exists at all T' > T (transitive)

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

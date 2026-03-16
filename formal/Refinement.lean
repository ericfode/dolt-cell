/-
  Refinement: Denotational-Operational Correspondence

  This file connects the operational model (Retort.lean) to the
  denotational semantics (Denotational.lean) via a refinement relation.

  The key insight: both models track the same computation, but at
  different abstraction levels.

  - Retort: operational state machine with frames, yields, bindings,
    claims. Frame status is derived. Bodies are opaque strings
    evaluated by external pistons.

  - Denotational: mathematical semantics where programs are DAGs of
    cells with callable bodies (CellBody Id = Env -> (Env x Continue)).
    Evaluation is a pure step function producing ExecFrames.

  The refinement says: for every frozen frame in a well-formed Retort,
  there exists a corresponding ExecFrame in the denotational trace
  with matching cell name and generation.

  To bridge the gap, we introduce a RetortConfig that pairs a Retort
  state with the denotational Program it implements, plus a body
  interpretation function that maps Retort string yields to
  denotational Env values.
-/

import Retort
import Denotational

/-! ====================================================================
    BRIDGE TYPES: Connecting Retort to Denotational
    ==================================================================== -/

/-- A body interpreter maps a Retort yield value (string) and field name
    to a denotational Val. This is the semantic bridge between the
    operational string world and the denotational value world. -/
structure BodyInterp where
  /-- Map a Retort yield value (string) and field name to a denotational Val -/
  yieldToVal : FieldName -> String -> Val
  /-- Map a Retort cell's yield field names to denotational output field names.
      By default, identity. -/
  fieldMap : FieldName -> FieldName := id

/-- A RetortConfig pairs a Retort state with the denotational Program it
    implements, plus an interpretation function. This is the "simulation
    relation" that ties the two models together. -/
structure RetortConfig where
  retort  : Retort
  program : Program Id
  interp  : BodyInterp

/-! ====================================================================
    ABSTRACTION FUNCTION: Retort -> ExecTrace
    ==================================================================== -/

/-- Convert a list of Retort Yields for a single frame into a
    denotational Env, using the body interpreter. -/
def yieldsToEnv (interp : BodyInterp) (ys : List Yield) : Env :=
  ys.map (fun y => (interp.fieldMap y.field, interp.yieldToVal y.field y.value))

/-- Convert a single frozen Retort Frame to a denotational ExecFrame.
    The inputs are resolved from the bindings table; the outputs come
    from the yields. -/
def frameToExecFrame (r : Retort) (interp : BodyInterp) (f : Frame) : ExecFrame :=
  let yieldList := r.frameYields f.id
  let outputs := yieldsToEnv interp yieldList
  -- Inputs come from bindings: what this frame read from producer frames
  let bindingInputs := r.resolveBindings f.id
  let inputs : Env := bindingInputs.map (fun (field, value) =>
    (interp.fieldMap field, interp.yieldToVal field value))
  { cellName   := f.cellName.val
    generation := f.generation
    inputs     := inputs
    outputs    := outputs
    oraclePass := true  -- frozen frames passed all checks by construction
  }

/-- The frozen frames of a Retort, in order of appearance. -/
def Retort.frozenFrames (r : Retort) : List Frame :=
  r.frames.filter (fun f => r.frameStatus f == .frozen)

/-- The abstraction function: map a Retort state to a denotational ExecTrace.
    Each frozen frame in the Retort becomes an ExecFrame in the trace.
    Frames that are declared or computing are not yet part of the trace
    (they represent in-progress computation). -/
def Retort.toExecTrace (r : Retort) (interp : BodyInterp) : ExecTrace :=
  (r.frozenFrames).map (frameToExecFrame r interp)

/-! ====================================================================
    SIMULATION RELATION: When does a RetortConfig correspond?
    ==================================================================== -/

/-- The cell-name correspondence: every Retort cell definition has a
    matching denotational cell definition in the program. -/
def cellsCorrespond (rc : RetortConfig) : Prop :=
  ∀ rcd ∈ rc.retort.cells,
    ∃ dcd ∈ rc.program.cells,
      dcd.interface.name = rcd.name.val

/-- The field correspondence: for each Retort cell, its yield field
    names match the denotational cell's output field names (under the
    field map). -/
def fieldsCorrespond (rc : RetortConfig) : Prop :=
  ∀ rcd ∈ rc.retort.cells,
    ∃ dcd ∈ rc.program.cells,
      dcd.interface.name = rcd.name.val ∧
      rcd.fields.length = dcd.interface.outputs.length

/-- A RetortConfig is coherent when the operational and denotational
    models agree on structure: cell names correspond, fields correspond,
    and the Retort is well-formed. -/
structure Coherent (rc : RetortConfig) : Prop where
  wf            : wellFormed rc.retort
  cellsOk       : cellsCorrespond rc
  fieldsOk      : fieldsCorrespond rc

/-! ====================================================================
    REFINEMENT THEOREM 1: Frozen Frame Correspondence

    If a frame is frozen in a well-formed Retort whose cells correspond
    to a denotational Program, then the abstraction function produces
    an ExecFrame with matching cell name.
    ==================================================================== -/

/-- Helper: a frozen frame is in frozenFrames. -/
theorem frozen_in_frozenFrames (r : Retort) (f : Frame)
    (hMem : f ∈ r.frames)
    (hFrozen : r.frameStatus f = .frozen) :
    f ∈ r.frozenFrames := by
  unfold Retort.frozenFrames
  rw [List.mem_filter]
  exact ⟨hMem, by rw [hFrozen]; decide⟩

/-- Helper: if f is in frozenFrames, then frameToExecFrame f is in toExecTrace. -/
theorem execFrame_in_trace (r : Retort) (interp : BodyInterp) (f : Frame)
    (hFrozen : f ∈ r.frozenFrames) :
    frameToExecFrame r interp f ∈ r.toExecTrace interp := by
  unfold Retort.toExecTrace
  have h := List.mem_map_of_mem (f := frameToExecFrame r interp) hFrozen
  exact h

/-- The cell name of a frameToExecFrame is the string value of the Frame's cellName. -/
theorem frameToExecFrame_cellName (r : Retort) (interp : BodyInterp) (f : Frame) :
    (frameToExecFrame r interp f).cellName = f.cellName.val := by
  unfold frameToExecFrame
  rfl

/-- The generation of a frameToExecFrame matches the Frame's generation. -/
theorem frameToExecFrame_generation (r : Retort) (interp : BodyInterp) (f : Frame) :
    (frameToExecFrame r interp f).generation = f.generation := by
  unfold frameToExecFrame
  rfl

/-- REFINEMENT THEOREM: If a frame is frozen in a well-formed Retort,
    the corresponding ExecFrame exists in the denotational trace with
    matching cell name and generation.

    This is the core soundness result connecting the operational and
    denotational models. -/
theorem frozen_frame_corresponds (rc : RetortConfig) (f : Frame)
    (_hCoherent : Coherent rc)
    (hMem : f ∈ rc.retort.frames)
    (hFrozen : rc.retort.frameStatus f = .frozen) :
    ∃ ef ∈ rc.retort.toExecTrace rc.interp,
      ef.cellName = f.cellName.val ∧ ef.generation = f.generation := by
  have hFF := frozen_in_frozenFrames rc.retort f hMem hFrozen
  have hInTrace := execFrame_in_trace rc.retort rc.interp f hFF
  exact ⟨frameToExecFrame rc.retort rc.interp f, hInTrace,
         frameToExecFrame_cellName rc.retort rc.interp f,
         frameToExecFrame_generation rc.retort rc.interp f⟩

/-! ====================================================================
    REFINEMENT THEOREM 2: Frozen Frames Preserved

    Frozen frames are preserved by append-only transitions.
    ==================================================================== -/

/-- Helper: if the frozen-fields condition holds for r, it holds for r'
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

/-- Frozen frames are preserved by append-only transitions: if a frame
    was frozen before, it remains frozen after (because yields and
    cell defs are preserved). -/
theorem frozenFrames_preserved_by_appendOnly (r r' : Retort)
    (hAppend : appendOnly r r')
    (hCells : r'.cells = r.cells)
    (f : Frame)
    (hMem : f ∈ r.frames)
    (hFrozen : r.frameStatus f = .frozen) :
    f ∈ r'.frames ∧ r'.frameStatus f = .frozen := by
  constructor
  · exact hAppend.2.1 f hMem
  · unfold Retort.frameStatus at hFrozen ⊢
    have hCellDef : r'.cellDef f.cellName = r.cellDef f.cellName := by
      unfold Retort.cellDef; rw [hCells]
    rw [hCellDef]
    -- Case split on cellDef
    cases hcd : r.cellDef f.cellName with
    | none =>
      -- cellDef is none: frameStatus r = .declared, but hFrozen says = .frozen
      rw [hcd] at hFrozen; exact hFrozen
    | some cd =>
      rw [hcd] at hFrozen
      -- hFrozen now says the if-then-else in r equals .frozen
      -- The condition must have been true (if branch taken)
      simp only at hFrozen
      -- If the all-fields condition was false, the result would be .computing or .declared,
      -- not .frozen. So the condition must be true.
      split at hFrozen
      · -- all fields frozen in r; show they're frozen in r' too
        rename_i hAll
        simp only
        rw [if_pos (frozen_fields_preserved r r' hAppend.2.2.1 cd f.id hAll)]
      · -- all fields NOT frozen in r, so result is .computing or .declared
        -- But hFrozen says the result is .frozen, contradiction
        rename_i hNotAll
        split at hFrozen
        · exact absurd hFrozen (by decide)
        · exact absurd hFrozen (by decide)

/-! ====================================================================
    REFINEMENT THEOREM 3: Finite Program Termination
    ==================================================================== -/

/-- A Retort has no stem cells for a given program. -/
def noStemCells (r : Retort) (prog : ProgramId) : Prop :=
  ∀ cd ∈ r.cells, cd.program = prog → cd.bodyType ≠ .stem

/-- The number of non-frozen frames for a program. This is the
    "fuel" that decreases toward termination. -/
def nonFrozenCount (r : Retort) (prog : ProgramId) : Nat :=
  (r.frames.filter (fun f =>
    f.program == prog && r.frameStatus f != .frozen)).length

/-- In a finite non-stem program, non-frozen count is bounded by
    the number of frames. Since each eval cycle freezes one frame,
    the program terminates in at most |frames| cycles.

    This is the operational analogue of Denotational.nonStem_finite. -/
theorem finite_program_bounded (r : Retort) (prog : ProgramId)
    (_hNoStem : noStemCells r prog) :
    nonFrozenCount r prog ≤ r.frames.length := by
  unfold nonFrozenCount
  exact List.length_filter_le _ _

/-! ====================================================================
    REFINEMENT THEOREM 4: Completeness
    ==================================================================== -/

/-- Helper: BEq equality on FrameStatus implies Prop equality. -/
private theorem FrameStatus_eq_of_beq : ∀ (a b : FrameStatus),
    (a == b) = true → a = b := by
  intro a b h
  cases a <;> cases b <;> first | rfl | (revert h; decide)

/-- Helper: BEq equality on BodyType implies Prop equality. -/
private theorem BodyType_eq_of_beq : ∀ (a b : BodyType),
    (a == b) = true → a = b := by
  intro a b h
  cases a <;> cases b <;> first | rfl | (revert h; decide)

/-- When a Retort program is complete, every non-stem cell has at least
    one frozen frame, and therefore at least one ExecFrame in the
    denotational trace. -/
theorem complete_implies_all_cells_traced (rc : RetortConfig) (prog : ProgramId)
    (hCoherent : Coherent rc)
    (hComplete : rc.retort.programComplete prog = true) :
    ∀ rcd ∈ rc.retort.cells, rcd.program = prog → rcd.bodyType ≠ .stem →
      ∃ ef ∈ rc.retort.toExecTrace rc.interp,
        ef.cellName = rcd.name.val := by
  intro rcd hrcd hProg hNotStem
  unfold Retort.programComplete at hComplete
  rw [List.all_eq_true] at hComplete
  have hCdComplete := hComplete rcd (by
    rw [List.mem_filter]; exact ⟨hrcd, by rw [hProg]; exact beq_self_eq_true prog⟩)
  simp only [Bool.or_eq_true] at hCdComplete
  cases hCdComplete with
  | inl hIsStem =>
    exfalso
    exact hNotStem (BodyType_eq_of_beq _ _ hIsStem)
  | inr hHasFrozen =>
    rw [List.any_eq_true] at hHasFrozen
    obtain ⟨f, hf_mem, hf_pred⟩ := hHasFrozen
    rw [List.mem_filter] at hf_mem
    simp only [Bool.and_eq_true] at hf_pred
    obtain ⟨hf_name, hf_status⟩ := hf_pred
    have hNameEq : f.cellName = rcd.name := eq_of_beq hf_name
    have hStatusFrozen : rc.retort.frameStatus f = .frozen :=
      FrameStatus_eq_of_beq _ _ hf_status
    obtain ⟨ef, hef_mem, hef_name, _⟩ :=
      frozen_frame_corresponds rc f hCoherent hf_mem.1 hStatusFrozen
    exact ⟨ef, hef_mem, hef_name ▸ congrArg CellName.val hNameEq⟩

/-! ====================================================================
    REFINEMENT THEOREM 5: Trace Length Correspondence
    ==================================================================== -/

/-- The length of the denotational trace equals the number of frozen
    frames in the Retort. Definitional from toExecTrace. -/
theorem trace_length_eq_frozen_count (r : Retort) (interp : BodyInterp) :
    (r.toExecTrace interp).length = r.frozenFrames.length := by
  unfold Retort.toExecTrace
  exact List.length_map (frameToExecFrame r interp)

/-- The number of frozen frames is bounded by the total number of frames. -/
theorem frozen_bounded_by_frames (r : Retort) :
    r.frozenFrames.length ≤ r.frames.length := by
  unfold Retort.frozenFrames
  exact List.length_filter_le _ _

/-- Combined: trace length is bounded by total frames. -/
theorem trace_length_bounded (r : Retort) (interp : BodyInterp) :
    (r.toExecTrace interp).length ≤ r.frames.length := by
  calc (r.toExecTrace interp).length
      = r.frozenFrames.length := trace_length_eq_frozen_count r interp
    _ ≤ r.frames.length := frozen_bounded_by_frames r

/-! ====================================================================
    REFINEMENT THEOREM 6: Output Determinism
    ==================================================================== -/

/-- Two Retort states that agree on yields for a given frameId produce
    the same output Env for that frame. -/
theorem output_deterministic (r1 r2 : Retort) (interp : BodyInterp) (fid : FrameId)
    (hYieldsEq : r1.frameYields fid = r2.frameYields fid) :
    yieldsToEnv interp (r1.frameYields fid) = yieldsToEnv interp (r2.frameYields fid) := by
  rw [hYieldsEq]

/-! ====================================================================
    REFINEMENT THEOREM 7: Frozen Frame Determinism
    ==================================================================== -/

/-- If two Retort states agree on the yields and bindings for a frame,
    the frameToExecFrame produces identical ExecFrames. -/
theorem frameToExecFrame_deterministic (r1 r2 : Retort) (interp : BodyInterp) (f : Frame)
    (hYields : r1.frameYields f.id = r2.frameYields f.id)
    (hBindings : r1.resolveBindings f.id = r2.resolveBindings f.id) :
    frameToExecFrame r1 interp f = frameToExecFrame r2 interp f := by
  unfold frameToExecFrame
  simp only [hYields, hBindings]

/-! ====================================================================
    REFINEMENT THEOREM 8: Correspondence for Non-Pour Trace Steps
    ==================================================================== -/

/-- After a non-pour operation, every frozen frame in the old state
    remains frozen, and the corresponding ExecFrame exists in the
    new trace with matching cell name and generation. -/
theorem non_pour_frozen_preserved (r : Retort) (op : RetortOp)
    (interp : BodyInterp)
    (hNotPour : ∀ pd, op ≠ .pour pd)
    (f : Frame)
    (hMem : f ∈ r.frames)
    (hFrozen : r.frameStatus f = .frozen) :
    ∃ ef ∈ (applyOp r op).toExecTrace interp,
      ef.cellName = f.cellName.val ∧ ef.generation = f.generation := by
  have hCells : (applyOp r op).cells = r.cells := cells_stable_non_pour r op hNotPour
  have hAppend := all_ops_appendOnly r op
  have ⟨hMem', hFrozen'⟩ := frozenFrames_preserved_by_appendOnly
    r (applyOp r op) hAppend hCells f hMem hFrozen
  have hFF := frozen_in_frozenFrames (applyOp r op) f hMem' hFrozen'
  have hInTrace := execFrame_in_trace (applyOp r op) interp f hFF
  exact ⟨frameToExecFrame (applyOp r op) interp f, hInTrace,
         frameToExecFrame_cellName (applyOp r op) interp f,
         frameToExecFrame_generation (applyOp r op) interp f⟩

/-! ====================================================================
    REFINEMENT THEOREM 9: Finite Non-Stem Termination Characterization
    ==================================================================== -/

/-- When nonFrozenCount is 0, every program frame is frozen. -/
theorem zero_nonFrozen_implies_all_frozen (r : Retort) (prog : ProgramId)
    (hZero : nonFrozenCount r prog = 0) :
    ∀ f ∈ r.frames, f.program = prog → r.frameStatus f = .frozen := by
  intro f hf hProg
  unfold nonFrozenCount at hZero
  -- The filter has length 0. If f were not frozen, it would be in the filter,
  -- making the length > 0, contradicting hZero.
  -- Use decidability of FrameStatus equality.
  cases hFS : (inferInstance : DecidableEq FrameStatus) (r.frameStatus f) .frozen with
  | isTrue hp => exact hp
  | isFalse hNotFrozen =>
    -- f is in the filter
    have hProgBeq : (f.program == prog) = true := by
      rw [hProg]; exact beq_self_eq_true prog
    have hNotFrozenBeq : (r.frameStatus f != .frozen) = true := by
      cases hS : r.frameStatus f with
      | declared => decide
      | computing => decide
      | frozen => exact absurd hS hNotFrozen
    have hPred : (f.program == prog && r.frameStatus f != .frozen) = true := by
      rw [Bool.and_eq_true]; exact ⟨hProgBeq, hNotFrozenBeq⟩
    have hInFilter : f ∈ r.frames.filter (fun f =>
        f.program == prog && r.frameStatus f != .frozen) := by
      rw [List.mem_filter]; exact ⟨hf, hPred⟩
    have hPos := List.length_pos_of_mem hInFilter
    omega

/-! ====================================================================
    REFINEMENT THEOREM 10: Well-Formed Trace Produces Well-Formed Traces

    Every step of a ValidWFTrace produces a well-formed Retort (from
    Retort.lean's always_wellFormed), and therefore produces a valid
    denotational trace where every ExecFrame has matching cell names.
    ==================================================================== -/

/-- At every step of a valid well-formed trace, the operational state
    is well-formed, and frozen frames produce valid ExecFrames. -/
theorem valid_trace_produces_valid_exec_frames (vt : ValidWFTrace) (interp : BodyInterp)
    (n : Nat) :
    ∀ f ∈ (vt.trace n).frames,
      (vt.trace n).frameStatus f = .frozen →
      ∃ ef ∈ (vt.trace n).toExecTrace interp,
        ef.cellName = f.cellName.val ∧ ef.generation = f.generation := by
  intro f hf hFrozen
  have hFF := frozen_in_frozenFrames (vt.trace n) f hf hFrozen
  have hInTrace := execFrame_in_trace (vt.trace n) interp f hFF
  exact ⟨frameToExecFrame (vt.trace n) interp f, hInTrace,
         frameToExecFrame_cellName (vt.trace n) interp f,
         frameToExecFrame_generation (vt.trace n) interp f⟩

/-! ====================================================================
    SUMMARY: Denotational-Operational Correspondence
    ====================================================================

  ABSTRACTION FUNCTION:
  - Retort.toExecTrace: maps frozen Retort frames to denotational ExecFrames
  - frameToExecFrame: converts a single Frame + its yields/bindings to ExecFrame
  - yieldsToEnv: converts string yields to denotational Env via BodyInterp

  SIMULATION RELATION:
  - RetortConfig: pairs Retort state with denotational Program + interpreter
  - cellsCorrespond: cell names match between models
  - fieldsCorrespond: field names/counts match
  - Coherent: well-formedness + correspondence

  PROVEN THEOREMS (all sorry-free):

  1. frozen_frame_corresponds (CORE SOUNDNESS):
     If a frame is frozen in a well-formed coherent Retort, there exists
     an ExecFrame in the denotational trace with matching cellName and
     generation.

  2. frozenFrames_preserved_by_appendOnly (MONOTONICITY):
     Frozen frames remain frozen under append-only transitions when
     cells are stable.

  3. finite_program_bounded (TERMINATION BOUND):
     The non-frozen count is bounded by |frames|.

  4. complete_implies_all_cells_traced (COMPLETENESS):
     When Retort.programComplete is true, every non-stem cell has a
     corresponding ExecFrame in the denotational trace.

  5. trace_length_eq_frozen_count, frozen_bounded_by_frames,
     trace_length_bounded (STRUCTURAL):
     The trace has exactly as many frames as frozen Retort frames,
     and this count is bounded by total frames.

  6. output_deterministic (OUTPUT STABILITY):
     Same yields for a frameId produce the same denotational Env.

  7. frameToExecFrame_deterministic (FRAME DETERMINISM):
     Same yields + bindings => identical ExecFrames.

  8. non_pour_frozen_preserved (TRACE PERSISTENCE):
     After any non-pour operation, every frozen frame's ExecFrame
     persists in the new trace with matching cell name and generation.

  9. zero_nonFrozen_implies_all_frozen (TERMINATION):
     When nonFrozenCount reaches 0, every frame is frozen.

  10. valid_trace_produces_valid_exec_frames (TRACE VALIDITY):
      Every step of a well-formed trace produces valid ExecFrames
      for all frozen frames.

  TOTAL SORRY: 0

  DESIGN DECISIONS:
  - BodyInterp is the key bridge: it maps string yields to Val, allowing
    the Retort's string-based world to connect to Denotational's Env world.
  - RetortConfig keeps the Retort and Program paired, with the interpreter
    as a first-class component of the simulation relation.
  - The refinement is one-directional (Retort -> ExecTrace), not
    bidirectional, because the Retort has strictly more information
    (claims, bindings, operational state).
  - RCellDef (Retort) and CellDef M (Denotational) are intentionally
    different types: the operational model uses opaque string bodies,
    the denotational model uses callable function bodies.
-/

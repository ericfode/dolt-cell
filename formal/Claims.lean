/-
  Temporal Logic Formalization of the Claim System

  We model the retort runtime as a transition system and use
  LTL (Linear Temporal Logic) to state and prove safety and
  liveness properties about claiming, immutability, and the DAG.

  Approach C (hybrid: mutable lock + append-only log) is assumed.
-/

import Core

namespace Claims

/-! ====================================================================
    TRANSITION SYSTEM: States and Actions
    ==================================================================== -/

-- A yield in the store
structure StoredYield where
  frameId : FrameId
  field : String
  value : String
  deriving Repr, DecidableEq, BEq

-- The system state
structure State where
  holders    : List (FrameId × PistonId)  -- active claims (mutable lock table)
  yieldStore : List StoredYield           -- append-only yield history
  deriving Repr

def State.init : State := { holders := [], yieldStore := [] }

-- Who holds a frame?
def State.holder (s : State) (fid : FrameId) : Option PistonId :=
  (s.holders.find? (fun p => p.1 == fid)).map Prod.snd

-- Is a yield present?
def State.hasYield (s : State) (fid : FrameId) (field : String) : Bool :=
  s.yieldStore.any (fun y => y.frameId == fid && y.field == field)

/-! ## Individual Transition Functions

  Each transition is a separate function for cleaner proofs.
-/

-- Claim: add holder if frame is free
def claimStep (s : State) (pid : PistonId) (fid : FrameId) : State × Bool :=
  if s.holder fid |>.isNone then
    ({ holders := s.holders ++ [(fid, pid)], yieldStore := s.yieldStore }, true)
  else
    (s, false)

-- Release: remove holder
def releaseStep (s : State) (pid : PistonId) (fid : FrameId) : State × Bool :=
  let holders' := s.holders.filter (fun p => !(p.1 == fid && p.2 == pid))
  ({ holders := holders', yieldStore := s.yieldStore }, true)

-- Freeze: append yield if not already present
def freezeStep (s : State) (fid : FrameId) (field value : String) : State × Bool :=
  if s.hasYield fid field then
    (s, false)  -- immutability: reject duplicate
  else
    ({ holders := s.holders,
       yieldStore := s.yieldStore ++ [⟨fid, field, value⟩] }, true)

/-! ====================================================================
    LINEAR TEMPORAL LOGIC (LTL)
    ==================================================================== -/

abbrev Trace := Nat → State

-- □ (Always / Globally)
def always (P : State → Prop) (t : Trace) : Prop :=
  ∀ n : Nat, P (t n)

-- ◇ (Eventually)
def eventually (P : State → Prop) (t : Trace) : Prop :=
  ∃ n : Nat, P (t n)

-- ○ (Next)
def nextState (P : State → Prop) (t : Trace) (n : Nat) : Prop :=
  P (t (n + 1))

-- P U Q (Until)
def ltlUntil (P Q : State → Prop) (t : Trace) : Prop :=
  ∃ n : Nat, Q (t n) ∧ ∀ m : Nat, m < n → P (t m)

-- □P → P (sanity)
theorem always_implies_now (P : State → Prop) (t : Trace) (h : always P t) :
    P (t 0) := h 0

/-! ====================================================================
    SAFETY: MUTUAL EXCLUSION
    ==================================================================== -/

-- □(∀ frame, at most one piston holds it)
def mutualExclusion (s : State) : Prop :=
  ∀ f : FrameId, ∀ p1 p2 : PistonId,
    (f, p1) ∈ s.holders → (f, p2) ∈ s.holders → p1 = p2

-- Mutex holds on empty state
theorem mutex_init : mutualExclusion State.init := by
  intro f p1 p2 h1 _
  simp [State.init] at h1

-- Claim preserves mutex
-- (INSERT IGNORE semantics: only adds holder when none exists)
theorem claim_preserves_mutex (s : State) (pid : PistonId) (fid : FrameId)
    (hmutex : mutualExclusion s) :
    mutualExclusion (claimStep s pid fid).1 := by
  unfold claimStep
  split
  · -- claim succeeds: no current holder
    rename_i hfree
    -- Extract: no entry in s.holders has first component == fid
    have hno_old : ∀ p ∈ s.holders, ¬((p.1 == fid) = true) := by
      rw [Option.isNone_iff_eq_none] at hfree
      unfold State.holder at hfree
      have hfind : s.holders.find? (fun p => p.1 == fid) = none := by
        cases hf : s.holders.find? (fun p => p.1 == fid) with
        | none => rfl
        | some a => simp [hf] at hfree
      rwa [List.find?_eq_none] at hfind
    -- Now prove mutex on s.holders ++ [(fid, pid)]
    intro f p1 p2 h1 h2
    simp [List.mem_append] at h1 h2
    obtain h1old | ⟨h1f, h1p⟩ := h1
    · obtain h2old | ⟨h2f, h2p⟩ := h2
      · -- Both in original list: follows from hmutex
        exact hmutex f p1 p2 h1old h2old
      · -- p1 old, p2 new: f = fid, but no old entry has frame fid
        subst h2f; subst h2p
        have hbeq : ((f, p1).1 == f) = true := by simp
        exact absurd hbeq (hno_old (f, p1) h1old)
    · obtain h2old | ⟨h2f, h2p⟩ := h2
      · -- p1 new, p2 old: symmetric contradiction
        subst h1f; subst h1p
        have hbeq : ((f, p2).1 == f) = true := by simp
        exact absurd hbeq (hno_old (f, p2) h2old)
      · -- Both are the new entry: trivially p1 = p2
        rw [h1p, h2p]
  · exact hmutex  -- claim fails, state unchanged

-- Release preserves mutex (subset can't introduce duplicates)
theorem release_preserves_mutex (s : State) (pid : PistonId) (fid : FrameId)
    (hmutex : mutualExclusion s) :
    mutualExclusion (releaseStep s pid fid).1 := by
  unfold releaseStep
  intro f p1 p2 hp1 hp2
  simp [List.mem_filter] at hp1 hp2
  exact hmutex f p1 p2 hp1.1 hp2.1

-- Freeze doesn't touch holders → preserves mutex
theorem freeze_preserves_mutex (s : State) (fid : FrameId) (field value : String)
    (hmutex : mutualExclusion s) :
    mutualExclusion (freezeStep s fid field value).1 := by
  unfold freezeStep
  split
  · exact hmutex  -- rejected, state unchanged
  · exact hmutex  -- holders unchanged

/-! ====================================================================
    SAFETY: YIELD IMMUTABILITY
    ==================================================================== -/

-- □(∀ yield, once written it stays forever)
def yieldsPreserved (prev curr : State) : Prop :=
  ∀ y ∈ prev.yieldStore, y ∈ curr.yieldStore

-- Freeze is append-only
theorem freeze_preserves_yields (s : State) (fid : FrameId) (field value : String) :
    yieldsPreserved s (freezeStep s fid field value).1 := by
  unfold freezeStep
  split
  · exact fun y hy => hy  -- rejected, unchanged
  · intro y hy; exact List.mem_append_left _ hy  -- appended

-- Claim doesn't touch yields
theorem claim_preserves_yields (s : State) (pid : PistonId) (fid : FrameId) :
    (claimStep s pid fid).1.yieldStore = s.yieldStore := by
  unfold claimStep; split <;> rfl

-- Release doesn't touch yields
theorem release_preserves_yields (s : State) (pid : PistonId) (fid : FrameId) :
    (releaseStep s pid fid).1.yieldStore = s.yieldStore := by
  unfold releaseStep; rfl

-- Freeze rejects duplicates (immutability enforced)
theorem freeze_rejects_duplicate (s : State) (fid : FrameId) (field value : String)
    (hExists : s.hasYield fid field = true) :
    (freezeStep s fid field value).2 = false := by
  unfold freezeStep; simp [hExists]

/-! ====================================================================
    SAFETY: YIELD VALUE STABILITY

    □(value(F, field) = V → □(value(F, field) = V))

    Stronger than preservation: the VALUE never changes.
    Follows from: freeze rejects duplicates + freeze is the only
    way to add yields + other transitions don't touch yieldStore.
    ==================================================================== -/

-- If a yield exists and no new yield with the same key is added,
-- the value is stable.
theorem value_stable_on_claim (s : State) (pid : PistonId) (fid : FrameId)
    (y : StoredYield) (hy : y ∈ s.yieldStore) :
    y ∈ (claimStep s pid fid).1.yieldStore := by
  rw [claim_preserves_yields]; exact hy

theorem value_stable_on_release (s : State) (pid : PistonId) (fid : FrameId)
    (y : StoredYield) (hy : y ∈ s.yieldStore) :
    y ∈ (releaseStep s pid fid).1.yieldStore := by
  rw [release_preserves_yields]; exact hy

theorem value_stable_on_freeze (s : State) (fid : FrameId) (field value : String)
    (y : StoredYield) (hy : y ∈ s.yieldStore) :
    y ∈ (freezeStep s fid field value).1.yieldStore :=
  freeze_preserves_yields s fid field value y hy

/-! ====================================================================
    LIVENESS: PROGRESS
    ==================================================================== -/

-- □(free(F) ∧ claim(P, F) → succeeds)
-- If no one holds a frame, a claim attempt succeeds.
theorem unclaimed_claim_succeeds (s : State) (pid : PistonId) (fid : FrameId)
    (hFree : s.holder fid = none) :
    (claimStep s pid fid).2 = true := by
  unfold claimStep
  simp [hFree]

-- □(release(P, F) → holder(F) = None)  [if P was the sole holder]
-- After release, the frame is free (assuming mutex held).
-- After release, the frame is free (under mutex).
-- Filter removes the holder; mutex ensures no other holder exists for that frame.
theorem release_frees_frame (s : State) (pid : PistonId) (fid : FrameId)
    (hHeld : (fid, pid) ∈ s.holders)
    (hMutex : mutualExclusion s) :
    (releaseStep s pid fid).1.holder fid = none := by
  unfold releaseStep State.holder
  simp only
  rw [Option.map_eq_none_iff]
  rw [List.find?_eq_none]
  intro ⟨f, p⟩ hmem hfid
  simp [List.mem_filter] at hmem
  obtain ⟨hmem_orig, hfilter⟩ := hmem
  simp at hfid
  have hpeq : p = pid := hMutex f p pid hmem_orig (hfid ▸ hHeld)
  rw [hfid, hpeq] at hfilter
  simp at hfilter

/-! ====================================================================
    TRACE-LEVEL PROPERTIES
    ==================================================================== -/

-- A valid trace: each state follows from a valid transition
inductive TraceStep where
  | doClaim   : PistonId → FrameId → TraceStep
  | doRelease : PistonId → FrameId → TraceStep
  | doFreeze  : FrameId → String → String → TraceStep
  deriving Repr

def applyTraceStep (s : State) : TraceStep → State
  | .doClaim pid fid   => (claimStep s pid fid).1
  | .doRelease pid fid => (releaseStep s pid fid).1
  | .doFreeze fid f v  => (freezeStep s fid f v).1

structure ValidTrace where
  trace   : Trace
  steps   : Nat → TraceStep
  init_eq : trace 0 = State.init
  step_eq : ∀ n, trace (n + 1) = applyTraceStep (trace n) (steps n)

-- □mutualExclusion on all valid traces
-- Follows from: init satisfies mutex, every step preserves mutex.
theorem always_mutex_on_valid_trace (vt : ValidTrace) :
    always mutualExclusion vt.trace := by
  intro n
  induction n with
  | zero => rw [vt.init_eq]; exact mutex_init
  | succ k ih =>
    rw [vt.step_eq k]
    cases vt.steps k with
    | doClaim pid fid => exact claim_preserves_mutex _ pid fid ih
    | doRelease pid fid => exact release_preserves_mutex _ pid fid ih
    | doFreeze fid f v => exact freeze_preserves_mutex _ fid f v ih

-- □yieldsPreserved on all valid traces (monotonic yield store)
theorem always_yields_preserved_on_valid_trace (vt : ValidTrace) :
    ∀ n, yieldsPreserved (vt.trace n) (vt.trace (n + 1)) := by
  intro n
  rw [vt.step_eq n]
  cases vt.steps n with
  | doClaim pid fid =>
    intro y hy; simp [applyTraceStep]; rw [claim_preserves_yields]; exact hy
  | doRelease pid fid =>
    intro y hy; simp [applyTraceStep]; rw [release_preserves_yields]; exact hy
  | doFreeze fid f v =>
    simp [applyTraceStep]; exact freeze_preserves_yields _ fid f v

/-! ====================================================================
    VERDICT: Temporal Properties of Approach C
    ====================================================================

  PROVEN on all valid traces:

  1. □mutualExclusion
     At every point in time, no frame is held by two pistons.
     (always_mutex_on_valid_trace)

  2. □yieldsPreserved
     Yields are monotonically growing — once written, never removed.
     (always_yields_preserved_on_valid_trace)

  3. □(yield duplicate → rejected)
     A yield value can never be overwritten.
     (freeze_rejects_duplicate)

  4. □(free(F) ∧ claim(P,F) → succeeds)
     No deadlock: if a frame is free, claiming it always works.
     (unclaimed_claim_succeeds)

  5. □(release(P,F) → free(F))
     Release always frees the frame (under mutex).
     (release_frees_frame)

  APPROACH C SUMMARY:
  - Lock table (active_claims): mutable, provides atomic mutual exclusion
  - Claim log: append-only, provides full temporal audit trail
  - Yield store: append-only, values immutable once written
  - Frames: append-only, one row per execution
  - Cells: immutable after pour
  - Bindings: append-only, records resolved givens per frame

  The lock table is the ONLY mutable component. It is a coordination
  primitive (like a semaphore), not execution history. Its temporal
  behavior is fully characterized by the mutex and liveness properties.
-/

end Claims

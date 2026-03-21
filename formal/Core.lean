/-
  Core: Shared type definitions for the Cell formal model

  These identity types are used across Retort, Claims, StemCell,
  and Denotational. Centralizing them eliminates incompatible
  duplicate definitions.
-/

/-! ====================================================================
    IDENTITY TYPES (all strings in SQL, opaque here)
    ==================================================================== -/

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
    EFFECT LEVELS (canonical taxonomy: Pure < Replayable < NonReplayable)
    ==================================================================== -/

inductive EffLevel where
  | pure           -- deterministic, retryable (hard cells)
  | replayable     -- bounded nondeterminism, retryable with oracle (soft cells)
  | nonReplayable  -- world-mutating: DML, beads, autopour (NonReplayable cells)
  deriving Repr, DecidableEq, BEq

def EffLevel.toNat : EffLevel → Nat
  | .pure => 0
  | .replayable => 1
  | .nonReplayable => 2

instance : LE EffLevel where
  le a b := a.toNat ≤ b.toNat

instance : LT EffLevel where
  lt a b := a.toNat < b.toNat

instance (a b : EffLevel) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

instance (a b : EffLevel) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- Pure is the bottom of the effect lattice. -/
theorem EffLevel.pure_le_all (e : EffLevel) : EffLevel.pure ≤ e := by
  show EffLevel.pure.toNat ≤ e.toNat
  simp [EffLevel.toNat]

/-- NonReplayable is the top of the effect lattice. -/
theorem EffLevel.all_le_nonReplayable (e : EffLevel) : e ≤ EffLevel.nonReplayable := by
  show e.toNat ≤ EffLevel.nonReplayable.toNat
  cases e <;> simp [EffLevel.toNat]

/-! ====================================================================
    BODY TYPES (cell evaluation strategy)
    ==================================================================== -/

inductive BodyType where
  | hard     -- evaluated by SQL/literal inline
  | soft     -- evaluated by LLM piston
  | stem     -- permanently soft, cycles through generations
  deriving Repr, DecidableEq, BEq

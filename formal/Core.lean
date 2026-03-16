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
    EFFECT LEVELS (unified cell kind)
    ==================================================================== -/

inductive EffectLevel where
  | pure       -- hard cells: deterministic, no LLM
  | semantic   -- soft cells: LLM-evaluated, may vary
  | divergent  -- stem cells: permanently soft, cycles
  deriving Repr, DecidableEq, BEq

/-! ====================================================================
    BODY TYPES (cell evaluation strategy)
    ==================================================================== -/

inductive BodyType where
  | hard     -- evaluated by SQL/literal inline
  | soft     -- evaluated by LLM piston
  | stem     -- permanently soft, cycles through generations
  deriving Repr, DecidableEq, BEq

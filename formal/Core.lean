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
    CANONICAL EFFECT LATTICE: EffLevel
    ==================================================================== -/

/-- The canonical effect lattice, ordered by recovery cost.
    Pure < Replayable < NonReplayable.
    This is the shared definition used by EffectEval, Autopour, TupleSpace,
    and (via bridge) Denotational. -/
inductive EffLevel where
  | pure          -- deterministic: literal, SQL query, arithmetic
  | replayable    -- bounded nondeterminism: LLM oracle, auto-retry safe
  | nonReplayable -- world-mutating: DML, external API, thaw, autopour
  deriving Repr, DecidableEq, BEq

/-- Numeric encoding for total order. -/
def EffLevel.toNat : EffLevel → Nat
  | .pure          => 0
  | .replayable    => 1
  | .nonReplayable => 2

/-- LE instance via toNat. -/
instance : LE EffLevel where
  le a b := a.toNat ≤ b.toNat

/-- LT instance via toNat. -/
instance : LT EffLevel where
  lt a b := a.toNat < b.toNat

instance (a b : EffLevel) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

instance (a b : EffLevel) : Decidable (a < b) :=
  inferInstanceAs (Decidable (a.toNat < b.toNat))

/-- Bool version for decidable checks. -/
def EffLevel.le (a b : EffLevel) : Bool := a.toNat ≤ b.toNat

/-- Pure is the bottom of the lattice. -/
theorem EffLevel.pure_le_all (e : EffLevel) : EffLevel.pure ≤ e := by
  show EffLevel.pure.toNat ≤ e.toNat
  simp [EffLevel.toNat]

/-- NonReplayable is the top. -/
theorem EffLevel.all_le_nonReplayable (e : EffLevel) : e ≤ EffLevel.nonReplayable := by
  show e.toNat ≤ EffLevel.nonReplayable.toNat
  cases e <;> simp [EffLevel.toNat]

/-- Helper to unfold LE for EffLevel in proofs. -/
theorem EffLevel.le_def (a b : EffLevel) : (a ≤ b) = (a.toNat ≤ b.toNat) := rfl

/-- Join = max of two effect levels. -/
def EffLevel.join (a b : EffLevel) : EffLevel :=
  if b.toNat ≤ a.toNat then a else b

private theorem EffLevel.toNat_injective (a b : EffLevel) (h : a.toNat = b.toNat) : a = b := by
  cases a <;> cases b <;> simp [EffLevel.toNat] at h <;> rfl

theorem EffLevel.join_comm (a b : EffLevel) : EffLevel.join a b = EffLevel.join b a := by
  simp only [EffLevel.join]
  split <;> split
  · rename_i h1 h2
    exact EffLevel.toNat_injective a b (Nat.le_antisymm h2 h1)
  · rfl
  · rfl
  · rename_i h1 h2; omega

theorem EffLevel.join_assoc (a b c : EffLevel) :
    EffLevel.join (EffLevel.join a b) c = EffLevel.join a (EffLevel.join b c) := by
  simp only [EffLevel.join]
  cases a <;> cases b <;> cases c <;> simp [EffLevel.toNat]

theorem EffLevel.join_idem (a : EffLevel) : EffLevel.join a a = a := by
  simp only [EffLevel.join, EffLevel.toNat]
  cases a <;> simp

theorem EffLevel.join_le_left (a b : EffLevel) : a ≤ EffLevel.join a b := by
  simp only [EffLevel.join]
  show a.toNat ≤ (if b.toNat ≤ a.toNat then a else b).toNat
  split
  · exact Nat.le_refl a.toNat
  · rename_i h; omega

theorem EffLevel.join_le_right (a b : EffLevel) : b ≤ EffLevel.join a b := by
  simp only [EffLevel.join]
  show b.toNat ≤ (if b.toNat ≤ a.toNat then a else b).toNat
  split
  · rename_i h; exact h
  · exact Nat.le_refl b.toNat

theorem EffLevel.join_lub (a b c : EffLevel) (ha : a ≤ c) (hb : b ≤ c) :
    EffLevel.join a b ≤ c := by
  simp only [EffLevel.join, EffLevel.le_def]
  split
  · exact ha
  · exact hb

/-- Join with pure is identity. -/
theorem EffLevel.join_pure_left (e : EffLevel) : EffLevel.join .pure e = e := by
  simp only [EffLevel.join, EffLevel.toNat]
  cases e <;> simp

theorem EffLevel.join_pure_right (e : EffLevel) : EffLevel.join e .pure = e := by
  rw [EffLevel.join_comm]; exact EffLevel.join_pure_left e

/-- Join is monotone in each argument. -/
theorem EffLevel.join_mono_left (a b c : EffLevel) (h : a ≤ b) :
    EffLevel.join a c ≤ EffLevel.join b c := by
  cases a <;> cases b <;> cases c <;> simp_all [EffLevel.join, EffLevel.toNat, EffLevel.le_def]

theorem EffLevel.join_mono_right (a b c : EffLevel) (h : b ≤ c) :
    EffLevel.join a b ≤ EffLevel.join a c := by
  rw [EffLevel.join_comm a b, EffLevel.join_comm a c]
  exact EffLevel.join_mono_left b c a h

/-! ====================================================================
    LEGACY EFFECT LEVELS (deprecated — use EffLevel)
    ==================================================================== -/

/-- DEPRECATED: Old effect taxonomy that conflates effect level with lifecycle.
    Use EffLevel (pure/replayable/nonReplayable) for new code.
    Kept for backward compatibility with Denotational.lean. -/
inductive EffectLevel where
  | pure       -- hard cells: deterministic, no LLM
  | semantic   -- soft cells: LLM-evaluated, may vary
  | divergent  -- stem cells: permanently soft, cycles
  deriving Repr, DecidableEq, BEq

/-- Bridge from legacy EffectLevel to canonical EffLevel.
    semantic → replayable, divergent → nonReplayable. -/
def EffectLevel.toCanonical : EffectLevel → EffLevel
  | .pure      => .pure
  | .semantic  => .replayable
  | .divergent => .nonReplayable

/-! ====================================================================
    BODY TYPES (cell evaluation strategy)
    ==================================================================== -/

inductive BodyType where
  | hard     -- evaluated by SQL/literal inline
  | soft     -- evaluated by LLM piston
  | stem     -- permanently soft, cycles through generations
  deriving Repr, DecidableEq, BEq

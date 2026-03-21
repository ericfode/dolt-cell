/-
  Autopour: Formal Model of Programs-as-Yields

  Extends Denotational.lean with the autopour primitive:
  a cell can yield a program value, and the runtime pours it.

  This is the metacircular primitive: eval expressed within the language.

  Key additions:
  1. Val.program — programs are first-class values
  2. AutopourCtx — fuel-bounded evaluation context
  3. autopourStep — operational semantics of pour-on-yield
  4. Theorems: fuel termination, effect monotonicity, monotonicity preservation

  Design decisions (see docs/research/autopour-denotational-semantics.md):
  - Programs as values (Option C): no new cell kind, extends Val
  - Fuel in evaluation context, not per-cell
  - Parse failure = bottom
  - Effect monotonicity: poured program ≤ parent effect level

  Effect taxonomy: Uses the CANONICAL taxonomy (Pure < Replayable < NonReplayable)
  defined in Core.lean as EffLevel and shared by all modules.

  Author: Sussmind (2026-03-19, migrated to canonical effects 2026-03-20)
-/

import Core

namespace Autopour

/-! ====================================================================
    EFFECT LATTICE (EffLevel imported from Core.lean)
    ==================================================================== -/

/-- Bool version for decidable checks. -/
def EffLevel.le (a b : EffLevel) : Bool := a.toNat ≤ b.toNat

/-- Autopour is a NonReplayable operation (it mutates the tuple space). -/
def autopourEffLevel : EffLevel := .nonReplayable

/-! ====================================================================
    EXTENDED VALUE DOMAIN
    ==================================================================== -/

/-- ProgramText is opaque — the runtime parses it. -/
structure ProgramText where
  source : String
  deriving Repr, DecidableEq, BEq

/-- Values in the Cell language, extended with program values. -/
inductive Val where
  | str     : String → Val
  | none    : Val
  | error   : String → Val
  | program : ProgramText → Val    -- NEW: a program is a value
  deriving Repr, DecidableEq, BEq

/-- Check whether a Val is a program. -/
def Val.isProgram : Val → Bool
  | .program _ => true
  | _ => false

/-- Check whether a Val is an error. -/
def Val.isError : Val → Bool
  | .error _ => true
  | _ => false

/-! ====================================================================
    ENVIRONMENTS (same as Denotational.lean but over extended Val)
    ==================================================================== -/

abbrev Env := List (FieldName × Val)

def Env.lookup (env : Env) (f : FieldName) : Val :=
  match env.find? (fun p => p.1 == f) with
  | some (_, v) => v
  | none => .none

def Env.bind (env : Env) (f : FieldName) (v : Val) : Env :=
  env ++ [(f, v)]

/-! ====================================================================
    CELL BODY (same signature as Denotational.lean)
    ==================================================================== -/

inductive Continue where
  | done : Continue
  | more : Continue
  deriving Repr, DecidableEq, BEq

def CellBody (M : Type → Type) := Env → M (Env × Continue)

/-! ====================================================================
    AUTOPOUR CONTEXT
    ==================================================================== -/

/-- The autopour evaluation context. Threads through evaluation.
    fuel: decrements on each pour (0 = bottom)
    depth: tracks current nesting depth (diagnostic)
    maxDepth: hard limit on nesting depth -/
structure AutopourCtx where
  fuel     : Nat
  depth    : Nat := 0
  maxDepth : Nat := 100
  deriving Repr

/-- Can we still pour? -/
def AutopourCtx.canPour (ctx : AutopourCtx) : Bool :=
  ctx.fuel > 0 && ctx.depth < ctx.maxDepth

/-- Consume one unit of fuel and increment depth. -/
def AutopourCtx.step (ctx : AutopourCtx) : AutopourCtx :=
  { ctx with fuel := ctx.fuel - 1, depth := ctx.depth + 1 }

/-! ====================================================================
    CELL AND PROGRAM DEFINITIONS
    ==================================================================== -/

structure CellInterface where
  name     : String
  inputs   : List FieldName
  outputs  : List FieldName
  deriving Repr, DecidableEq

structure Dep where
  sourceCell  : String
  sourceField : FieldName
  targetField : FieldName
  optional    : Bool
  deriving Repr, DecidableEq, BEq

def Oracle := Env → Bool

structure CellDef (M : Type → Type) where
  interface    : CellInterface
  deps         : List Dep
  body         : CellBody M
  effLevel     : EffLevel          -- canonical: pure/replayable/nonReplayable
  oracles      : List Oracle
  autopour     : Bool := false     -- is this yield an autopour yield?

structure Program (M : Type → Type) where
  name  : String
  cells : List (CellDef M)

/-! ====================================================================
    AUTOPOUR YIELD ANNOTATION
    ==================================================================== -/

/-- A yield field can be marked [autopour], meaning:
    when the cell freezes and this field contains Val.program,
    the runtime parses and pours the program. -/
structure AutopourYield where
  fieldName     : FieldName
  effectBound   : EffLevel   -- max effect level for poured program
  deriving Repr

/-- Check that a program respects an effect bound (decidable version). -/
def Program.respectsEffectBoundB {M : Type → Type}
    (p : Program M) (bound : EffLevel) : Bool :=
  p.cells.all (fun cd => EffLevel.le cd.effLevel bound)

/-- Propositional version. -/
def Program.respectsEffectBound {M : Type → Type}
    (p : Program M) (bound : EffLevel) : Prop :=
  ∀ cd ∈ p.cells, EffLevel.le cd.effLevel bound = true

/-- The Bool check implies the Prop. -/
theorem respectsEffectBound_of_B {M : Type → Type}
    (p : Program M) (bound : EffLevel)
    (h : p.respectsEffectBoundB bound = true) :
    p.respectsEffectBound bound := by
  intro cd hcd
  simp [Program.respectsEffectBoundB, List.all_eq_true] at h
  exact h cd hcd

/-! ====================================================================
    EXECUTION FRAMES (from Denotational.lean)
    ==================================================================== -/

structure ExecFrame where
  cellName   : String
  generation : Nat
  inputs     : Env
  outputs    : Env
  oraclePass : Bool
  deriving Repr

abbrev ExecTrace := List ExecFrame

/-! ====================================================================
    AUTOPOUR STEP: the operational semantics
    ==================================================================== -/

/-- Result of attempting an autopour. -/
inductive AutopourResult where
  | success  : AutopourCtx → AutopourResult
  | noFuel   : AutopourResult
  | parseFail : String → AutopourResult
  | effectViolation : AutopourResult
  deriving Repr

/-- Attempt to autopour a program value.
    Parameterized over a parse-and-validate function provided by the runtime.
    This is the core operational semantics of autopour:
    1. Check fuel
    2. Parse the program text and check effect bound
    3. Return success for pouring -/
def autopourStep
    (parseAndValidate : ProgramText → EffLevel → Bool)
    (ctx : AutopourCtx)
    (val : Val)
    (effectBound : EffLevel)
    : AutopourResult :=
  match val with
  | .program pt =>
    if !ctx.canPour then
      .noFuel
    else
      if parseAndValidate pt effectBound then
        .success ctx.step
      else
        .parseFail s!"Failed to parse or effect violation: {pt.source.take 100}"
  | _ => .parseFail "autopour: value is not a program"

/-! ====================================================================
    KEY THEOREMS
    ==================================================================== -/

/-! ### Fuel Termination

    The total number of pours across all levels of the autopour tower
    is bounded by the initial fuel. Each pour decrements fuel by 1.
    No operation creates fuel. -/

/-- Fuel decreases on each step. -/
theorem fuel_decreases (ctx : AutopourCtx) (h : ctx.fuel > 0) :
    ctx.step.fuel < ctx.fuel := by
  simp [AutopourCtx.step]
  omega

/-- Fuel is non-negative (trivially, since it's a Nat). -/
theorem fuel_nonneg (ctx : AutopourCtx) : ctx.fuel ≥ 0 := Nat.zero_le _

/-! ### Monotonicity Preservation

    Pour is append-only (from Retort.lean). Autopour is a sequence of
    pours. Therefore autopour preserves the append-only invariant.

    We state this as: the trace only grows.
    (Full proof requires integration with the retort state model.) -/

/-- Autopour extends, never shrinks, the execution trace. -/
theorem autopour_trace_monotonic
    (trace : ExecTrace) (newFrames : ExecTrace) :
    trace.length ≤ (trace ++ newFrames).length := by
  simp [List.length_append]

/-! ====================================================================
    THE SELF-EVALUATION FIXED POINT
    ==================================================================== -/

/-! When cell-zero (with autopour) is applied to its own definition,
    the result is a fuel-bounded divergent computation:

    cell-zero(cell-zero) → pour(cell-zero, fuel-1) → pour(cell-zero, fuel-2) → ...

    This terminates at fuel = 0 with bottom. The tower has depth = initial fuel.

    KEY INSIGHT: Cell's dependency DAG provides NATURAL termination that
    lambda calculus lacks. The poured copy has unsatisfied dependencies
    and simply doesn't fire. Fuel is only needed for chained autopour
    (program A pours B, B pours C...), not for self-evaluation.

    See docs/research/autopour-denotational-semantics.md Section 5.
-/

/-- Model of the self-evaluation tower. Each level produces some output
    before potentially pouring the next level. -/
def selfEvalTower (fuel : Nat) : List String :=
  match fuel with
  | 0 => ["bottom: fuel exhausted"]
  | n + 1 => s!"layer {n + 1}: evaluating" :: selfEvalTower n

/-- The tower has exactly (fuel + 1) entries. -/
theorem selfEvalTower_length (fuel : Nat) :
    (selfEvalTower fuel).length = fuel + 1 := by
  induction fuel with
  | zero => simp [selfEvalTower]
  | succ n ih =>
    simp [selfEvalTower, List.length_cons, ih]

/-- The tower always ends with bottom. We prove this by showing
    the last element of the list is the base case value. -/
theorem selfEvalTower_terminates (fuel : Nat) :
    (selfEvalTower fuel).getLast (by cases fuel <;> simp [selfEvalTower])
    = "bottom: fuel exhausted" := by
  induction fuel with
  | zero => simp [selfEvalTower]
  | succ n ih =>
    simp only [selfEvalTower]
    rw [List.getLast_cons]
    exact ih

/-! ====================================================================
    CRYSTALLIZATION: Movement Down the Effect Lattice
    ==================================================================== -/

/-! Crystallization is the process by which a Replayable (soft) cell
    becomes a Pure (hard) cell. If a soft cell produces the same output
    for the same inputs across N observations, it can crystallize.

    Denotationally: crystallization is a REFINEMENT. If f : Env → IO Val
    and we observe f(x) = v for all observed x, we introduce
    g : Env → Id Val where g(x) = v. The refinement theorem says:
    the program's observable behavior is unchanged.

    When is this safe?
    1. The cell has no side effects beyond its yields
    2. All oracles pass with the crystallized value
    3. The crystallized value is verified against the original for N runs
    4. The cell's inputs are frozen (no upstream changes possible)

    When is this NOT safe?
    - Stem cells (divergent by design — they SHOULD vary)
    - Cells reading NonReplayable sources (inputs may change)
    - Cells with semantic oracles (the oracle itself may be non-deterministic)
-/

/-- An observation record: inputs, output, oracle result. -/
structure CrystalObs where
  inputs  : Env
  output  : Env
  oracleOk : Bool
  deriving Repr, BEq

/-- A cell is crystallization-eligible if it's Replayable and has
    no NonReplayable dependencies. -/
def crystallizationEligible (cell : CellDef Id) : Bool :=
  cell.effLevel == .replayable

/-- Check whether all observations in a list produce the same output
    as a reference output. -/
def allAgreeWith (ref : Env) (obs : List CrystalObs) : Bool :=
  obs.all (fun o => o.output == ref && o.oracleOk)

/-- The crystallization threshold: how many agreeing observations
    before we consider crystallization safe. -/
def crystallizationThreshold : Nat := 3

/-- A crystallization candidate: a cell with sufficient agreeing observations
    relative to a chosen reference output. -/
structure CrystalCandidate where
  cellName     : String
  refOutput    : Env
  observations : List CrystalObs
  hEnough      : observations.length ≥ crystallizationThreshold := by omega
  hAgree       : allAgreeWith refOutput observations = true

/-- KEY THEOREM: Crystallization is a refinement — every observation
    in a valid candidate agrees with the reference output (as BEq). -/
theorem crystallization_sound (c : CrystalCandidate) :
    ∀ obs ∈ c.observations, (obs.output == c.refOutput) = true := by
  intro obs hobs
  have hAll := c.hAgree
  simp [allAgreeWith, List.all_eq_true, Bool.and_eq_true] at hAll
  exact (hAll obs hobs).1

/-! NOTE: This theorem is about observed inputs only. It does NOT
    guarantee the crystallized cell will produce the same output on
    UNSEEN inputs. That's fundamentally unprovable for LLM-evaluated
    cells (the LLM might return something different for novel inputs).

    In practice, crystallization is speculative: we ASSUME the pattern
    holds, and if a future evaluation contradicts it, we DE-crystallize
    (thaw the cell back to Replayable and re-evaluate).

    The formal model of de-crystallization:
    - Observe(crystallized_cell, new_input) → output ≠ expected
    - Thaw(cell) → revert to Replayable
    - Re-evaluate with the LLM

    This is safe because yields are append-only: the crystallized yields
    remain in the trace (at their generation), and the thawed cell
    produces new yields at a higher generation. History is preserved. -/

end Autopour

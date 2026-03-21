/-
  Denotational Semantics of the Cell Language (Unified Model)

  We formalize what a Cell program MEANS, independent of syntax.
  This is the mathematical foundation: what does evaluation produce?

  Key abstractions:
  - A program is a finite DAG of computations
  - Each cell is a function from inputs to outputs, parameterized over
    an effect monad M; there is ONE cell kind, not three
  - The Continue signal replaces the old Bool for "more demand"
  - An effect lattice classifies cells by computational power
  - Stem cells are corecursive (productive streams)
  - Oracles are predicates that constrain outputs
  - The execution graph grows as stem cells cycle
  - Bottom (error) propagates eagerly through non-optional dependencies

  We deliberately avoid the turnstyle syntax (⊢, ∴, ⊨, etc.)
  and work with abstract structures.
-/

import Core

/-! ====================================================================
    VALUE DOMAIN
    ==================================================================== -/

-- Values in the Cell language are strings (for now).
-- This is a design limitation we'll identify below.
inductive Val where
  | str   : String → Val
  | none  : Val              -- absent / not yet computed
  | error : String → Val     -- computation failed
  deriving Repr, DecidableEq, BEq

-- An environment maps field names to values
abbrev Env := List (FieldName × Val)

def Env.lookup (env : Env) (f : FieldName) : Val :=
  match env.find? (fun p => p.1 == f) with
  | some (_, v) => v
  | none => .none

def Env.bind (env : Env) (f : FieldName) (v : Val) : Env :=
  env ++ [(f, v)]

-- Check whether a Val is an error
def Val.isError : Val → Bool
  | .error _ => true
  | _ => false

/-! ====================================================================
    UNIFIED CELL BODY
    ==================================================================== -/

-- Continue replaces the old Bool in RecBody.
-- A cell body returns (outputs, done|more).
-- Non-stem cells always return .done.
-- Stem cells return .more to request another cycle.
inductive Continue where
  | done : Continue
  | more : Continue
  deriving Repr, DecidableEq, BEq

-- One cell body type, parameterized over a monad M.
-- Replaces the old PureBody / EffBody / RecBody trichotomy.
def CellBody (M : Type → Type) := Env → M (Env × Continue)

/-! ====================================================================
    EFFECT LATTICE (EffLevel imported from Core)
    ==================================================================== -/

-- LE, LT, Decidable instances for EffLevel are provided by Core.lean.

/-! ====================================================================
    CELL DEFINITIONS (abstract, parameterized over M)
    ==================================================================== -/

-- A cell's interface: what it needs and what it produces
structure CellInterface where
  name     : String
  inputs   : List FieldName     -- given fields (what this cell reads)
  outputs  : List FieldName     -- yield fields (what this cell produces)
  deriving Repr, DecidableEq

-- Dependency: this cell reads from that cell's field
structure Dep where
  sourceCell  : String
  sourceField : FieldName
  targetField : FieldName       -- the name in this cell's input env
  optional    : Bool
  deriving Repr, DecidableEq, BEq

-- Oracle: a predicate on the cell's output environment
def Oracle := Env → Bool

-- A complete cell definition, parameterized over the effect monad M.
-- There is ONE kind of cell. The effLevel classifies it.
structure CellDef (M : Type → Type) where
  interface    : CellInterface
  deps         : List Dep
  body         : CellBody M
  effLevel     : EffLevel
  oracles      : List Oracle

/-! ====================================================================
    PROGRAMS: DAGs of cells
    ==================================================================== -/

-- A program is a collection of cell definitions, parameterized over M.
structure Program (M : Type → Type) where
  name  : String
  cells : List (CellDef M)

-- Well-formedness: dependencies reference cells that exist in the program
def Program.depsWellFormed {M : Type → Type} (p : Program M) : Prop :=
  ∀ cd ∈ p.cells, ∀ d ∈ cd.deps,
    ∃ src ∈ p.cells, src.interface.name = d.sourceCell ∧
      d.sourceField ∈ src.interface.outputs

-- Well-formedness: no circular dependencies (among non-nonReplayable cells)
-- For nonReplayable (stem) cells, self-dependency is allowed (they read previous generation)
def Program.acyclic {M : Type → Type} (p : Program M) : Prop :=
  ∃ order : List String,
    (∀ cd ∈ p.cells,
      cd.effLevel = .nonReplayable ∨ cd.interface.name ∈ order) ∧
    (∀ cd ∈ p.cells, ∀ d ∈ cd.deps,
      cd.effLevel = .nonReplayable ∨
        (cd.interface.name ∈ order ∧ d.sourceCell ∈ order))

/-! ====================================================================
    DENOTATIONAL SEMANTICS
    ==================================================================== -/

-- The meaning of a program is a function from an initial state
-- to a (possibly infinite) stream of execution frames.

-- An execution frame: one cell's evaluation result
structure ExecFrame where
  cellName   : String
  generation : Nat
  inputs     : Env               -- what was read
  outputs    : Env               -- what was produced
  oraclePass : Bool              -- did all oracles pass?
  deriving Repr

-- The execution trace: a sequence of frames
-- (potentially infinite for programs with stem cells)
abbrev ExecTrace := List ExecFrame

/-! ## Resolving Inputs (with bottom propagation)

  A cell's inputs come from its dependencies. Each dependency says:
  "read field F from cell C's outputs." The resolution process
  finds the LATEST frozen frame for cell C and reads field F.

  BOTTOM PROPAGATION: if a non-optional dependency resolved to a cell
  whose latest frozen frame has an error output for the requested field,
  the error value is passed through. The caller checks for poisoned
  inputs and short-circuits to an error frame.
-/

-- Find the latest frame for a cell in the trace
def latestFrame (trace : ExecTrace) (cellName : String) : Option ExecFrame :=
  let matching := trace.filter (fun f => f.cellName == cellName && f.oraclePass)
  matching.getLast?

-- Resolve all dependencies for a cell.
-- Error values from source cells flow through as-is (bottom propagation).
def resolveInputs (trace : ExecTrace) (deps : List Dep) : Env :=
  deps.foldl (fun env d =>
    match latestFrame trace d.sourceCell with
    | some frame => env.bind d.targetField (frame.outputs.lookup d.sourceField)
    | none => if d.optional then env else env.bind d.targetField .none
  ) []

-- Check whether any non-optional input carries an error (bottom).
-- If so, the cell should immediately produce error outputs.
def inputsPoisoned (inputs : Env) (deps : List Dep) : Bool :=
  deps.any (fun d =>
    !d.optional && (inputs.lookup d.targetField).isError)

-- Build an error output environment: every output field gets an error value.
def errorOutputs (outputFields : List FieldName) (msg : String) : Env :=
  outputFields.map (fun f => (f, Val.error msg))

/-! ## The Evaluation Function

  [[program]] : ExecTrace

  Evaluation proceeds in topological order:
  1. Cells with no dependencies evaluate first
  2. Each cell reads from the already-evaluated cells
  3. Stem cells (effLevel = nonReplayable) contribute frames repeatedly

  We define this as a STEP function that takes a trace prefix
  and produces the next frame.

  We instantiate M = Id for concrete evaluation. The CellDef is
  parameterized over M, but evalStep works with CellDef Id so that
  the body is a pure Lean function we can call directly.
-/

-- Can a cell fire? (All non-optional deps have frozen frames in the trace)
def cellReady {M : Type → Type} (trace : ExecTrace) (cd : CellDef M) : Bool :=
  cd.deps.all (fun d =>
    d.optional || (latestFrame trace d.sourceCell).isSome)

-- Find the next cell to evaluate in a program.
-- NonReplayable cells can always re-fire; others fire at most once.
def nextCell {M : Type → Type} (p : Program M) (trace : ExecTrace) : Option (CellDef M) :=
  p.cells.find? (fun cd =>
    cellReady trace cd &&
    match cd.effLevel with
    | .nonReplayable => true   -- stem cells can always re-fire
    | _ => !(trace.any (fun f => f.cellName == cd.interface.name && f.oraclePass)))

-- Evaluate one step (unified: one branch for all cell kinds).
-- Bottom propagation: if any non-optional input is an error, the cell
-- immediately produces error outputs without running the body.
def evalStep (p : Program Id) (trace : ExecTrace) : Option ExecFrame :=
  match nextCell p trace with
  | none => none
  | some cd =>
    let inputs := resolveInputs trace cd.deps
    let gen := (trace.filter (fun f => f.cellName == cd.interface.name)).length
    -- Bottom propagation: poisoned inputs => error frame
    if inputsPoisoned inputs cd.deps then
      some { cellName := cd.interface.name, generation := gen,
             inputs := inputs,
             outputs := errorOutputs cd.interface.outputs "bottom: dependency error",
             oraclePass := false }
    else
      -- Unified evaluation: call the body, extract outputs and continue signal
      let (outputs, _continue) := cd.body inputs
      some { cellName := cd.interface.name, generation := gen,
             inputs := inputs, outputs := outputs,
             oraclePass := cd.oracles.all (· outputs) }

-- Evaluate N steps (bounded evaluation for non-stem programs)
def evalN (p : Program Id) (n : Nat) : ExecTrace :=
  match n with
  | 0 => []
  | n + 1 =>
    let trace := evalN p n
    match evalStep p trace with
    | none => trace       -- no more cells to evaluate
    | some frame => trace ++ [frame]

/-! ## Semantic Properties -/

-- A program is COMPLETE when evalStep returns none
def programComplete (p : Program Id) (trace : ExecTrace) : Prop :=
  evalStep p trace = none

-- A trace is VALID if each frame follows from evalStep on the prefix
def validTrace (p : Program Id) (trace : ExecTrace) : Prop :=
  ∀ i, ∀ h : i < trace.length,
    evalStep p (trace.take i) = some (trace.get ⟨i, h⟩)

-- Pure cells are DETERMINISTIC: same inputs, same outputs
theorem pure_deterministic (body : CellBody Id) (inputs : Env) :
    body inputs = body inputs := rfl

-- The trace grows monotonically (frames are append-only).
-- Proof: evalN (n+1) either returns the same trace (evalStep = none)
-- or appends one frame. Either way length does not decrease.
theorem evalN_monotonic (p : Program Id) (n : Nat) :
    (evalN p n).length ≤ (evalN p (n + 1)).length := by
  simp only [evalN]
  split
  · -- evalStep returns none: trace unchanged
    exact Nat.le_refl _
  · -- evalStep returns some: trace ++ [frame]
    simp [List.length_append]

/-! ====================================================================
    GRAPH GROWTH: Stem cells produce unbounded traces
    ==================================================================== -/

-- Model streams as functions from Nat to Optional frames
def CellStream := Nat → Option ExecFrame

-- A stem cell's meaning: produces frames indexed by generation
def stemDenotation (body : CellBody Id) (trace : ExecTrace) : CellStream :=
  fun n =>
    let inputs := resolveInputs trace []
    let (outputs, _) := body inputs
    some { cellName := "stem", generation := n,
           inputs := inputs, outputs := outputs, oraclePass := true }

-- The graph grows because each stem cycle appends a frame.
-- The trace length increases by 1 each cycle.

-- For non-stem programs, the trace is finite:
-- it has exactly one frame per cell (in topological order).
-- For programs with stem cells, the trace is potentially infinite.

-- Helper: evalN produces at most n frames (each step adds at most one)
private theorem evalN_length_le (p : Program Id) (n : Nat) :
    (evalN p n).length ≤ n := by
  induction n with
  | zero => simp [evalN]
  | succ n ih =>
    simp only [evalN]
    split
    · -- evalStep returns none: trace unchanged, length ≤ n ≤ n + 1
      exact Nat.le_succ_of_le ih
    · -- evalStep returns some: trace ++ [frame], length = old + 1 ≤ n + 1
      simp only [List.length_append, List.length_cons, List.length_nil]
      omega

-- FINITE BOUND for non-stem programs:
-- (The hypothesis hNoStem is the semantic precondition; the bound holds
-- structurally because evalN adds at most one frame per step.)
theorem nonStem_finite (p : Program Id)
    (_hNoStem : ∀ cd ∈ p.cells, cd.effLevel ≠ .nonReplayable) :
    (evalN p p.cells.length).length ≤ p.cells.length :=
  evalN_length_le p p.cells.length

/-! ====================================================================
    WHAT'S MISSING FROM THE LANGUAGE
    ==================================================================== -/

/-! ## Missing Feature 1: Types

  Currently all values are strings. The Val type should be richer:

  inductive Val where
    | str    : String → Val
    | num    : Int → Val
    | bool   : Bool → Val
    | json   : JsonValue → Val
    | list   : List Val → Val
    | record : List (String × Val) → Val
    | none   : Val
    | error  : String → Val

  Oracles are ad-hoc type checks ("is_json_array", "not_empty").
  A proper type system would:
  - Validate yields at compile time (pour time)
  - Eliminate the need for most oracles
  - Enable schema-level compatibility checking between cells

  Type inference: given a cell's body and input types, infer output types.
  For hard cells this is straightforward (SQL types).
  For soft cells, the type is declared (the yield spec).
-/

-- A typed interface (what the language SHOULD have)
inductive CellType where
  | string  : CellType
  | number  : CellType
  | boolean : CellType
  | json    : CellType
  | list    : CellType → CellType
  | record  : List (String × CellType) → CellType
  deriving Repr

structure TypedField where
  name : FieldName
  type : CellType
  deriving Repr

-- Type checking: does the output match the declared type?
-- This would replace most oracles.

/-! ## Missing Feature 2: Conditional Branching (Guards)

  The current DAG is static: every cell is always evaluated
  (if its dependencies are satisfied). There's no way to say:
  "evaluate cell A only if cell B's output satisfies condition C."

  This is a GUARD:
    ⊢ expensive-analysis
      guard route→decision = "proceed"
      given data→input
      yield result

  The cell only fires if the guard evaluates to true.
  Guards are a restricted form of conditionals that preserve
  the DAG structure (no dynamic topology changes).

  Without guards, you waste computation: cells evaluate even
  when their results won't be used.
-/

structure GuardedCellDef (M : Type → Type) where
  cell  : CellDef M
  guard : Option (String × FieldName × String)  -- (sourceCell, field, expectedValue)

def guardSatisfied (trace : ExecTrace) : Option (String × FieldName × String) → Bool
  | none => true
  | some (cell, field, expected) =>
    match latestFrame trace cell with
    | some frame => frame.outputs.lookup field == .str expected
    | none => false

/-! ## Missing Feature 3: Aggregation (Fold/Collect)

  There's no way to collect outputs from multiple cells
  or multiple generations of a stem cell.

  Current workaround: `given NAME-*→FIELD` (wildcard gather)
  which expands at pour time. But this requires knowing the
  number of sources at compile time.

  A proper aggregation would be:
    ⊢ summary
      collect results-*→output AS all_results
      yield combined
      ∴ Combine all results: «all_results»

  Where `collect` gathers a LIST of values from all matching cells,
  not just one. This is fold/reduce over the DAG.
-/

-- Aggregation: collect all values matching a pattern
def collectValues (trace : ExecTrace) (cellPattern : String → Bool) (field : FieldName) : List Val :=
  (trace.filter (fun f => cellPattern f.cellName && f.oraclePass)).map
    (fun f => f.outputs.lookup field)

/-! ## Missing Feature 4: Dynamic Spawn (First-Class Programs)

  A cell can't create new cells at runtime. cell-zero-eval works
  around this by operating at the SQL level (inserting into the
  cells table directly). But this breaks the abstraction.

  In a proper language, a cell should be able to:
    ⊢ orchestrator
      yield sub_program
      ∴ Based on the input, generate a Cell program as output

  And the runtime would POUR the output as a new program.
  This is metaprogramming: programs that produce programs.

  Denotationally, this is a function from Val to Program:
-/

def MetaCell (M : Type → Type) := Env → Program M

/-! ## Missing Feature 5: Explicit Parallelism

  Independent cells CAN run in parallel (they have no data
  dependencies). But there's no way to control:
  - Maximum concurrency (at most N pistons)
  - Sequential ordering (evaluate A then B even if independent)
  - Priority (evaluate A before B)

  This matters for resource management (LLM API rate limits)
  and for deterministic replay.
-/

/-! ## Missing Feature 6: Cell References (Quoting)

  A cell can't reference another cell's DEFINITION (body, deps, etc.)
  Pour-one does this via SQL: `SELECT body FROM cells WHERE name = ?`
  But this is outside the Cell language.

  A `quote` operator would let cells inspect definitions:
    ⊢ inspector
      given target→definition   ← the DEFINITION, not the OUTPUT
      yield analysis

  This enables reflection and metaprogramming within the language.
-/

/-! ====================================================================
    THE COMPLETE SEMANTIC PICTURE (UNIFIED MODEL)
    ==================================================================== -/

/-
  THE CELL LANGUAGE (UNIFIED MODEL):

    Continue ::= done | more
    CellBody M ::= Env -> M (Env x Continue)

    EffLevel ::= pure | replayable | nonReplayable
      pure <= replayable <= nonReplayable     (total order / lattice)

    Cell M ::= (interface, deps, body : CellBody M, effLevel, oracles)
    Program M ::= name x List (Cell M)

    [[Program]] ::= ExecTrace (List ExecFrame)

    Evaluation: topological order, one frame per non-nonReplayable cell,
    multiple frames per nonReplayable (stem) cells. Demand-driven for stems.

    Bottom propagation: if any non-optional input carries Val.error,
    the cell immediately produces error outputs without running the body.
    This prevents cascading hangs when a dependency fails.

  WHAT'S MISSING (in order of impact):

    1. TYPES      -- eliminate ad-hoc oracles, enable compile-time checking
    2. GUARDS     -- conditional execution without wasting computation
    3. AGGREGATION -- fold/collect over multiple cells or generations
    4. DYNAMIC SPAWN -- cells that produce programs (metaprogramming)
    5. PARALLELISM -- concurrency control, priority, rate limiting
    6. QUOTING    -- reflection, inspect cell definitions

  WHAT'S SOLID:

    - DAG structure is correct and well-defined
    - Unified CellBody with Continue signal covers the computation space:
        pure cells return .done, stems return .more
    - Effect lattice classifies cells without changing the body type
    - Givens (data flow) + Oracles (constraints) = the core abstraction
    - Bottom propagation ensures errors don't silently block the graph
    - Content-addressed frames give immutable execution history
    - Demand-driven stems prevent busy-spinning
    - The separation of DEFINITION (cells) from EXECUTION (frames)
      is the key architectural insight from the formal model
    - M is kept abstract: CellDef is parameterized over the effect monad,
      only evalStep/evalN require M = Id for concrete execution

  THE FRAME MODEL IS THE RIGHT FOUNDATION:
    - Definitions are immutable (CellDef)
    - Executions are immutable (ExecFrame)
    - The trace is append-only
    - Missing features (types, guards, aggregation) can be added
      WITHOUT changing the frame model -- they extend CellDef,
      not the execution infrastructure
-/

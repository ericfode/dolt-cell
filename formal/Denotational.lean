/-
  Denotational Semantics of the Cell Language

  We formalize what a Cell program MEANS, independent of syntax.
  This is the mathematical foundation: what does evaluation produce?

  Key abstractions:
  - A program is a finite DAG of computations
  - Each cell is a function from inputs to outputs
  - Stem cells are corecursive (productive streams)
  - Oracles are predicates that constrain outputs
  - The execution graph grows as stem cells cycle

  We deliberately avoid the turnstyle syntax (⊢, ∴, ⊨, etc.)
  and work with abstract structures.
-/

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
abbrev FieldName := String
abbrev Env := List (FieldName × Val)

def Env.lookup (env : Env) (f : FieldName) : Val :=
  match env.find? (fun p => p.1 == f) with
  | some (_, v) => v
  | none => .none

def Env.bind (env : Env) (f : FieldName) (v : Val) : Env :=
  env ++ [(f, v)]

/-! ====================================================================
    CELL BODIES: What a cell computes
    ==================================================================== -/

-- A cell body is a function from resolved inputs to outputs.
-- We model three kinds:

-- 1. Pure: deterministic, total function (hard cells)
--    Given inputs, always produces the same outputs.
def PureBody := Env → Env

-- 2. Effectful: may use external resources (soft cells, LLM)
--    Modeled as a function that returns in some monad.
--    We abstract over the monad — it could be IO, State, etc.
def EffBody (M : Type → Type) := Env → M Env

-- 3. Recursive: produces output AND a continuation (stem cells)
--    Each invocation yields outputs AND indicates whether to continue.
structure RecBody (M : Type → Type) where
  step : Env → M (Env × Bool)   -- (output, more_demand?)

/-! ====================================================================
    CELL DEFINITIONS (abstract)
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

-- A cell kind determines evaluation behavior
inductive CellKind where
  | pure     : PureBody → CellKind           -- hard cells
  | effect   : EffBody Id → CellKind         -- soft cells (Id monad for simplicity)
  | stream   : RecBody Id → CellKind         -- stem cells

-- A complete cell definition
structure CellDef where
  interface : CellInterface
  deps      : List Dep
  kind      : CellKind
  oracles   : List Oracle

/-! ====================================================================
    PROGRAMS: DAGs of cells
    ==================================================================== -/

-- A program is a collection of cell definitions
structure Program where
  name  : String
  cells : List CellDef

-- Well-formedness: dependencies reference cells that exist in the program
def Program.depsWellFormed (p : Program) : Prop :=
  ∀ cd ∈ p.cells, ∀ d ∈ cd.deps,
    ∃ src ∈ p.cells, src.interface.name = d.sourceCell ∧
      d.sourceField ∈ src.interface.outputs

-- Well-formedness: no circular dependencies (among non-stem cells)
-- For stem cells, self-dependency is allowed (they read previous generation)
def Program.acyclic (p : Program) : Prop :=
  ∃ order : List String,
    (∀ cd ∈ p.cells, match cd.kind with
      | .stream _ => True
      | _ => cd.interface.name ∈ order) ∧
    (∀ cd ∈ p.cells, ∀ d ∈ cd.deps,
      match cd.kind with
      | .stream _ => True
      | _ => cd.interface.name ∈ order ∧ d.sourceCell ∈ order)

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

-- Evaluate a pure cell given its resolved inputs
def evalPure (body : PureBody) (inputs : Env) (oracles : List Oracle) : ExecFrame → Prop :=
  fun frame =>
    frame.outputs = body inputs ∧
    frame.oraclePass = oracles.all (· frame.outputs)

-- Evaluate an effectful cell
def evalEffect (body : EffBody Id) (inputs : Env) (oracles : List Oracle) : ExecFrame → Prop :=
  fun frame =>
    frame.outputs = body inputs ∧
    frame.oraclePass = oracles.all (· frame.outputs)

/-! ## Resolving Inputs

  A cell's inputs come from its dependencies. Each dependency says:
  "read field F from cell C's outputs." The resolution process
  finds the LATEST frozen frame for cell C and reads field F.
-/

-- Find the latest frame for a cell in the trace
def latestFrame (trace : ExecTrace) (cellName : String) : Option ExecFrame :=
  let matching := trace.filter (fun f => f.cellName == cellName && f.oraclePass)
  matching.getLast?

-- Resolve all dependencies for a cell
def resolveInputs (trace : ExecTrace) (deps : List Dep) : Env :=
  deps.foldl (fun env d =>
    match latestFrame trace d.sourceCell with
    | some frame => env.bind d.targetField (frame.outputs.lookup d.sourceField)
    | none => if d.optional then env else env.bind d.targetField .none
  ) []

/-! ## The Evaluation Function

  ⟦program⟧ : ExecTrace

  Evaluation proceeds in topological order:
  1. Cells with no dependencies evaluate first
  2. Each cell reads from the already-evaluated cells
  3. Stem cells contribute frames repeatedly

  We define this as a STEP function that takes a trace prefix
  and produces the next frame.
-/

-- Can a cell fire? (All non-optional deps have frozen frames in the trace)
def cellReady (trace : ExecTrace) (cd : CellDef) : Bool :=
  cd.deps.all (fun d =>
    d.optional || (latestFrame trace d.sourceCell).isSome)

-- Find the next cell to evaluate in a program
def nextCell (p : Program) (trace : ExecTrace) : Option CellDef :=
  p.cells.find? (fun cd =>
    cellReady trace cd &&
    -- For non-stem cells: only fire if not already evaluated
    match cd.kind with
    | .stream _ => true  -- stem cells can always re-fire
    | _ => !(trace.any (fun f => f.cellName == cd.interface.name && f.oraclePass)))

-- Evaluate one step
def evalStep (p : Program) (trace : ExecTrace) : Option ExecFrame :=
  match nextCell p trace with
  | none => none
  | some cd =>
    let inputs := resolveInputs trace cd.deps
    let gen := (trace.filter (fun f => f.cellName == cd.interface.name)).length
    match cd.kind with
    | .pure body =>
      let outputs := body inputs
      some { cellName := cd.interface.name, generation := gen,
             inputs := inputs, outputs := outputs,
             oraclePass := cd.oracles.all (· outputs) }
    | .effect body =>
      let outputs := body inputs
      some { cellName := cd.interface.name, generation := gen,
             inputs := inputs, outputs := outputs,
             oraclePass := cd.oracles.all (· outputs) }
    | .stream rb =>
      let (outputs, _moreDemand) := rb.step inputs
      some { cellName := cd.interface.name, generation := gen,
             inputs := inputs, outputs := outputs,
             oraclePass := cd.oracles.all (· outputs) }

-- Evaluate N steps (bounded evaluation for non-stem programs)
def evalN (p : Program) (n : Nat) : ExecTrace :=
  match n with
  | 0 => []
  | n + 1 =>
    let trace := evalN p n
    match evalStep p trace with
    | none => trace       -- no more cells to evaluate
    | some frame => trace ++ [frame]

/-! ## Semantic Properties -/

-- A program is COMPLETE when evalStep returns none
def programComplete (p : Program) (trace : ExecTrace) : Prop :=
  evalStep p trace = none

-- A trace is VALID if each frame follows from evalStep on the prefix
def validTrace (p : Program) (trace : ExecTrace) : Prop :=
  ∀ i, ∀ h : i < trace.length,
    evalStep p (trace.take i) = some (trace.get ⟨i, h⟩)

-- Pure cells are DETERMINISTIC: same inputs → same outputs
theorem pure_deterministic (body : PureBody) (inputs : Env) :
    body inputs = body inputs := rfl

-- The trace grows monotonically (frames are append-only)
theorem evalN_monotonic (p : Program) (n : Nat) :
    (evalN p n).length ≤ (evalN p (n + 1)).length := by
  sorry

/-! ====================================================================
    GRAPH GROWTH: Stem cells produce unbounded traces
    ==================================================================== -/

-- Model streams as functions from Nat to Optional frames
def CellStream := Nat → Option ExecFrame

-- A stem cell's meaning: produces frames indexed by generation
def stemDenotation (rb : RecBody Id) (trace : ExecTrace) : CellStream :=
  fun n =>
    let inputs := resolveInputs trace []
    let (outputs, _) := rb.step inputs
    some { cellName := "stem", generation := n,
           inputs := inputs, outputs := outputs, oraclePass := true }

-- The graph grows because each stem cycle appends a frame.
-- The trace length increases by 1 each cycle.

-- For non-stem programs, the trace is finite:
-- it has exactly one frame per cell (in topological order).
-- For programs with stem cells, the trace is potentially infinite.

-- FINITE BOUND for non-stem programs:
theorem nonStem_finite (p : Program)
    (hNoStem : ∀ cd ∈ p.cells, match cd.kind with | .stream _ => False | _ => True) :
    (evalN p p.cells.length).length ≤ p.cells.length := by
  sorry -- Each non-stem cell contributes at most one frame

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

/-! ## Missing Feature 2: Error Propagation (Bottom)

  When a cell fails, its yields never materialize. Dependent cells
  block forever. There's no way to:
  - Detect that a dependency failed
  - Propagate failure downstream
  - Provide fallback values

  The denotational semantics needs ⊥ (bottom):

  A cell's output is ⊥ if:
  - Its body raises an error
  - An oracle fails after max retries
  - A non-optional dependency is ⊥

  ⊥ propagation: if any non-optional input is ⊥, the cell is ⊥.
  This is standard in dataflow semantics.
-/

-- Bottom propagation
def propagateBottom (inputs : Env) (deps : List Dep) : Bool :=
  deps.any (fun d =>
    !d.optional && inputs.lookup d.targetField == .error "dependency failed")

/-! ## Missing Feature 3: Conditional Branching

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

structure GuardedCellDef where
  cell  : CellDef
  guard : Option (String × FieldName × String)  -- (sourceCell, field, expectedValue)

def guardSatisfied (trace : ExecTrace) : Option (String × FieldName × String) → Bool
  | none => true
  | some (cell, field, expected) =>
    match latestFrame trace cell with
    | some frame => frame.outputs.lookup field == .str expected
    | none => false

/-! ## Missing Feature 4: Aggregation (Fold/Collect)

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

/-! ## Missing Feature 5: Dynamic Spawn (First-Class Programs)

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

def MetaCell := Env → Program

/-! ## Missing Feature 6: Explicit Parallelism

  Independent cells CAN run in parallel (they have no data
  dependencies). But there's no way to control:
  - Maximum concurrency (at most N pistons)
  - Sequential ordering (evaluate A then B even if independent)
  - Priority (evaluate A before B)

  This matters for resource management (LLM API rate limits)
  and for deterministic replay.
-/

/-! ## Missing Feature 7: Cell References (Quoting)

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
    THE COMPLETE SEMANTIC PICTURE
    ==================================================================== -/

/-
  THE CELL LANGUAGE AS IT EXISTS TODAY:

    Cell ::= (name, deps, kind, oracles, yields)
    kind ::= Pure (Env → Env)
           | Effect (Env → M Env)
           | Stream (Env → M (Env × Bool))

    Program ::= name × List Cell
    ⟦Program⟧ ::= ExecTrace (List ExecFrame)

    Evaluation: topological order, one frame per non-stem cell,
    multiple frames per stem cell. Demand-driven for stems.

  WHAT'S MISSING (in order of impact):

    1. TYPES — eliminate ad-hoc oracles, enable compile-time checking
    2. BOTTOM — error propagation, failure handling
    3. GUARDS — conditional execution without wasting computation
    4. AGGREGATION — fold/collect over multiple cells or generations
    5. DYNAMIC SPAWN — cells that produce programs (metaprogramming)
    6. PARALLELISM — concurrency control, priority, rate limiting
    7. QUOTING — reflection, inspect cell definitions

  WHAT'S SOLID:

    - DAG structure is correct and well-defined
    - Pure/Effect/Stream trichotomy covers the computation space
    - Givens (data flow) + Oracles (constraints) = the core abstraction
    - Content-addressed frames give immutable execution history
    - Demand-driven stems prevent busy-spinning
    - The separation of DEFINITION (cells) from EXECUTION (frames)
      is the key architectural insight from the formal model

  THE FRAME MODEL IS THE RIGHT FOUNDATION:
    - Definitions are immutable (CellDef)
    - Executions are immutable (ExecFrame)
    - The trace is append-only
    - Missing features (types, guards, aggregation) can be added
      WITHOUT changing the frame model — they extend CellDef,
      not the execution infrastructure
-/

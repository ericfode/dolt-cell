/-
  Stem Cell Identity Problem — Deep Exploration

  REQUIREMENTS (from user):
  - Execution graph must be a DAG
  - Content-addressed: every execution frame addressable
  - Immutability is critical — no overwriting state
  - Stem cells block on demand (not always-ready)
  - Dolt should make content addressing transparent

  We explore five approaches, prove their properties, and debate.
-/

/-! ====================================================================
    FOUNDATIONS: Types and Desired Properties
    ==================================================================== -/

-- A commit hash / content address
structure Hash where
  val : Nat
  deriving Repr, DecidableEq, BEq

-- Cell identity (stable across generations)
structure CellName where
  program : String
  name : String
  deriving Repr, DecidableEq, BEq

-- An execution frame: one run of a cell
structure Frame where
  cell : CellName
  generation : Nat
  deriving Repr, DecidableEq, BEq

-- A yield produced by a specific frame
structure Yield where
  frame : Frame
  field : String
  value : String
  deriving Repr, DecidableEq, BEq

-- A dependency: this frame reads from that frame's yield
structure Edge where
  consumer : Frame
  producer : Frame
  field : String
  deriving Repr, DecidableEq

-- The execution graph: frames + yields + edges
structure ExecGraph where
  frames : List Frame
  yields : List Yield
  edges  : List Edge
  deriving Repr

/-! ## The Five Desired Properties -/

-- P1: DAG — no cycles in the dependency edges
-- (simplified: no frame depends on itself or a later generation of the same cell)
def noCycles (g : ExecGraph) : Prop :=
  ∀ e ∈ g.edges, e.consumer ≠ e.producer

-- P2: Content-addressed — each frame is uniquely identifiable
def contentAddressed (g : ExecGraph) : Prop :=
  ∀ f1 f2, f1 ∈ g.frames → f2 ∈ g.frames →
    f1.cell = f2.cell → f1.generation = f2.generation → f1 = f2

-- P3: Immutable — once a yield is produced, it never changes
def immutableYields (g : ExecGraph) : Prop :=
  ∀ y1 y2, y1 ∈ g.yields → y2 ∈ g.yields →
    y1.frame = y2.frame → y1.field = y2.field → y1.value = y2.value

-- P4: Bounded cells — the number of CELL DEFINITIONS is fixed (not frames)
-- Frames may grow (stem cells produce new frames), but cell definitions don't
def boundedCells (g : ExecGraph) (numCells : Nat) : Prop :=
  (g.frames.map (·.cell) |>.eraseDups).length ≤ numCells

-- P5: Demand-driven — a stem cell frame exists only if there was demand
-- (no frame without an incoming edge or an explicit trigger)
def demandDriven (g : ExecGraph) (triggers : Frame → Bool) : Prop :=
  ∀ f ∈ g.frames,
    triggers f ∨ (∃ e ∈ g.edges, e.consumer = f)

/-! ====================================================================
    APPROACH 1: Spawn (current model)
    Status: BROKEN — violates P2, P4
    ==================================================================== -/

/-
  Each stem cell completion creates a NEW cell row with a new ID.
  eval-one → cz-eval-abc → cz-eval-def → ...

  The "cell name" is reused but the ID is different.
  Frames accumulate without bound in the cells table.
-/

-- Spawn creates a new frame with a DIFFERENT cell name (new ID = new name)
def spawnFrame (f : Frame) (newName : CellName) : Frame :=
  { cell := newName, generation := 0 }

-- Spawn violates boundedCells: each cycle adds a new unique cell name
theorem spawn_violates_bounded :
    ∃ (g : ExecGraph),
      ¬ boundedCells g 2 := by
  refine ⟨{ frames := [⟨⟨"p", "eval"⟩, 0⟩, ⟨⟨"p", "eval-1"⟩, 0⟩, ⟨⟨"p", "eval-2"⟩, 0⟩],
            yields := [], edges := [] }, ?_⟩
  simp [boundedCells]
  native_decide

/-! ====================================================================
    APPROACH 2: Cycle-in-place (mutable reset)
    Status: REJECTED — violates P3 (immutability)
    ==================================================================== -/

/-
  The cell row is MUTATED: state goes declared → computing → declared.
  Yields are overwritten each generation.

  This satisfies P4 (bounded cells) and P2 (content-addressed if we add
  generation). But it VIOLATES P3: overwriting yields = mutation.
  And it violates the DAG property: the "same cell" at different times
  isn't distinguishable in the current state.

  The execution history is only preserved implicitly in Dolt commits.
  If you want to query "what did eval-one produce in generation 3?"
  you need `AS OF` time-travel — it's not in the current tables.
-/

-- Model: a mutable cell that overwrites
structure MutableCell where
  name : CellName
  currentGen : Nat
  currentYields : List Yield
  deriving Repr

-- Overwriting yields is NOT immutable
def overwriteYields (mc : MutableCell) (newYields : List Yield) : MutableCell :=
  { mc with currentGen := mc.currentGen + 1, currentYields := newYields }

-- The previous generation's yields are GONE from the live table
-- Only Dolt commit history preserves them
-- This means: immutableYields cannot hold on the live state

/-! ====================================================================
    APPROACH 3: Append-only yield log (immutable, no state column)
    Status: PROMISING — satisfies P2, P3, P4. Explore P1 and P5.
    ==================================================================== -/

/-
  KEY INSIGHT: Separate the DEFINITION from the EXECUTION.

  - `cells` table: IMMUTABLE after pour. Contains body, name, isStem.
    NO state column. The cell definition never changes.

  - `yield_log` table: APPEND-ONLY. Each row is (cell_name, generation,
    field, value). Once written, never modified or deleted.

  - `claims` table: EPHEMERAL. Tracks which cell+generation is being
    computed. Deleted after completion. This is the only mutable state,
    and it's operational bookkeeping, not execution history.

  - Cell "state" is DERIVED:
    - "frozen at gen G" = yield_log has entries for (cell, G, all fields)
    - "computing at gen G" = claim exists for (cell, G)
    - "declared for gen G" = no yields and no claim for (cell, G)

  - The cell's "current generation" = max(G where yields exist) + 1
    For non-stem cells: current gen is always 0 (they only run once)
    For stem cells: current gen increments with each completion

  - Givens resolve against yield_log: given cell→field at generation G
    reads yield_log WHERE cell_name = cell AND field = field AND gen = G
-/

-- The immutable cell definition
structure CellDef where
  name : CellName
  isStem : Bool
  body : String
  deriving Repr, DecidableEq

-- The append-only yield log
structure YieldEntry where
  cell : CellName
  generation : Nat
  field : String
  value : String
  deriving Repr, DecidableEq, BEq

abbrev YieldLog := List YieldEntry

-- Ephemeral claim (not part of execution history)
structure Claim where
  cell : CellName
  generation : Nat
  piston : String
  deriving Repr

-- Derived state
inductive DerivedState where
  | declared
  | computing
  | frozen
  deriving Repr, DecidableEq, BEq

def deriveState (log : YieldLog) (claims : List Claim) (cell : CellName) (gen : Nat)
    (expectedFields : List String) : DerivedState :=
  let frozenFields := (log.filter (fun y => y.cell == cell && y.generation == gen)).map (·.field)
  if expectedFields.all (· ∈ frozenFields) then .frozen
  else if claims.any (fun c => c.cell == cell && c.generation == gen) then .computing
  else .declared

-- Current generation for a cell
def currentGen (log : YieldLog) (cell : CellName) : Nat :=
  let gens := (log.filter (fun y => y.cell == cell)).map (·.generation)
  match gens.foldl max 0 with
  | 0 => if gens.isEmpty then 0 else 1
  | n => n + 1

-- P3 (Immutability): append-only log never overwrites
-- Adding a yield doesn't change existing yields
theorem appendOnly_preserves_existing (log : YieldLog) (entry : YieldEntry) :
    ∀ y ∈ log, y ∈ (log ++ [entry]) := by
  intro y hy
  exact List.mem_append_left [entry] hy

-- P2 (Content-addressed): (cell, generation, field) is the address
-- We can always look up a specific frame's output
def lookupYieldLog (log : YieldLog) (cell : CellName) (gen : Nat) (field : String) : Option String :=
  (log.find? (fun y => y.cell == cell && y.generation == gen && y.field == field)).map (·.value)

-- P4 (Bounded): cell definitions are fixed; only yield_log grows
-- And yield_log growth is bounded by (num_stem_cells × max_generations × num_fields)
-- For non-stem cells, exactly one generation's yields exist

-- The exec graph derived from an append-only log IS a DAG
-- because frames at generation G only depend on frames at generation < G
-- (or on other cells' frames at any generation)

/-! ### Debate: Approach 3

  PROS:
  + Immutable: yield_log is append-only, cells table never changes
  + Content-addressed: (cell, gen, field) uniquely identifies any yield
  + Bounded cells: cell definitions fixed at pour time
  + DAG: dependency edges always point to earlier or concurrent frames
  + Simple: state is derived, not stored

  CONS:
  - yield_log grows without bound for stem cells
    (each generation appends rows)
  - "Current generation" requires MAX query on yield_log
  - Claims table is mutable (but it's ephemeral bookkeeping)
  - ready_cells view becomes complex: must compute derived state

  CRITICAL QUESTION: Is unbounded yield_log growth acceptable?
  For eval-one running 1000 cycles, that's 3000 yield rows (3 fields × 1000 gens).
  That's... fine? It's a log. Logs grow. And it's the execution trace.
-/

/-! ====================================================================
    APPROACH 4: Dolt commits as frames (each execution = commit)
    Status: ELEGANT but IMPRACTICAL — explore why
    ==================================================================== -/

/-
  IDEA: Each cell evaluation IS a Dolt commit. The commit hash is the
  content address. The commit's diff is the yields. The commit graph
  (parent pointers) IS the execution DAG.

  This is beautiful because Dolt already gives us:
  - Immutability (commits are immutable)
  - Content addressing (commit hashes)
  - DAG structure (commit parents)
  - History traversal (git log, AS OF)

  Implementation:
  - Pour: creates initial commit with cell definitions
  - Claim: no commit needed (ephemeral)
  - Freeze yield: DOLT_COMMIT with yield values in the diff
  - Dependency: "given X→field" resolves by finding the commit where
    X's field was frozen, and reading the value AS OF that commit

  PROBLEM: Dolt commits are LINEAR on a branch (or a DAG across branches).
  But cell evaluation is a wider DAG — multiple cells freeze independently.
  A single branch forces serialization: cell A freezes at commit 5,
  cell B freezes at commit 6. But they might be independent.

  You COULD use Dolt branches: each cell evaluation forks a branch,
  freezes on it, then merges back. But:
  - Dolt branches are heavyweight (full database copy semantics)
  - Merge conflicts if two cells touch the same table
  - Querying across branches is complex

  ALSO: To resolve "given X→field", you'd need to find which commit
  froze X. That requires scanning the commit log or maintaining an index.
  The index IS the yield_log from Approach 3.
-/

/-
  VERDICT on Approach 4:
  Dolt commits give us immutability and content-addressing FOR FREE,
  but they don't naturally model the CELL-LEVEL DAG. The commit graph
  is too coarse (whole-database level) or too expensive (per-cell branches).

  HOWEVER: we should STILL use Dolt commits as the persistence mechanism.
  The yield_log from Approach 3 gets committed to Dolt, so the full
  history is recoverable. We get the best of both worlds:
  - Queryable: yield_log table with (cell, gen, field) lookups
  - Immutable: Dolt commits ensure the log is append-only
  - Recoverable: any historical state via AS OF
-/

/-! ====================================================================
    APPROACH 5: Frame table (each execution = row, fully immutable)
    Status: STRONG CONTENDER — compare with Approach 3
    ==================================================================== -/

/-
  IDEA: Instead of deriving frames from yield_log, make frames explicit.
  A `frames` table records each execution frame as an immutable row.

  Schema:
    cells(name, program, body, body_type, is_stem)          -- immutable
    frames(id, cell_name, generation, commit_hash, status)  -- append-only
    yields(frame_id, field, value)                          -- append-only
    edges(consumer_frame, producer_frame, field)            -- append-only
    claims(frame_id, piston_id)                             -- ephemeral

  Lifecycle:
    1. Pour: INSERT into cells (immutable)
    2. Demand appears: INSERT into frames (cell, gen, status='declared')
    3. Claim: INSERT into claims (ephemeral)
                UPDATE frames SET status='computing' ← MUTATION!
    4. Freeze: INSERT into yields
              INSERT into edges (what this frame read)
              UPDATE frames SET status='frozen', commit_hash=X ← MUTATION!

  PROBLEM: frames.status is mutable (declared → computing → frozen).
  This violates P3 unless we model status differently.

  FIX: Don't store status. Derive it (like Approach 3):
    frames(id, cell_name, generation)  -- INSERT once, never modify
    yields(frame_id, field, value)     -- INSERT once per field
    edges(consumer_frame, producer_frame, field)  -- INSERT once

    status = if yields complete then frozen
             else if claim exists then computing
             else declared

  NOW frames table is fully immutable. Frames are created when demand
  appears. They sit "empty" (no yields) until a piston fills them.

  BUT WAIT — this is basically Approach 3 with an extra frames table.
  Is the frames table adding value?
-/

/-
  THE FRAMES TABLE ADDS VALUE because:

  1. It makes the DAG explicit: edges reference frame_ids, not
     (cell_name, generation) pairs. This is cleaner for queries.

  2. Frame creation IS the demand signal: a frame row appearing means
     "this cell needs to run." No frame = no demand = cell blocked.

  3. The frame_id can BE the content address (or include the commit hash
     where the frame was created). This ties into Dolt naturally.

  4. For non-stem cells: exactly one frame exists (generation 0).
     For stem cells: frames accumulate (one per generation).
     This is the explicit execution history.

  5. Edges between frames make the DAG queryable:
     "What did eval-one@gen5 depend on?" →
     SELECT * FROM edges WHERE consumer_frame = 'eval-one@gen5'

  The frames table IS the execution log. yield_log rows are just
  the frame's output. Edges are the frame's inputs.
-/

/-! ### Formalizing Approach 5 -/

-- Immutable cell definition (written at pour time, never changes)
structure CellDef5 where
  name : CellName
  isStem : Bool
  body : String
  deriving Repr, DecidableEq

-- Immutable frame (written when demand appears, never modified)
structure Frame5 where
  id : Hash
  cell : CellName
  generation : Nat
  deriving Repr, DecidableEq, BEq

-- Immutable yield (written when piston produces output, never modified)
structure Yield5 where
  frameId : Hash
  field : String
  value : String
  deriving Repr, DecidableEq

-- Immutable edge (written when piston resolves a given, never modified)
structure Edge5 where
  consumerFrame : Hash  -- the frame that READ
  producerFrame : Hash  -- the frame that WROTE
  field : String
  deriving Repr, DecidableEq

-- Ephemeral claim (mutable, not part of history)
structure Claim5 where
  frameId : Hash
  pistonId : String
  deriving Repr

-- The full database state
structure RetortState where
  cells  : List CellDef5
  frames : List Frame5
  yields : List Yield5
  edges  : List Edge5
  claims : List Claim5
  deriving Repr

-- Derived status (NOT stored)
def frameStatus (s : RetortState) (frameId : Hash) (expectedFields : List String) : DerivedState :=
  let frozenFields := (s.yields.filter (fun y => y.frameId == frameId)).map (·.field)
  if expectedFields.all (· ∈ frozenFields) then .frozen
  else if s.claims.any (fun c => c.frameId == frameId) then .computing
  else .declared

/-! ### Proving the properties for Approach 5 -/

-- Build an ExecGraph from RetortState
def toExecGraph (s : RetortState) : ExecGraph :=
  { frames := s.frames.map (fun f => ⟨f.cell, f.generation⟩)
    yields := s.yields.map (fun y =>
      let frame := s.frames.find? (fun f => f.id == y.frameId)
      match frame with
      | some f => ⟨⟨f.cell, f.generation⟩, y.field, y.value⟩
      | none => ⟨⟨⟨"?", "?"⟩, 0⟩, y.field, y.value⟩)
    edges := s.edges.map (fun e =>
      let cf := s.frames.find? (fun f => f.id == e.consumerFrame)
      let pf := s.frames.find? (fun f => f.id == e.producerFrame)
      match cf, pf with
      | some c, some p => ⟨⟨c.cell, c.generation⟩, ⟨p.cell, p.generation⟩, e.field⟩
      | _, _ => ⟨⟨⟨"?","?"⟩,0⟩, ⟨⟨"?","?"⟩,0⟩, e.field⟩) }

-- P2: Content-addressed — frames are identified by (cell, generation)
-- If we enforce unique (cell, generation) on insert, this holds trivially
def framesUnique (s : RetortState) : Prop :=
  ∀ f1 f2, f1 ∈ s.frames → f2 ∈ s.frames →
    f1.cell = f2.cell → f1.generation = f2.generation → f1 = f2

-- P3: Immutability — all tables are append-only
-- We model this as: any valid transition only ADDS rows, never removes or modifies
def appendOnlyTransition (before after : RetortState) : Prop :=
  (∀ c ∈ before.cells, c ∈ after.cells) ∧
  (∀ f ∈ before.frames, f ∈ after.frames) ∧
  (∀ y ∈ before.yields, y ∈ after.yields) ∧
  (∀ e ∈ before.edges, e ∈ after.edges)
  -- Note: claims NOT included — they're ephemeral

-- P4: Bounded cells — cell definitions don't grow after pour
def cellsBounded (before after : RetortState) : Prop :=
  before.cells = after.cells

-- Key theorem: append-only transition preserves all existing yields
theorem appendOnly_yields_stable (before after : RetortState)
    (h : appendOnlyTransition before after) :
    ∀ y ∈ before.yields, y ∈ after.yields := by
  exact h.2.2.1

/-! ### The DAG structure in Approach 5

  The edges table makes dependencies explicit. For the DAG property,
  we need: no frame transitively depends on itself.

  For stem cells, the critical constraint is:
    eval-one@gen(N+1) may depend on eval-one@gen(N)'s OUTPUT
    (if eval-one reads its own previous results as context).
    But eval-one@gen(N) must NOT depend on gen(N+1).

  This is naturally enforced because:
  - A frame's edges are written at freeze time
  - A frame can only read yields that already exist
  - A yield can only exist for a frame that has already been created
  - Frame creation happens BEFORE yield creation

  So the temporal ordering guarantees acyclicity:
    create frame → create claim → write yields → write edges → done
    Each step is append-only. You can't create an edge pointing to
    a frame that hasn't been created yet, and you can't point to
    yields from the future.
-/

-- Temporal ordering: edges only point to frames that exist
def edgesWellFormed (s : RetortState) : Prop :=
  ∀ e ∈ s.edges,
    (∃ f ∈ s.frames, f.id = e.consumerFrame) ∧
    (∃ f ∈ s.frames, f.id = e.producerFrame)

-- Acyclicity: no frame depends on a later generation of the same cell
def acyclicSameCell (s : RetortState) : Prop :=
  ∀ e ∈ s.edges,
    ∀ cf ∈ s.frames, ∀ pf ∈ s.frames,
      cf.id = e.consumerFrame → pf.id = e.producerFrame →
      cf.cell = pf.cell → pf.generation < cf.generation

/-! ====================================================================
    APPROACH 3 vs 5: THE DEBATE
    ==================================================================== -/

/-
  APPROACH 3 (append-only yield_log, no frames table):
    cells:     immutable ✓
    yield_log: append-only ✓ (cell, gen, field, value)
    claims:    ephemeral ✓
    state:     derived ✓

  APPROACH 5 (explicit frames table):
    cells:     immutable ✓
    frames:    append-only ✓ (id, cell, generation)
    yields:    append-only ✓ (frame_id, field, value)
    edges:     append-only ✓ (consumer, producer, field)
    claims:    ephemeral ✓
    state:     derived ✓

  APPROACH 5 WINS on:
  + Explicit DAG: edges table makes dependencies queryable
  + Frame identity: frame_id is a first-class content address
  + Separation of concerns: frame creation (demand) ≠ yield creation (output)
  + Edge tracking: "what inputs did this frame use?" is a simple query
  + Non-stem and stem cells treated uniformly: one frame per non-stem execution,
    N frames per stem cell — the model doesn't special-case

  APPROACH 3 WINS on:
  + Simpler schema: one fewer table
  + Less indirection: yields directly carry (cell, gen) instead of frame_id lookup

  APPROACH 5 costs ONE extra table (frames) and ONE extra table (edges).
  But edges are already implicit in the givens table — making them explicit
  per-execution-frame is just recording WHICH generation was actually read.

  VERDICT: Approach 5.

  But there's a subtlety: WHERE DO FRAMES COME FROM?
-/

/-! ====================================================================
    THE KEY QUESTION: Frame Creation
    ==================================================================== -/

/-
  For non-stem cells: one frame is created at pour time. Simple.

  For stem cells: a new frame must be created each time demand appears.
  WHO creates the frame?

  OPTION A: The eval loop creates frames.
    cell_eval_step checks: "is there a stem cell with demand but no
    declared frame?" If so, INSERT a new frame, then claim it.
    The procedure manages frame lifecycle.

  OPTION B: Demand detection creates frames.
    A trigger or view detects demand (ready cells exist for eval-one,
    pour-requests exist for pour-one) and auto-creates a frame.
    This is reactive — frames appear when conditions are met.

  OPTION C: The piston creates frames.
    After completing gen N, the piston checks for more demand.
    If demand exists, it INSERTs a gen N+1 frame.
    This is the "spawn" model but with immutable frames instead of
    mutable cell state.

  OPTION D: Frames are pre-created.
    At pour time, create frames for generations 0..K.
    When generation K-1 completes, create frames K..2K.
    Batch creation avoids per-cycle overhead.

  WAIT — Option C is actually interesting. Let's compare it to the
  current spawn model:

  Current spawn: cell freezes → INSERT new cell row (mutable state)
  Option C:      frame freezes → INSERT new frame row (immutable)

  The difference: in Option C, we're not creating a new CELL, we're
  creating a new FRAME for the SAME cell. The cell definition is
  stable. Only the frame (execution instance) is new.

  And the frame row is IMMUTABLE — once created, never modified.
  Its status is derived from yields and claims.

  THIS IS THE SYNTHESIS:
  - Cell definitions: immutable, created at pour time
  - Frames: immutable, created on demand
  - Yields: immutable, created at freeze time
  - Edges: immutable, created at freeze time
  - Claims: ephemeral, the only mutable state
  - Status: derived, never stored

  The frame table IS the execution history. Each row is a node in the DAG.
  It grows for stem cells — but that growth IS the trace. It's not garbage
  like the spawn model's duplicate cell rows. Each frame is meaningful.
-/

/-! ====================================================================
    FINAL SYNTHESIS: Approach 5 + Option C
    ==================================================================== -/

/-
  ## Schema

  cells (
    name        VARCHAR PRIMARY KEY,  -- e.g., 'eval-one'
    program_id  VARCHAR,
    body_type   VARCHAR,              -- 'soft', 'stem', 'hard'
    body        TEXT,
    -- IMMUTABLE: never modified after pour
  )

  frames (
    id          VARCHAR PRIMARY KEY,  -- content-addressed: hash(cell, gen)
    cell_name   VARCHAR FK,
    generation  INT,
    created_at  DATETIME,
    commit_hash VARCHAR,              -- Dolt commit where this frame was created
    UNIQUE(cell_name, generation),
    -- IMMUTABLE: never modified after creation
  )

  yields (
    frame_id    VARCHAR FK,
    field_name  VARCHAR,
    value_text  TEXT,
    frozen_at   DATETIME,
    PRIMARY KEY (frame_id, field_name),
    -- IMMUTABLE: INSERT once, never update
  )

  edges (
    consumer_frame  VARCHAR FK,
    producer_frame  VARCHAR FK,
    field_name      VARCHAR,
    -- IMMUTABLE: records which frame's yield was read
  )

  claims (
    frame_id    VARCHAR PRIMARY KEY,
    piston_id   VARCHAR,
    claimed_at  DATETIME,
    -- EPHEMERAL: deleted after completion
  )

  ## Derived State

  CREATE VIEW frame_status AS
  SELECT f.id, f.cell_name, f.generation,
    CASE
      WHEN (SELECT COUNT(*) FROM yields y WHERE y.frame_id = f.id)
           = (SELECT COUNT(*) FROM cell_fields cf WHERE cf.cell_name = f.cell_name)
        THEN 'frozen'
      WHEN EXISTS (SELECT 1 FROM claims c WHERE c.frame_id = f.id)
        THEN 'computing'
      ELSE 'declared'
    END AS status
  FROM frames f;

  ## Lifecycle

  1. POUR: INSERT into cells. For non-stem: INSERT frame(gen=0).
     For stem: no frame yet (waits for demand).

  2. DEMAND: When demand detected (ready cells exist, pour-request exists),
     INSERT frame for the stem cell at next generation.
     This is done by cell_eval_step or a demand-detection procedure.

  3. CLAIM: INSERT into claims. (Frame is now 'computing' via derived state.)

  4. EVALUATE: Piston does its work.

  5. FREEZE: INSERT into yields (one per field).
     INSERT into edges (one per given that was resolved).
     DELETE from claims.
     DOLT_COMMIT.
     (Frame is now 'frozen' via derived state.)

  6. DEMAND CHECK: If stem cell AND more demand exists,
     INSERT next-gen frame → goto 3.

  ## Content Addressing

  Frame ID = hash(cell_name, generation) or simply cell_name + "@" + gen.
  Yield address = (frame_id, field_name).
  Edge = (consumer_frame_id, producer_frame_id, field).

  Given resolution:
    "given eval-one→status" in a non-stem cell resolves to
    the LATEST frozen frame of eval-one. The edge records which frame.

    "given eval-one→status" in a stem cell (like a judge reading eval-one's
    output) resolves to a SPECIFIC frame. The edge records which.

  ## DAG Property

  Edges only point to frames that are already frozen (yields exist).
  A frame can't depend on itself or a future generation.
  Temporal ordering of INSERTs enforces acyclicity.

  ## Immutability

  cells, frames, yields, edges: INSERT-only, never UPDATE or DELETE.
  claims: ephemeral bookkeeping, not part of execution history.
  Dolt commits capture every INSERT as an immutable snapshot.

  ## Relation to Dolt

  Each DOLT_COMMIT captures a batch of INSERTs. The commit hash is
  a content address for that batch. Yields frozen in the same commit
  share a commit hash. The Dolt commit graph augments the edge graph:
  - edges: cell-level dependencies (which yields were read)
  - commits: temporal ordering (what happened in what order)
  Both are immutable DAGs. Together they form the full execution trace.
-/

-- Final model: the five valid operations on RetortState
inductive RetortOp where
  | pour       : CellDef5 → RetortOp              -- add cell definition
  | createFrame : Frame5 → RetortOp               -- demand detected
  | claim      : Claim5 → RetortOp                -- piston claims frame
  | freeze     : Yield5 → List Edge5 → RetortOp   -- piston produces output
  | unclaim    : Hash → RetortOp                   -- remove claim after freeze
  deriving Repr

-- Apply an operation (append-only for all but claims)
def applyOp (s : RetortState) : RetortOp → RetortState
  | .pour cd      => { s with cells := s.cells ++ [cd] }
  | .createFrame f => { s with frames := s.frames ++ [f] }
  | .claim cl     => { s with claims := s.claims ++ [cl] }
  | .freeze y es  => { s with yields := s.yields ++ [y], edges := s.edges ++ es }
  | .unclaim fid  => { s with claims := s.claims.filter (fun c => c.frameId != fid) }

-- Pour, createFrame, and freeze are all append-only
theorem pour_is_appendOnly (s : RetortState) (cd : CellDef5) :
    appendOnlyTransition s (applyOp s (.pour cd)) := by
  unfold appendOnlyTransition applyOp
  simp only
  exact ⟨fun c hc => List.mem_append_left _ hc,
         fun f hf => hf, fun y hy => hy, fun e he => he⟩

theorem createFrame_is_appendOnly (s : RetortState) (f : Frame5) :
    appendOnlyTransition s (applyOp s (.createFrame f)) := by
  unfold appendOnlyTransition applyOp
  simp only
  exact ⟨fun c hc => hc, fun f' hf => List.mem_append_left _ hf,
         fun y hy => hy, fun e he => he⟩

theorem freeze_is_appendOnly (s : RetortState) (y : Yield5) (es : List Edge5) :
    appendOnlyTransition s (applyOp s (.freeze y es)) := by
  unfold appendOnlyTransition applyOp
  simp only
  exact ⟨fun c hc => hc, fun f hf => hf,
         fun y' hy => List.mem_append_left _ hy,
         fun e he => List.mem_append_left _ he⟩

-- Cells never change (pour only adds, never modifies)
theorem cells_stable_on_non_pour (s : RetortState) (op : RetortOp) (hNotPour : ∀ cd, op ≠ .pour cd) :
    (applyOp s op).cells = s.cells := by
  cases op with
  | pour cd => exact absurd rfl (hNotPour cd)
  | createFrame _ => simp [applyOp]
  | claim _ => simp [applyOp]
  | freeze _ _ => simp [applyOp]
  | unclaim _ => simp [applyOp]

/-! ====================================================================
    CONCLUSION
    ====================================================================

  The winning approach is Approach 5 (explicit frames) + Option C (piston
  creates next-gen frame on demand).

  Summary of properties:
  - P1 DAG: ✓ edges only point backward, temporal ordering enforces acyclicity
  - P2 Content-addressed: ✓ frame_id = hash(cell, gen), yield addr = (frame_id, field)
  - P3 Immutable: ✓ cells/frames/yields/edges are append-only (proven)
  - P4 Bounded cells: ✓ cell definitions fixed after pour (proven)
  - P5 Demand-driven: ✓ frames created only when demand exists

  Frames table grows for stem cells, but this growth IS the execution
  trace — it's not waste, it's history. And it's bounded by the number
  of actual evaluations performed.

  The only mutable state is the claims table, which is ephemeral
  operational bookkeeping (like a lock table), not execution history.

  Dolt commits layer on top: each commit captures the INSERTs from one
  or more operations. The commit graph augments the edge graph. Together
  they form the full, immutable, content-addressed execution DAG.
-/

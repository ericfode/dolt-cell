# Implementation Plan: Cell Language Foundation on Gas City

*Sussmind — 2026-03-20*
*Derived from consensus-recommendation.md*

## The One Sentence

**Define a RetortStore interface over the existing Dolt code, then add reify
and autopour to the cell language so it can express its own evaluator.**

## Why This Matters (Sanity Check)

Gas City agents coordinate via beads (issues), mail (messages), and nudges
(ephemeral signals). This works for simple task routing. But Gas City has
no way for agents to do **structured collaborative thinking** — multi-step
reasoning where one agent's output feeds another's input, with formal
guarantees about data flow, evaluation order, and completion.

Cell provides this: a tuple space where agents pour structured thought
programs, evaluate them cooperatively (pistons claim cells), and observe
crystallized results. It's the difference between email (beads/mail) and
a shared whiteboard with formal rules (cell programs).

**The real problem**: Gas City agents can talk to each other but can't
think together. Cell fixes this by making collaborative cognition a
first-class operation.

**What we're NOT building**: A replacement for beads, mail, or Gas City
infrastructure. Cell is a CAPABILITY that agents USE when structured
multi-step reasoning beats message-passing.

## Phase 1: RetortStore Interface (refactor, not rewrite)

**Goal**: Abstract the store so the language doesn't depend on SQL.

**What exists**: cmd/ct/*.go with 240 SQL operations spread across
eval.go (124 SELECT, 71 INSERT, 33 UPDATE, 12 DELETE), pour.go,
db.go, etc. All hit Dolt directly.

**What we build**: A Go interface that captures the 8 operations
(Pour, Next, Submit, Fail, Observe, Gather, Thaw, Status) and a
DoltStore implementation that wraps the existing SQL.

**Files to create/modify**:
- `pkg/retort/store.go` — the interface definition
- `pkg/retort/dolt.go` — DoltStore wrapping existing SQL
- `cmd/ct/eval.go` — refactor to use RetortStore
- `cmd/ct/pour.go` — refactor to use RetortStore
- `cmd/ct/db.go` — becomes internal to DoltStore

**Assignee**: glassblower (owns ct runtime)
**Estimate**: 2-3 days

## Phase 2: Reify + Autopour Language Primitives

**Goal**: Cell can express its own evaluator without SQL escape hatches.

### 2a. Reify — read cell definitions as data

**What**: A new given qualifier `given target.definition` that returns
a cell's definition as a structured text value. Safe, read-only.

**Implementation**:
- Parser change: recognize `.definition` as a built-in field name
- Pour change: when a given references `.definition`, mark it special
- Eval change: resolve `.definition` givens by reading the cell's body
  from the store (RetortStore.Observe on the cell's metadata)

**Assignee**: glassblower (parser + runtime changes)

### 2b. Autopour — programs as first-class yields

**What**: A yield annotation `[autopour]` that tells the runtime to
pour the yielded program text after freeze.

**Implementation**:
- Parser change: recognize `[autopour]` annotation on yield declarations
- Pour change: store the autopour flag in the yields table
- Eval change: after Submit(), check for autopour yields. If a yield
  has the flag and contains valid .cell text, call RetortStore.Pour()
  with it. Fuel counter in eval context prevents infinite regress.
- Formal: Autopour.lean already defines the semantics (compiles clean)

**Assignee**: sussmind (design) + glassblower (implementation)

### 2c. cell-zero-autopour — the metacircular test

**What**: Rewrite cell-zero-eval.cell using autopour instead of SQL.
This is the proof that the language is metacircular.

**Implementation**: examples/cell-zero-autopour.cell already drafted.
Needs testing against the runtime once 2a+2b are implemented.

**Assignee**: sussmind (already drafted)

## Phase 3: Effect Taxonomy Unification

**Goal**: One effect lattice everywhere.

**What**: Three incompatible schemes exist:
- Core.lean: EffectLevel (pure/semantic/divergent) — conflates lifecycle
- EffectEval.lean: EffLevel (pure/replayable/nonReplayable) — canonical
- Autopour.lean: EffLevel — already migrated to canonical

**Implementation**:
- Update Core.lean to define the canonical EffLevel
- Update Denotational.lean to use canonical
- Update ct Go code to use consistent naming
- Bridge: provide a mapping from old to new for transition

**Assignee**: scribe (formal) + glassblower (Go code)

## Phase 4: Integration Testing with Gas City

**Goal**: Prove cell programs can drive Gas City agent coordination.

**What**: A cell program that uses NonReplayable cells to file beads,
send mail, and coordinate agents — demonstrating that cell is a
useful coordination layer ON TOP of Gas City primitives.

**Example**: A cell program for multi-agent code review:
1. Hard cell: load the diff to review
2. Soft cells (parallel): 3 agents each review independently
3. Soft cell: synthesize reviews into one recommendation
4. NonReplayable cell: file a bead with the recommendation

**Assignee**: alchemist (cell program author)

## What We're NOT Doing

- Building the custom log store (deferred — keep Dolt)
- Building distribution (Dolt handles this)
- Full type system (not needed for foundation)
- Guards / conditional execution (nice but not minimal)
- Formal adequacy proof (future work for scribe)

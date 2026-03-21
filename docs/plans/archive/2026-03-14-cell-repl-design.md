# Cell REPL Design: Runtime Formulas on Beads

**Date**: 2026-03-14
**Status**: Draft — pending adversarial review
**Bead**: do-27k

## One-Sentence Summary

Cell programs are poured molecules whose cells are beads, driven by an LLM using
a toolkit of runtime formulas for the mechanical operations, with everything
starting as text and crystallizing toward deterministic code over time.

---

## Core Architecture

### The Three Layers

```
Layer 0: Runtime Formulas (mechanical toolkit — hard from day one)
Layer 1: Everything is text (programs, parser, eval loop — all soft/LLM-driven)
Layer 2: Crystallization (text patterns harden into syntax, parsers, deterministic code)
```

### What This Means Concretely

**A Cell program IS a poured molecule.** When you "run" a Cell program, you pour
a molecule. Each cell becomes a bead. Dependencies become bead dependencies.
The molecule progresses as cells evaluate and freeze.

**The LLM IS the runtime.** The LLM drives the eval loop, reading cell-zero
(or following its own judgment) to decide what to evaluate next. But it doesn't
do the mechanical work — it invokes runtime formulas for that.

**The runtime formulas are the calculator buttons.** Dependency resolution, input
interpolation, yield freezing, oracle spawning, state rendering — these are
deterministic operations the LLM calls as tools. The formulas ensure rigor; the
LLM provides judgment.

**The syntax is a second layer.** The first Cell programs are just text — natural
language descriptions of cells, their dependencies, and their yields. No turnstyle
operators required. The parser is itself a Cell program that starts soft (LLM reads
text, creates beads) and crystallizes as syntax patterns stabilize.

---

## Runtime Formula Toolkit

| Formula | Purpose | Inputs | Outputs |
|---------|---------|--------|---------|
| `mol-cell-pour` | Load a cell program (text or .cell) into beads | Source text, program name | Molecule ID, bead IDs |
| `mol-cell-ready` | Query frontier: which cells can eval now? | Molecule ID | List of ready cell bead IDs |
| `mol-cell-resolve` | Resolve a cell's inputs: read upstream frozen yields, interpolate `«»` | Cell bead ID | Resolved inputs map |
| `mol-cell-eval` | Dispatch evaluation (soft→polecat, hard→inline) | Cell bead ID, resolved inputs | Tentative output |
| `mol-cell-oracle` | Spawn oracle claim beads, evaluate them | Cell bead ID, tentative output | Pass/fail per oracle |
| `mol-cell-freeze` | Write yields to bead metadata, close bead | Cell bead ID, yield values | Frozen confirmation |
| `mol-cell-bottom` | Mark yields as ⊥, propagate downstream | Cell bead ID | Affected downstream IDs |
| `mol-cell-status` | Render the machine state (the window into execution) | Molecule ID | DAG visualization with states |
| `mol-cell-step` | One full eval-one cycle (ready→pick→eval→oracle→freeze) | Molecule ID | Step result |
| `mol-cell-run` | Loop mol-cell-step until quiescent | Molecule ID | Final state |

### Formula Details

**mol-cell-pour**: The "loader." Takes text describing a Cell program (initially
natural language, later `.cell` syntax) and creates beads:
- One bead per cell, labeled `cell` + `soft`/`hard`
- Dependencies via `bd dep add`
- Yields, givens, body type stored in bead metadata
- Oracle assertions stored as metadata on the cell bead
- Returns a molecule ID that tracks this program execution

**mol-cell-ready**: The "frontier query." Wraps `bd ready --label=cell` with
Cell-specific filtering:
- Checks that all required givens have upstream yields frozen
- Checks that no required upstream yields are ⊥ (unless `given?`)
- Evaluates guard expressions against frozen values
- Returns ordered list of evaluable cell bead IDs

**mol-cell-eval**: The "dispatch." Two paths:
- **Soft cells** (`∴`): Compose prompt from cell description + resolved inputs.
  Dispatch to polecat via `gt sling`. Polecat evaluates, returns tentative output.
- **Hard cells** (`⊢=`): Evaluate deterministic expression locally. No LLM needed.

**mol-cell-oracle**: The "verifier." For each oracle assertion on the cell:
- Deterministic oracles: evaluate expression against tentative output
- Structural oracles: check properties (permutation, sorted, etc.)
- Semantic oracles: dispatch to LLM (can be same polecat or new one)
- Returns pass/fail per oracle with failure details for retry context

**mol-cell-freeze**: The "committer." When oracles pass:
- Write yield values to cell bead metadata
- Close the bead (frozen = closed)
- Dolt commit (the eval step is now in version history)
- Update downstream cells' readiness

**mol-cell-status**: The "lens." Renders the machine state:
```
Program: sort-proof  (molecule: mol-abc123)
State: RUNNING  |  Frozen: 1/3  |  Ready: 1  |  ⊥: 0

 [■ frozen]  data
    └─ items = [4, 1, 7, 3, 9, 2]

 [▶ eval]    sort  (polecat: alpha, 3.2s elapsed)
    ├─ given: data→items ✓ resolved
    └─ yield: sorted = (pending)
       ├─ ⊨ permutation check (waiting)
       └─ ⊨ ascending order (waiting)

 [○ blocked] report
    └─ given: sort→sorted (unresolved)
```

---

## Bootstrap Sequence

### Phase 1: The Formulas (Mechanical Toolkit)
Build the runtime formula set. These are hard from day one — deterministic TOML
formulas that perform mechanical Cell operations on beads.

**Demo**: Manually create cell-beads via `bd create`, then invoke `mol-cell-ready`
to verify it correctly identifies which cells are evaluable.

### Phase 2: The First Cell Program (All Text)
Write a Cell program as prose text. The LLM reads it, creates beads (invoking
`mol-cell-pour`), and runs them using the runtime formulas.

No turnstyle syntax. Just: "Here are three cells. Cell A produces a list of
numbers. Cell B sorts them. Cell C verifies the sort is correct. B depends on A,
C depends on B."

**Demo**: A 3-5 cell program authored as plain text, executed end-to-end via
runtime formulas. Show `mol-cell-status` at each step.

### Phase 3: The Oracle Loop (Verification)
Add oracle checking to Phase 2. Soft cells get verified. Failures trigger retry
with feedback context. The generate-and-check cycle works on pure text.

**Demo**: A soft cell produces output, an oracle catches a mistake, the cell
retries with the failure context appended, succeeds on retry.

### Phase 4: The Parser Cell (Soft → Hard)
A cell whose job is to read text and produce beads. Initially soft — the LLM
reads the input text and figures out what cells/deps/yields to create.

As syntax patterns stabilize (the LLM keeps seeing `⊢`, `∴`, `⊨`), this cell
crystallizes: the soft parser gets replaced by a deterministic parser (`⊢=`).

The turnstyle syntax is the RESIDUE of crystallization — the patterns that
emerged from the LLM repeatedly parsing similar text structures.

**Demo**: Feed the parser cell both prose descriptions AND turnstyle-syntax
programs. Show it producing identical bead structures for both. Show the
crystallized version handling `.cell` files without LLM calls.

### Phase 5: Cell-Zero (Metacircular)
Cell-zero as a text document describing the eval loop. The LLM reads it, follows
it, using runtime formulas as tools. Cell-zero's cells describe the same
operations the formulas perform.

Cell-zero evaluating cell-zero: the molecule contains cells that describe how to
evaluate cells. Running it with the runtime formulas produces... the eval loop.

**Demo**: cell-zero.cell loaded via `mol-cell-pour`, executed via `mol-cell-run`.
The output is a working eval loop that can evaluate other Cell programs.

---

## The Top-Down Bootstrap

Cell bootstraps opposite to classical languages:

| Classical (Forth, Lisp) | Cell |
|------------------------|------|
| Start with weak primitives | Start with maximally capable LLM |
| Build UP through composition | Build DOWN through crystallization |
| Assembly → compiler → language | Text → patterns → syntax → deterministic code |
| Bottom-up: additive | Top-down: subtractive |
| End state: everything is compiled | End state: core is hard, frontier is soft |

The bootstrap direction is "sculpting marble" — the full semantic capability
exists from the start (the LLM can do anything). Crystallization carves away
the soft stone to reveal hard structure. What remains soft is genuinely semantic —
the stem cells that must stay warm so others can go cold.

---

## Observability: Seeing Inside the Machine

### Requirements

The user must be able to see, at any point during execution:
- **The DAG**: which cells exist and how they depend on each other
- **The frontier**: which cells are ready to evaluate NOW
- **The flow**: values moving through yields as cells freeze
- **The oracles**: pass/fail/retry status in real time
- **The crystallization ratio**: what % is hard vs soft
- **The in-flight**: which cells are being evaluated (polecats working)
- **The history**: Dolt diff showing what changed at each eval step

### Implementation

`mol-cell-status` is the primary lens. It reads bead state and renders it in
Cell terms (frozen/ready/blocked/bottom/in-flight) rather than beads terms
(open/closed/in_progress).

Dolt provides the time dimension: `dolt diff HEAD~1` shows exactly what changed
at each eval step. The execution trace IS the commit history.

---

## Key Design Decisions

### Why Beads, Not Retort (Dedicated DB)?

Earlier iterations proposed a separate "Retort" Dolt database for Cell computation.
This design uses beads directly because:
1. Cell programs ARE work — cells are tasks, evaluation is execution
2. Beads already handles dependencies, readiness, metadata, and dispatch
3. `bd ready` already computes the frontier
4. `gt sling` already dispatches to polecats
5. One system to reason about, not two

The cell-specific semantics (yields, oracles, body type) live in bead metadata
and labels. The runtime formulas interpret this metadata.

### Why Formulas, Not a Custom Runtime?

The formula engine provides deterministic orchestration that the LLM can invoke
as tools. This solves the "LLM won't rigorously execute" problem from cell-zero
v1 — the LLM tried to be the entire runtime and hand-waved the mechanical parts.

Now: LLM provides judgment (what to eval, how to handle failures). Formulas
provide rigor (dependency resolution, state management, oracle checking).

### Why Text First, Syntax Second?

The turnstyle syntax (⊢, ∴, ⊨, «») is the crystallized form of patterns that
emerge from the LLM repeatedly parsing similar text. Building the parser first
assumes the syntax is settled. Building the runtime first lets the syntax emerge
from usage.

This also means the first Cell programs can be authored by humans in natural
language, without learning the syntax. The syntax is an optimization for
experienced users, not a prerequisite for execution.

---

## Personas for Adversarial Review

Five perspectives will challenge this design:

### Mara — Language Implementer
15 years building compilers (Racket, Tree-sitter). Thinks in ASTs and operational
semantics. Will challenge: parsing ambiguity, expression evaluation, the
crystallization boundary, whether "text first" leads to unparseable programs.

### Deng — Database Architect
10 years MySQL/PostgreSQL/Dolt. Will challenge: bead metadata as cell state
(JSON columns resist indexing), Dolt commit overhead per eval step, ready_cells
query performance at scale, concurrent writer conflicts.

### Priya — UX/Observability Designer
Developer tools at JetBrains and Observable. Will challenge: mol-cell-status
rendering, what "seeing inside" actually means, DAG visualization, progressive
disclosure, whether the status view is sufficient or needs live updates.

### Ravi — LLM Integration Specialist
Production LLM pipelines at scale. Will challenge: soft cell dispatch latency,
oracle checking doubling LLM cost, retry-with-feedback prompt engineering,
cost tracking, whether the LLM can reliably drive the eval loop even with
formula tools.

### Kai — Systems Architect
Built Gas Town. Will challenge: concurrent polecat evaluation, Dolt transaction
model under parallel writes, the beads bridge protocol, molecule lifecycle
management, whether formulas are the right abstraction for runtime operations.

---

## Open Questions

1. **Formula granularity**: Are 10 formulas the right decomposition? Should
   `mol-cell-step` be the primary interface (one formula that does the full
   eval-one cycle), or should the LLM compose the primitives itself?

2. **Concurrency model**: When multiple cells are ready, does the LLM dispatch
   them in parallel (multiple `gt sling`)? Who commits to Dolt — the orchestrating
   LLM or the individual polecats?

3. **Yield storage**: Bead metadata JSON works for small values. What about large
   yields (generated code, long text)? Comments? Attached files?

4. **Oracle batching**: Can we batch the cell eval + oracle check into a single
   LLM call to avoid doubling latency?

5. **Molecule lifecycle**: When does a Cell molecule end? Cell programs don't
   terminate by design. Is quiescence (no ready cells) the natural endpoint?

6. **Cross-program references**: Can one poured molecule reference yields from
   another? How do Cell programs compose?

7. **The parser bootstrap chicken-and-egg**: If the parser is a Cell program,
   what parses the parser? (Answer: the LLM, initially. But this needs to be
   made explicit in the bootstrap sequence.)

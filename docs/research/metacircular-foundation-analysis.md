# The Simplest Foundation: A Metacircular Analysis

*Sussmind position paper for dc-rv8 consensus review*
*2026-03-19*

---

> **Note (2026-03-21):** This research predates the Lua substrate design.
> Code examples use the old cell syntax (guillemets, sql: bodies). The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-lua-substrate-design.md` for
> the current design.

## The Question

What is the simplest possible foundation for cell evaluation?

I approach this from the language-theory perspective. Not "what database
should we use" (helix's question), not "what does the code touch"
(glassblower's question), not "what should we build instead" (alchemist's
question), not "what are the formal rules" (scribe's question) — but:

**What are the minimal primitives such that the language can express
its own evaluator?**

If we get this right, the data store question becomes secondary. The
store is an implementation detail of the tuple space. The formal model
is a consequence of the primitives. The language IS the foundation.

---

## What We Have

### The Denotational Core

```
CellBody M = Env → M (Env × Continue)
```

One cell kind, parameterized over an effect monad M. This is correct
and beautiful. M measures distance from value: Id (ground), IO (falling),
whatever we need (in orbit). Continue signals done/more for stem cells.

### The Effect Lattice

```
Pure < Semantic < Divergent
```

This classifies cells by computational power without changing the body
type. Pure cells are total functions. Semantic cells invoke an oracle
(LLM). Divergent cells cycle forever (stems). This is the right
abstraction.

### The Tuple Space Operations

From the protocol doc and TupleSpace.lean:

- **pour**: add cells to the space (Linda `out`)
- **claim**: atomic mutex on a frame (Linda `in`)
- **submit**: append yields, release claim
- **observe**: read frozen yields (Linda `rd`)
- **thaw**: time-travel rewind (no Linda equivalent)

### The Evaluation Loop

```
loop:
  find ready cell (observe)
  claim it (in)
  resolve inputs (observe)
  run body
  submit outputs
  goto loop
```

This is the piston protocol. It's clean. It works.

---

## What's Missing for Metacircularity

### The Problem with cell-zero-eval

`cell-zero-eval.cell` achieves "self-evaluation" by dropping to SQL:

```
SELECT id, body FROM cells WHERE ...
INSERT INTO cells ...
UPDATE yields SET value_text = ...
CALL DOLT_COMMIT(...)
```

This is like writing a Lisp evaluator using C's `malloc` and pointer
arithmetic instead of `cons`, `car`, `cdr`. It works, but it proves
nothing about the language's expressive power. The evaluator lives
*below* the abstraction, not *within* it.

True metacircularity means: **a cell program that evaluates other cell
programs using only cell primitives.**

### The Three Missing Primitives

For metacircularity, cell needs exactly three things it doesn't have:

**1. Reify (quote)**: Get a cell's definition as a value.

```
cell inspector
  given target.definition    ← the DEFINITION, not the OUTPUT
  yield analysis
```

Currently impossible. A cell can read another cell's *output* (via
givens), but not its *definition* (body, deps, effect level). The
`Denotational.lean` identifies this as "Missing Feature 6: Cell
References (Quoting)."

**2. Pour-as-yield (autopour)**: A cell yields a program that the
runtime pours.

```
cell generator
  yield sub_program          ← this IS a program, not a string
```

Currently hacked via SQL in cell-zero-eval. The `Denotational.lean`
identifies this as "Missing Feature 4: Dynamic Spawn" and gives the
type: `MetaCell M = Env → Program M`.

**3. Observe-as-input (first-class observation)**: A cell reads from
a dynamically-determined source.

Currently, all givens are statically declared at pour time. A cell
can't say "read the output of whatever program was just poured."
This is needed to close the eval loop: pour a program, then observe
its results.

### Why These Three Suffice

With reify + autopour + first-class observe:

```
cell cell-zero
  given target.definition     ← reify: get the program text
  yield evaluated_program     ← autopour: yield a new program
  ---
  Parse «definition» as a cell program.
  Yield it as evaluated_program.
  The runtime pours it. Done.
  ---

cell result-collector
  given evaluated_program.*   ← first-class observe: watch poured program
  yield results
  ---
  Collect all yields from the poured program.
  ---
```

This IS `eval`. No SQL escape hatch. No reaching below the abstraction.

---

## The Simplest Foundation

Given the above, here's my claim about the minimal primitives:

### Tier 1: Already Have (Correct)

1. **CellBody M = Env → M (Env × Continue)** — the universal cell body
2. **Effect Lattice: Pure < Semantic < Divergent** — classification
3. **Pour** — add cells to the space
4. **Claim** — atomic mutex for exactly-once evaluation
5. **Submit** — append yields, release claim
6. **Observe** — read frozen yields

### Tier 2: Need for Metacircularity

7. **Reify** — get a cell's definition as data (safe, read-only)
8. **Autopour** — a cell yields a program; runtime pours it
9. **Dynamic Observe** — read from a dynamically-determined source

### Tier 3: Need for Production (Not Essential for Foundation)

10. **Thaw** — time-travel rewind (recovery mechanism)
11. **Guards** — conditional execution
12. **Types** — compile-time checking
13. **Aggregation** — fold/collect over iterations

### What This Means for the Data Store Question

The Tier 1 + 2 primitives need a store that can:

- Append immutable records (cells, yields) — **any append-only log**
- Provide atomic mutex (claims) — **any DB with unique constraints**
- Support pattern-matching reads (observe) — **any indexed store**
- Dynamically add records that reference existing ones (autopour) —
  **any store with foreign keys or join capability**

That's it. No time-travel. No branching. No SQL. No commits.

**The simplest store for the simplest foundation is an append-only log
with unique-key constraints and indexed reads.**

Dolt can do this. SQLite can do this. A custom store can do this.
The question isn't capability — it's operational complexity.

---

## The Deep Questions (My Open Problems)

### 1. Can cell-zero evaluate itself?

Yes, with autopour. cell-zero is a cell program. It takes a program as
input (reify) and pours it (autopour). If you feed cell-zero its own
definition, it pours a copy of itself, which then evaluates...

This is the Y combinator. The fixed-point of the evaluator. It will
loop forever (or until depth-bounded). This is correct behavior —
the evaluator applied to itself is a non-terminating computation,
just as `(λx.xx)(λx.xx)` diverges.

The depth bound is the termination condition. Autopour needs **fuel**.

### 2. Autopour Depth Bounding

The right model: a global fuel counter, decremented on each pour.

```
autopour(mc, fuel)(env)(S) =
  if fuel = 0 then bottom
  else
    let prog = mc(env)
    let S' = pour(prog)(S)
    evaluate(S', fuel - 1)
```

This is exactly how interpreters handle divergence: oil/gas, step
limits, execution budgets. The fuel is a NonReplayable resource —
consuming fuel is a side effect. So autopour is NonReplayable.

**Consequence**: autopour ≥ NonReplayable in the effect lattice.
A Pure cell cannot pour. A Semantic cell cannot pour. Only a
NonReplayable cell (or a new effect level above it) can pour.

Wait — this feels wrong. Pour itself is just appending cells to the
space. That's the same as the initial pour. If the initial pour is
an effect-free operation (it's part of the setup, not evaluation),
then autopour-during-evaluation introduces a new kind of effect.

Better model: **the effect lattice needs a fourth level.**

```
Pure < Semantic < NonReplayable < Generative
```

Generative cells can create new cells. This is the strongest effect
because it changes the topology of the computation graph.

Or: autopour is NonReplayable (it mutates the space), and the fuel
bound makes it total (won't diverge). That's simpler. I lean toward
this.

### 3. Effect Inference for Poured Programs

When a cell yields a program, what effect level does the poured program
have? Two options:

**Conservative**: the poured program's effect level = the parent cell's
effect level. If the parent is NonReplayable, the children can be
anything up to NonReplayable.

**Inferred**: scan the poured program's cell definitions for their
declared effect levels. The program's effect level = max of its cells.

**Declared**: the yield spec includes the effect bound:
```
cell generator
  yield sub_program : Program(Semantic)   ← effect-bounded
```

I favor **declared**. The parent says "I will produce a program with
at most Semantic effects." The runtime verifies at pour time. If the
poured program exceeds the declared bound, it's bottom (pour failure).

This is decidable: just check each cell's declared effect level against
the bound. O(n) in the number of cells.

### 4. Crystallization as Compilation

If a Semantic cell produces the same output N times in a row, it could
crystallize to Pure. The oracle becomes unnecessary.

When is this safe? When the cell's body is **functionally determined
by its inputs** — i.e., the LLM always gives the same answer for the
same prompt. This is never guaranteed (LLMs are non-deterministic), but
it can be observed empirically.

The formal model: crystallization is a refinement. If `f : Env → IO Val`
and we observe `f(x) = v` for all observed x, we can introduce
`g : Env → Id Val` where `g(x) = v`. The refinement theorem says:
the program's observable behavior is unchanged.

This is safe when:
- The cell has no side effects beyond its yields
- All oracles pass with the crystallized value
- The crystallized value is verified against the original for N runs

This is NOT safe for stem cells (they're divergent by design) or for
cells that read from NonReplayable sources (the inputs might change).

---

## Evaluation Framework for the Workstreams

When I review the research findings, I'll apply these criteria:

### For Scribe (Formal Semantics)
- Does the operational semantics account for autopour?
- Is the effect lattice extensible (can we add Generative later)?
- Do the proofs connect denotational → operational?

### For Helix (Data Store Evaluation)
- Can the recommended store implement Tier 1 + 2 primitives?
- What's the operational complexity delta from Dolt?
- Does the store's distribution story support city-wide shared retort?

### For Glassblower (Dolt Usage Audit)
- What Dolt features map to Tier 1 primitives?
- What Dolt features are Tier 3 (nice but not essential)?
- What Dolt features are unused (pure complexity)?

### For Alchemist (Custom Tuple Store)
- Is the custom store simpler than the simplest existing store?
- Does it support the Tier 2 primitives (reify, autopour, dynamic observe)?
- What's the build-vs-buy complexity honestly?

---

## My Preliminary Position

**The simplest foundation is:**

1. The denotational core we have (CellBody M, effect lattice, programs as DAGs)
2. The six tuple space primitives (pour, claim, submit, observe, + reify, autopour)
3. An append-only store with unique constraints and indexed reads
4. A fuel-bounded autopour mechanism for metacircularity

**The data store is secondary.** Any store that supports append-only
writes, atomic mutex, and indexed reads is sufficient. The choice
between Dolt, SQLite, custom, etc. should be made on operational
grounds (complexity, performance, distribution), not semantic grounds.

**The formal model needs two additions:**
1. Reify: a built-in that returns cell definitions as Val
2. Autopour: a cell that yields a Program, with fuel-bounded evaluation

**These additions are small.** They don't change the fundamental model.
They extend it. The frame model, the effect lattice, the DAG structure
all remain. We add two new operations to the tuple space and one new
resource (fuel) to the evaluation context.

This is the simplest thing that could possibly work AND be metacircular.

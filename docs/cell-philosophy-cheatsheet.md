# Cell Language Philosophy — Cheat Sheet

*Distilled from a Socratic dialogue, 2026-03-16*

---

## The One Insight

**Evaluation is gravity toward value.**

Everything in Cell is on a spectrum of refinement. A literal value is maximally refined — it's on the ground. A SQL query is almost there. A soft cell (LLM prompt) is falling. A stem cell is in orbit — it keeps producing values but never lands. A whole program is a galaxy of falling objects.

M measures **how far a cell is from being a value.** Evaluation reduces that distance.

---

## The Four Cells Are One Cell

| Cell | What it does | Structural shape |
|------|-------------|-----------------|
| topic | represents a value | inputs → outputs |
| compose | applies a function to a value | inputs → outputs |
| count-words | applies a function to a value | inputs → outputs |
| critique | applies a function to values | inputs → outputs |

"Hard" and "soft" aren't different species. They're the same thing at different altitudes.

**One cell kind: `Env → M (Env × Continue)`**

- `Env` = inputs (resolved givens)
- `M` = distance from ground (how much work remains)
- `Env` = outputs (yields)
- `Continue` = Done (landed) or More (still orbiting)

---

## The Effect Lattice IS the Refinement Axis

```
Pure < Semantic < Divergent
     ↑           ↑           ↑
  on the      falling     in orbit
  ground
```

- **Pure**: fully contextualized, perfectly deterministic. Literals, SQL.
- **Semantic**: partially contextualized, non-deterministic. LLM prompts.
- **Divergent**: perpetual process, never lands. Stem cells.

A cell moves DOWN the lattice over time as it crystallizes:
`Divergent → Semantic → Pure`

If a soft cell produces the same output 100 times, it could crystallize into a hard cell. If a program always produces the same trace, the whole program could become a lookup table.

---

## M Measures Distance From Value

M is not "what effects this cell has." M is **how far this cell is from being a value.**

- `M = Id` → already a value (Pure). No work to do.
- `M = IO` → needs the real world (Semantic). LLM call, network, etc.
- `M = ExceptT Error (WriterT Cost IO)` → honest about what can go wrong and what it costs.

Wadler: "A cell doesn't go from input to output — it goes from input to *output-together-with-everything-that-happened-along-the-way*."

Feynman: "Proving your bridge is safe by assuming zero wind is lying about M."

---

## Soft Cells Are Future Hard Cells

The distinction between soft and hard isn't permanent — it's a **stage in a lifecycle**. A soft cell is a hard cell that hasn't been decomposed yet.

Crystallization = a cell moving down the refinement axis.
Decomposition = breaking a soft cell into finer deterministic cells.

Exception: stem cells. They're in orbit. They may never land — and that's by design. They're processes, not values.

But even stem cells produce values each cycle. And even programs, if they always produce the same trace, could theoretically crystallize.

---

## Key Concepts (Plain English)

**Monotonicity**: Once a cell has a value, that value doesn't change. Information only accumulates. This gives you confluence — evaluation order doesn't matter.

**Bottom ≠ Null**: Null is a value that says "nothing here." Bottom means "this computation never finished." Null hides the problem. Bottom exposes it. Bottom propagates through the graph like a crack through glass.

**Guards**: Preconditions on inputs. Check values BEFORE firing, not after. Moves the proof obligation from the cell author to the infrastructure. Free checks vs expensive oracle failures.

**Bindings**: When a cell reads from another cell, that specific connection is recorded and frozen. The cell's meaning is fixed by its bindings, not by "whatever the latest value happens to be." This is what makes monotonicity work.

**Autopour**: A cell yields a program. The runtime pours it. This IS eval. Tradeoffs: bound the pour depth, track cost, parse-failure = bottom.

**Reification vs Reflection**: Reification = treat a cell as data (safe, sufficient for metacircularity). Reflection = treat data as a running cell (dangerous, not required).

---

## The Frame Model

Cells are definitions (immutable). Frames are executions (append-only). The difference:

- **Cell**: "compose takes a subject and writes a haiku" — permanent, defined at pour time
- **Frame**: "compose@gen0 took 'autumn rain' and wrote 'Rain taps weathered tiles...'" — one specific run

State is **derived, never stored**: frozen = all yields exist, computing = claim exists, declared = neither.

The only mutable thing: the claims table (a lock). Everything else is append-only. Dolt commits capture the full history.

---

## The Retort Database Is a Chemical Abstract Machine

- Frozen yields = molecules in the solution
- Cell definitions = reaction rules
- ready_cells view = the match operation (which reactions can fire?)
- INSERT IGNORE claiming = linearization of concurrent reactions
- Stem cells = catalytic reactions (consume inputs, produce outputs, regenerate self)

---

## What's Missing (Ordered by Priority)

1. Unify cell kinds + parameterize M + effect lattice (one change)
2. Prove termination (productivity for stems, termination for others)
3. Prove monotonicity (bindings fix resolution at claim time)
4. Bottom propagation (the only live bug)
5. Guard expressions (preconditions on values)
6. Notation reform (expose mode x lifecycle)
7. Autopour (programs as first-class yields)

---

## Quotes to Remember

**Feynman**: "One law. Different inputs."

**Dijkstra**: "Prove what matters, not what yields to proof easily."

**Milner**: "Oracles on soft cells are dynamic contracts, not types. Types are checked at pour time. Contracts are checked at freeze time."

**Hoare**: "The guard creates a boundary of certainty."

**Wadler**: "Items 1 and 3 are the same conversation. Once cell kinds are unified, what distinguishes them is which M they live in."

**Sussman**: "A language that can express its own evaluator in itself is a language that can be extended by its users without modifying the implementation."

**Iverson**: "If you need to tell me what kind of cell something is before I can read the expression, your notation has a leak."

**You**: "Evaluation is gravity toward value."

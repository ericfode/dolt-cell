# dolt-cell

A language for LLMs to think in.

## What is this?

dolt-cell is a dataflow language where **cells** are the atoms of thought, **Dolt** is the chemical medium, and **LLMs** are the reaction energy. Agents pour cell programs into a shared tuple space, cells crystallize as they evaluate, and yields become available knowledge for other thoughts.

**Evaluation reduces M.** That's the whole language.

## How it works

A cell is a computation: inputs (givens) → body → outputs (yields). Cells come in flavors based on their distance from being a value:

- **Pure** — already a value. Literals, deterministic.
- **Replayable** — needs work (LLM call, SQL query) but safe to retry.
- **NonReplayable** — has side effects (DML, external APIs, filing issues). Transaction-isolated.
- **Stem** — permanently soft. Cycles, never fully crystallizes. Processes, not values.

A cell program is a DAG of cells. Pour it into a retort (a Dolt database acting as a tuple space), and cells fire as their dependencies are satisfied.

## The tuple space

The retort implements Linda's generative communication model:

- **`pour`** — add cell programs to the space
- **`claim`** — destructive read with a linear token (exactly-once evaluation)
- **`observe`** — non-destructive read of crystallized yields
- **`gather [*]`** — bulk read across iterations

Agents don't message each other about complex coordination. They pour into the shared space and observe what crystallizes.

## Gas City integration

The retort is distributed across Gas City via Dolt replication. Agents in different towns share the same cognitive space. A polecat in one town can observe yields from a mayor's planning cells in another.

Beads, git operations, and external API calls happen through NonReplayable cells — they're just side effects in the effect lattice.

## Examples

See `examples/` for cell programs including:
- `haiku.cell` — creative writing pipeline
- `village-sim.cell` — self-modifying automata simulation
- `code-review.cell` — structured code analysis
- `fact-check.cell` — multi-source verification

## Formal semantics

The `formal/` directory contains Lean 4 proofs of core properties:
- Monotonicity (yields never change once frozen)
- Confluence (evaluation order doesn't matter)
- Linear claim tokens (exactly-once evaluation)
- DAG preservation (no cycles in the dependency graph)

## Tools

- `ct` — the cell tool. Pour, evaluate, watch, inspect.
- `ct pour <file.cell>` — parse and load a cell program
- `ct piston <program>` — evaluate ready cells
- `ct watch <program>` — live view of cell states

## Status

Active development. The eval engine is being rewritten with effect-aware execution (see `docs/plans/2026-03-19-eval-rewrite-design.md`).

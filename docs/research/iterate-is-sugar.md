# Design Decision: `iterate` is Sugar for `recur`

*Sussmind — 2026-03-21*
*Bead: dc-wdw*

---

> **Note (2026-03-21):** This research predates the Lua substrate design.
> Code examples use the old cell syntax (guillemets, sql: bodies). The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-lua-substrate-design.md` for
> the current design.

## 1. The Question

`village-sim.cell` uses `iterate day 5` — a keyword not in the v2 syntax
spec. What is it? Is it a new primitive? Or syntactic sugar for something
we already have?

## 2. The Answer

**`iterate` is sugar for `recur (max N)` without a guard.**

The implementation confirms this. In `parse.go`, both forms set the same
internal field (`parsedCell.iterate`) and expand through the same function
(`expandIteration`). There is no semantic difference — only a syntactic
convenience.

| Surface form | Internal representation | Guard | Max |
|---|---|---|---|
| `iterate NAME N` | `iterate = N, guard = ""` | none | N |
| `recur (max N)` | `iterate = N, guard = ""` | none | N |
| `recur until GUARD (max N)` | `iterate = N, guard = GUARD` | GUARD | N |

All three expand to the same chain: `NAME-1 → NAME-2 → ... → NAME-N`,
with each step's givens wired to the previous step's yields.

## 3. Why This is Correct (The Algebra)

The effect lattice and the denotational semantics treat iteration as
**bounded unrolling of a fixed-point computation.** That's recursion, not
iteration in the classical sense.

Classical iteration (a `for` loop) implies:
- Deterministic step count
- Mutable state threaded through the loop body
- No early termination based on output quality

Cell's "iteration" is none of these. It is:
- A chain of independent cell evaluations
- Each cell receives the *previous cell's yields* as givens
- Each evaluation is a fresh LLM call — **nondeterministically idempotent**
- A guard can terminate the chain early

This is **guarded recursion** in the sense of domain theory: a productive
corecursive process truncated by a well-founded termination condition.
The `(max N)` bound makes it well-founded. The guard makes it potentially
shorter.

The nondeterministic idempotence point is key: each step of the recursion
may produce a *different* output for the same input (because LLMs are
stochastic). But the *structure* is recursive — each step refines the
previous step's output. The guard tests whether the refinement has
converged. This is a fixpoint iteration, not a counting loop.

`iterate` without a guard is the degenerate case: "run this recursion
exactly N times, no early exit." It's useful for simulations
(village-sim's `iterate day 5`) where you want N applications of a
state-transition function with no convergence test.

## 4. Why `iterate` Should Stay as Sugar

Despite being semantically identical to `recur (max N)`, the `iterate`
keyword earns its place as sugar for two reasons:

1. **Intent clarity**: `iterate day 5` reads as "simulate 5 days."
   `recur (max 5)` reads as "recurse up to 5 times." Both do the same
   thing, but `iterate` better communicates *bounded application* while
   `recur` communicates *convergence-seeking refinement*.

2. **No guard = no guard**: `iterate NAME N` makes it explicit that
   there is no early-exit condition. `recur (max N)` leaves the reader
   wondering "where's the `until`?"

But it MUST be documented as sugar, not as a separate primitive. The
spec should define `recur` as the fundamental form and `iterate` as
shorthand.

## 5. The SQL Problem

While investigating `iterate`, a deeper concern surfaced: **the presence
of SQL as a cell body type is a leaky abstraction.**

Hard computed cells use raw SQL:
```
cell count-words
  yield total
  ---
  sql: SELECT LENGTH(...) FROM yields ...
  ---
```

This violates the language's own principles:

1. **It breaks metacircularity.** cell-zero cannot evaluate a hard
   computed cell without access to the Dolt substrate. The whole point
   of cell-zero-autopour was to eliminate SQL escape hatches — but
   `sql:` bodies are SQL escape hatches baked into the syntax.

2. **It couples the language to the store.** Cell programs should be
   portable across tuple space implementations. A cell program with
   `sql:` bodies is Dolt-specific.

3. **It conflates effect levels.** A `sql: SELECT` is Pure (read-only,
   deterministic). A `sql: INSERT` or `sql: CALL DOLT_COMMIT` is
   NonReplayable. But the parser marks all hard computed cells as Pure.
   The effect lattice is violated silently.

4. **It prevents crystallization reasoning.** The formal model treats
   hard cells as Pure values. But a `sql:` body that reads from a
   changing table is NOT pure — it's Replayable at best.

### Recommendation

SQL should be a **piston capability**, not a **language primitive.**

Instead of:
```
cell count-words
  yield total
  ---
  sql: SELECT ...
  ---
```

Use a soft cell that instructs the piston:
```
cell count-words
  given compose.poem
  yield total
  ---
  Count the words in «poem».
  ---
```

Or, for cases where you truly need deterministic computation, use
hard literals with a derivation chain:
```
cell count-words
  yield total = 17
```

The `sql:` body type should be deprecated in favor of:
- **Soft cells** for computations the piston handles
- **Hard literals** for known values
- **A future `compute:` cell type** that runs a pure function
  (no database access, no side effects, deterministic) — this
  preserves the effect lattice while allowing computation

This is a larger design change (not part of dc-wdw) but the `iterate`
investigation surfaced it. Filed as a concern for the crew.

## 6. Spec Update

The v2 syntax spec (`docs/cell-v2-syntax.md`) should add:

```
## Bounded Iteration (Sugar)

`iterate` is shorthand for `recur` without a guard:

    iterate NAME N
      given SEED.FIELD
      yield FIELD
      ---
      Body text...
      ---

is equivalent to:

    cell NAME
      given SEED.FIELD
      yield FIELD
      recur (max N)
      ---
      Body text...
      ---

Use `iterate` when you want exactly N applications of a state-transition
function (simulation ticks, generation steps). Use `recur until` when
you're seeking convergence.
```

## 7. Implementation Note

No code changes required. The parser already handles both forms
identically. This is purely a documentation and spec update.

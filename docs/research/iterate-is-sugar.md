# iterate is sugar — Design Rationale

> **Note (2026-03-21):** This research predates the Zygo S-expression
> substrate (dc-jo2). Code examples use the old cell syntax. The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-zygo-substrate-design.md` for
> the current syntax.

## Summary

`iterate NAME N` is syntactic sugar for `cell NAME` + `recur (max N)`.
The parser desugars it at parse time; no runtime distinction exists.

## Why a keyword?

The v1 syntax `⊢∘ NAME × N` was the most common recursion pattern:
run a cell N times, chaining outputs. In v2, the equivalent is:

```
cell NAME
  ...
  recur (max N)
  ...
```

This is correct but verbose for the common case. `iterate NAME N`
provides a one-liner that reads naturally for the "do this N times"
intent while expanding to the same AST.

## iterate is recursion, not classical iteration

Despite the name, `iterate` is fundamentally recursion:

| Property | Classical iteration | Cell iterate |
|----------|-------------------|--------------|
| State | Mutable loop variable | Immutable yield chain |
| Determinism | Deterministic | Nondeterministic (LLM eval) |
| Body | Side-effecting statements | Pure transformation |
| Termination | Loop counter / break | Fixed bound, no early exit |
| Composition | Sequential | Dataflow (given/yield) |

Each step is a fresh cell evaluation. The output of step K becomes
the input of step K+1 via the yield chain. There is no shared
mutable state between steps.

## Nondeterministic idempotence

A key property: `iterate NAME 1` is NOT guaranteed to be a no-op.
Even with identical input, the LLM may produce different output.
This distinguishes iterate from a mathematical fixpoint iteration
where f(f(x)) = f(x) implies convergence.

For Cell, "iterate 1" means "evaluate once" — the same as a plain
cell with no recursion. "iterate 3" means "evaluate, then evaluate
the result, then evaluate that result." Each evaluation is an
independent nondeterministic transformation.

This is why guarded recursion (`recur until GUARD`) exists separately:
it provides a semantic convergence criterion that doesn't depend on
deterministic equality.

## When to use iterate vs recur

| Scenario | Use |
|----------|-----|
| Refine until a quality criterion is met | `recur until GUARD (max N)` |
| Run exactly N refinement passes | `iterate NAME N` |
| Single evaluation, no recursion | Plain `cell NAME` |
| Perpetual daemon (never freezes) | `cell NAME (stem)` |

## The SQL-as-body concern

During design, we noted that `iterate` cells with SQL bodies create
an odd pattern: iterating a deterministic SQL query N times always
produces the same result. This is technically valid but useless.
We chose not to lint or forbid it — the type system (Pure vs Semantic
effect levels) already makes this visible, and adding a special case
would complicate the parser for no real safety gain.

## Parser implementation

The desugaring is trivial:

```
iterate NAME N  →  cell NAME
  ...               ...
  recur (max N)      recur (max N)
  ...               ...
```

The parser treats `iterate` as an alternative cell-declaration keyword.
All subsequent indented lines (yields, givens, body, checks) parse
identically. The only difference is that `recur (max N)` is injected
automatically from the declaration line.

If the body also contains an explicit `recur` statement, the parser
raises a diagnostic: "iterate already implies recur (max N)."

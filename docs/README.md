# Cell Documentation

## Start Here

- **[Architecture](architecture.md)** — How Cell is built. Five primitives,
  Gas City resonance, layering invariants. Read this first.
- **[Philosophy Cheatsheet](cell-philosophy-cheatsheet.md)** — "Evaluation
  reduces M." The one insight that everything else follows from.

## Language

- **[Cell v2 Syntax](cell-v2-syntax.md)** — The grammar. Migration from
  v1 Unicode to v2 ASCII notation.
- **[Parser Spec](cell-v2-parser-spec.md)** — Formal grammar, parsing rules,
  derived cell kinds, ID generation.

## Formal Model

All in `formal/`:

- **[Tuple Space Spec](../formal/cell-tuple-space-spec.md)** — Complete v4
  specification. Five operations, effect lattice, execution model, 12 edge
  cases, proof obligations.
- **[Effect Algebra](../formal/EffectAlgebra.md)** — Wadler's graded free
  monad. PistonOp, 11 algebraic laws, handler interpretation.
- **Core.lean** — Canonical `EffLevel` with full join algebra. Identity types.
- **EventBus.lean** — Append-only event log. 9 properties, zero sorries.
- **AgentProtocol.lean** — Session lifecycle. Stop idempotence, monotonicity.
- **Autopour.lean** — Programs as values, fuel termination, crystallization.
- **Denotational.lean** — `CellBody M = Env -> M (Env x Continue)`. Traces.
- **EffectEval.lean** — Effect-aware eval step, retry safety, append-only.
- **Retort.lean** — Full retort state model. *(Has Lean 4.28 compat issues.)*
- **Claims.lean**, **TupleSpace.lean**, **Refinement.lean**, **StemCell.lean**

## Research

- **[Metacircular Foundation](research/metacircular-foundation-analysis.md)** —
  Reify + autopour + dynamic observe: the three missing primitives.
- **[Autopour Denotational Semantics](research/autopour-denotational-semantics.md)** —
  Formal semantics of yielded programs.
- **[Tuple Space Protocol](research/tuple-space-protocol.md)** — Linda mapping.
- **[Consensus Recommendation](research/consensus-recommendation.md)** — Team synthesis.
- **[Custom Tuple Store](research/custom-tuple-store-design.md)** — Store alternatives.
- **[Hard Cells After Rewrite](research/hard-cells-after-rewrite.md)** — Analysis.
- **[Phase A Results](research/cell-pour-phase-a-results.md)** — Empirical findings.

## Plans

- **[Implementation Plan v2](plans/2026-03-20-implementation-plan-v2.md)** —
  Phased roadmap: RetortStore -> Reify+Autopour -> Effect unification -> Gas City.
- **[Autopour Runtime Spec](plans/2026-03-21-autopour-runtime-spec.md)** —
  Concrete spec for reify + autopour in ct.

## Operations

- **[UX Notes](cell-ux-notes.md)** — Real bugs from piston stress testing.
- **[Deltas Exploration](deltas-obsidion-exploration.md)** — First runtime
  stress test, 6 beads filed.
- **[Frame Model Migration](frame-model-migration.md)** — Schema v2 spec.
- **[Reading List](reading-list.md)** — Linda, actors, blackboard systems, GAMMA.

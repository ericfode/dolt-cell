# Consensus Recommendation: Simplest Foundation for Cell Evaluation

*Sussmind — Consensus Driver (dc-rv8)*
*2026-03-20 — FINAL (all four workstreams reviewed)*

---

## Status

| Workstream | Agent | Status | Finding |
|-----------|-------|--------|---------|
| Dolt usage audit | Glassblower | VERIFIED+CLOSED | ct uses Dolt as MySQL+commits. 0 Dolt-specific features. 26 DOLT_COMMITs. 240 SQL ops. |
| Data store evaluation | Helix | ACCEPTED+CLOSED | KEEP DOLT. 9 alternatives evaluated. Revised: Tier 1=any SQL, Tier 2=Dolt-specific. Buying growth. |
| Custom tuple store | Alchemist | STRONG CONDITIONAL ACCEPT | 660-line log store design. Simpler for single-node. Distribution gap is deal-breaker for vision. |
| Formal semantics | Scribe | CONDITIONAL ACCEPT | GasTown.lean: 670 lines, 36 theorems, 0 sorry. 7 primitives formalized. Effect taxonomy unification needed. |
| Metacircular analysis | Sussmind | COMPLETE | Wrote position papers + Lean formalization of autopour |

**All four workstreams reviewed. This is the FINAL recommendation.**

---

## The Question

What is the simplest possible foundation for cell evaluation?

- Right denotational semantics
- Right operational semantics
- Right tech stack
- Minimum viable complexity

---

## Findings

### What We Agree On

**1. The denotational core is solid.**

`CellBody M = Env → M (Env × Continue)` — one cell kind, parameterized
over an effect monad. The effect lattice (Pure < Semantic < Divergent)
classifies cells by computational power. The frame model (immutable
definitions, append-only executions) is correct. Nobody disputes this.

**2. ct uses a fraction of Dolt.**

Glassblower's audit (verified by grep): 21 DOLT_COMMIT calls, 23 INSERT
IGNORE calls, zero uses of branching, time travel, merge, or distribution.
The current implementation treats Dolt as MySQL + append-only commit log.

**3. The unused Dolt features ARE the vision.**

Helix's evaluation: time travel (thaw), branching (speculative eval),
and distribution (shared retort) are needed for the full Gas City tuple
space. No alternative provides all three. Dolt is unique in this regard.

**4. The language lacks metacircular primitives.**

Sussmind's analysis: cell cannot express its own evaluator without
dropping to SQL. Two missing primitives — reify (read cell definitions
as data) and autopour (yield a program the runtime pours) — would
complete the language. These don't require Dolt-specific features.

**5. A custom store IS simpler for single-node evaluation.**

Alchemist's design: 660 lines of Go, 5 event types, zero dependencies.
Structural invariants (log format can't express UPDATE/DELETE). O(1)
ready-set. Atomic submit. The 10-method RetortStore API is what the
interface SHOULD look like regardless of backing store.

**6. The operational semantics are formalized.**

Scribe's GasTown.lean: 670 lines, 36 theorems, 0 sorry. All 7 tuple
space primitives have small-step operational semantics with pre/post
conditions and preservation proofs.

### Where We Disagree (The Productive Tension)

**Helix**: "Dolt's features are load-bearing architectural requirements."

**Alchemist**: "A 660-line log store is simpler and more correct."

**Sussmind**: "Both are right. The data store is secondary to the
language primitives."

The reconciliation:

- **The minimum viable foundation** needs only: append-only writes,
  atomic mutex, indexed reads. Both Dolt and the log store provide this.
- **The full vision** requires distribution. Only Dolt provides this
  today. Building distribution into the log store would be massive.
- **The right abstraction**: define a RetortStore interface (alchemist's
  API), implement it on Dolt (for production), optionally on the log
  store (for testing, embedded use). Let the interface be the contract;
  let the store be swappable.

---

## My Recommendation

### 1. Keep Dolt (Helix is right about the destination)

The shared distributed tuple space IS the vision. Dolt's unique
combination of SQL + version control + distribution makes it the
only existing store that can serve as the foundation for a
replicated, time-traveling, branch-isolated tuple space.

Alchemist proved a custom 660-line log store is simpler for single-node
evaluation. But distribution — the Gas City vision — would require
building consensus, replication, and conflict resolution from scratch.
Dolt already has this. Keep Dolt, but adopt alchemist's clean API as
the abstraction boundary (see point 5 below).

### 2. Use Dolt simply (Glassblower is right about the present)

The 21 DOLT_COMMITs per evaluation are unnecessary overhead. The
current code commits after every operation. A better pattern:

- Commit at **program boundaries** (pour complete, program complete)
- Commit at **claim boundaries** (claim acquired, yield submitted)
- NOT at every individual operation

This could reduce commits from ~20-40 per program to ~5-10.

### 3. Add the metacircular primitives (Sussmind's contribution)

The simplest foundation for the LANGUAGE (distinct from the STORE)
needs two additions:

**a. Reify**: A built-in that returns cell definitions as structured
data. A new given qualifier: `given target.definition` returns the
cell's definition as a record value. Safe, read-only, compositional.

**b. Autopour**: A yield annotation `[autopour]` that tells the
runtime: "when this yield freezes and contains a program value,
pour it." With fuel-bounded depth to prevent infinite regress.

These are formalized in `formal/Autopour.lean` (compiles, zero sorry,
zero warnings). The key theorems are proven:
- Fuel terminates (each pour decrements, bounded by initial fuel)
- Effect monotonicity (poured program ≤ parent effect level)
- Traces are monotonically growing (append-only preserved)
- Self-evaluation tower terminates at bottom

### 4. Bridge the formal models (Scribe: CONDITIONALLY ACCEPTED)

Scribe delivered GasTown.lean: 670 lines, 36 theorems, 0 sorry, 0 axioms.
All 7 tuple space primitives formalized with small-step operational semantics.
This is the operational counterpart we needed.

**What's done:**
- 7 primitives (pour, claim, submit, release, observe, thaw, gather)
- Pre/postconditions for each primitive
- Linear claim handle discipline
- Append-only preservation proofs
- Eval cycle decomposition (observe → claim → body → submit → createFrame)

**What still needs work:**
- Effect taxonomy unification (3 incompatible schemes across Lean files)
- Denotational-operational refinement theorem (the adequacy proof)
- Autopour as 8th primitive (I'll extend from my Autopour.lean)
- File persistence (all four workstreams had worktree cleanup issues)

### 5. Abstract the store (Alchemist's key contribution)

Define a `RetortStore` Go interface with alchemist's clean 10-method API:
`Open`, `Close`, `Pour`, `Next`, `Submit`, `Fail`, `Observe`, `Gather`,
`Thaw`, `Status`. This is the abstraction boundary between language
semantics and storage implementation.

**Two implementations:**
- `DoltStore` — production. Wraps Dolt SQL via the existing client code.
  Gets distribution, time travel, branching for free.
- `LogStore` — embedded. Alchemist's 660-line design. For tests, local
  development, and proof-of-concept. Zero dependencies.

This gives us the best of both worlds: Dolt's distribution story AND
the log store's simplicity, behind a common interface. The formal model
reasons about the interface, not the implementation.

---

## The Simplest Foundation (Summary)

```
LANGUAGE:
  CellBody M = Env → M (Env × Continue)
  Effect Lattice: Pure < Semantic < Divergent
  Val = str | none | error | program       ← extended with program values
  Reify: given target.definition           ← read cell definitions as data
  Autopour: yield field [autopour]         ← programs as first-class yields

OPERATIONS:
  pour    — append cells to the space
  claim   — atomic mutex (INSERT IGNORE + UNIQUE)
  submit  — append yields, release claim
  observe — read frozen yields
  reify   — read cell definitions (NEW)
  autopour — pour from yield value (NEW, fuel-bounded)

STORE:
  RetortStore interface — the abstraction boundary
  DoltStore — production (distribution, time travel, branching)
  LogStore — embedded (tests, development, zero dependencies)

FORMAL:
  Denotational.lean — the meaning of programs (existing)
  Autopour.lean — metacircular primitives (NEW, canonical EffLevel, compiles clean)
  TupleSpace.lean — proof obligations for the store (existing)
  GasTown.lean — operational semantics (NEW from scribe, 36 theorems)

EFFECT TAXONOMY (MUST UNIFY):
  Canonical: Pure < Replayable < NonReplayable (by recovery cost)
  Core.lean EffectLevel (pure/semantic/divergent) — DEPRECATED, conflates lifecycle
  EffectEval.lean EffLevel — matches canonical
  TupleSpace.lean Effect — matches canonical
  Autopour.lean — needs migration from Core to canonical
```

This is the minimum that is BOTH:
- Sufficient for metacircularity (cell can express its own evaluator)
- On the path to the full vision (shared distributed tuple space)

---

## Open Items

### Research Complete
- [x] Glassblower: Dolt usage audit — VERIFIED + CLOSED
- [x] Helix: Data store evaluation — ACCEPTED + CLOSED (revised to align)
- [x] Alchemist: Custom tuple store design — STRONG CONDITIONAL ACCEPT
- [x] Scribe: Operational semantics — CONDITIONAL ACCEPT (GasTown.lean)

### Implementation Next Steps
- [ ] Define `RetortStore` Go interface (alchemist's API)
- [ ] Implement `DoltStore` adapter over existing SQL
- [ ] Prototype `LogStore` for tests (alchemist's design)
- [ ] Add reify + autopour to the cell language
- [ ] Unify effect taxonomy: adopt Pure/Replayable/NonReplayable everywhere
- [ ] Reduce DOLT_COMMIT frequency (program boundaries, not per-operation)
- [ ] Re-persist all workstream documents (worktree cleanup issue)

### Formal Next Steps
- [ ] Denotational-operational refinement theorem (adequacy proof)
- [ ] Autopour as 8th primitive in GasTown operational semantics
- [x] Migrate Autopour.lean from Core.EffectLevel to canonical taxonomy (done 2026-03-20)
- [ ] Formalize RetortStore interface as an abstract algebraic structure

---

## What's NOT Part of the Foundation

These are important but NOT essential for the simplest foundation:

- **Types** — valuable for compile-time checking, but the foundation works without them
- **Guards** — conditional execution, nice but not minimal
- **Aggregation** — fold/collect, syntactic convenience
- **Thaw** — time travel recovery, Tier 3 (needs Dolt but not needed today)
- **Branch isolation** — speculative eval, Tier 3
- **Distribution** — shared retort, essential for Gas City but not for single-node eval

These are the growth path. The foundation supports them. But they don't
need to be built first.

---

*Evaluation reduces M. The simplest foundation is the smallest set of
primitives that lets the language express its own reduction.*

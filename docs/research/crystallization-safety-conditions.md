# Crystallization Safety Conditions

**Date**: 2026-03-21
**Author**: dolt-cell/alchemist
**Status**: Research
**Parent**: dc-9gl

> **Note (2026-03-21):** This research predates the Lua substrate design.
> Code examples use the old cell syntax (guillemets, sql: bodies). The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-lua-substrate-design.md` for
> the current design.

## The Question

When can a Replayable cell safely crystallize into a Pure cell?

The effect lattice says: `Pure < Replayable < NonReplayable`.
Movement DOWN this lattice (Replayable → Pure) is the crystallization
transition. The existing formal model (Autopour.lean) proves observed-input
soundness but explicitly notes: "It does NOT guarantee the crystallized
cell will produce the same output on UNSEEN inputs."

This doc formalizes the conditions under which crystallization is safe,
explores de-crystallization, and connects to broader PL theory.

## 1. The Formal Safety Conditions

### 1.1 Crystallization as Refinement

Let `f : Env → IO Val` be the soft cell (Replayable). Crystallization
introduces `g : Env → Id Val` (Pure) such that for all observed inputs:

```
∀ x ∈ observed_inputs, g(x) = f(x)
```

This is a **speculative refinement**: we bet that the pattern generalizes.
The bet has a formal safety net: de-crystallization (thaw).

### 1.2 The Safety Conditions

A Replayable cell may crystallize when ALL of the following hold:

**C1: Deterministic inputs.** All upstream cells providing `given` values
are themselves Pure or crystallized. If any given comes from a Replayable
source, the input space is not stable — the cell cannot crystallize.

```
∀ g ∈ cell.givens,
  effectLevel(source(g)) ≤ Pure
```

**C2: No stem ancestry.** The cell is not a stem cell, and no ancestor
in the DAG is a stem cell. Stem cells are designed to vary; crystallizing
their downstream freezes a moving target.

```
¬ cell.isStem ∧ ∀ ancestor ∈ transitiveDeps(cell), ¬ ancestor.isStem
```

**C3: Sufficient observations.** At least N agreeing observations exist
where:
- Same inputs produced same outputs
- All oracles passed

```
|observations| ≥ threshold ∧
∀ obs ∈ observations, obs.output = refOutput ∧ obs.oracleOk
```

(This is the `CrystalCandidate` in Autopour.lean.)

**C4: Oracle completeness.** The cell has at least one deterministic
oracle (`check`, not `check~`). Semantic oracles (`check~`) are
themselves Replayable — they can't witness Pure behavior.

```
∃ oracle ∈ cell.checks, oracle.isDeterministic
```

**C5: Frozen upstream.** All givens resolve to frozen frames. No
upstream computation is pending or could change.

```
∀ g ∈ cell.givens, frameStatus(latestFrame(source(g))) = Frozen
```

### 1.3 What C1-C5 Give You

Under C1-C5, the crystallized cell is **observationally equivalent**
to the soft cell for all inputs that the upstream DAG can produce.
Since all upstream is Pure (C1) and frozen (C5), the input space is
fixed. The cell cannot receive an input it hasn't been tested on
(modulo hash collisions in input comparison).

The gap: if the program is re-poured with different initial literals,
the crystallized cell may see new inputs. This is handled by C5
(frozen upstream) — re-pouring creates new frames, not new inputs to
existing frames.

## 2. De-Crystallization (Thaw)

### 2.1 When to Thaw

A crystallized cell must be thawed (reverted to Replayable) when:

**T1: Oracle failure.** The crystallized value fails an oracle check
on a new input.

**T2: Upstream thaw cascade.** An upstream cell was thawed. C1 no
longer holds — the crystallized cell's inputs may change.

**T3: Manual override.** A human or agent explicitly requests
de-crystallization (e.g., for debugging or updating behavior).

### 2.2 Thaw Protocol

```
1. Mark cell as Replayable (body_type = 'soft')
2. Restore original soft body from cell_soft_bodies
3. Create new frame at generation + 1
4. Re-evaluate with LLM piston
5. Run oracles on new output
6. If oracles pass → freeze new frame
7. Check downstream: cascade thaw to any cells
   that crystallized with this cell as a given
```

### 2.3 Thaw Safety

Thawing is always safe because:
- Yields are append-only. The crystallized yields remain at their
  generation. New yields appear at a higher generation.
- Downstream cells that read `latest frozen frame` will pick up the
  new (re-evaluated) values.
- The thaw cascade (T2) ensures transitive consistency.

Formally: if `thaw(cell)` produces a new frame at generation `n+1`,
then for any downstream cell `d`:
- If `d` was crystallized → d is also thawed (cascade)
- If `d` was Replayable → d naturally re-evaluates with new inputs
- If `d` was Pure (hard cell) → d is unaffected (reads frozen data)

## 3. Crystallization × Autopour

### 3.1 The Weird Case: Crystallized Metacells

An autopoured cell yields a program. If that cell crystallizes, it
becomes a Pure cell that yields a fixed program. This is:

- **Useful**: a cell program factory that always produces the same
  template. E.g., a "code review" metacell that always pours the
  same review DAG.
- **Dangerous**: if the template should vary based on context but
  the crystallized version is frozen.

Safety condition: metacells should NOT crystallize unless:
- The program template is genuinely context-independent
- Or the context is fully determined by Pure givens (C1)

### 3.2 Crystallization of Poured Programs

When a metacell pours program P, and cells within P crystallize:
- The crystallization is local to P
- If the metacell is re-evaluated (thawed), P is discarded and
  re-poured — crystallizations within the old P are irrelevant

This means autopour creates a natural scope boundary for
crystallization: crystallizations don't survive across autopour
cycles.

## 4. Meta-Crystallization: Crystallize as Cell Program

Can crystallization itself be expressed as a cell program?

Yes. Here's the pattern:

```
cell crystal-scan
  yield candidates
  ---
  sql: SELECT c.name FROM cells c
       WHERE c.body_type = 'soft'
       AND ... (eligibility checks)
  ---

cell crystal-propose (per candidate)
  given crystal-scan.candidates
  yield sql_view
  ---
  Write a SQL view that computes the same output as
  the soft cell «candidate». The view must:
  - Read from yields and cells tables
  - Produce the same field values
  ---

cell crystal-validate
  given crystal-propose.sql_view
  yield validation_result
  ---
  sql: [differential test of proposed view against
       existing frozen yields]
  ---
  check validation_result = "PASS"

cell crystal-apply
  given crystal-validate.validation_result
  given crystal-propose.sql_view
  yield applied
  ---
  sql: [CREATE VIEW + UPDATE cells]
  ---
```

This is crystallization expressed as a cell DAG. The meta-circularity:
the `crystal-propose` cell is itself Replayable (it uses an LLM to
write SQL). Could IT crystallize? Only if there's a deterministic way
to write SQL from cell definitions — which would require solving program
synthesis in general. So `crystal-propose` is a permanently Replayable
cell, like the evaluator cells in cell-zero.

## 5. Connection to Memoization / Tabling

### 5.1 Crystallization ≠ Memoization

Memoization: cache outputs for seen inputs. Return cached value on
cache hit, compute on miss.

Crystallization: replace the computation with a deterministic function.
Never call the original computation again (unless thawed).

The difference is committal: memoization is speculative and lazy.
Crystallization is a permanent (until thawed) structural change.

### 5.2 Crystallization ≈ Tabling (Partial Evaluation)

In logic programming, tabling stores derived facts so they don't need
re-derivation. A tabled predicate is like a crystallized cell: the
derivation is replaced by a lookup.

The analogy:
- Soft cell body ≈ Prolog clause (rule)
- Crystallized cell ≈ tabled fact (ground truth)
- Thaw ≈ invalidating the table (re-derive on demand)
- Oracle ≈ integrity constraint on the table

### 5.3 The Effect Lattice as a Compilation Target

The deeper vision: the effect lattice is a program transformation axis.

```
Interpretation                    Compilation
    ↑                                  ↑
Replayable                          Pure
(LLM evaluates)                (SQL evaluates)
    ↑                                  ↑
    └── crystallization ──────────────→┘
```

Crystallization is partial evaluation applied to the cell language.
A cell program starts fully interpreted (all Replayable). Over time,
cells that stabilize get compiled (crystallized to Pure). The program
becomes a mix of interpreted and compiled cells — exactly like a
JIT compiler.

The difference from traditional JIT: the "compiler" is an LLM, the
"machine code" is SQL, and the "profiling" is oracle-validated
observations. But the structure is the same.

## 6. Open Questions

1. **Cascading thaw performance.** If a deeply-nested cell thaws,
   the cascade could re-evaluate many cells. Is there a way to
   bound the cascade? (Answer: the DAG depth bounds it, and depth
   is typically small for cell programs.)

2. **Crystallization and gather.** If a cell uses `gather` to read
   all iterations of a stem cell, it can never satisfy C2 (no stem
   ancestry). Should gather-of-stem be a special case?

3. **Probabilistic crystallization.** Instead of C3's binary "all
   agree", could we crystallize with a confidence interval? E.g.,
   "95% of observations agree" → crystallize with a monitoring flag?

4. **Cross-program crystallization.** If the same cell definition
   appears in multiple programs and crystallizes in all of them,
   can the crystallization be shared? (This is global optimization.)

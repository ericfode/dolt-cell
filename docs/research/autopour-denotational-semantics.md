# Autopour: Denotational Semantics of Programs-as-Yields

*Sussmind — 2026-03-19*

> **Note (2026-03-21):** This research predates the Zygo S-expression
> substrate (dc-jo2). Code examples use the old cell syntax. The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-zygo-substrate-design.md` for
> the current syntax.

---

## 1. The Problem

cell-zero-eval achieves metacircularity by SQL manipulation:
```sql
INSERT INTO cells ...
UPDATE yields SET value_text = ...
CALL DOLT_COMMIT(...)
```

This is eval-by-escape: the evaluator leaves the language to manipulate
the substrate directly. It proves the runtime works, but proves nothing
about the language's expressive power.

**Autopour** makes eval a first-class operation: a cell yields a program,
the runtime pours it. The cell stays within the language. The runtime
does the work.

---

## 2. The Type

### Basic form

```
MetaCell M := Env → M (Program M × Env)
```

A metacell takes an environment (resolved givens) and produces:
- A program to be poured
- An output environment (the cell's own yields, excluding the program)

The `M` in `Program M` is critical: the produced program is
parameterized by the SAME effect monad as the parent. This means:
- A Pure metacell produces Pure programs (impossible — Pure can't pour)
- A Semantic metacell produces programs with at most Semantic cells
- A Divergent metacell produces programs with any effect level

### With fuel

```
AutopourCtx := { fuel : Nat, maxDepth : Nat, totalCost : Nat }

MetaCellF M := AutopourCtx → Env → M (Program M × Env × AutopourCtx)
```

The context threads through:
- `fuel` decrements on each pour (0 = bottom)
- `maxDepth` tracks nesting depth (for diagnostics/limits)
- `totalCost` accumulates across the tower (for billing/budgets)

### Integration with CellBody

Currently:
```
CellBody M = Env → M (Env × Continue)
```

With autopour, a cell body can ALSO produce a program. Two options:

**Option A: Extend CellBody** (rich return type)
```
CellBody M = Env → M (Env × Continue × Option (Program M))
```

Every cell can optionally yield a program. Most return None. This is
uniform but adds complexity to every cell evaluation.

**Option B: New cell kind** (separate constructor)
```
inductive CellKind M where
  | standard : CellBody M → CellKind M
  | meta     : MetaCell M → CellKind M
```

Metacells are explicitly marked. This is simpler to reason about
but introduces a second cell kind (which we just unified away).

**Option C: Programs as values** (no special cell kind)
```
inductive Val where
  | str     : String → Val
  | none    : Val
  | error   : String → Val
  | program : ProgramText → Val    -- NEW: a program is a value
```

A cell yields a `Val.program`. The runtime recognizes it and pours.
No new cell kind. No changed CellBody signature. The magic is in
the runtime's handling of program-valued yields, not in the cell
definition.

**I favor Option C.** It's the simplest. It doesn't change the
denotational model at all — it extends the value domain. And it
makes programs first-class values: they can be stored, passed as
givens, inspected, transformed. This is reification.

The autopour annotation in the cell syntax:
```
cell generator
  yield sub_program [autopour]
  ---
  Generate a program...
  ---
```

is syntactic sugar for: "this yield field contains a program value;
the runtime should pour it after freeze."

---

## 3. Operational Semantics of Autopour

When the piston submits a yield of type `Val.program`:

```
submit(handle, yields_including_program, bindings)(S) =
  let S₁ = normal_submit(handle, yields, bindings)(S)
  for each yield y in yields where y.value is Val.program:
    if fuel(S₁) > 0 then
      let prog = parse(y.value)
      if prog = None then     -- parse failure
        S₁ with { yield y := Val.error "autopour: parse failure" }
      else
        let S₂ = pour(prog, fuel(S₁) - 1)(S₁)
        S₂
    else
      S₁ with { yield y := Val.error "autopour: fuel exhausted" }
```

Key decisions:
1. **Parse failure = bottom.** If the yielded program text doesn't
   parse, the yield becomes an error. The program that would have
   been poured is replaced by a bottom value. Downstream cells that
   depend on the poured program's yields get bottom propagation.

2. **Fuel is checked before pour.** The fuel counter lives in the
   evaluation context (not in individual cells). It decrements on
   each autopour. When fuel = 0, the yield is capped to error.

3. **Pour happens after submit.** The parent cell finishes first.
   Then the poured program enters the retort. This means the parent
   can observe the poured program's yields only if it has a way to
   reference them (dynamic observe — a separate feature).

4. **The poured program is independent.** It has its own cells, its
   own DAG, its own evaluation trace. It shares the retort (tuple
   space) with the parent program but has a distinct program_id.

---

## 4. Key Properties to Prove

### 4a. Effect Monotonicity for Autopour

If a cell at effect level E autopours a program P, then:
```
∀ cell ∈ P.cells, cell.effectLevel ≤ E
```

The poured program cannot exceed the parent's effect level. This
preserves the effect lattice: a Pure context stays pure. A Semantic
context can add Semantic cells but not NonReplayable ones.

**Proof strategy:** The runtime checks each cell in the poured program
against the parent's declared effect bound. If any cell exceeds it,
pour fails (bottom). This is a structural check, O(n) in cells.

### 4b. Fuel Termination

```
∀ initial fuel N, the total number of pours ≤ N.
```

Each pour decrements fuel by 1. Fuel starts at N. No pour creates
fuel. Therefore total pours ≤ N. This is trivially total.

**Consequence:** The autopour tower (program that pours a program
that pours a program...) has bounded depth = initial fuel. The
evaluation of all poured programs terminates (modulo individual
cell evaluation, which has its own termination arguments).

### 4c. Monotonicity Preservation

Autopour preserves the append-only invariant:

```
∀ S S', S' = autopour(S) →
  S.cells ⊆ S'.cells ∧
  S.yields ⊆ S'.yields ∧
  S.frames ⊆ S'.frames
```

Pour is append-only. Autopour is a sequence of pours. Therefore
autopour is append-only. No existing state is modified.

### 4d. DAG Preservation

The poured program's cells can depend on existing cells (cross-program
givens) but the dependency graph remains acyclic:

```
∀ cd ∈ P_poured.cells, ∀ d ∈ cd.deps,
  d.sourceCell ∈ P_poured.cells ∨ d.sourceCell is frozen in S
```

A poured cell can read from:
- Other cells in the same poured program (normal DAG)
- Already-frozen cells in the parent program (cross-program observe)
- NOT from cells that haven't been evaluated yet (would create cycles)

This preserves the DAG acyclicity of the overall retort.

---

## 5. The Self-Evaluation Question

Can cell-zero (with autopour) evaluate itself?

### Setup
```
cell cell-zero-meta
  given target.program_text     ← reify: get program as text
  yield evaluated [autopour]    ← autopour: pour the program
  ---
  Parse «program_text» and yield it for autopour.
  ---
```

### What happens when target = cell-zero-meta?

1. cell-zero-meta receives its own definition as input
2. It parses and yields a copy of itself
3. The runtime pours the copy (fuel - 1)
4. The copy has a `given target.program_text` — from where?
5. Nobody provides it → the copy's given is unsatisfied
6. The copy is inert. Self-evaluation terminates **naturally**.

**KEY INSIGHT: Cell's dependency DAG provides natural termination
that lambda calculus lacks.** In lambda calculus, (λx.xx)(λx.xx)
diverges because application is immediate. In Cell, the poured copy
has unsatisfied dependencies and simply doesn't fire. The DAG acts
as a natural termination condition — no fuel needed for this case.

Fuel is needed only for **chained** autopour: program A pours B,
B pours C, C pours D... Each pour decrements fuel. At fuel=0,
autopour yields bottom.

### When does self-evaluation actually loop?

Only when the poured copy's dependencies are ALSO satisfied:

```
cell self-loop
  given self.definition           ← reify: own definition
  yield copy [autopour]           ← autopour: pour a copy
```

If `self.definition` is a built-in that always resolves (returns the
current cell's definition), then the poured copy also has a satisfied
`self.definition`, and we get:

```
self-loop(n) → pour(self-loop(n+1)) → pour(self-loop(n+2)) → ...
```

THIS is the Y combinator case. This terminates at fuel = 0.

### The two termination mechanisms

1. **DAG termination** (natural): poured copy has unsatisfied
   dependencies → doesn't fire → no loop. FREE. No fuel needed.

2. **Fuel termination** (bounded): poured copy has satisfied
   dependencies AND autopours → loop → fuel decrements → bottom.

The practical evaluator (cell-zero-autopour.cell) uses mechanism 1.
The pathological case (self-referencing autopour) uses mechanism 2.
Both are correct. Both terminate.

### The tower of interpreters

When fuel IS consumed (chained autopour), we get Sussman's tower:
```
Layer 0: cell-zero-meta evaluates program P
Layer 1: if P autopours Q, Q enters the retort
Layer 2: if Q autopours R, R enters the retort
...
Layer N: fuel exhausted, autopour yields bottom
```

Each layer is a complete evaluation context. The formal model is a
**coinductive** structure (potentially infinite, productive at each
step) truncated by the fuel bound to a **finite** prefix.

---

## 6. The Reify Primitive

Autopour needs reify (otherwise, what does the metacell operate on?).

### Option A: SQL-level reify (current hack)

cell-zero-eval reads from the `cells` table:
```sql
SELECT body FROM cells WHERE name = ?
```

This is reflection (unsafe). It couples the language to the store.

### Option B: First-class reify (language primitive)

A new given qualifier:
```
cell inspector
  given target.definition    ← returns CellDef as structured data
  yield analysis
```

Where `definition` is a special built-in field that returns the cell's
definition as a `Val.record`:
```
{ name: "target",
  body: "...",
  bodyType: "soft",
  effectLevel: "semantic",
  deps: [...],
  outputs: [...] }
```

This is reification (safe). The cell gets a read-only data view of
another cell's definition. It cannot modify the definition. It can
inspect, analyze, transform, and yield a new program based on it.

### Option C: Program-level reify

Instead of individual cells, reify an entire program:
```
cell program-inspector
  given target_program.source    ← returns entire program text
  yield analysis
```

This is simpler (one field, not a structured record) but less
compositional (you get a blob of text, not structured data).

**I favor Option B (structured reify)** for the formal model, with
**Option C (program-level reify)** as syntactic sugar for practical
use. The structured form enables formal reasoning; the text form
enables practical metacircular evaluation.

---

## 7. Design Decisions Summary

| Decision | Recommendation | Rationale |
|----------|---------------|-----------|
| How to add programs to Val | Option C: Val.program | Simplest, no new cell kind |
| When does pour happen | After parent cell submits | Clean separation of concerns |
| Parse failure | Bottom (error value) | Consistent with existing error handling |
| Fuel location | Evaluation context, not cell | Global resource, not per-cell |
| Effect check | Runtime verifies at pour time | O(n) structural check |
| Reify mechanism | Structured built-in field | Safe, compositional, formal |
| Self-evaluation | Fuel-bounded divergence | Correct, matches λ-calculus |

---

## 8. What This Means for the Foundation

Autopour adds ONE new value constructor (Val.program) and TWO new
runtime operations (pour-on-yield, reify-on-given). Everything else
— the CellBody type, the effect lattice, the DAG structure, the
tuple space operations — remains unchanged.

The formal additions are:
1. Extend `Val` with `| program : ProgramText → Val`
2. Define `autopour_step` in the operational semantics
3. Add fuel to the evaluation context
4. Prove the four properties (4a-4d above)

This is a small, well-defined extension. It completes the language:
with autopour and reify, cell can express its own evaluator without
leaving the language.

**Evaluation reduces M. Autopour lets M reduce itself.**

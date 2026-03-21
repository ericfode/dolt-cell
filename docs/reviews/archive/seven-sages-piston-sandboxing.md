# Seven Sages Review: Piston Sandboxing & Execution Model

**Date**: 2026-03-18
**Topic**: Sandboxing, piston capabilities, and fundamental flaws in the execution model
**Trigger**: 17 programs stress-tested, 6 bugs filed, zero capability enforcement observed

---

## The Question

How do we ensure pistons can collaborate on work but aren't wild and free? How do we balance capability vs. safety, make it elegant to express in the cell language, and actually possible to build?

---

## Feynman (Physicist): The Missing Conservation Law

**Grade: D** (on capability control — the formal model doesn't address it)

The formal model proves traffic lights work. It says nothing about what the cars do once through the intersection. The `wellFormed_preserved` theorem covers database transitions — claim, freeze, release — but evaluation lives *between* claim and freeze, and that's where pistons run arbitrary SQL, call LLMs, and in `cell-zero-eval`, INSERT and UPDATE arbitrary rows.

**The fundamental issue**: The transition system has three operations, and NONE say what happens during evaluation. The model treats `CellBody` as a black box: `Env → M (Env × Continue)`. Where did the value come from? The model doesn't know and doesn't ask.

**The conservation principle**: A piston's observable effects cannot exceed the transitive closure of its claimed frame's dependency graph. What goes in (givens) determines what you can see. What comes out (yields) determines what you can change. Everything else is forbidden. This is conservation of information flow.

**The one mechanism**: Add `Scope` to the formal model — computed at claim time from the cell's givens and yield declarations:

```
structure Scope where
  readableYields : List (FrameId × FieldName)
  writableYields : List (FrameId × FieldName)
```

Every operation between claim and freeze must satisfy: reads ∈ `readableYields`, writes ∈ `writableYields`. The effect lattice becomes a *capability lattice*:

- **Pure**: reads only declared givens, writes only declared yields, deterministic
- **Semantic**: same data scope as Pure, but non-deterministic (LLM)
- **Divergent**: can read/write across program boundaries, can spawn cells, can loop

The effect lattice and capability lattice are the same question asked two ways.

---

## Iverson (Notation Designer): Make Capability Visible in the Syntax

**Grade: C** (the language has zero notation for capability)

The annotation position already exists: `(stem)` on the cell declaration line. Extend it:

```
cell verify (pure, sql:read)
  given solve.x
  yield check
  ---
  sql: SELECT CASE WHEN ... THEN 'PASS' ELSE 'FAIL' END
  ---

cell investigate (stem, io)
  given incident.description
  yield findings
  ---
  Check system logs and reproduce the issue...
  ---

cell triage (semantic)
  given incident.description
  yield category
  ---
  Classify this incident by severity...
  ---
```

**The capability vocabulary**:

| Grant | Meaning |
|---|---|
| `sql:read` | SELECT only. Parser rejects write operations |
| `sql:write` | DML allowed (INSERT, UPDATE, DELETE). Requires `dml:` body prefix |
| `sql:ddl` | Schema mutation. Must be explicit |
| `io` | Shell access, file system, external tools |
| `net` | Network requests |
| (none) | Pure computation |

**Critical design choice**: `sql:read` is the DEFAULT for `sql:` bodies. `sql:write` must be opted into. The parser enforces this statically — a `sql:` body containing `DROP TABLE` on a cell declared `(pure, sql:read)` is a parse error at pour time, not a runtime surprise.

**Default inference** (backward compatible):
- `yield x = "literal"` → `(pure)`, no capabilities
- Soft cell with body text → `(semantic)`
- `sql: SELECT ...` → `(pure, sql:read)`
- `(stem)` → `(divergent)`

**Grammar extension**: Seven new tokens, zero new indented keywords:

```
cell-decl   := "cell" NAME annotations?
annotations := "(" annotation ("," annotation)* ")"
annotation  := "pure" | "semantic" | "divergent"
             | "stem" | "sql:read" | "sql:write" | "sql:ddl" | "io" | "net"
```

---

## Dijkstra (Formalist): Five Missing Proof Obligations

**Grade: D** (on piston safety — the model proves bookkeeping, not behavior)

The model treats cell evaluation as a mathematical oracle. The `bodiesFaithful` predicate in `Refinement.lean` is an *assumption*, not a theorem. The entire behavioral refinement (Theorem 11, `frozen_frame_outputs_match`) is conditional on this assumption. The "if" does all the work.

**Five missing obligations**:

1. **Input confinement**: A piston should read only the yields specified by its frame's resolved bindings. Nothing prevents reading any row in any table.

2. **Output conformance**: `freezeValid` checks structural correctness of yields but not that values are well-formed or related to inputs.

3. **Side-effect freedom**: Nothing prevents arbitrary SQL during the evaluation window. The claim grants frame exclusivity, not database exclusivity.

4. **Termination**: `finite_program_terminates` assumes each step completes. No formal timeout contract.

5. **Semantic oracle honesty**: The Go runtime logs `"not machine-checked yet — piston self-judges"`. This is a prayer, not a proof obligation.

**The weakest precondition for safe piston evaluation**:

> wp(P, F) := piston reads only from yields identified by F's bindings; produces exactly the yields declared in F's cell definition with values satisfying all oracles; causes no side effects outside F's yield slots; and terminates within bounded time.

**The fundamental tension**: An LLM piston is not a function. It is not deterministic or reproducible. You cannot establish `bodiesFaithful` a priori. What you CAN do:

1. **Enforce preconditions mechanically**: sandbox the piston, provide exactly the resolved bindings and nothing else
2. **Verify postconditions mechanically**: check all oracles before freezing (currently yields are written BEFORE oracle checks — unsound)
3. **Bound the damage**: if a piston violates its contract, bottom the frame immediately

**Five runtime invariants for untrusted pistons**:
- (a) Claim timeout: auto-release after T seconds
- (b) Write confinement: piston writes restricted to its frame's yield slots
- (c) Read confinement: piston sees only resolved bindings + cell body
- (d) Validate-then-write: oracles checked BEFORE yield insertion (currently reversed)
- (e) Bottom is total: timeout → bottom, not hang

---

## Milner (Type Theorist): Type the Piston Protocol

**Grade: D** (the protocol is stringly-typed with no session discipline)

**The session type**:

```
PistonSession = &{ claim: CellId .
                    ⊕{ dispatch: CellSpec . result: YieldValue . PistonSession,
                       timeout: end } }
```

The claim produces a *linear capability* — a token consumed by submission. You cannot submit without the token, and you cannot use a token for a cell you didn't claim. Currently `ct submit` takes a cell_id as a positional argument. This is wrong. The cell_id should be a bound variable from the claim, not a free argument.

**Process isolation via channel restriction**: In the pi-calculus, `(ν x)` creates a name visible only within scope. A piston's view should be constructed by restriction: it receives channels only for its authorized cells. You cannot send on a channel you do not have.

**Capability as type, not check**:

```
type ClaimedPiston<C: CellId> = {
  submit: (value: YieldType<C>) -> Result,
  release: () -> ()
}
```

The generic parameter `C` ensures at the type level that a piston can only submit yields of the type cell C expects, only to cell C.

**Inter-piston communication**: Pistons communicate through a shared tuple space (yields table). This is Linda, not pi-calculus. The cell DAG is the type environment: each edge is a typed channel. Cell 5 depending on cell 3 means cell 3's yield type must be compatible with cell 5's input type.

> Well-typed pistons do not go wrong. But first, they must be typed at all.

---

## Hoare (Verification): The Complete Contract and the Billion-Dollar Mistake

**Grade: D** (contracts are half-built — preconditions exist, capability contracts are absent)

**The contract that SHOULD exist**:

```
{  P1: frameReady(r, f) ∧ frameClaim(r, f.id) = none ∧ wellFormed(r)
   P2: cap(piston) >= requiredCapabilities(f.cellName)
   P3: reads(piston) ⊆ visibleYields(f)
   P4: writes(piston) ⊆ {yields(f.id)} ∪ {bindings(f.id)}
   P5: cost(body) <= budget(piston)
}
   piston evaluates cell body
{  Q1: frameStatus(r', f) = frozen ∧ appendOnly(r, r') ∧ wellFormed(r')
   Q2: ∀ y ∈ newYields(r', f.id), oraclesPass(f, y)
   Q3: modifiedTables(r, r') ⊆ {yields, bindings, claims, trace}
   Q4: ∀ f' ≠ f, frameYields(r', f'.id) = frameYields(r, f'.id)
}
```

Preconditions P2–P5 and postconditions Q3–Q4 are **entirely absent**.

**The oracle soundness bug**: `cell_submit` in `procedures.sql` writes the yield THEN checks oracles. A failing oracle leaves a written-but-unfrozen yield in the database. The correct order: validate, then write. The current implementation violates the formal model's append-only invariant (the procedure DELETEs then re-INSERTs on retry).

**The billion-dollar mistake**: The absence of capability distinction between `sql: SELECT ...` and `sql: DROP TABLE ...`. Both are `body_type = 'hard'`. Both pass through `PREPARE/EXECUTE`. The only barrier is a string-prefix filter that doesn't run inside stored procedures. A cell with `sql: SELECT * FROM cells WHERE 1=1 UNION SELECT * FROM mysql.user` has the same contract as `literal:hello`.

> Fix this before it becomes your billion-dollar lesson.

---

## Wadler (Functional Programmer): The Effect Algebra

**Grade: C-** (the effect lattice exists in the model but is decorative — `M = Id` everywhere)

The comment `M = Id` in `Denotational.lean` is not simplification. It is erasure. The formal model parameterises `CellBody` over M, then instantiates `M = Id` at every call site. The types say "pure." The implementation says "IO."

**The free monad over graded effects**:

```
data PistonOp : EffectLevel -> Type -> Type where
  Lookup   : FieldName -> PistonOp Pure String
  Yield    : FieldName -> String -> PistonOp Pure ()
  LLMCall  : String -> PistonOp Semantic String
  SQLExec  : String -> PistonOp Divergent String
  SQLQuery : String -> PistonOp Divergent String
  Spawn    : CellDef -> PistonOp Divergent ()

data Cell (e : EffectLevel) (a : Type) where
  Pure : a -> Cell e a
  Bind : PistonOp e x -> (x -> Cell e a) -> Cell e a
```

**Critical property**: `Cell Pure a ≅ a`. Pure cells are the identity monad. So `M = Id` is correct *only for Pure cells*. The lie is using it for everything.

**Eleven algebraic laws** including:
- Law 4: Pure Embedding — `Cell Pure a ~ a`
- Law 6: Pure Program Determinism — same inputs, same trace
- Law 8: Pure Cell Cacheability — referential transparency
- Law 10: SQL Query Purity — read-only SQL over an immutable Dolt generation is deterministic

**The sandbox via types, not strings**: A `sandboxHandler : Handler Semantic` has no case for `SQLExec`. The type system enforces the sandbox — there is nothing to match, nothing to evade, nothing to maintain. This replaces the string-prefix allow-list in `sandbox.go` with a type-level guarantee.

---

## Sussman (Systems Thinker): Branch-Per-Piston — The Buildable Sandbox

**Grade: C** (the architecture has no isolation boundary, but a practical path exists)

You do not have a security problem. You have an **authority problem.** Every piston runs as root on a shared database.

**The 80/20 — branch-per-piston**:

When a piston claims a cell, the runtime creates a Dolt branch `piston/{id}`. The piston's SQL connection uses that branch. It can read, write, trash the whole thing — the worst it can do is destroy its own branch. The runtime merges results back to `main` only after validating the yield through `ct submit`.

This is not theoretical. Dolt branches are copy-on-write. They are fast. The merge machinery exists. The branch IS the sandbox.

**Layered architecture**:
- Piston process: reads prompts, produces yields. Never touches runtime tables on main.
- Runtime process (`ct`): owns the merge. Validates yields, checks oracles, merges to main.
- The piston is an untrusted worker. The runtime is the authority.

**Meta-circularity** (`cell-zero-eval`): Meta-pistons get a distinct privilege level. They still work on branches, but the merge policy allows writing to `cells` and `yields`. Regular piston merges can only write to `yields`. Authority is in the merge policy, not the piston's connection.

**What will NOT work**:
- Separate Dolt users per piston — Dolt auth is too thin, weeks of work for minimal benefit
- Separate Dolt processes per piston — operational suicide, Dolt is already the bottleneck
- Capability tokens passed to LLMs — LLMs lose tokens, hallucinate tokens, share them in context
- Parsing/validating SQL before execution — never catch everything, branch sandbox makes it unnecessary

---

## Consensus: Seven Sages Agree

### 1. The execution model has a god-mode gap

All seven agree: the formal model proves database transitions are safe but says nothing about what happens during evaluation. The `bodiesFaithful` assumption is the rug everything is swept under. The claim mutex is necessary but wildly insufficient — it's a lock on the door with no walls.

### 2. Scope computed from the DAG is the right primitive

Feynman's conservation principle, Dijkstra's read/write confinement, Hoare's P3/P4 preconditions, Milner's channel restriction, and Sussman's branch isolation all describe the same thing: **a piston should see exactly what its cell's givens grant, and write exactly what its cell's yields declare**. The DAG IS the capability graph.

### 3. The effect lattice must become computational, not decorative

Wadler's free monad, Iverson's annotations, and Feynman's capability lattice converge: `Pure < Semantic < Divergent` should control what operations are available, not just label them. The `M = Id` lie in the formal model must end. Effect levels should be:
- Inferred from the cell body by the parser (backward compatible)
- Declared explicitly for override (`cell X (divergent, sql:write)`)
- Enforced by the runtime (Semantic pistons cannot issue SQL mutations)

### 4. Yields must be validated BEFORE writing (Hoare's billion-dollar finding)

The `cell_submit` procedure writes yields then checks oracles. This is unsound — a failed oracle leaves artifacts in the database. The order must be: validate, THEN write. This is not a theoretical concern; it violates the formal model's append-only invariant.

### 5. Branch-per-piston is the buildable foundation (Sussman's 80/20)

Dolt branches provide copy-on-write isolation that is cheap, real, and already built. The implementation path:
1. Claim creates a branch
2. Piston operates on its branch (can't hurt main)
3. Runtime validates yield on the branch
4. Runtime merges to main (the authority boundary)
5. Branch dropped

This makes SQL sandboxing moot for regular pistons — they can run whatever SQL they want on their own branch. The merge policy IS the sandbox.

---

## Priority Actions

| # | Action | Sages | Effort | Impact |
|---|--------|-------|--------|--------|
| 1 | **Fix oracle ordering**: validate yields BEFORE writing to DB | Hoare, Dijkstra | 1 day | Critical — currently unsound |
| 2 | **Add effect annotations to cell syntax**: `(pure)`, `(semantic)`, `(divergent)` + capabilities | Iverson, Wadler | 2 days | High — makes capability visible |
| 3 | **Implement branch-per-piston isolation** | Sussman | 3 days | High — the buildable sandbox |
| 4 | **Add `Scope` to formal model**: readable/writable yields computed from DAG | Feynman, Dijkstra | 2 days | High — closes the god-mode gap |
| 5 | **Split `sql:` into `sql-query:` (Pure) and `sql-exec:` (Divergent)** | Wadler, Iverson | 1 day | High — SQL is the biggest hole |
| 6 | **Type the piston protocol**: session types, linear claim tokens | Milner | 2 days | Medium — prevents cross-cell submission |
| 7 | **Replace `M = Id` with graded free monad in formal model** | Wadler, Feynman | 3 days | Medium — makes effect lattice honest |

**Total estimated effort**: 14 days. Items 1-2 can proceed in parallel. Item 3 is the infrastructure that makes 4-7 enforceable.

---

## The Design in One Sentence

> A piston's capabilities are the transitive closure of its cell's declared givens and yields, enforced by Dolt branch isolation at the infrastructure level and graded effect types at the language level.

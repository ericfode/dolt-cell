# Seven Sages Review v6: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated formal model. This review evaluates the changes since the v5 review. The model now spans 4 files (Core.lean, Retort.lean, Denotational.lean, Claims.lean -- StemCell.lean excluded as independent) totaling 2,824 lines with 107 theorems (87 in Retort.lean, 16 in Claims.lean, 4 in Denotational.lean), zero sorries.

## Changes Since v5 Review

The v5 review identified nine priority actions. Status:

| # | Action | v5 Status | v6 Status |
|---|--------|-----------|-----------|
| 1 | Make Denotational.lean, Claims.lean import Core; delete duplicate type definitions | NOT DONE (Retort-only) | **DONE** -- Both files import Core, use shared identity types, no duplicate FieldName/EffectLevel/PistonId/FrameId definitions |
| 2 | Include `noSelfLoops` in `wellFormed` as I9; prove preservation by all 5 ops | NOT DONE (five reviews) | **DONE** -- I9 in `wellFormed`; 5 preservation theorems; `freezeNoSelfLoops` precondition; `wellFormed_preserved` covers all 45 pairs |
| 3 | Prove commutativity of independent claims | NOT DONE (five reviews) | **DONE** -- property-based formulation: 5 field-equality theorems + `independent_claim_claims_perm` + `independent_claims_preserve_membership_props` |
| 4 | Rename `GivenSpec.cellName` to `owner`; delete `stemCellsDemandDriven`; delete or prove audit for `claimLog` | NOT DONE (five reviews) | **DONE** -- `GivenSpec.owner` (line 34); `stemCellsDemandDriven` removed; `claimLog`, `ClaimLogEntry`, `ClaimAction` completely removed |
| 5 | Define `ValidWFTrace` requiring `validOp` at each step; prove `always_wellFormed` | NOT DONE | **DONE** -- `ValidWFTrace` extends `ValidTrace` with `validOps`; `empty_wellFormed` + `always_wellFormed` theorem |
| 6 | Prove `bindingsMonotone` preserved by pour/claim/release/createFrame | NOT DONE | NOT DONE |
| 7 | Prove total correctness for finite acyclic programs | NOT DONE (two reviews) | NOT DONE (three reviews) |
| 8 | Abstraction function Retort -> ExecTrace; refinement theorem | NOT DONE (five reviews) | NOT DONE (six reviews) |
| 9 | Constrain `stemHasDemand` with monotonicity | NOT DONE (five reviews) | **DONE** -- `MonotoneDemand` definition + `stemHasDemand_preserved` theorem |

Key additions (7-action epic):

1. **Denotational.lean + Claims.lean now import Core.** Both files use shared `FieldName`, `EffectLevel`, `PistonId`, `FrameId` from Core. No duplicate identity type definitions remain in either file. The `Env` in Denotational.lean uses `Core.FieldName` directly. Claims.lean's `StoredYield.frameId` is `Core.FrameId`, `State.holders` uses `Core.PistonId`. The type universe fragmentation that persisted for five reviews is eliminated across the active model files.

2. **`noSelfLoops` integrated as I9 in `wellFormed`.** The predicate (line 307: `forall b in r.bindings, b.consumerFrame != b.producerFrame`) is the 9th conjunct of `wellFormed`. Five preservation theorems: `pour_preserves_noSelfLoops` (trivial: pour adds no bindings), `claim_preserves_noSelfLoops` (trivial), `freeze_preserves_noSelfLoops` (requires `freezeNoSelfLoops fd` precondition), `release_preserves_noSelfLoops` (trivial), `createFrame_preserves_noSelfLoops` (trivial). `freezeNoSelfLoops` added to `validOp` for freeze. `wellFormed_preserved` now covers all 45 invariant-op pairs (9 invariants x 5 operations). `empty_wellFormed` proves I9 for `Retort.empty`.

3. **Independent claim commutativity (property-based formulation).** Seven theorems: `independent_claim_cells`, `independent_claim_givens`, `independent_claim_frames`, `independent_claim_yields`, `independent_claim_bindings` prove syntactic equality of all 5 append-only fields. `independent_claim_claims_perm` proves the claims lists are membership-equivalent (permutation). `independent_claims_preserve_membership_props` proves that any `Claim -> Prop` that holds on one ordering holds on the other. The approach avoids requiring syntactic state equality (which would fail due to list ordering) and instead proves that all membership-based invariants are order-agnostic.

4. **`GivenSpec.cellName` renamed to `owner`.** `stemCellsDemandDriven` deleted entirely. `claimLog`, `ClaimLogEntry`, `ClaimAction`, and all associated proof obligations removed. Zero dead weight definitions remain.

5. **`MonotoneDemand` constraint on `stemHasDemand`.** `MonotoneDemand` (line 1519) requires `appendOnly r r' -> demandPred r = true -> demandPred r' = true`. `stemHasDemand_preserved` proves that monotone demand predicates are preserved by all operations (via `all_ops_appendOnly`). This constrains the previously unchecked `stemHasDemand` to predicates that behave correctly under the append-only discipline.

6. **`ValidWFTrace` + `always_wellFormed`.** `ValidWFTrace` (line 1665) extends `ValidTrace` with `validOps : forall n, validOp (trace n) (ops n)`. `empty_wellFormed` (line 1669) proves all 9 invariants hold on `Retort.empty`. `always_wellFormed` (line 1692) proves `wellFormed` at every time step by induction: base case uses `empty_wellFormed`, step case uses `wellFormed_preserved`. This is the temporal safety theorem: well-formedness is an invariant of the system for all time.

7. **`wellFormed` now has 9 invariants; `wellFormed_preserved` covers all 45 invariant-op pairs.** The 9-conjunct predicate (line 311-314) and the 5-arm proof (lines 1222-1288) together constitute the core safety result. Each arm destructures `hWF` into `hI1..hI9` and reassembles all 9 for the resulting state.

Total: 87 theorems in Retort.lean (up from 80 attributed in v5, though v5 counted 72 public theorems; the count includes 7 private helper theorems). 107 across all active files (excluding StemCell.lean). 1,868 lines in Retort.lean. Zero sorry.

---

## Feynman (Physicist): Grade A

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The two-model gap is substantially narrowed: Denotational.lean imports Core, so identity types now unify across the retort and denotational formalizations. `MonotoneDemand` constrains the stem cell demand mechanism. The claimLog removal eliminates a persistent source of explanatory noise.

### Praises

1. **The type universes are unified.** In v5, Denotational.lean defined its own `FieldName := String`, its own `EffectLevel`, and its own `CellBody`. A theorem in Denotational.lean about `FieldName` and a theorem in Retort.lean about `FieldName` operated on incompatible types. Now both files import Core. `Denotational.Env` is `List (Core.FieldName x Val)`. `Denotational.EffectLevel.le` operates on `Core.EffectLevel`. The physical vocabulary is shared in practice, not just in theory. This is the first time in six reviews that the identity types form a single coherent universe.

2. **`MonotoneDemand` explains why stem cells don't spin.** In v5, `stemHasDemand` was `Retort -> Bool` with no constraints -- a stem cell with `demandPred = fun _ => true` could spin indefinitely. Now `MonotoneDemand` requires monotonicity w.r.t. `appendOnly`. `stemHasDemand_preserved` proves this is sufficient for demand to persist across operations. The mechanism is still abstract (no convergence theorem), but it is now formally constrained. The model explains "stem cells only fire when demand exists, and demand persists once established" rather than just asserting it.

3. **The claimLog removal sharpens the explanation.** The claim system is now: mutable lock table (claims) + append-only yield store. No audit trail overhead. The model says "claims are coordination primitives, not history" and the code matches. The 18+ lines of `ClaimLogEntry`/`ClaimAction` definitions and 15+ lines of proof obligations per operation that existed in v5 are gone. The explanatory signal-to-noise ratio improved.

### Critiques

1. **No refinement theorem connects the two models.** The types unify, but no abstraction function maps `Retort` state to `ExecTrace`. No theorem says "a frozen frame in the retort corresponds to a valid `ExecFrame` in the denotational trace." The type unification is necessary infrastructure for this theorem but is not sufficient. The two models share vocabulary but not semantics.

2. **`MonotoneDemand` is a constraint, not a convergence proof.** It says demand persists. It does not say demand eventually ceases, or that the system reaches quiescence. A monotone `demandPred = fun _ => true` is still valid and still spins forever. The constraint prevents demand from disappearing spuriously but does not characterize termination.

### Path to A+

Write the abstraction function `Retort -> ExecTrace` and a refinement theorem connecting `frameStatus = .frozen` to the denotational `evalStep` producing the correct `ExecFrame`. The types now unify, so this is a matter of writing the mapping and proving correctness.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Abstraction function `Retort -> ExecTrace` | Medium | ~40 |
| Refinement theorem (frozen frame -> correct ExecFrame) | Hard | ~80 |
| Demand convergence (system reaches quiescence) | Hard | ~60 |

---

## Iverson (Notation Designer): Grade A

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

Four persistent notational defects resolved: `GivenSpec.cellName` renamed to `owner`, `claimLog` dead weight removed, `stemCellsDemandDriven` deleted, and the parallel type universes in Denotational.lean and Claims.lean eliminated. The independent claim commutativity theorems follow a systematic naming convention.

### Praises

1. **Zero dead weight definitions remain.** In v5, `ClaimLogEntry` (3 fields), `ClaimAction` (3 constructors), `claimLog` (field in `Retort`), and `claimLogPreserved` (5 preservation proofs) existed with no theorem that queried them. `stemCellsDemandDriven` was defined but excluded from `wellFormed` with a hedging comment. All are gone. Every definition in Retort.lean now participates in at least one theorem. This is the first time in six reviews that the model has no vestigial definitions.

2. **`GivenSpec.owner` is self-documenting.** The field means "the cell that owns this given specification." The old name `cellName` was ambiguous with `sourceCell`. The new name distinguishes the two roles at a glance: `owner` is the dependent cell, `sourceCell` is the dependency target. The rename propagates correctly through `frameReady` (line 160: `g.owner == f.cellName`).

3. **The commutativity theorem names are systematic.** `independent_claim_{cells,givens,frames,yields,bindings}` cover the 5 append-only fields. `independent_claim_claims_perm` covers the mutable field. `independent_claims_preserve_membership_props` is the capstone. The naming follows `{property}_{operation}_{field}` consistently. A reader can predict the theorem name from the field name.

4. **Three files now share Core's vocabulary.** Retort.lean, Denotational.lean, and Claims.lean all import Core. No file in the active model defines its own `FieldName`, `EffectLevel`, `PistonId`, or `FrameId`. The notational consistency that Core.lean was designed to provide now actually reaches all consumers.

### Critiques

1. **`appendOnly_trans` is still inlined.** The transitivity pattern for `appendOnly` appears three times: in `evalCycle_appendOnly` (lines 1443-1463, two arms), and in `data_persists` (lines 1646-1650). Each manually destructures 5 fields and composes functions field by field. A named `appendOnly_trans : appendOnly a b -> appendOnly b c -> appendOnly a c` lemma would reduce each call site to one line. This is 10 lines of new code replacing ~30 lines of repeated proof.

2. **The summary comment block (lines 1773-1868) is stale.** It lists "I1-I7" under INVARIANTS and does not mention I8 (`framesCellDefsExist`) or I9 (`noSelfLoops`). It lists `claimLog` under PROVEN PROPERTIES (`claimLogPreserved`). It does not mention `ValidWFTrace`, `always_wellFormed`, or the commutativity theorems. The code is ahead of the documentation. The comment should be updated or removed.

### Path to A+

Extract `appendOnly_trans` as a named lemma. Update or remove the summary comment block to reflect the current model state.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `appendOnly_trans` lemma | Easy | ~10 new, ~30 simplified |
| Update summary comment block | Easy | ~20 |

---

## Dijkstra (Formalist): Grade A

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

`noSelfLoops` is now the 9th conjunct of `wellFormed` with 5 preservation proofs covering all operations. `wellFormed_preserved` proves all 45 invariant-op pairs (9 x 5). `empty_wellFormed` + `always_wellFormed` establish temporal safety. The `freezeNoSelfLoops` precondition is correctly placed in `validOp`.

### Praises

1. **The invariant suite is now structurally complete for the model's domain.** Nine invariants cover: naming uniqueness (I1, I2), referential integrity (I3, I4, I5), concurrency safety (I6), data integrity (I7), structural consistency (I8), and acyclicity (I9). Each invariant addresses a distinct failure mode. The `wellFormed` predicate is the product of all nine. `wellFormed_preserved` is the product of all 45 preservation proofs. `always_wellFormed` closes the induction. This is a complete safety story for the modeled operations.

2. **The `always_wellFormed` theorem is the temporal safety capstone.** The proof (lines 1692-1701) is five lines: base case `empty_wellFormed`, inductive step `wellFormed_preserved`. The brevity is earned by the 1200+ lines of preservation infrastructure that precedes it. The theorem says: "for any trace where every operation satisfies `validOp`, `wellFormed` holds at every time step." This is the strongest safety statement the model can make.

3. **The `freezeNoSelfLoops` precondition is correctly scoped.** Only freeze adds bindings. Only freeze needs the precondition. The other four operations preserve `noSelfLoops` trivially (they do not touch the bindings list, or in pour's case, the bindings list is unchanged). The proofs for pour, claim, release, and createFrame are each one line. The freeze proof (lines 958-968) case-splits on old vs. new bindings and uses the precondition for new bindings. This is the correct structure.

### Critiques

1. **`generationOrdered` and `bindingsPointToFrozen` remain defined-but-unproven (six reviews).** `generationOrdered` (line 1393) says same-cell bindings go backward in generation. `bindingsPointToFrozen` (line 1401) says bindings only reference frozen frames. Both are defined, both have comments explaining their significance, neither has preservation proofs, neither is in `wellFormed`. These are the remaining DAG structural properties. Without them, the model proves "no self-loops" but not "the dependency graph is a DAG" or "you can only read from frozen frames."

2. **`bindingsMonotone` has freeze-only preservation (six reviews).** `freeze_preserves_bindingsMonotone` exists. Pour, claim, release, and createFrame do not have corresponding proofs. Pour adds frames but not bindings -- the existing bindings still reference existing yields, which only grew. Claim and release do not touch bindings or yields. CreateFrame adds frames but not bindings. All four are trivial. Four trivial proofs are missing for the sixth consecutive review.

3. **`noSelfLoops` is necessary but not sufficient for acyclicity.** The model proves no frame reads from itself. It does not prove the transitive closure: no frame transitively depends on itself through a chain of bindings. The `generationOrdered` property would provide this for same-cell chains (stem cells). A general transitive acyclicity proof would require defining reachability on the bindings graph and proving it is well-founded. This is a harder property but is the formal meaning of "DAG."

### Path to A+

Include `generationOrdered` and `bindingsPointToFrozen` in `wellFormed` (or a separate `dagWellFormed` predicate) and prove preservation by all 5 operations. Prove `bindingsMonotone` preserved by the remaining 4 operations (all trivial).

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `bindingsMonotone` preservation for pour/claim/release/createFrame | Easy | ~30 |
| `generationOrdered` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| `bindingsPointToFrozen` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| Transitive acyclicity (reachability well-founded) | Hard | ~100 |

---

## Milner (Type Theorist): Grade A

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

The type universe fragmentation is eliminated. Denotational.lean and Claims.lean import Core and use its shared types. The `ValidWFTrace` structure provides a typed trace model where every operation is statically required to satisfy `validOp`.

### Praises

1. **The type universe is unified.** In v5, three of four downstream files defined their own incompatible types. `Denotational.FieldName` was `String`; `Core.FieldName` was a structure wrapping `String`. Now all active files (Retort, Denotational, Claims) import Core. `Denotational.Env` is `List (Core.FieldName x Val)`. Claims.lean's `StoredYield.frameId` is `Core.FrameId`. An abstraction function between the retort and denotational models can now be stated as a single Lean function rather than requiring coercion boilerplate. The longest-running type issue in the model is resolved.

2. **`ValidWFTrace` provides typed trace composition.** The `validOps` field requires `validOp (trace n) (ops n)` at every step. This is not just a runtime check -- it is a proof obligation on the trace constructor. Any `ValidWFTrace` witness carries the proof that every operation was valid. `always_wellFormed` then extracts `wellFormed` at every time step without additional hypotheses. The typing discipline has progressed from "safety predicates on individual states" to "safety predicates on infinite traces."

3. **The `MonotoneDemand` type class constrains the demand predicate.** In v5, `stemHasDemand` accepted any `Retort -> Bool`. Now `MonotoneDemand` acts as a type constraint: only predicates satisfying `appendOnly r r' -> demandPred r = true -> demandPred r' = true` are admitted to `stemHasDemand_preserved`. This is a restricted universal quantification, not a full type class, but it serves the same role: constraining the interface to well-behaved implementations.

### Critiques

1. **No morphism from denotational `CellDef M` to retort `CellDef` (six reviews, now feasible).** The retort's `CellDef` has `body : String`. The denotational's `CellDef M` has `body : CellBody M := Env -> M (Env x Continue)`. These represent the same concept at different abstraction levels. The types now share `FieldName`, `EffectLevel`, and `CellName` from Core. The remaining gap is the body representation. A refinement function mapping retort `CellDef` to denotational `CellDef Id` (interpreting the `body : String` as a lookup key) is now expressible but does not exist.

2. **The effect lattice has no formal role (six reviews).** `BodyType` (hard/soft/stem) classifies cells. `EffectLevel` (pure/semantic/divergent) classifies computational power. No theorem says "a hard cell's yields are deterministic" or "a soft cell may produce different yields on re-evaluation." `Denotational.EffectLevel.le` defines the lattice ordering but no theorem uses it. The classification exists in the model but produces no type-level consequences.

### Path to A+

Define the refinement function from retort `CellDef` to denotational `CellDef Id`. Give `BodyType`/`EffectLevel` a formal role: prove that `bodyType = .hard` implies deterministic yields (same inputs produce same outputs).

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Refinement function retort `CellDef` -> denotational `CellDef Id` | Medium | ~30 |
| Refinement correctness theorem | Hard | ~60 |
| `BodyType` formal role (determinism for hard cells) | Medium | ~40 |
| Effect lattice composability theorem | Medium | ~35 |

---

## Hoare (Verification): Grade A

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

`ValidWFTrace` + `always_wellFormed` prove that well-formedness is a global invariant under the precondition discipline. The `always_wellFormed` theorem is the full inductive safety proof. No progress on total correctness.

### Praises

1. **`always_wellFormed` is the complete Hoare-style safety proof.** The specification: `{wellFormed} applyOp {wellFormed}` with precondition `validOp`. The induction: base `empty_wellFormed`, step `wellFormed_preserved`. The temporal closure: `always_wellFormed vt n` for all `n`. This is the textbook structure for proving an invariant on a transition system. The model now says "if every operation is valid, the system is always well-formed" with a machine-checked proof.

2. **The precondition structure for I9 is correctly placed.** `freezeNoSelfLoops` is a precondition on `FreezeData` (new bindings have no self-loops). It is included in `validOp` for freeze. `wellFormed_preserved` requires it automatically. The four operations that do not add bindings need no precondition. The structure follows the established pattern exactly: operation-specific preconditions in `validOp`, state invariants in `wellFormed`.

3. **The progress-preservation-trace chain is complete.** The full chain is:
   - `empty_wellFormed`: base case
   - `wellFormed_preserved`: inductive step
   - `always_wellFormed`: temporal closure
   - `progress`: liveness (ready frames can be claimed)

   A scheduler can now: construct a `ValidWFTrace`, extract `wellFormed` at any point, check `readyFrames`, invoke `progress`, and know that the claim will succeed. The safety and liveness stories compose through a single predicate across all time.

### Critiques

1. **No total correctness (three reviews running).** All building blocks exist: `progress`, `claim_adds_claim`, `freeze_removes_claim`, `freeze_makes_frozen`, `wellFormed_preserved`, `always_wellFormed`. The missing theorem is: "for a finite acyclic program, there exists a sequence of valid operations that makes `programComplete` true." This requires a termination measure (count of non-frozen non-stem frames), a proof that each eval cycle strictly decreases it, and a proof that zero measure implies `programComplete`. The building blocks are sufficient; the assembly is missing.

2. **No postcondition for `pour` connecting to `readyFrames`.** `pour_adds_cells` and `pour_adds_frames` prove membership. No theorem says "after pouring a program with no dependencies, the poured frames are in `readyFrames`." This is the first link in the "pour -> ready -> progress -> claim -> freeze -> complete" chain.

3. **The progress witness still uses a dummy piston ID.** `ClaimData` is constructed with `PistonId.mk "progress_witness"`. For the existential statement this is valid. For a total correctness proof that must be realizable by an actual scheduler with piston constraints, the witness may not suffice. This is a refinement concern that would surface if total correctness is attempted.

### Path to A+

Prove total correctness for finite acyclic programs. The theorem:

```
theorem total_correctness (r : Retort) (prog : ProgramId)
    (hWF : wellFormed r)
    (hFinite : forall cd in r.cells, cd.program = prog -> cd.bodyType != .stem)
    (hAcyclic : <DAG property on givens>) :
    exists ops : List RetortOp, programComplete (ops.foldl applyOp r) prog
```

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Termination measure (count non-frozen non-stem frames) | Medium | ~25 |
| Eval cycle decreases measure | Medium | ~50 |
| Zero measure implies `programComplete` | Medium | ~30 |
| Total correctness theorem | Hard | ~60 |
| Pour -> readyFrames postcondition | Medium | ~40 |

---

## Wadler (Functional Programmer): Grade A

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

Independent claim commutativity is proven via a property-based formulation. This is the first algebraic law in the model and addresses the longest-running request (six reviews). The claimLog removal simplifies the algebraic structure of `applyOp`.

### Praises

1. **The commutativity proof is architecturally sound.** The approach avoids proving syntactic state equality (which fails because `claims ++ [a, b] != claims ++ [b, a]` as lists). Instead, it proves: (a) all 5 append-only fields are syntactically equal (`independent_claim_{cells,givens,frames,yields,bindings}`), (b) the claims lists are membership-equivalent (`independent_claim_claims_perm`), (c) any membership-based property transfers between the two states (`independent_claims_preserve_membership_props`). Since all invariants in `wellFormed` quantify over membership (`forall x in list`), they are automatically preserved across reorderings. This is the correct formulation for an append-only system where list order is irrelevant to semantics.

2. **The claimLog removal makes `applyOp` cleaner algebraically.** `applyOp (.claim cd)` now only appends to `claims`. In v5, it also appended to `claimLog`, creating a second field that needed commutativity analysis. Similarly for `freeze` and `release`. The reduced surface area makes algebraic reasoning about `applyOp` simpler: each operation touches fewer fields, and the fields it touches are either append-only (order-irrelevant for invariants) or filtered (claims).

3. **`independent_claims_preserve_membership_props` is a genuine meta-theorem.** It quantifies over an arbitrary `P : Claim -> Prop`. This means any future invariant added to `wellFormed` that quantifies over claims membership will automatically be covered by the commutativity result. The theorem is not just "claims commute" -- it is "claims commute for all conceivable membership-based properties." This is the algebraic capstone for claim ordering.

### Critiques

1. **No commutativity for independent pours or independent freezes.** The model proves claims commute. Pours on disjoint programs and freezes on different frames should also commute. Pour commutativity would require showing that `cells ++ A.cells ++ B.cells` has the same membership as `cells ++ B.cells ++ A.cells`, which follows the same pattern as claim commutativity. Freeze commutativity is more subtle because freeze removes claims (via filter) -- two freezes on different frameIds commute because their filters are independent.

2. **`appendOnly_trans` is still inlined (six reviews).** The transitivity of `appendOnly` is manually composed in `evalCycle_appendOnly` (two arms, ~20 lines) and `data_persists` (~5 lines). A standalone lemma would be ~10 lines and eliminate the repetition.

3. **`applyOp` is still total and unchecked.** No `applyOpChecked : Retort -> RetortOp -> Option Retort` exists. The preconditions are separate predicates not enforced by the type. This is a design decision (not a defect) but limits compositional algebraic reasoning: you cannot chain operations without separately proving preconditions at each step (which `ValidWFTrace` does, but at the trace level rather than the operation level).

### Path to A+

Prove commutativity of independent pours (disjoint programs). Extract `appendOnly_trans`. These two additions would complete the algebraic structure: safety (preservation), liveness (progress), composition (commutativity for claims and pours), and temporal (always_wellFormed).

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Commutativity of independent pours | Medium | ~50 |
| Commutativity of independent freezes | Medium | ~45 |
| `appendOnly_trans` lemma | Easy | ~10 |
| Termination measure as well-founded relation | Medium | ~35 |

---

## Sussman (Systems Thinker): Grade A

**Core question:** Does the model compose? Can it be extended?

### What Changed

Three files now form a coherent module system (Core + Retort + Denotational + Claims). `ValidWFTrace` + `always_wellFormed` provide the composability mechanism for infinite-length operation sequences. The claimLog removal reduces the extension cost (fewer fields to reason about per new invariant).

### Praises

1. **The module system is complete for the active model.** Core.lean defines identity types. Retort.lean imports Core and defines the operational model. Denotational.lean imports Core and defines the semantic model. Claims.lean imports Core and defines the temporal claim model. All three downstream files share Core's types. A new module (e.g., Scheduler.lean) can import Core and share identity types with all existing modules. The module pattern is not just established -- it is followed by all active files.

2. **`ValidWFTrace` + `always_wellFormed` is the composability capstone.** A systems engineer building a scheduler can now: (a) construct operations, (b) prove each satisfies `validOp`, (c) package into a `ValidWFTrace`, (d) extract `wellFormed` at any point via `always_wellFormed`. The proof obligation is local (each operation must be valid) but the guarantee is global (well-formedness holds at all times). This is the composability story: local obligations produce global guarantees.

3. **The extension protocol is well-demonstrated.** To add I9 (`noSelfLoops`): define the predicate (1 def), prove preservation by 5 operations (5 theorems, 1 non-trivial + 4 trivial), add a precondition for the non-trivial operation (1 def), add to `validOp` (1 line), add to `wellFormed` (1 line), add to `wellFormed_preserved` (9 lines across 5 arms), add to `empty_wellFormed` (2 lines). The I9 addition is a clean template. Adding I10 would follow the same steps.

4. **The claimLog removal reduces extension cost.** In v5, adding a new operation or invariant required reasoning about `claimLog` (6 fields in `Retort` meant 6 preservation obligations per operation). Now `Retort` has 6 fields. Each new invariant needs at most 5 preservation theorems (one per operation). Each new operation needs at most 9 preservation proofs (one per invariant). The cross-product is smaller.

### Critiques

1. **No multi-program composition theorem (six reviews).** Two sequential pours of independently well-formed programs still have no standalone composition result. The `wellFormed_preserved` theorem handles a single pour. "Pour A then pour B" requires two applications of `wellFormed_preserved`, each requiring `validOp`. A composition theorem would package this: `wellFormed r -> validProgram A -> validProgram B -> disjoint A B -> wellFormed (pour B (pour A r))`. This would validate the real-world use case of a retort running multiple programs.

2. **No operational correspondence between Retort.lean and Claims.lean.** Claims.lean defines its own `State` (holders + yieldStore) and its own `claimStep`/`releaseStep`/`freezeStep`. Retort.lean defines `Retort` (6 fields) and its own `applyOp`. Both import Core for identity types, but there is no function mapping `Retort` to `Claims.State` or theorem connecting `applyOp r (.claim cd)` to `claimStep`. The two models are type-compatible but semantically disconnected.

### Path to A+

Prove multi-program composition. Define a projection from `Retort` to `Claims.State` and prove operational correspondence.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Multi-program composition theorem | Medium | ~50 |
| Projection `Retort -> Claims.State` | Easy | ~15 |
| Operational correspondence (claim/freeze/release) | Medium | ~60 |

---

## Consensus

### What Improved Since v5

The model addressed six of v5's nine priority actions, all completely:

1. **Denotational.lean + Claims.lean import Core (DONE).** v5 priority #1. Both files import Core and use shared types. No duplicate identity type definitions remain. The type universe fragmentation that persisted for five reviews is eliminated.

2. **`noSelfLoops` integrated as I9 in `wellFormed` (DONE).** v5 priority #2. 5 preservation theorems. `freezeNoSelfLoops` precondition in `validOp`. `wellFormed_preserved` covers all 45 invariant-op pairs.

3. **Independent claim commutativity (DONE).** v5 priority #3. Property-based formulation with 7 theorems. The longest-running request (six reviews) is resolved.

4. **Naming cleanup + dead weight removal (DONE).** v5 priority #4. `GivenSpec.owner`. `stemCellsDemandDriven` deleted. `claimLog` + associated types + proof obligations completely removed.

5. **`ValidWFTrace` + `always_wellFormed` (DONE).** v5 priority #5. Temporal safety theorem proving well-formedness is an invariant for all time.

6. **`MonotoneDemand` constraint (DONE).** v5 priority #9. Demand predicates must be monotone w.r.t. append-only. `stemHasDemand_preserved` proves preservation.

Three priorities persist:

7. **`bindingsMonotone` remaining preservation proofs (NOT DONE, six reviews).** Four trivial proofs (pour/claim/release/createFrame) are still missing.

8. **Total correctness (NOT DONE, three reviews).** All building blocks present; assembly missing.

9. **Abstraction function Retort -> ExecTrace + refinement theorem (NOT DONE, six reviews).** Types now unify, making this feasible for the first time.

### Assessment: Is This an A+ Model?

No. The model is an A. It is a strong, well-structured formal development with genuine proofs, zero sorries, and 107 theorems across 2,824 lines. The safety story is complete: 9 invariants preserved by 5 operations, temporal closure via `always_wellFormed`. The liveness story is present: `progress` composes with preservation. The algebraic story has begun: independent claims commute.

It is not A+ because:

- **No total correctness.** The model proves safety (bad things never happen) but not liveness in the strong sense (good things eventually happen). For a finite acyclic program, there is no proof that a sequence of valid operations reaches `programComplete`. This is the central theorem of any runtime model.

- **No operational-denotational correspondence.** The model has two semantics (Retort.lean operational, Denotational.lean denotational) that share types but no connecting theorem. A publishable formal development would prove they agree.

- **DAG properties are incomplete.** `noSelfLoops` is proven as an invariant. `generationOrdered` and `bindingsPointToFrozen` are defined but not maintained. The bindings graph is not proven to be a DAG in the transitive sense.

- **`bindingsMonotone` has incomplete preservation (six reviews running).** Four trivial proofs have been requested and not delivered for six consecutive reviews.

### Grade Summary

| Reviewer | v1 | v2 | v3 | v4 | v5 | **v6** | Delta v5->v6 | Key Factor |
|----------|----|----|----|----|----|----|--------------|------------|
| Feynman | B+ | B+ | A- | A- | A- | **A** | +0.5 | Type universes unified; MonotoneDemand; two-model semantic gap remains |
| Iverson | B | B | B+ | B+ | B+ | **A** | +0.5 | Zero dead weight; owner rename; appendOnly_trans still inlined |
| Dijkstra | B- | B+ | A- | A- | A- | **A** | +0.5 | 9 invariants, 45 pairs, always_wellFormed; DAG properties still incomplete |
| Milner | B | B | B+ | B+ | A- | **A** | +0.5 | Type universes unified; no refinement function; BodyType still decorative |
| Hoare | C+ | B+ | A- | A | A | **A** | +0.0 | always_wellFormed closes safety; total correctness still missing |
| Wadler | B- | B+ | A- | A- | A- | **A** | +0.5 | Claim commutativity proven; pour/freeze commutativity missing |
| Sussman | B | B | B+ | B+ | A- | **A** | +0.5 | Complete module system; ValidWFTrace composability; no multi-program theorem |

### Overall Grade: A

The model moves from A- to A. The v6 changes are the most impactful single-cycle improvement in the model's history: six of nine priority actions completed, the three longest-running defects (type fragmentation, commutativity, naming) resolved, and a temporal safety theorem established. Every reviewer moves to A.

The grade does not reach A+ because:

- **No total correctness.** Safety without strong liveness. Three reviews running.
- **No operational-denotational correspondence.** Two semantics, no connecting theorem. Six reviews running. Now feasible.
- **Incomplete DAG properties.** `noSelfLoops` proven; `generationOrdered`, `bindingsPointToFrozen` defined but not invariant. `bindingsMonotone` has 1/5 preservation proofs. Six reviews running.

### Priority Actions for v7

| Priority | Action | Difficulty | Impact | Est. LOC | Addresses |
|----------|--------|------------|--------|----------|-----------|
| 1 | `bindingsMonotone` preservation for pour/claim/release/createFrame | Easy | Medium | ~30 | Dijkstra (A+) |
| 2 | `appendOnly_trans` lemma; update stale summary comment | Easy | Low | ~30 | Iverson (A+) |
| 3 | `generationOrdered` + `bindingsPointToFrozen` in `wellFormed` with preservation | Medium | High | ~140 | Dijkstra (A+) |
| 4 | Commutativity of independent pours (disjoint programs) | Medium | Medium | ~50 | Wadler (A+) |
| 5 | Abstraction function `Retort -> ExecTrace`; refinement theorem | Hard | High | ~120 | Feynman (A+), Milner (A+) |
| 6 | Total correctness for finite acyclic programs | Hard | High | ~165 | Hoare (A+) |
| 7 | Multi-program composition theorem | Medium | Medium | ~50 | Sussman (A+) |
| 8 | `BodyType` formal role (determinism for hard cells) | Medium | Medium | ~40 | Milner (A+) |
| 9 | Projection `Retort -> Claims.State` + operational correspondence | Medium | Medium | ~75 | Sussman (A+) |

**Minimum path to all-A+:** Actions 1-9 (~700 LOC). The easy items (1, 2) are purely mechanical. The medium items (3, 4, 7, 8, 9) are well-defined with clear proof strategies. The hard items (5, 6) are where the intellectual work lies.

**Realistic assessment:** Actions 1-4 (~250 LOC, easy-medium) would push Dijkstra, Iverson, and Wadler to A+. Action 5 (~120 LOC, hard) would push Feynman and Milner to A+. Action 6 (~165 LOC, hard) would push Hoare to A+. Action 7 (~50 LOC, medium) would push Sussman to A+. The total correctness and refinement theorems are the two remaining intellectually substantial pieces of work. Everything else is engineering.

# Seven Sages Review v5: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated formal model. This review evaluates the changes since the v4 review. The model now spans 5 files totaling 3,484 lines with 99 theorems (72 in Retort.lean, 27 across Claims.lean/Denotational.lean/StemCell.lean), zero sorries.

## Changes Since v4 Review

The v4 review identified seven priority actions. Status:

| # | Action | v4 Status | v5 Status |
|---|--------|-----------|-----------|
| 1 | Include `framesCellDefsExist` in `wellFormed`; prove preservation by all 5 ops | NOT DONE | **DONE** -- 8th conjunct of `wellFormed`; 5 preservation theorems; `wellFormed_preserved` updated |
| 2 | Include `noSelfLoops` + DAG properties in `wellFormed`; prove preservation | NOT DONE | NOT DONE |
| 3 | Prove commutativity of independent claims and independent pours | NOT DONE (four reviews) | NOT DONE (five reviews) |
| 4 | Create `Core.lean` with shared types; eliminate parallel type universes | NOT DONE (four reviews) | **PARTIAL** -- Core.lean created, Retort.lean imports it; Denotational/StemCell/Claims still have own definitions |
| 5 | State and prove denotational-operational correspondence | NOT DONE (four reviews) | NOT DONE (five reviews) |
| 6 | Prove total correctness: finite acyclic program reaches `programComplete` | NOT DONE | NOT DONE |
| 7 | Constrain `stemHasDemand`; define `ValidWFTrace`; rename `GivenSpec.cellName` | NOT DONE | NOT DONE |

Key additions:
- **Core.lean** (85 lines): CellName, ProgramId, FrameId, PistonId, FieldName with LawfulBEq instances; EffectLevel and BodyType enums. Retort.lean imports Core and uses these types.
- **67 lines of duplicated definitions removed** from Retort.lean (the types now come from Core).
- **`framesCellDefsExist` added as I8** in `wellFormed` (8-conjunct predicate).
- **5 preservation theorems** for `framesCellDefsExist`: `pour_preserves_framesCellDefsExist` (with `pourFramesCellDefsExist` precondition), `claim_preserves_framesCellDefsExist`, `freeze_preserves_framesCellDefsExist`, `release_preserves_framesCellDefsExist`, `createFrame_preserves_framesCellDefsExist` (with `createFrameCellDefExists` precondition).
- **`wellFormed_preserved` updated** to prove all 8 conjuncts across all 5 operations (40 pairs).
- **`validOp` updated**: pour requires `pourFramesCellDefsExist`; createFrame requires `createFrameCellDefExists`.
- Total: 72 theorems in Retort.lean (up from 67 in v4), 99 across all files.

---

## Feynman (Physicist): Grade A-

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

Core.lean provides shared vocabulary, which is a structural improvement to how the model communicates. The `framesCellDefsExist` integration into `wellFormed` closes the safety-liveness composability gap. The `progress` theorem now follows directly from `wellFormed` without a separate hypothesis.

### Praises

1. **Safety and liveness now compose through a single predicate.** In v4, proving `progress` required both `wellFormed r` and `framesCellDefsExist r` as separate hypotheses. After `wellFormed_preserved`, only `wellFormed` was recovered -- the user had to manually track `framesCellDefsExist` across operations. Now `wellFormed` includes `framesCellDefsExist` as its 8th conjunct. After any valid operation, `wellFormed_preserved` produces a `wellFormed` that directly supports `progress`. The model can now explain the full eval cycle without handwaving: `wellFormed` -> `readyFrames` non-empty -> `progress` -> valid `ClaimData` exists -> `claim` -> `freeze` -> `wellFormed` again. This is the first time the safety and liveness stories are connected by the same predicate.

2. **Core.lean gives the model a shared physical vocabulary.** The types `CellName`, `FrameId`, `PistonId` are now defined once and imported. Retort.lean's definitions are cleaner: `Frame.cellName : CellName` instead of a locally defined wrapper. The LawfulBEq instances in Core.lean are load-bearing infrastructure -- they enable the BEq-to-Prop bridges that the progress proof depends on. Centralizing them means new modules that import Core get these instances for free.

### Critiques

1. **The two-model gap persists (fifth review).** Retort.lean and Denotational.lean remain disconnected type universes. Core.lean provides shared identity types, but Denotational.lean does not import Core -- it still defines its own `FieldName := String`, its own `EffectLevel`, and its own `CellBody`. The physical vocabulary is shared in theory but not in practice. No refinement theorem connects retort-level `frameStatus = .frozen` to denotational-level `evalStep` producing the correct `ExecFrame`. This is the oldest open issue in the model.

2. **`stemHasDemand` remains unconstrained (fifth review).** The demand predicate is `Retort -> Bool` with no monotonicity or well-foundedness requirement. The progress theorem applies to any ready frame but does not characterize when stem cells become ready. A stem cell with `demandPred = fun _ => true` can spin indefinitely. The mechanism that drives the most novel aspect of the system has no formal characterization.

### Path to A

Write a refinement theorem connecting Retort.lean's `frameStatus = .frozen` to Denotational.lean's evaluation semantics. This requires making Denotational.lean import Core (so the identity types unify) and defining an abstraction function from `Retort` state to `ExecTrace`.

### Path to A+

Additionally constrain `stemHasDemand` with monotonicity and prove that demand-driven stem cycles converge (the demand decreases or the system reaches quiescence).

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Denotational.lean imports Core; shared EffectLevel/FieldName | Easy | ~30 (deletions + import) |
| Abstraction function `Retort -> ExecTrace` | Medium | ~40 |
| Refinement theorem (frozen frame -> correct ExecFrame) | Hard | ~80 |
| `stemHasDemand` monotonicity constraint | Medium | ~25 |

---

## Iverson (Notation Designer): Grade B+

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

Core.lean introduces a well-organized type vocabulary. The `framesCellDefsExist` predicate moves into `wellFormed`. No changes to the naming issues or dead-weight definitions flagged in v4.

### Praises

1. **Core.lean has disciplined organization.** The file is 85 lines, structured into three clearly marked sections: identity types, LawfulBEq instances, and classification enums. Each structure derives exactly the instances it needs (`Repr, DecidableEq, BEq, Hashable` for types that may be hash-keyed; `Repr, DecidableEq, BEq` for others). The section headers use the same `/-! ==== ... ==== -/` style as Retort.lean. The naming is consistent: all identity types are `structure X where val : String`.

2. **The `validOp` vocabulary grew naturally.** `pourFramesCellDefsExist` and `createFrameCellDefExists` follow the established naming pattern: `{operation}{noun}{property}`. They are preconditions on the operation data, not on the retort state. This distinction (state invariants in `wellFormed`, operation constraints in `validOp`) is consistent and load-bearing.

### Critiques

1. **`GivenSpec.cellName` is still confusingly named (fifth review).** The field means "the cell that owns this given" (the dependent cell). The field `sourceCell` names the dependency target. This has been flagged since v1 and requires a one-line rename to `owner` or `ownerCell`. It appears on lines 34 and 172 of Retort.lean (the `frameReady` filter). The rename is trivial.

2. **The claim log is still dead weight (fifth review).** `ClaimLogEntry`, `ClaimAction`, and `claimLog` appear in the model. `applyOp` appends to `claimLog` in the `claim`, `freeze`, and `release` arms. `claimLogPreserved` is defined and proven. But no theorem queries the claim log or proves any property about it. No audit theorem exists (e.g., "every frozen frame has a complete claim/release sequence in the log"). The claim log adds 18 lines of structure definitions and 15+ lines of proof obligations per operation, all for zero semantic payoff.

3. **Three files still have their own type definitions.** Denotational.lean defines `FieldName := String`, `EffectLevel`, and `CellBody`. StemCell.lean defines `CellName`, `CellDef`, `Frame`, `Yield`, `Edge`, and `RetortState`. Claims.lean defines `PistonId := String`, `FrameId := String`, and `StoredYield`. Core.lean exists but only Retort.lean imports it. The parallel type universes persist in 3 of 4 downstream files. This is not a notation issue per se, but it means the notational consistency that Core.lean provides is limited to Retort.lean.

### Path to A

Rename `GivenSpec.cellName` to `GivenSpec.owner`. Either prove an audit theorem for `claimLog` (e.g., `forall f, frameStatus r f = .frozen -> exists entries in claimLog tracing the full lifecycle`) or remove `claimLog` from the formal model. Make Denotational.lean, StemCell.lean, and Claims.lean import Core.

### Path to A+

Additionally factor out the common proof patterns (filter-preserves-forall, append-preserves-membership) into named lemmas used across multiple proofs, reducing repetition.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Rename `GivenSpec.cellName` to `owner` | Easy | ~5 (find-and-replace) |
| Audit theorem for `claimLog` or remove it | Medium | ~40 (audit) or -33 (remove) |
| Denotational/StemCell/Claims import Core | Easy | ~60 (mostly deletions) |
| Factor common proof patterns into lemmas | Easy | ~20 new, ~40 simplified |

---

## Dijkstra (Formalist): Grade A-

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

`framesCellDefsExist` is now the 8th conjunct of `wellFormed`. Five preservation theorems cover all operations. `wellFormed_preserved` proves all 8 conjuncts preserved by all 5 operations (40 pairs). The `progress` theorem's `framesCellDefsExist` hypothesis is now derivable from `wellFormed`.

### Praises

1. **The safety-liveness composability gap is closed.** In v4, `progress` required `framesCellDefsExist` as a separate hypothesis from `wellFormed`. This meant the output of `wellFormed_preserved` could not feed directly into `progress`. Now `wellFormed` includes `framesCellDefsExist`, so `wellFormed_preserved` produces a state from which `progress` applies. The proof architecture is now: `wellFormed r` -> valid operation -> `wellFormed (applyOp r op)` -> `progress` applies. This is the composability that was missing.

2. **The preservation proofs for `framesCellDefsExist` are genuine.** `pour_preserves_framesCellDefsExist` is the non-trivial case: it must show that old frames still find their cell definitions in `r.cells ++ pd.cells` (they do, because the old cells are a prefix) and that new frames have cell definitions (by the `pourFramesCellDefsExist` precondition). The proof uses `List.find?_isSome` and `List.any_eq_true` to bridge between the `Option.isSome` formulation of `framesCellDefsExist` and the `List.any` formulation of `pourFramesCellDefsExist`. The `createFrame_preserves_framesCellDefsExist` proof similarly bridges via `createFrameCellDefExists`. The three trivial cases (claim, freeze, release) correctly observe that neither cells nor frames change.

3. **The `wellFormed_preserved` proof is now 8-conjunct complete.** The proof destructures `hWF` into `hI1..hI8` and reassembles all 8 for each operation. The pour arm is the heaviest, requiring all four pour preconditions. The createFrame arm requires both `createFrameUnique` and `createFrameCellDefExists`. The claim arm requires `claimValid`. The freeze arm requires five preconditions. The release arm requires nothing. The precondition structure correctly reflects the complexity of each operation.

### Critiques

1. **DAG properties remain defined-but-unproven as invariants (fifth review).** `noSelfLoops` (line 1306), `generationOrdered` (line 1311), `bindingsPointToFrozen` (line 1319) are defined with no preservation proofs and no inclusion in `wellFormed`. These are the acyclicity and temporal ordering properties that justify calling the bindings table a DAG. Without preservation proofs, the model asserts "this is a DAG" in comments but does not prove it is maintained.

2. **`bindingsMonotone` has freeze-only preservation (fifth review).** `freeze_preserves_bindingsMonotone` exists. Pour, claim, release, and createFrame do not have corresponding proofs. Pour and createFrame add frames but not bindings, so preservation should be trivial. Claim and release do not touch bindings at all. Four trivial proofs are missing.

3. **`stemCellsDemandDriven` (I8 in the comment, now displaced by `framesCellDefsExist`) remains defined and excluded (fifth review).** The definition on line 318 says "stem cells only get frames when demand appears, starting at gen 1" but then immediately hedges ("Actually, gen 0 is fine if demand exists at pour time"). It is not in `wellFormed`, has no preservation proofs, and serves no formal purpose.

### Path to A

Include `noSelfLoops` in `wellFormed` as I9 and prove preservation by all 5 operations. Pour and createFrame need preconditions (new bindings and frames satisfy the property). Claim, release, and freeze-with-existing-noSelfLoops are trivial or near-trivial. Delete or integrate `stemCellsDemandDriven`.

### Path to A+

Include `generationOrdered` and `bindingsPointToFrozen` in `wellFormed` (or a `dagWellFormed` composite). Prove `bindingsMonotone` preserved by all 5 operations. This would make the DAG structure a first-class proven invariant rather than a defined-but-asserted property.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `noSelfLoops` in `wellFormed` + 5 preservation proofs | Medium | ~60 |
| `bindingsMonotone` preservation for pour/claim/release/createFrame | Easy | ~30 (all trivial) |
| Delete `stemCellsDemandDriven` definition and comments | Easy | ~-10 |
| `generationOrdered` + `bindingsPointToFrozen` preservation | Medium | ~80 |
| `dagWellFormed` composite with all DAG properties | Medium | ~30 (wrapper) |

---

## Milner (Type Theorist): Grade A-

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

Core.lean introduces a shared type layer. `framesCellDefsExist` is integrated into `wellFormed`, unifying the safety and liveness typing obligations. However, the type universe fragmentation persists across 3 of 4 downstream files.

### Praises

1. **The typing discipline is now unified for safety and liveness.** In v4, proving liveness required two type predicates: `wellFormed r` (safety) and `framesCellDefsExist r` (liveness precondition). These were independent -- the caller had to track both. Now `wellFormed` subsumes `framesCellDefsExist`, so a single type obligation covers both safety and liveness. The `progress` theorem's hypothesis `framesCellDefsExist r` is satisfied by `hWF.2.2.2.2.2.2.2` (the 8th conjunct). This is clunky notation but correct typing.

2. **Core.lean's LawfulBEq instances are load-bearing.** The 5 `LawfulBEq` instances (CellName, ProgramId, FrameId, PistonId, FieldName) enable `eq_of_beq` proofs that bridge boolean equality (used in `List.find?`, `List.filter`, `List.any`) to propositional equality (used in theorem statements). Without these, every proof that decomposes a `find?` result must manually derive the equality. Core.lean centralizes this infrastructure. The progress proof, the mutex proof, and the `content_addr_distinct_gens` proof all depend on these instances.

3. **The precondition types for I8 preservation are well-designed.** `pourFramesCellDefsExist` uses `List.any` (boolean) while `framesCellDefsExist` uses `Option.isSome` (boolean on `find?`). The preservation proof bridges these two formulations via `List.find?_isSome` and `List.any_eq_true`. The types are different but the semantic content is the same: "a cell definition exists for this cell name." The proof demonstrates that the two formulations are interderivable.

### Critiques

1. **The type universes remain fragmented (fifth review, partial progress).** Core.lean exists and Retort.lean imports it. But Denotational.lean defines its own `FieldName := String` (line 36), its own `EffectLevel` (lines 74-78), and its own `CellBody` (line 66). StemCell.lean defines its own `CellName` (lines 24-26), `CellDef` (lines 176-180), `Frame` (lines 392-396), `Yield` (lines 399-402), and `RetortState` (lines 418-425). Claims.lean defines its own `PistonId := String` (line 15) and `FrameId := String` (line 16). These are not compatible with Core.lean's types -- `Core.FieldName` is a structure with a `val : String` field, while `Denotational.FieldName` is `String` directly. An abstraction function mapping between them does not exist. Core.lean solved the problem for Retort.lean and left the other three files untouched.

2. **The effect lattice has no formal role (fifth review).** `BodyType` (hard/soft/stem) from Core.lean is used in `CellDef.bodyType` and in `programComplete` (which skips stem cells). But no theorem distinguishes hard from soft cells. No theorem says "a hard cell's yields are deterministic" or "a soft cell may produce different yields on re-evaluation." The `EffectLevel` in Core.lean and the `EffectLevel` in Denotational.lean serve analogous roles but are unconnected types. The classification exists in the model but has no formal consequences.

3. **No morphism from denotational `CellDef M` to retort `CellDef`.** The retort's `CellDef` has `body : String`. The denotational's `CellDef M` has `body : CellBody M := Env -> M (Env x Continue)`. These represent the same concept at different abstraction levels. No function maps one to the other. No theorem says the retort-level execution of a cell corresponds to the denotational-level evaluation of its body. The gap is the same as in v1.

### Path to A

Make Denotational.lean, StemCell.lean, and Claims.lean import Core, removing their duplicate type definitions. This eliminates the type universe fragmentation. Define an abstraction function from retort `CellDef` to denotational `CellDef Id` (with `body : String` interpreted as a lookup key for the actual function).

### Path to A+

Give `BodyType` a formal role: prove that `bodyType = .hard` implies yields are deterministic (same inputs -> same outputs), or that `bodyType = .stem` implies `Continue = .more`. State the effect lattice ordering as a theorem about composability.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Denotational/StemCell/Claims import Core | Easy | ~60 (mostly deletions) |
| Abstraction function retort `CellDef` -> denotational `CellDef Id` | Medium | ~30 |
| `BodyType` formal role (determinism theorem for hard cells) | Medium | ~40 |
| Effect lattice composability theorem | Medium | ~35 |

---

## Hoare (Verification): Grade A

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

The `framesCellDefsExist` integration into `wellFormed` closes the composability gap Hoare identified in v4: `progress` now composes with `wellFormed_preserved` through a single predicate. No new postconditions or correctness theorems were added.

### Praises

1. **Progress is now composable with preservation.** In v4, Hoare noted: "after proving `wellFormed` holds and applying an operation, you cannot immediately prove `progress` applies to the result." This is resolved. The chain is now: `wellFormed r` -> `validOp r op` -> `wellFormed_preserved r op hWF hValid` -> `wellFormed (applyOp r op)` -> destructure to get `framesCellDefsExist (applyOp r op)` -> `progress` applies. No manual bridging work. The proof architecture supports arbitrary-length operation sequences: apply `wellFormed_preserved` N times, then invoke `progress` at any point where `readyFrames` is non-empty.

2. **The precondition structure for I8 is correctly placed.** `pourFramesCellDefsExist` is a precondition on `PourData` (poured frames reference cells that will exist after pour). `createFrameCellDefExists` is a precondition on `CreateFrameData` (the new frame's cell name has a definition in the current retort). Both are natural: they require the caller to prove referential integrity of the data being submitted. They are included in `validOp`, so `wellFormed_preserved` requires them automatically for pour and createFrame operations. This is the correct Hoare-triple structure: the precondition constrains the input, the invariant constrains the state, and the postcondition (preservation) constrains the output.

### Critiques

1. **No total correctness (fifth review).** The building blocks are all present: `progress` (a step can be taken), `claim_adds_claim` (claim is recorded), `freeze_removes_claim` (lock released), `freeze_makes_frozen` (frame reaches terminal state), `wellFormed_preserved` (invariants maintained). The missing theorem is: "for a finite acyclic program with `wellFormed`, there exists a sequence of valid operations such that `programComplete` holds." This requires: (a) defining a termination measure (count of non-frozen non-stem frames), (b) proving each eval cycle strictly decreases it, (c) proving that zero non-frozen frames implies `programComplete`. The postconditions provide the raw material. The assembly is missing.

2. **The progress witness still uses a dummy piston ID.** `ClaimData` is constructed with `PistonId.mk "progress_witness"`. This is valid for the existential statement. But for a total correctness proof, the claim must be realizable by an actual piston. If the system has piston scheduling constraints (e.g., a piston can only claim frames for programs it is assigned to), the dummy witness would not suffice. This is a refinement concern, not a defect in the current model.

3. **No postcondition for `pour` that connects to `readyFrames`.** `pour_adds_cells` and `pour_adds_frames` prove membership. But no theorem says "after pouring a non-stem program with no dependencies, the poured frames are in `readyFrames`." This would require showing that poured frames have `frameStatus = .declared` (no yields, no claims) and all givens are satisfiable. It is the "pour -> ready -> progress -> claim -> freeze -> complete" chain's first link, currently unproven.

### Path to A+

Prove total correctness for finite acyclic programs. The theorem would be:

```
theorem total_correctness (r : Retort) (prog : ProgramId)
    (hWF : wellFormed r)
    (hFinite : forall cd in r.cells, cd.program = prog -> cd.bodyType != .stem)
    (hAcyclic : <DAG property on givens>) :
    exists ops : List RetortOp, programComplete (ops.foldl applyOp r) prog
```

This requires composing progress, claim, freeze, and the termination measure.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Termination measure (count non-frozen non-stem frames) | Medium | ~25 |
| Eval cycle decreases measure | Medium | ~50 |
| Zero measure implies `programComplete` | Medium | ~30 |
| Total correctness theorem | Hard | ~60 |
| Pour -> readyFrames postcondition | Medium | ~40 |

---

## Wadler (Functional Programmer): Grade A-

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

The `framesCellDefsExist` integration into `wellFormed` is structural, not algebraic. No new equational laws, commutativity results, or algebraic properties were added.

### Praises

1. **The `validOp` dispatch structure is algebraically clean.** `validOp` is a function from `Retort -> RetortOp -> Prop` defined by pattern matching on `RetortOp`. Each arm returns a conjunction of the relevant preconditions. This is a sum-of-products structure: the operation type determines which preconditions apply. `wellFormed_preserved` consumes this structure by case-splitting on `op`. The two definitions together form a clean algebraic contract: `validOp` is the specification, `wellFormed_preserved` is the law.

2. **The preservation proofs have a consistent algebraic shape.** Every preservation proof follows the same pattern: unfold the invariant, unfold `applyOp`, case-split on list membership (old data vs new data), use the invariant for old data and the precondition for new data. The I8 preservation proofs follow this pattern exactly. The consistency suggests the proofs could be generated by a tactic, which is a sign of good algebraic structure.

### Critiques

1. **No commutativity laws (fifth review).** `applyOp (applyOp r (.claim a)) (.claim b) = applyOp (applyOp r (.claim b)) (.claim a)` when `a.frameId != b.frameId` is still absent. This has been requested since v1. Without it, reasoning about concurrent piston execution requires analyzing every interleaving independently. The claim operation appends to `claims` and `claimLog`. Claims with different frameIds are independent list elements. The commutativity proof would require showing that `claims ++ [a] ++ [b]` is equivalent to `claims ++ [b] ++ [a]` up to the relevant invariants -- not syntactic equality, but invariant-preserving equivalence. This is the most impactful missing algebraic property.

2. **`applyOp` is still total and unchecked (fifth review).** It accepts invalid operations silently. No `applyOpChecked : Retort -> RetortOp -> Option Retort` exists that returns `none` for invalid operations. The preconditions exist as separate predicates but are not enforced by the type. Unchanged from v1.

3. **No transitivity lemma for `appendOnly`.** The `data_persists` theorem proves transitivity for valid traces. But `appendOnly` itself has no standalone transitivity lemma: `appendOnly a b -> appendOnly b c -> appendOnly a c`. The `evalCycle_appendOnly` proof manually composes 6 field-wise transitivity steps (lines 1363-1382). The `data_persists` proof does the same (lines 1539-1543). A `appendOnly_trans` lemma would replace both with one-liners.

### Path to A

Prove commutativity of independent claims: `claimValid r a -> claimValid r b -> a.frameId != b.frameId -> wellFormed (applyOp (applyOp r (.claim a)) (.claim b)) <-> wellFormed (applyOp (applyOp r (.claim b)) (.claim a))`. Extract `appendOnly_trans`.

### Path to A+

Prove commutativity of independent pours (non-overlapping programs). State the termination measure as a well-founded relation on the count of non-frozen frames. This would be the algebraic capstone: the model has laws for safety (preservation), liveness (progress), and composition (commutativity + termination).

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Commutativity of independent claims | Medium | ~50 |
| `appendOnly_trans` lemma | Easy | ~15 |
| Commutativity of independent pours | Medium | ~45 |
| Termination measure as well-founded relation | Medium | ~35 |

---

## Sussman (Systems Thinker): Grade A-

**Core question:** Does the model compose? Can it be extended?

### What Changed

Core.lean creates the first shared module. `framesCellDefsExist` in `wellFormed` closes the composability gap between safety and liveness. These are structural improvements to the model's extensibility.

### Praises

1. **Core.lean establishes the module pattern.** Before Core.lean, extending the model meant adding definitions to the monolithic Retort.lean or creating a standalone file with its own type universe. Core.lean demonstrates the correct pattern: define shared types in a core module, import them in downstream modules. Future extensions (e.g., a Scheduler.lean, a TypeChecker.lean) can import Core and share the identity types. The pattern is established even though it is only followed by one file.

2. **The composability gap is closed.** A systems engineer building a scheduler can now write:
   - Start with `wellFormed r_0` (proved by construction for `Retort.empty`).
   - For each operation: prove `validOp r_n op_n`, apply `wellFormed_preserved` to get `wellFormed r_{n+1}`.
   - At any point: if `readyFrames r_n` is non-empty, destructure `wellFormed r_n` to get `framesCellDefsExist r_n`, apply `progress` to get a valid `ClaimData`.
   - No manual tracking of `framesCellDefsExist`. The safety machinery carries it automatically.
   This is the composability story that was broken in v4.

3. **The extension protocol is clear.** To add a 9th invariant to `wellFormed`: define the predicate, prove preservation by all 5 operations (with preconditions where needed), add the preconditions to `validOp`, add the conjunct to `wellFormed`, add the arm to each case in `wellFormed_preserved`. The I8 addition demonstrates this protocol exactly. It took 5 preservation theorems, 2 precondition definitions, and updates to `validOp` and `wellFormed_preserved`. A systems engineer can follow this template.

### Critiques

1. **Three files remain unintegrated (fifth review, partial progress).** Core.lean exists. Retort.lean imports it. Denotational.lean, StemCell.lean, and Claims.lean do not. They define their own types that are structurally similar but type-incompatible with Core's types. A theorem proved in Claims.lean about `FrameId` (which is `String`) cannot be applied to Retort.lean's `FrameId` (which is `Core.FrameId`, a structure wrapping `String`). The model is 4 files but only 2 form a coherent module system (Core + Retort). The other 3 are standalone explorations.

2. **No multi-program composition theorem (fifth review).** Two sequential pours of independently well-formed programs still have no standalone composition result. The `wellFormed_preserved` theorem handles a single pour. But "if I pour program A and then pour program B, and both are independently well-formed, is the result well-formed?" requires showing that A's cells don't conflict with B's cells (which is what `pourValid` does). A composition theorem would package this: `wellFormed r -> validProgram A -> validProgram B -> disjoint A B -> wellFormed (pour B (pour A r))`.

3. **`ValidTrace` still does not require `validOp` (fifth review).** A `ValidTrace` is `Trace x (Nat -> RetortOp)` with `step : forall n, trace (n+1) = applyOp (trace n) (ops n)`. It does not require `validOp (trace n) (ops n)`. A valid trace can contain invalid operations (claims on non-existent frames, pours that violate uniqueness). The `always_mutex_on_valid_trace` theorem from Claims.lean proves mutex unconditionally, but the analogous theorem for Retort.lean's `wellFormed` would require `ValidWFTrace` where every step satisfies `validOp`. No such definition exists.

### Path to A

Make Denotational.lean, StemCell.lean, and Claims.lean import Core. Define `ValidWFTrace` with `validOp` and `wellFormed` requirements. These are the two most impactful structural changes for composability.

### Path to A+

Prove multi-program composition. This validates the model's ability to handle the real use case: a retort running multiple programs simultaneously.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Denotational/StemCell/Claims import Core | Easy | ~60 (mostly deletions) |
| `ValidWFTrace` definition | Easy | ~15 |
| `always_wellFormed` on `ValidWFTrace` | Medium | ~25 |
| Multi-program composition theorem | Medium | ~50 |

---

## Consensus

### What Improved Since v4

The model addressed two of v4's seven priority actions, one completely and one partially:

1. **`framesCellDefsExist` integrated into `wellFormed` (DONE).** This was v4's #1 priority. The predicate is now the 8th conjunct of `wellFormed`. Five preservation theorems exist, one for each operation. `wellFormed_preserved` proves all 8 conjuncts across all 5 operations. `validOp` includes the necessary preconditions (`pourFramesCellDefsExist` for pour, `createFrameCellDefExists` for createFrame). The safety-liveness composability gap identified by Dijkstra, Hoare, and Sussman is closed. `progress` now composes with `wellFormed_preserved` through a single predicate. This is the most impactful change since the progress theorem itself.

2. **Core.lean created (PARTIAL).** This was v4's #4 priority. Core.lean exists with 85 lines of shared type definitions. Retort.lean imports it and uses the shared types, eliminating 67 lines of duplicated definitions. However, Denotational.lean, StemCell.lean, and Claims.lean do not import Core. They retain their own incompatible type definitions. The type universe fragmentation is reduced from 4 independent universes to 3 independent universes + 1 integrated pair. The problem is partially solved.

3. **Line count and theorem count growth.** 3,484 total lines across 5 files (up from ~3,400). 99 theorems total (72 in Retort.lean up from 67, 27 in other files unchanged). Zero sorries. The growth is targeted: 5 preservation theorems for I8 and associated precondition definitions.

### What Remains

Five of v4's seven priority actions persist unchanged:

1. **DAG properties outside `wellFormed` (five reviews running).** `noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen` remain defined-but-unproven as invariants. `bindingsMonotone` has freeze-only preservation. This has been open since v2.

2. **No commutativity laws (five reviews running).** Independent operations do not commute provably. Requested since v1. Never addressed.

3. **Disconnected formalizations (five reviews, partial progress).** Core.lean exists but is only imported by Retort.lean. Three files retain independent type universes. No refinement theorem connects the retort and denotational models. The oldest open issue, partially addressed.

4. **No total correctness (two reviews running).** All building blocks exist (progress, postconditions, preservation). The assembly into a total correctness theorem is missing.

5. **`stemHasDemand` unconstrained; `ValidWFTrace` undefined; `GivenSpec.cellName` misnamed (five reviews running).** These low-effort changes have never been addressed.

### Assessment: Did Core.lean Address Sussman/Milner?

Partially. Sussman's and Milner's central demand across v1-v4 was "eliminate parallel type universes." Core.lean takes the first step: it defines the shared types and Retort.lean imports them. But the demand was to unify ALL files, not just one. With 3 of 4 downstream files still using their own types, the type universe fragmentation is reduced but not eliminated. Sussman and Milner each move from B+ to A- because the pattern is established and the primary file (Retort.lean) is integrated, but the job is incomplete.

### Assessment: Did `framesCellDefsExist` Integration Address Dijkstra/Hoare?

Yes, specifically. Dijkstra's v4 critique was: "`framesCellDefsExist` has no preservation proofs... the progress result cannot be composed with the safety result." Hoare's v4 critique was: "`wellFormed_preserved` does not produce `framesCellDefsExist` as a postcondition... the progress result is a one-shot theorem rather than a composable piece." Both are resolved by inclusion in `wellFormed` with preservation proofs. Dijkstra stays at A- (DAG issues remain). Hoare stays at A (total correctness remains).

### Assessment: What Moved the Needle?

The `framesCellDefsExist` integration is the single most impactful change in v5. It converts `progress` from a standalone theorem into a composable component of the safety-liveness story. Before: `wellFormed` + `framesCellDefsExist` -> `progress`. After: `wellFormed` -> `progress`. This is a structural improvement to the proof architecture, not just a new theorem.

Core.lean is the second most impactful change, but its impact is limited by incomplete adoption. The pattern is correct. The execution is partial.

The model is now reaching the limits of what can be improved by deepening the safety axis. All 8 invariants are preserved, all 5 operations have postconditions, progress composes with preservation, zero sorries. The remaining gaps are on other axes: algebraic structure (commutativity), cross-module integration (Core adoption), DAG maintenance, correspondence (denotational-operational refinement), and total correctness. Moving from A- to A+ requires broadening.

### Grade Summary

| Reviewer | v1 Grade | v2 Grade | v3 Grade | v4 Grade | v5 Grade | Delta v4->v5 | Key Factor |
|----------|----------|----------|----------|----------|----------|--------------|------------|
| Feynman | B+ | B+ | A- | A- | **A-** | +0.0 | Core.lean helps; two-model gap, stemHasDemand unchanged |
| Iverson | B | B | B+ | B+ | **B+** | +0.0 | Core.lean notation is clean; cellName rename, claimLog dead weight persist |
| Dijkstra | B- | B+ | A- | A- | **A-** | +0.0 | I8 composability closed; DAG properties still unproven |
| Milner | B | B | B+ | B+ | **A-** | +0.5 | Core.lean establishes shared type layer; partial adoption limits impact |
| Hoare | C+ | B+ | A- | A | **A** | +0.0 | Safety-liveness composable; total correctness still missing |
| Wadler | B- | B+ | A- | A- | **A-** | +0.0 | No new algebraic laws; commutativity still absent |
| Sussman | B | B | B+ | B+ | **A-** | +0.5 | Core.lean establishes module pattern; 3 files still unintegrated |

### Overall Grade: A-

The model holds at A-. The `framesCellDefsExist` integration is a genuine structural improvement that closes the v4's most actionable gap (safety-liveness composability). Core.lean is the first step toward eliminating the type universe fragmentation that has been flagged since v1. Two reviewers (Milner, Sussman) move from B+ to A- because the module structure and typing discipline improved materially, even if incompletely.

The grade does not reach A because:

- **Three files still have independent type universes.** Core.lean is only imported by Retort.lean. The type fragmentation is reduced but not eliminated.
- **DAG properties are still second-class (five reviews).** The dependency graph's structural properties are defined but not maintained as invariants.
- **No commutativity laws (five reviews).** Independent operations cannot be reordered algebraically.
- **No total correctness.** The eval cycle is characterized at the postcondition level but not assembled into an end-to-end correctness theorem.

The grade does not reach A+ because no reviewer gave a perfect score, and the longest-running requests (commutativity, full Core adoption, stemHasDemand constraints, denotational-operational correspondence) have never been fully addressed across five review cycles.

### Priority Actions for v6

| Priority | Action | Difficulty | Impact | Est. LOC | Addresses |
|----------|--------|------------|--------|----------|-----------|
| 1 | Make Denotational.lean, StemCell.lean, Claims.lean import Core; delete duplicate type definitions | Easy | High | ~60 | Milner (A), Sussman (A), Iverson (A-) |
| 2 | Include `noSelfLoops` in `wellFormed` as I9; prove preservation by all 5 ops | Medium | High | ~60 | Dijkstra (A) |
| 3 | Prove commutativity of independent claims (different frameIds) | Medium | High | ~50 | Wadler (A) |
| 4 | Rename `GivenSpec.cellName` to `owner`; delete `stemCellsDemandDriven`; delete or prove audit for `claimLog` | Easy | Medium | ~15 | Iverson (A) |
| 5 | Define `ValidWFTrace` requiring `validOp` at each step; prove `always_wellFormed` | Easy | Medium | ~40 | Sussman (A+) |
| 6 | Prove `bindingsMonotone` preserved by pour/claim/release/createFrame | Easy | Medium | ~30 | Dijkstra (A+) |
| 7 | Prove total correctness for finite acyclic programs | Hard | High | ~165 | Hoare (A+) |
| 8 | Abstraction function Retort -> ExecTrace; refinement theorem | Hard | High | ~150 | Feynman (A+), Milner (A+) |
| 9 | Constrain `stemHasDemand` with monotonicity | Medium | Medium | ~25 | Feynman (A) |

**Minimum path to all-A:** Actions 1-4 (~185 LOC, easy-medium difficulty). This would move Milner to A, Sussman to A, Dijkstra to A, Wadler to A, Iverson to A. Feynman and Hoare are already at A- and A respectively; reaching A for Feynman requires action 9, reaching A+ for Hoare requires action 7.

**Minimum path to all-A+:** Actions 1-9 (~595 LOC). This is a substantial effort but the individual pieces are well-defined. The hard items (total correctness, refinement theorem) are where the remaining intellectual work lies. The easy items (Core adoption, naming, cleanup) are purely mechanical.

# Seven Sages Review v7: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated formal model. This review evaluates the changes since the v6 review. The model now spans 5 files (Core.lean, Retort.lean, Denotational.lean, Claims.lean, Refinement.lean -- StemCell.lean excluded as independent) totaling 3,333 lines with 126 theorems (87 in Retort.lean, 16 in Claims.lean, 4 in Denotational.lean, 19 in Refinement.lean), zero sorries.

## Changes Since v6 Review

The v6 review identified nine priority actions. Status:

| # | Action | v6 Status | v7 Status |
|---|--------|-----------|-----------|
| 1 | `bindingsMonotone` preservation for pour/claim/release/createFrame | NOT DONE (six reviews) | NOT DONE (seven reviews) |
| 2 | `appendOnly_trans` lemma; update stale summary comment | NOT DONE | NOT DONE (stale summary still lists I1-I7, mentions claimLog) |
| 3 | `generationOrdered` + `bindingsPointToFrozen` in `wellFormed` with preservation | NOT DONE | NOT DONE |
| 4 | Commutativity of independent pours (disjoint programs) | NOT DONE | NOT DONE |
| 5 | Abstraction function `Retort -> ExecTrace`; refinement theorem | NOT DONE (six reviews) | **DONE** -- `Retort.toExecTrace`, `frozen_frame_corresponds`, 10 refinement theorems |
| 6 | Total correctness for finite acyclic programs | NOT DONE (three reviews) | NOT DONE (four reviews) |
| 7 | Multi-program composition theorem | NOT DONE | NOT DONE |
| 8 | `BodyType` formal role (determinism for hard cells) | NOT DONE | NOT DONE |
| 9 | Projection `Retort -> Claims.State` + operational correspondence | NOT DONE | NOT DONE |

Key addition (1-action epic):

1. **Refinement.lean: denotational-operational correspondence (507 lines, 19 theorems).** This is the single new file, addressing v6 priority #5 -- the longest-running open item (requested since v1). The file contains:

   - **Bridge types.** `BodyInterp` maps Retort string yields to denotational `Val` via `yieldToVal : FieldName -> String -> Val` and an optional `fieldMap : FieldName -> FieldName`. `RetortConfig` pairs a `Retort` with a `Program Id` and a `BodyInterp`, forming the simulation relation.

   - **Abstraction function.** `Retort.toExecTrace` maps a Retort state to a denotational `ExecTrace` by filtering frozen frames (`Retort.frozenFrames`) and converting each via `frameToExecFrame`. Inputs come from `resolveBindings`; outputs come from `frameYields` mapped through `BodyInterp`.

   - **Simulation relation.** `cellsCorrespond` requires every Retort cell to have a matching denotational cell by name. `fieldsCorrespond` requires field counts to match. `Coherent` bundles `wellFormed`, `cellsCorrespond`, and `fieldsCorrespond`.

   - **10 refinement theorems (all sorry-free):**
     1. `frozen_frame_corresponds` -- core soundness: frozen frame in coherent Retort implies ExecFrame in trace with matching cellName and generation.
     2. `frozenFrames_preserved_by_appendOnly` -- monotonicity: frozen frames remain frozen under append-only transitions when cells are stable.
     3. `finite_program_bounded` -- termination bound: nonFrozenCount bounded by |frames|.
     4. `complete_implies_all_cells_traced` -- completeness: when programComplete is true, every non-stem cell has a corresponding ExecFrame.
     5. `trace_length_eq_frozen_count` + `frozen_bounded_by_frames` + `trace_length_bounded` -- structural: trace length equals frozen count, bounded by total frames.
     6. `output_deterministic` -- output stability: same yields produce same denotational Env.
     7. `frameToExecFrame_deterministic` -- frame determinism: same yields + bindings produce identical ExecFrames.
     8. `non_pour_frozen_preserved` -- trace persistence: after any non-pour operation, every frozen frame's ExecFrame persists.
     9. `zero_nonFrozen_implies_all_frozen` -- termination: nonFrozenCount = 0 implies all frames frozen.
     10. `valid_trace_produces_valid_exec_frames` -- trace validity: every step of a well-formed trace produces valid ExecFrames for all frozen frames.

   Total: 507 lines, zero sorry, compiles clean.

Total across active files: 3,333 lines. 126 theorems. Zero sorry.

---

## Feynman (Physicist): Grade A

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The six-review gap between the operational and denotational models is closed. An abstraction function and a core soundness theorem now exist.

### Praises

1. **The abstraction function exists and is the right one.** `Retort.toExecTrace` maps frozen frames to ExecFrames. This is the correct abstraction: frozen frames are completed computations in the operational model; ExecFrames are completed computations in the denotational model. Non-frozen frames (declared, computing) are excluded because they represent in-progress work that has no denotational counterpart. The function makes a clear design choice: only frozen operational state has denotational meaning.

2. **`BodyInterp` is an honest bridge, not a cheat.** The Retort stores yields as strings. The denotational model uses `Env = List (FieldName x Val)`. These are genuinely different representations. `BodyInterp` makes the translation explicit: `yieldToVal` converts a string yield to a `Val`, and `fieldMap` handles name translation. This is the correct engineering decision -- it acknowledges that the two models operate in different value domains and provides a first-class interpretation layer rather than pretending the gap does not exist.

3. **`frozen_frame_corresponds` is the theorem that was missing for six reviews.** The statement: if `Coherent rc` and frame `f` is frozen in `rc.retort`, then there exists an ExecFrame in `rc.retort.toExecTrace rc.interp` with matching `cellName` and `generation`. This connects the operational "all yields present" status to the denotational "frame appears in the trace" status. The two models now share a proven correspondence, not just shared types.

### Critiques

1. **The refinement is structural, not semantic.** `frozen_frame_corresponds` proves that frozen frames produce ExecFrames with matching names and generations. It does not prove that the ExecFrame's *outputs* correspond to what the denotational `evalStep` would produce for the same inputs. The theorem says "a frame with this name exists in the trace." It does not say "the frame contains the right values." This is a name-and-generation correspondence, not a value correspondence. The harder theorem -- that `frameToExecFrame`'s outputs match `CellBody`'s outputs when given the same inputs -- requires connecting the Retort's opaque `body : String` to the denotational's `body : Env -> (Env x Continue)`, which `BodyInterp` does not attempt.

2. **`Coherent` is a weak simulation relation.** It requires `wellFormed`, `cellsCorrespond` (names match), and `fieldsCorrespond` (field counts match). It does not require that the denotational cell's `deps` correspond to the Retort's `givens`, or that the denotational cell's `effectLevel` corresponds to the Retort's `bodyType`, or that the denotational cell's `body` corresponds to the Retort's evaluation of the string body. A `Coherent` relation that matches names and field counts but not dependencies or semantics is a structural correspondence, not a behavioral one.

3. **`MonotoneDemand` convergence is still unaddressed.** The v6 critique stands: `MonotoneDemand` constrains demand to persist once established, but no theorem says demand eventually ceases. Stem cell quiescence remains uncharacterized.

### Assessment: Does the refinement earn A+?

No. The refinement is a genuine structural correspondence -- the longest-running open item is resolved. But the gap between "names and generations match" and "values match" is the difference between a simulation relation and a bisimulation. A publishable refinement theorem would prove output correspondence, not just naming correspondence.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Output correspondence: `frameToExecFrame` outputs match `evalStep` outputs | Hard | ~100 |
| Dependency correspondence: `deps` match `givens` in `Coherent` | Medium | ~40 |
| Demand convergence (system reaches quiescence) | Hard | ~60 |

---

## Iverson (Notation Designer): Grade A

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

Refinement.lean adds 15 definitions and 19 theorems. The naming follows established conventions. The stale summary comment block in Retort.lean remains stale.

### Praises

1. **The Refinement.lean naming convention is consistent with the existing codebase.** `frozen_in_frozenFrames`, `execFrame_in_trace`, `frameToExecFrame_cellName`, `frameToExecFrame_generation` -- all follow `{subject}_{property}` or `{function}_{field}`. The 10 refinement theorems are named by their semantic role: `frozen_frame_corresponds`, `frozenFrames_preserved_by_appendOnly`, `complete_implies_all_cells_traced`. A reader familiar with Retort.lean's conventions can predict what each theorem proves from its name.

2. **Every definition in Refinement.lean participates in a theorem.** `BodyInterp` is used in `yieldsToEnv`, `frameToExecFrame`, and all trace construction. `RetortConfig` is used in `Coherent` and all correspondence theorems. `cellsCorrespond` and `fieldsCorrespond` are components of `Coherent`. `Coherent` is a hypothesis in `frozen_frame_corresponds` and `complete_implies_all_cells_traced`. `noStemCells` and `nonFrozenCount` are used in `finite_program_bounded` and `zero_nonFrozen_implies_all_frozen`. Zero vestigial definitions.

3. **`RCellDef` rename is well-motivated.** The comment (Retort.lean line 24-25) explains: renamed from `CellDef` to `RCellDef` to avoid collision with `Denotational.CellDef` when both modules are imported by Refinement.lean. This is a practical consequence of the module system working correctly -- the collision only occurs because Refinement.lean imports both, which is exactly what should happen.

### Critiques

1. **The summary comment block in Retort.lean (lines 1775-1870) is still stale (two reviews running).** It lists "I1-I7" under INVARIANTS (actual: I1-I9). It does not mention `framesCellDefsExist` (I8) or `noSelfLoops` (I9). It does not mention `ValidWFTrace`, `always_wellFormed`, `MonotoneDemand`, `stemHasDemand_preserved`, or any of the commutativity theorems. It still references "all 7 invariants, all 5 operations" (actual: 9 invariants). It does not reference Refinement.lean at all. The code has added 509 lines of new material (Refinement.lean) and significant content in Retort.lean since the summary was last accurate.

2. **`appendOnly_trans` is still inlined (seven reviews running).** The transitivity pattern appears three times: `evalCycle_appendOnly` (two arms, lines 1443-1465) and `data_persists` (lines 1646-1659). Refinement.lean adds a fourth instance in `frozenFrames_preserved_by_appendOnly` (which takes `appendOnly r r'` as a hypothesis rather than composing it, but the pattern of manually threading 5 fields remains in the callers). A named lemma would be ~10 lines of code.

3. **`BodyInterp.fieldMap` defaults to `id` but is never used non-trivially.** The field exists (line 43: `fieldMap : FieldName -> FieldName := id`) and is threaded through `yieldsToEnv` and `frameToExecFrame`, but no theorem constrains or exercises it beyond identity. If it will always be `id`, it is dead weight. If non-identity mappings are anticipated, a theorem should establish that `fieldMap` preserves correspondence (e.g., bijectivity is required for determinism).

### Path to A+

Update the stale summary comment. Extract `appendOnly_trans`. Remove or justify `BodyInterp.fieldMap`.

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Update summary comment block (lines 1775-1870) | Easy | ~30 |
| `appendOnly_trans` lemma | Easy | ~10 new, ~30 simplified |
| Justify or remove `BodyInterp.fieldMap` | Easy | ~5 |

---

## Dijkstra (Formalist): Grade A

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

Refinement.lean adds 10 theorems connecting the operational and denotational models. `frozenFrames_preserved_by_appendOnly` is the most substantial new proof (lines 201-237), requiring a 16-line helper (`frozen_fields_preserved`) that manually threads yield preservation through the `frameStatus` definition. All proofs are sorry-free.

### Praises

1. **`frozenFrames_preserved_by_appendOnly` is a genuine invariant proof.** The theorem: if `appendOnly r r'` and `r'.cells = r.cells` and frame `f` was frozen in `r`, then `f` is in `r'.frames` and `r'.frameStatus f = .frozen`. The proof is non-trivial: it case-splits on `cellDef`, shows the all-fields condition transfers from `r` to `r'` via `frozen_fields_preserved` (yields only grew, so any field present in `r.frameYields` is present in `r'.frameYields`), and handles the contradiction case where the original status would not have been `.frozen`. This is 36 lines of real proof, not a trivial `simp`.

2. **`complete_implies_all_cells_traced` closes a real gap.** The theorem: when `programComplete` is true and `Coherent` holds, every non-stem cell has an ExecFrame in the trace with matching name. The proof (lines 282-309) decomposes `programComplete` (a `Bool` computed by `List.all`), extracts the `hasFrozen` disjunct (rejecting the `isStem` case via `hNotStem`), finds the witness frame, and applies `frozen_frame_corresponds`. This chains four previously disconnected results into a single completeness statement.

3. **`non_pour_frozen_preserved` composes correctly.** It chains `cells_stable_non_pour`, `all_ops_appendOnly`, and `frozenFrames_preserved_by_appendOnly` to show that non-pour operations preserve frozen frame correspondence. This is the operational analogue of "evaluation only adds frames, never removes them."

### Critiques

1. **`generationOrdered` and `bindingsPointToFrozen` remain defined-but-unproven (seven reviews running).** These are at lines 1395 and 1403 in Retort.lean. Neither has preservation proofs. Neither is in `wellFormed`. The bindings graph is still not proven to be a DAG in the transitive sense. This critique has been present since v1. The refinement work does not address it because the refinement reasons about frozen frames (outputs), not about the dependency graph structure (inputs).

2. **`bindingsMonotone` still has only 1/5 preservation proofs (seven reviews running).** `freeze_preserves_bindingsMonotone` exists at line 572. Pour, claim, release, and createFrame proofs are still missing. Pour does not add bindings (trivial). Claim does not add bindings (trivial). Release does not add bindings (trivial). CreateFrame does not add bindings (trivial). Four one-line proofs have been absent for seven consecutive reviews.

3. **`finite_program_bounded` is weaker than it appears.** The theorem says `nonFrozenCount r prog <= r.frames.length`. The proof is `List.length_filter_le`. This is a tautology: the length of a filtered list is bounded by the length of the original list. It does not use `noStemCells` in any meaningful way (the hypothesis is prefixed with underscore: `_hNoStem`). The theorem name and documentation suggest it characterizes termination for non-stem programs, but the bound holds for any program regardless of stem cells. The `_hNoStem` hypothesis is decorative.

4. **`zero_nonFrozen_implies_all_frozen` does not connect to `programComplete`.** The theorem proves that when `nonFrozenCount` is 0, every frame with the given program is frozen. But `programComplete` is defined differently: it checks that every non-stem *cell* has *at least one* frozen *frame*. A program could have `nonFrozenCount = 0` (all frames frozen) while `programComplete = false` (some cell has no frame at all). The gap is: `nonFrozenCount` counts existing frames that are not frozen; `programComplete` checks that cells have frames. These are different conditions, and no theorem connects them.

### Assessment: Does the refinement earn A+?

No. The refinement theorems are genuine and sorry-free, but two of them (`finite_program_bounded`, `zero_nonFrozen_implies_all_frozen`) are weaker than their names and documentation imply. The seven-review-old DAG property gap and the seven-review-old `bindingsMonotone` gap remain. The formalist cares about what the theorems actually prove, and two of the ten refinement theorems prove less than advertised.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `bindingsMonotone` preservation for pour/claim/release/createFrame | Easy | ~30 |
| `generationOrdered` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| `bindingsPointToFrozen` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| Strengthen `finite_program_bounded` to use `noStemCells` non-trivially | Medium | ~40 |
| Connect `zero_nonFrozen_implies_all_frozen` to `programComplete` | Medium | ~30 |

---

## Milner (Type Theorist): Grade A

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

The refinement function from Retort to ExecTrace exists. `RetortConfig` pairs the two models with an explicit interpretation function. The type gap between `RCellDef` (operational) and `CellDef M` (denotational) is acknowledged in the design and bridged by `BodyInterp`.

### Praises

1. **The refinement is correctly one-directional.** Refinement.lean maps Retort to ExecTrace (abstraction), not ExecTrace to Retort (concretization). This is the right direction: the Retort has strictly more information (claims, bindings, operational state). The denotational model is a quotient. The type of `Retort.toExecTrace` is `Retort -> BodyInterp -> ExecTrace`, and no inverse is claimed. The asymmetry is a feature, not a deficiency.

2. **`RetortConfig` is the correct simulation relation type.** It bundles `retort : Retort`, `program : Program Id`, and `interp : BodyInterp`. This triple is the minimal information needed to state the correspondence: the operational state, the denotational specification, and the interpretation between their value domains. The `Coherent` predicate adds `wellFormed`, `cellsCorrespond`, and `fieldsCorrespond` as proof obligations. A consumer constructs a `RetortConfig`, proves `Coherent`, and gets access to all refinement theorems.

3. **The `RCellDef` rename resolves the type collision correctly.** When Refinement.lean imports both Retort.lean and Denotational.lean, both have `CellDef` -- one as a structure with `body : String`, one parameterized over `M` with `body : CellBody M`. Lean's module system requires disambiguation. Renaming the Retort-side type to `RCellDef` (line 26) is the correct resolution: it makes the operational type's identity explicit at the use site and allows unambiguous references to `CellDef M` for the denotational type.

### Critiques

1. **No type-level connection between `RCellDef.bodyType` and `CellDef.effectLevel`.** The operational model classifies cells with `bodyType : BodyType` (hard/soft/stem). The denotational model classifies cells with `effectLevel : EffectLevel` (pure/semantic/divergent). `Core.lean` defines both types (lines 71-85). `Coherent` does not require that `bodyType` and `effectLevel` correspond (e.g., `hard <-> pure`, `soft <-> semantic`, `stem <-> divergent`). A cell could be `bodyType = .hard` in the Retort and `effectLevel = .divergent` in the denotational program, and `Coherent` would accept it.

2. **`BodyInterp` is an unstructured function, not a morphism.** `yieldToVal : FieldName -> String -> Val` has no algebraic laws. There is no injectivity requirement (two different strings could map to the same `Val`). There is no surjectivity requirement (some `Val` constructors might be unreachable). There is no homomorphism property connecting string operations to `Val` operations. The interpretation is a raw function, not a structured mapping. This means `output_deterministic` (theorem 6) is a tautology -- `f(x) = f(x)` -- rather than a meaningful determinism result.

3. **The effect lattice still has no formal role (seven reviews running).** `EffectLevel.le` defines `pure <= semantic <= divergent`. No theorem in any file uses this ordering. No theorem says "a pure cell is deterministic" or "a divergent cell may produce unbounded frames." The classification exists in `Core.lean` and is referenced in `CellDef.effectLevel` but produces no type-level consequences anywhere in the model.

### Assessment: Does the refinement earn A+?

No. The refinement establishes a structural correspondence (names, generations, field counts) but not a behavioral one (values, dependencies, effect levels). The types now connect but do not constrain each other deeply enough. A publishable type-theoretic development would require `Coherent` to demand body correspondence and effect-level correspondence, and would give the effect lattice a formal role.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `bodyType <-> effectLevel` correspondence in `Coherent` | Easy | ~15 |
| `BodyInterp` algebraic laws (injectivity or homomorphism) | Medium | ~30 |
| `BodyType` formal role (determinism for hard cells) | Medium | ~40 |
| Effect lattice composability theorem | Medium | ~35 |

---

## Hoare (Verification): Grade A

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

`complete_implies_all_cells_traced` closes the loop from `programComplete` to denotational trace membership. `non_pour_frozen_preserved` establishes postcondition persistence. No progress on total correctness.

### Praises

1. **`complete_implies_all_cells_traced` is a partial correctness result.** The specification: `{Coherent rc /\ programComplete}` implies `{every non-stem cell has an ExecFrame in the trace}`. This is the partial correctness direction of the refinement: IF the program completes, THEN the trace is complete. It does not say the program will complete (that requires total correctness), but it says that completion implies completeness.

2. **`non_pour_frozen_preserved` is a frame stability postcondition.** After any non-pour operation, every frozen frame's ExecFrame persists with matching name and generation. This composes with `always_wellFormed`: at every step, frozen frames are stable, so the denotational trace only grows. Combined with `trace_length_bounded`, the trace is bounded and monotonically growing -- a key postcondition for any scheduler.

3. **`valid_trace_produces_valid_exec_frames` ties the temporal and refinement results together.** At every step of a `ValidWFTrace`, every frozen frame produces a valid ExecFrame. This uses `always_wellFormed` from Retort.lean indirectly (through the `ValidWFTrace` structure). The temporal safety theorem and the refinement theorem compose through the `ValidWFTrace` type.

### Critiques

1. **No total correctness (four reviews running).** All building blocks exist: `progress` (liveness), `claim_adds_claim` / `freeze_removes_claim` / `freeze_makes_frozen` (postconditions), `wellFormed_preserved` / `always_wellFormed` (safety), `complete_implies_all_cells_traced` (partial correctness). The missing theorem: "for a finite acyclic program, there exists a sequence of valid operations that makes `programComplete` true." This has been the top-priority hard item since v4. The refinement work does not advance it because the refinement theorems are about the abstraction function (what the trace looks like) not about the existence of a completing trace.

2. **No postcondition for `pour` connecting to `readyFrames` (two reviews running).** `pour_adds_cells` and `pour_adds_frames` prove membership. No theorem says "after pouring a program with no dependencies, the poured frames are in `readyFrames`." This remains the first missing link in the "pour -> ready -> progress -> claim -> freeze -> complete" chain.

3. **`finite_program_bounded` is not a termination argument.** The theorem proves `nonFrozenCount r prog <= r.frames.length`, which is tautologically true. A termination argument requires proving that each eval cycle *strictly decreases* `nonFrozenCount`. The building blocks exist: `freeze_makes_frozen` (a frame becomes frozen after freeze) and `freeze_removes_claim` (claims decrease). But no theorem says "after an eval cycle, `nonFrozenCount` decreases by at least 1." The refinement file provides the measure (`nonFrozenCount`) but not the progress lemma.

### Assessment: Does the refinement earn A+?

No. The refinement provides partial correctness (completion implies trace completeness) but not total correctness (completion is achievable). Partial correctness without total correctness is the defining characteristic of an incomplete verification. The model proves "if it terminates, it terminates correctly" but not "it terminates."

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Eval cycle decreases `nonFrozenCount` by 1 | Medium | ~50 |
| Zero `nonFrozenCount` implies `programComplete` (with cell-has-frame hyp) | Medium | ~30 |
| Total correctness theorem | Hard | ~60 |
| Pour -> readyFrames postcondition | Medium | ~40 |

---

## Wadler (Functional Programmer): Grade A

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

Refinement.lean adds structural equalities (`frameToExecFrame_cellName`, `frameToExecFrame_generation`, `output_deterministic`, `frameToExecFrame_deterministic`) that enable equational reasoning about the abstraction function. No new commutativity results.

### Praises

1. **`frameToExecFrame_deterministic` is a genuine equational law.** Two Retort states with the same yields and bindings for a frame produce identical ExecFrames. The proof is `simp only [hYields, hBindings]` -- pure equational rewriting. This is the algebraic foundation for replay: if you reconstruct the yields and bindings identically, the denotational trace is identical.

2. **The abstraction function is compositional.** `toExecTrace` is `frozenFrames.map frameToExecFrame`. `frozenFrames` is `frames.filter (frameStatus == .frozen)`. Each component is a standard list operation. This means algebraic reasoning about the trace reduces to algebraic reasoning about `List.map` and `List.filter`, both of which have extensive Lean4/Mathlib lemmas. The abstraction function inherits the algebraic properties of its components for free.

3. **`trace_length_eq_frozen_count` is a definitional equality.** The proof is `List.length_map`. This is not a deep theorem -- it is the abstraction function being correctly defined such that structural properties are immediate. Good abstractions make important properties trivial. This one does.

### Critiques

1. **No commutativity for independent pours or independent freezes (two reviews running).** The v6 claim commutativity is proven but not extended. Independent pours (disjoint programs) and independent freezes (different frameIds) should commute. The refinement work does not address this because it focuses on the abstraction function, not on the algebraic structure of `applyOp`.

2. **`appendOnly_trans` is still inlined (seven reviews running).** Refinement.lean adds uses of `appendOnly` (in `frozenFrames_preserved_by_appendOnly`) but does not extract the transitivity lemma. The pattern of manually composing 5 fields now appears in 4 locations across 2 files.

3. **`output_deterministic` is a tautology.** The theorem: `r1.frameYields fid = r2.frameYields fid -> yieldsToEnv interp (r1.frameYields fid) = yieldsToEnv interp (r2.frameYields fid)`. This is `f(x) = f(x)` after substitution. The proof is `rw [hYieldsEq]`. This is not a determinism result -- it is congruence of function application. A genuine determinism result would say "the same cell body with the same inputs produces the same yields," which requires connecting `body : String` to evaluation semantics.

### Assessment: Does the refinement earn A+?

No. The refinement provides useful equational facts about the abstraction function, but does not add new algebraic laws about the operational model. `output_deterministic` is a tautology. Commutativity results are not extended. The algebraic story is the same as v6 plus some definitional equalities.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `appendOnly_trans` lemma | Easy | ~10 |
| Commutativity of independent pours | Medium | ~50 |
| Commutativity of independent freezes | Medium | ~45 |
| Non-trivial determinism (same body + inputs -> same yields) | Hard | ~60 |

---

## Sussman (Systems Thinker): Grade A

**Core question:** Does the model compose? Can it be extended?

### What Changed

Refinement.lean is the first file to import both Retort.lean and Denotational.lean. The module system now has a diamond dependency: Core <- Retort <- Refinement and Core <- Denotational <- Refinement. The composition works without type collisions (after the `RCellDef` rename).

### Praises

1. **The diamond import works.** Core.lean is the shared base. Retort.lean and Denotational.lean both import Core. Refinement.lean imports both Retort and Denotational. The `RCellDef` rename prevents name collision. All shared types (`CellName`, `FrameId`, `FieldName`, `EffectLevel`, `BodyType`) resolve to Core's definitions in all four files. This is the module composition pattern that was designed in v1 (Core.lean) and is now fully exercised. A new module (e.g., Scheduler.lean) can import Refinement and access both models through a single coherent type universe.

2. **`RetortConfig` is the right extension point.** A system that wants to verify a specific program would: (a) construct a `Retort` by applying operations, (b) define the `Program Id` corresponding to the cell definitions, (c) define a `BodyInterp` mapping string yields to `Val`, (d) prove `Coherent`. Steps (a)-(c) are construction; step (d) is verification. The extension cost is proportional to the number of cells (each cell needs a name correspondence and field correspondence), not to the size of the model.

3. **The refinement theorems compose with the temporal theorems.** `valid_trace_produces_valid_exec_frames` uses `ValidWFTrace` (from Retort.lean). `non_pour_frozen_preserved` uses `cells_stable_non_pour` and `all_ops_appendOnly` (from Retort.lean). `complete_implies_all_cells_traced` uses `Coherent` (which includes `wellFormed` from Retort.lean). The refinement layer does not reinvent safety -- it imports and composes the existing safety infrastructure.

### Critiques

1. **No multi-program composition theorem (two reviews running).** Two sequential pours of independently well-formed programs still have no standalone composition result. Refinement.lean does not address this because it focuses on the abstraction function for a single Retort state, not on composing multiple programs.

2. **No operational correspondence between Retort.lean and Claims.lean (two reviews running).** Claims.lean defines its own `State` and transition functions. Retort.lean defines `Retort` and `applyOp`. Both import Core. No projection maps `Retort` to `Claims.State`. The refinement file connects Retort to Denotational but not Retort to Claims. The model now has three semantic layers (Claims, Retort, Denotational) with two connections (Claims-Core types, Retort-Denotational refinement) but no Claims-Retort correspondence.

3. **The abstraction function is not incremental.** `Retort.toExecTrace` recomputes the entire trace from scratch by filtering all frames and mapping all frozen ones. There is no incremental version: "given the old trace and one new operation, produce the new trace." An incremental abstraction function would enable compositional verification of operation sequences: prove each step preserves the trace property, rather than re-establishing it from scratch. `non_pour_frozen_preserved` is a step toward this (it shows existing ExecFrames persist), but it does not show the new ExecFrame (if any) is correct.

### Assessment: Does the refinement earn A+?

No. The refinement demonstrates that the module system composes correctly and that refinement theorems compose with temporal theorems. But the multi-program and Claims-Retort gaps remain, and the abstraction function is batch rather than incremental. The systems story is stronger -- Refinement.lean is the first cross-model file -- but the composition is not deep enough for A+.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Multi-program composition theorem | Medium | ~50 |
| Projection `Retort -> Claims.State` | Easy | ~15 |
| Operational correspondence (claim/freeze/release) | Medium | ~60 |
| Incremental abstraction function | Medium | ~40 |

---

## Consensus

### What Improved Since v6

The model addressed one of v6's nine priority actions, the most impactful one:

1. **Abstraction function + refinement theorem (DONE).** v6 priority #5. Seven-review-old request resolved. 507 lines, 19 theorems, zero sorry. `Retort.toExecTrace` maps frozen frames to denotational ExecFrames. `frozen_frame_corresponds` proves name-and-generation correspondence. `complete_implies_all_cells_traced` proves completeness. `frozenFrames_preserved_by_appendOnly` proves monotonicity. The operational and denotational models are now formally connected.

Eight priorities persist:

2. **`bindingsMonotone` remaining preservation proofs (NOT DONE, seven reviews).** Four trivial proofs still missing.

3. **`appendOnly_trans` lemma + stale summary comment (NOT DONE, two reviews).** Easy items not addressed.

4. **`generationOrdered` + `bindingsPointToFrozen` in `wellFormed` (NOT DONE, seven reviews).** DAG properties still defined-but-unproven.

5. **Commutativity of independent pours (NOT DONE, two reviews).** Algebraic structure not extended.

6. **Total correctness (NOT DONE, four reviews).** All building blocks present; assembly missing.

7. **Multi-program composition (NOT DONE, two reviews).** Not addressed.

8. **`BodyType` formal role (NOT DONE, seven reviews).** Effect lattice still decorative.

9. **`Retort -> Claims.State` projection (NOT DONE, two reviews).** Three semantic layers, only one cross-layer connection.

### Assessment: Is This an A+ Model?

No. The model is a solid A. The refinement work resolves the single most impactful open item from v6 and brings the total to 3,333 lines, 126 theorems, zero sorries across 5 files. The operational and denotational models are now connected by a formal abstraction function with a proven correspondence theorem.

It is not A+ because:

- **The refinement is structural, not behavioral.** `frozen_frame_corresponds` proves name-and-generation matching, not output-value matching. The theorem says "an ExecFrame with this name exists" not "the ExecFrame contains the correct values." This is a simulation relation on labels, not on semantics. A publishable refinement in the programming languages literature would prove value correspondence: the abstraction function commutes with evaluation.

- **No total correctness (four reviews running).** The model proves partial correctness (IF complete THEN correct) but not termination (WILL complete). For a runtime model, this is the central theorem. All building blocks exist; the assembly has not been attempted.

- **Weak points in the refinement theorems.** `finite_program_bounded` is a tautology (`List.length_filter_le`). `output_deterministic` is congruence (`rw [hYieldsEq]`). `zero_nonFrozen_implies_all_frozen` does not connect to `programComplete`. Three of ten refinement theorems are weaker than their names suggest. A publishable development would either strengthen these theorems or rename them to reflect their actual content.

- **Persistent easy items (seven reviews running).** `bindingsMonotone` needs four trivial proofs. The summary comment is stale. `appendOnly_trans` is inlined. These are collectively 30 minutes of mechanical work. Their persistence across seven reviews is a process failure, not a technical one.

### Is This Publishable?

Conditionally. The model has genuine substance: 126 machine-checked theorems, zero sorries, a clean module structure, and a formal abstraction function connecting two semantic layers. The safety story (9 invariants, 45 preservation proofs, temporal closure) is complete and real. The refinement exists and is sorry-free.

For a workshop paper (ITP, CPP) on "formalizing a database-backed cell runtime in Lean 4," the current model is sufficient as-is. The contribution would be the formalization methodology and the `wellFormed` / `always_wellFormed` infrastructure.

For a full research paper on "denotational-operational correspondence for the Cell runtime," the model needs: (a) behavioral refinement (output correspondence, not just name correspondence), (b) total correctness for finite programs, and (c) cleanup of the weak theorems. Items (a) and (b) are the hard remaining work. Item (c) is editorial.

### Grade Summary

| Reviewer | v1 | v2 | v3 | v4 | v5 | v6 | **v7** | Delta v6->v7 | Key Factor |
|----------|----|----|----|----|----|----|--------|--------------|------------|
| Feynman | B+ | B+ | A- | A- | A- | A | **A** | +0.0 | Abstraction function exists; refinement is structural not behavioral |
| Iverson | B | B | B+ | B+ | B+ | A | **A** | +0.0 | Refinement naming consistent; summary still stale; appendOnly_trans still inlined |
| Dijkstra | B- | B+ | A- | A- | A- | A | **A** | +0.0 | Refinement proofs genuine; finite_program_bounded tautological; DAG gaps persist |
| Milner | B | B | B+ | B+ | A- | A | **A** | +0.0 | RetortConfig correct; Coherent too weak; effect lattice still decorative |
| Hoare | C+ | B+ | A- | A | A | A | **A** | +0.0 | Partial correctness via completeness theorem; total correctness still missing |
| Wadler | B- | B+ | A- | A- | A- | A | **A** | +0.0 | Equational facts about abstraction; output_deterministic tautological; no new algebra |
| Sussman | B | B | B+ | B+ | A- | A | **A** | +0.0 | Diamond import works; three semantic layers; one cross-layer connection |

### Overall Grade: A

The model holds at A. The refinement work is genuine, substantial (507 lines), and addresses the most important open item. But it does not push any individual reviewer to A+ because the refinement is structural (names and generations) rather than behavioral (values and evaluation), and the persistent easy items remain unaddressed.

The grade plateau at A is diagnostic: the remaining distance to A+ requires either (a) deepening the refinement from structural to behavioral, which is a hard theorem, or (b) proving total correctness, which is a hard theorem. The easy items (bindingsMonotone, appendOnly_trans, summary comment) would not individually move the grade but their persistent absence signals that the development is prioritizing new theorems over consolidating existing ones.

### Priority Actions for v8

| Priority | Action | Difficulty | Impact | Est. LOC | Addresses |
|----------|--------|------------|--------|----------|-----------|
| 1 | `bindingsMonotone` preservation for pour/claim/release/createFrame | Easy | Low | ~30 | Dijkstra |
| 2 | `appendOnly_trans` lemma; update stale summary comment | Easy | Low | ~40 | Iverson, Wadler |
| 3 | Strengthen `Coherent` with dep/effect correspondence | Medium | High | ~40 | Milner, Feynman |
| 4 | Behavioral refinement: output values correspond | Hard | Critical | ~100 | All reviewers |
| 5 | Total correctness for finite acyclic programs | Hard | Critical | ~140 | Hoare |
| 6 | `generationOrdered` + `bindingsPointToFrozen` in `wellFormed` | Medium | Medium | ~140 | Dijkstra |
| 7 | `zero_nonFrozen_implies_all_frozen` -> `programComplete` connection | Medium | Medium | ~30 | Dijkstra, Hoare |
| 8 | Multi-program composition theorem | Medium | Medium | ~50 | Sussman |
| 9 | Projection `Retort -> Claims.State` + operational correspondence | Medium | Medium | ~75 | Sussman |

**Minimum path to all-A+:** Actions 1-9 (~645 LOC). Actions 1-2 are purely mechanical (clear the backlog). Action 3 strengthens the simulation relation. Actions 4-5 are the two intellectually hard theorems that would transform the model from "well-structured formalization with structural refinement" to "publishable denotational-operational correspondence with total correctness."

**What would move the grade to A+:** Actions 4 and 5. Behavioral refinement (output correspondence, not just name correspondence) would push Feynman, Milner, Wadler, and Sussman to A+. Total correctness would push Hoare to A+. Combined with the Coherent strengthening (action 3), Dijkstra and Iverson would follow once the easy items (actions 1-2) are cleared. The two hard theorems are the gate. Everything else is engineering.

# Seven Sages Review v8: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated formal model. This review evaluates the changes since the v7 review. The model now spans 7 files (Core.lean, Retort.lean, Denotational.lean, Claims.lean, Refinement.lean, StemCell.lean, lakefile.lean) totaling 4,464 lines with 145 theorems (93 in Retort.lean, 16 in Claims.lean, 4 in Denotational.lean, 25 in Refinement.lean, 7 in StemCell.lean), zero sorries. `lake build` clean.

## Changes Since v7 Review

The v7 review identified nine priority actions. Status:

| # | Action | v7 Status | v8 Status |
|---|--------|-----------|-----------|
| 1 | `bindingsMonotone` preservation for pour/claim/release/createFrame | NOT DONE (seven reviews) | **DONE** -- `pour_preserves_bindingsMonotone`, `claim_preserves_bindingsMonotone`, `release_preserves_bindingsMonotone`, `createFrame_preserves_bindingsMonotone` (lines 594-646) |
| 2 | `appendOnly_trans` lemma; update stale summary comment | NOT DONE (two reviews) | **DONE** -- `appendOnly_trans` factored at line 1502; summary comment rewritten (lines 1823-1929) with I8, I9, all theorems, all 5 ops |
| 3 | Strengthen `Coherent` with dep/effect correspondence | NOT DONE | **PARTIALLY DONE** -- `depsCorrespond` added to `Coherent` (lines 115-133); effect correspondence not added |
| 4 | Behavioral refinement: output values correspond | NOT DONE | **DONE** -- `CellBodyFaithful`, `bodiesFaithful`, `frozen_frame_outputs_match`, `frozen_frame_full_correspondence`, `complete_program_all_outputs_correct` (lines 506-660) |
| 5 | Total correctness for finite acyclic programs | NOT DONE (four reviews) | NOT DONE (five reviews) |
| 6 | `generationOrdered` + `bindingsPointToFrozen` in `wellFormed` | NOT DONE (seven reviews) | NOT DONE (eight reviews) |
| 7 | `zero_nonFrozen_implies_all_frozen` -> `programComplete` connection | NOT DONE | NOT DONE |
| 8 | Multi-program composition theorem | NOT DONE (two reviews) | NOT DONE (three reviews) |
| 9 | Projection `Retort -> Claims.State` + operational correspondence | NOT DONE (two reviews) | NOT DONE (three reviews) |

Key additions (five-action sweep):

1. **`bindingsMonotone` preservation -- all 5 operations (lines 572-646, 75 lines).** The seven-review gap is closed. `pour_preserves_bindingsMonotone` requires `bindingsWellFormed` as a hypothesis: new frames from a pour might match old bindings' consumer IDs, but since bindings were well-formed against old frames, the old frame with that ID already existed. `claim_preserves_bindingsMonotone` and `release_preserves_bindingsMonotone` are trivial (bindings and yields unchanged). `createFrame_preserves_bindingsMonotone` mirrors the pour proof, requiring `bindingsWellFormed`. `freeze_preserves_bindingsMonotone` (already present in v7) uses `freezeBindingsWitnessed`. All five sorry-free.

2. **`appendOnly_trans` factored as named lemma (line 1502, 10 lines).** The eight-character proof decomposes the 5-field `appendOnly` tuple, chains the preservation functions via function composition, and reconstructs the tuple. `evalCycle_appendOnly` (line 1513) now calls `appendOnly_trans` twice instead of manually threading fields. `data_persists` (line 1695) uses `appendOnly_trans` in the inductive step. The inlining pattern that existed across 4 locations in 2 files is eliminated.

3. **Summary comment fully rewritten (lines 1823-1929).** Now lists all 9 invariants (I1-I9), all 5 operations for each invariant, `appendOnly_trans`, `bindingsMonotone` preservation for all operations, `ValidWFTrace`, `always_wellFormed`, `MonotoneDemand`, `stemHasDemand_preserved`, and the claim commutativity theorems. Correctly states "all 9 invariants, all 5 operations." No mention of stale "I1-I7" or "claimLog."

4. **`depsCorrespond` strengthens `Coherent` (lines 115-133).** The operational givens table now formally mirrors the denotational deps list: for every `GivenSpec` in the Retort, the corresponding denotational `CellDef` has a `Dep` matching on `sourceCell`, `sourceField`, and `optional`. `Coherent` now bundles `wellFormed`, `cellsCorrespond`, `fieldsCorrespond`, and `depsCorrespond`. `given_has_matching_dep` (line 204) is the new theorem exercising this predicate.

5. **Behavioral refinement: `CellBodyFaithful` + `bodiesFaithful` + three theorems (lines 506-660, 155 lines).** This is the A+ gate theorem that was missing for seven reviews.

   - `CellBodyFaithful` (line 506): a structure asserting that for a specific frozen frame `f` and its corresponding denotational `CellDef dcd`, the interpreted operational yields equal the denotational body's output when called on the interpreted inputs. The key field `outputsMatch` states: `yieldsToEnv(interp, frameYields(f)) = fst(dcd.body(interpretedInputs))`.

   - `bodiesFaithful` (line 518): for every frozen frame in the Retort, there exists a matching `CellDef` with `CellBodyFaithful`.

   - `frozen_frame_outputs_match` (line 547): the core behavioral refinement theorem. Under `Coherent` and `bodiesFaithful`, a frozen frame has a corresponding ExecFrame in the denotational trace whose outputs equal the denotational body's evaluation on the interpreted inputs. The proof chains `frozen_in_frozenFrames`, `execFrame_in_trace`, `bodiesFaithful`, then rewrites via `frameToExecFrame_outputs` and `frameToExecFrame_inputs` to connect the two value domains.

   - `frozen_frame_full_correspondence` (line 582): the combined structural + behavioral soundness result. Every frozen frame has an ExecFrame with matching name, generation, correct outputs (via body evaluation), AND correct inputs (from binding resolution).

   - `complete_program_all_outputs_correct` (line 613): the full program soundness theorem. When `programComplete` is true and `bodiesFaithful` holds, every non-stem cell's ExecFrame has output values matching the denotational body evaluation. The proof decomposes `programComplete`, finds the witness frame via `List.mem_map`, extracts frozen-frame membership, applies `bodiesFaithful`, and rewrites outputs.

Total across active files: 4,464 lines. 145 theorems. Zero sorry.

---

## Feynman (Physicist): Grade A+

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The seven-review gap between structural and behavioral refinement is closed. `frozen_frame_outputs_match` proves that operational outputs equal denotational body evaluation. The model now explains what the system computes, not just what names it assigns.

### Praises

1. **`frozen_frame_outputs_match` is the theorem that elevates the refinement from naming to semantics.** The v7 critique was precise: `frozen_frame_corresponds` proves "an ExecFrame with this name exists" but not "the ExecFrame contains the right values." `frozen_frame_outputs_match` fills this gap. The statement: under `Coherent rc`, `bodiesFaithful rc`, and a frozen frame `f`, there exists an ExecFrame `ef` in the trace where `ef.outputs = fst(dcd.body(ef.inputs))` for the corresponding denotational cell. This is a genuine simulation: the abstraction function commutes with evaluation. The operational model produces the same values as the denotational specification, not just the same labels.

2. **`CellBodyFaithful` is an honest design choice, not a cheat.** The Retort stores bodies as opaque strings evaluated by external pistons. The denotational model stores bodies as callable Lean functions (`CellBody Id`). These are genuinely different representations with no mechanical bridge. `CellBodyFaithful` makes the semantic commitment explicit: "the piston computed what the body specifies." This is an axiom about the external world (piston correctness), which is the correct boundary -- you cannot prove piston correctness inside the Lean model because pistons are LLM calls. The assumption is stated cleanly, used precisely, and produces a meaningful theorem. Contrast with v7's `BodyInterp`, which bridged value representations but not computational semantics.

3. **`complete_program_all_outputs_correct` closes the full program loop.** The chain is now complete: `Coherent` (structural correspondence) + `bodiesFaithful` (value correspondence) + `programComplete` (all cells have frozen frames) implies every cell's ExecFrame has correct outputs. This is partial correctness for the entire program, not just individual frames. The proof at lines 613-660 is 48 lines of genuine theorem composition: it decomposes `programComplete`, finds the frozen frame witness via the trace abstraction, applies `bodiesFaithful`, and rewrites through the bridge types.

### Remaining Critique

1. **`bodiesFaithful` is an assumption, not a derived property.** This is inherent to the architecture (pistons are external), but it means the behavioral refinement is conditional on an unverified premise. A future development could define a restricted "hard cell" where the body is a Lean function and `CellBodyFaithful` is provable, not assumed. For pure/hard cells, `CellBodyFaithful` should be a theorem, not an axiom. This would give a complete (non-conditional) refinement for the deterministic fragment.

### Why A+

The refinement now has three layers: structural (names and generations via `frozen_frame_corresponds`), dependency (givens mirror deps via `given_has_matching_dep`), and behavioral (outputs match body evaluation via `frozen_frame_outputs_match`). The combined result (`frozen_frame_full_correspondence`) establishes that the operational model is a faithful implementation of the denotational specification across all three dimensions. The `bodiesFaithful` assumption is the correct abstraction boundary for a system with external pistons. This is the standard form of a simulation theorem in the programming languages literature: an abstraction function, a simulation relation, and a commuting diagram on values.

---

## Iverson (Notation Designer): Grade A+

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

The two-review stale summary is fixed. `appendOnly_trans` is factored. `depsCorrespond` is a new definition exercised by `given_has_matching_dep`. The behavioral refinement adds 5 definitions and 6 theorems, all following established naming conventions.

### Praises

1. **The summary comment (lines 1823-1929) is now accurate and complete.** It lists all 9 invariants by number and name. It lists all 5 operations for each invariant preservation section. It includes `appendOnly_trans`, `bindingsMonotone` preservation for all operations, `ValidWFTrace`, `always_wellFormed`, and the stem cell lifecycle. It correctly states "all 9 invariants, all 5 operations." The two-review staleness is resolved. A reader encountering the codebase for the first time can use this summary as a reliable index.

2. **`appendOnly_trans` eliminates the inlining pattern.** The lemma at line 1502 is 10 lines. `evalCycle_appendOnly` (line 1513) now reads `exact appendOnly_trans _ _ _ h1 h2` for the `none` case and `exact appendOnly_trans _ _ _ h1 (appendOnly_trans _ _ _ h2 h3)` for the `some` case -- composing transitivity cleanly instead of manually destructuring 5 fields. `data_persists` (line 1695) composes `ih` with `always_appendOnly` via `appendOnly_trans`. The pattern is now used, not replicated.

3. **Every new definition in the behavioral refinement participates in a theorem.** `CellBodyFaithful` is used in `bodiesFaithful` and `frozen_frame_outputs_match`. `bodiesFaithful` is a hypothesis in `frozen_frame_outputs_match`, `frozen_frame_full_correspondence`, and `complete_program_all_outputs_correct`. `frameToExecFrame_outputs` and `frameToExecFrame_inputs` (helper theorems) are used in the behavioral refinement proofs. Zero vestigial definitions in the new code.

### Remaining Critique

1. **`BodyInterp.fieldMap` still defaults to `id` and is never used non-trivially.** The v7 critique persists: no theorem constrains or exercises `fieldMap` beyond identity. It adds a parameter to `yieldsToEnv` and `frameToExecFrame` without justification. Removing it (or adding a bijectivity constraint) would tighten the interface.

### Why A+

The codebase is now self-documenting: the summary comment accurately indexes 145 theorems across 7 files, naming conventions are systematic (`{subject}_{predicate}` for theorems, `{Adjective}{Noun}` for structures), every definition participates in a proof, and the two longest-running notation debts (`appendOnly_trans` inlining, stale summary) are cleared. The `fieldMap` issue is a minor wart on an otherwise disciplined notation system.

---

## Dijkstra (Formalist): Grade A

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

`bindingsMonotone` preservation is complete for all 5 operations. `appendOnly_trans` is a named lemma. The behavioral refinement adds 6 genuine proofs. `depsCorrespond` strengthens `Coherent`.

### Praises

1. **`bindingsMonotone` preservation is complete (lines 572-646).** The seven-review gap is closed. The four new proofs are structurally uniform: `claim_preserves_bindingsMonotone` and `release_preserves_bindingsMonotone` are each 5 lines (bindings and yields unchanged, so `hWF` applies directly). `pour_preserves_bindingsMonotone` and `createFrame_preserves_bindingsMonotone` each require `bindingsWellFormed` as a hypothesis because new frames might match old binding consumer IDs -- but `bindingsWellFormed` guarantees the old frame already existed, so `hWF` applies. The `pour` proof (line 594) is 15 lines; the `createFrame` proof (line 633) is 14 lines. Both are structurally identical: case split on frame membership, delegate old frames to `hWF`, use `bindingsWellFormed` to find the original frame for new-frame cases.

2. **`frozen_frame_outputs_match` is a non-trivial 30-line proof.** Lines 547-576: it chains `frozen_in_frozenFrames` (frame is in `frozenFrames`), `execFrame_in_trace` (ExecFrame is in the trace), `hFaithful f hMem hFrozen` (body faithfulness gives the CellDef and the faithfulness proof), then rewrites the goal via `frameToExecFrame_outputs` and `frameToExecFrame_inputs` to connect the operational yields/bindings to the denotational body's inputs/outputs. The final step is `exact hBF.outputsMatch`, which discharges the let-binding in the goal. This is genuine proof composition, not a tautology.

3. **`complete_program_all_outputs_correct` at line 613 is 48 lines of real proof.** It decomposes `programComplete` (a `Bool` from `List.all`), extracts the `hasFrozen` disjunct, finds the witness frame in `frozenFrames` via `List.mem_map`, extracts membership and frozen-status from the filter predicate, applies `bodiesFaithful` to get the CellDef and faithfulness proof, constructs the ExecFrame witness, and rewrites outputs. This chains six previously independent results into a single program-level soundness statement.

### Critiques

1. **`generationOrdered` and `bindingsPointToFrozen` remain defined-but-unproven (eight reviews running).** Lines 1452 and 1460 in Retort.lean. Neither has preservation proofs. Neither is in `wellFormed`. The bindings graph is still not proven to be a DAG in the transitive sense. The behavioral refinement does not address this because it reasons about frozen frame values, not about the dependency graph structure.

2. **`finite_program_bounded` remains tautological.** The v7 critique is unchanged: the theorem proves `nonFrozenCount r prog <= r.frames.length` via `List.length_filter_le`. The `_hNoStem` hypothesis is still decorative. The new `bindingsMonotone` proofs do not strengthen this theorem.

3. **`zero_nonFrozen_implies_all_frozen` still does not connect to `programComplete`.** The v7 gap persists. `nonFrozenCount = 0` means all existing frames are frozen; `programComplete` means every cell has at least one frozen frame. No theorem bridges these two conditions.

4. **`depsCorrespond` strengthens `Coherent` but `bodyType <-> effectLevel` correspondence is still absent.** A Retort cell with `bodyType = .hard` could correspond to a denotational cell with `effectLevel = .divergent` and `Coherent` would accept it. The effect lattice classification remains decorative across models.

### Assessment: Does the model earn A+?

No. The behavioral refinement is genuine, `bindingsMonotone` is complete, and `appendOnly_trans` is factored -- three significant improvements. But the eight-review `generationOrdered`/`bindingsPointToFrozen` gap persists, `finite_program_bounded` is still tautological, and the `nonFrozenCount`-to-`programComplete` connection is still missing. The formalist requires that every named theorem prove what its name implies. Two theorems (`finite_program_bounded`, `zero_nonFrozen_implies_all_frozen`) still underdeliver relative to their documentation.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| `generationOrdered` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| `bindingsPointToFrozen` in `wellFormed` + 5 preservation proofs | Medium | ~70 |
| Strengthen `finite_program_bounded` to use `noStemCells` non-trivially, or rename to `nonFrozenCount_bounded` | Easy | ~5 |
| Connect `zero_nonFrozen_implies_all_frozen` to `programComplete` | Medium | ~30 |

---

## Milner (Type Theorist): Grade A+

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

`depsCorrespond` strengthens the simulation relation. `CellBodyFaithful` introduces a structured per-cell faithfulness predicate. The refinement now connects three levels: structural (names), dependency (givens/deps), and behavioral (values).

### Praises

1. **`CellBodyFaithful` is a well-typed specification of the semantic bridge.** It is a structure (not a bare Prop) with a single field `outputsMatch` that expresses the commuting diagram: interpreted operational outputs equal denotational body outputs on interpreted inputs. The structure is parameterized over `rc : RetortConfig`, `f : Frame`, and `dcd : CellDef Id` -- the operational state, the specific frame, and the denotational cell. This is the correct type for a per-cell simulation witness. It composes cleanly: `bodiesFaithful` universally quantifies over frozen frames, producing `CellBodyFaithful` witnesses that `frozen_frame_outputs_match` consumes.

2. **`depsCorrespond` closes the dependency gap in the simulation relation.** The v7 critique: `Coherent` matched names and field counts but not dependencies. Now `Coherent` includes `depsOk : depsCorrespond rc`, which requires every operational `GivenSpec` to have a matching denotational `Dep` with same `sourceCell`, `sourceField`, and `optional`. This means the DAG structure is preserved across abstraction layers, not just the node labels. `given_has_matching_dep` (line 204) is the straightforward witness-extraction theorem.

3. **The three-level refinement composes correctly.** Level 1 (structural): `cellsCorrespond` + `fieldsCorrespond` ensures nodes match. Level 2 (dependency): `depsCorrespond` ensures edges match. Level 3 (behavioral): `bodiesFaithful` ensures computed values match. `frozen_frame_full_correspondence` (line 582) composes all three into a single theorem: every frozen frame has an ExecFrame with matching name, generation, correct outputs via body evaluation, AND correct inputs via binding resolution. The types flow cleanly: `Coherent` bundles levels 1-2, `bodiesFaithful` adds level 3, and the combined theorem requires both.

### Remaining Critique

1. **`bodyType <-> effectLevel` correspondence is still absent.** The operational `BodyType` (hard/soft/stem) and denotational `EffectLevel` (pure/semantic/divergent) are both defined in `Core.lean` but no formal connection exists. `Coherent` does not require them to correspond. The effect lattice remains typographically present but semantically inert.

### Why A+

The refinement now has the structure of a publishable simulation theorem: an abstraction function (`toExecTrace`), a simulation relation (`Coherent` + `bodiesFaithful`) with three levels of correspondence (structural, dependency, behavioral), and a commuting diagram on values (`frozen_frame_outputs_match`). The typing discipline is sound: every hypothesis in the refinement theorems is necessary, every definition participates in a proof, and the composition from per-cell faithfulness to program-level soundness is type-safe and clean. The `bodyType`/`effectLevel` gap is real but secondary -- it affects classification, not correctness. The core type-theoretic contribution (a three-level simulation relation for a database-backed cell runtime) is complete.

---

## Hoare (Verification): Grade A

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

`complete_program_all_outputs_correct` establishes program-level partial correctness with value correspondence. `bindingsMonotone` is now a fully proven property. No progress on total correctness.

### Praises

1. **`complete_program_all_outputs_correct` is a genuine program-level partial correctness result.** The specification: `{Coherent rc /\ bodiesFaithful rc /\ programComplete}` implies `{every non-stem cell has an ExecFrame with outputs = body(inputs)}`. This is partial correctness with value correspondence -- the strongest form available without total correctness. Compared to v7's `complete_implies_all_cells_traced` (which only proved existence of an ExecFrame with matching name), this proves the ExecFrame contains the RIGHT values.

2. **`frozen_frame_full_correspondence` is a per-frame Hoare triple.** Precondition: `Coherent`, `bodiesFaithful`, frame is frozen. Postcondition: ExecFrame exists with matching name, matching generation, outputs equal body evaluation on inputs, inputs equal interpreted bindings. This is a complete specification of what "correct execution of a single cell" means. Every field of the postcondition is proven, not just asserted.

3. **`bindingsMonotone` full preservation closes a postcondition gap.** The property that resolved bindings never change (because bindings and yields are append-only and unique) is now a fully proven invariant for all operations. This means `resolveBindings` at time T returns a subset of `resolveBindings` at time T' > T (with identical values for existing entries). This is the postcondition needed for replay correctness: re-resolving a frozen frame's bindings at any later time produces the same or more results.

### Critiques

1. **No total correctness (five reviews running).** All building blocks exist and are now stronger than in v7: `progress` (liveness), `claim_adds_claim` / `freeze_removes_claim` / `freeze_makes_frozen` (postconditions), `wellFormed_preserved` / `always_wellFormed` (safety), `complete_program_all_outputs_correct` (partial correctness with values). The missing theorem: "for a finite acyclic program, there exists a sequence of valid operations that makes `programComplete` true." This has been the top-priority hard item since v4. The behavioral refinement work does not advance it because the refinement theorems are about the abstraction function (what the trace looks like) not about the existence of a completing trace.

2. **No "eval cycle decreases nonFrozenCount" lemma.** The preconditions for the decreasing measure exist: `freeze_makes_frozen` (a frame becomes frozen) and `freeze_removes_claim` (claims decrease). But no theorem says "after a valid eval cycle on a non-stem frame, `nonFrozenCount` decreases by exactly 1." This is the key progress lemma for total correctness.

3. **No postcondition connecting `pour` to `readyFrames` (three reviews running).** `pour_adds_frames` proves membership. No theorem says "after pouring a program whose cells have no dependencies, the poured frames are in `readyFrames`." This remains the first link in the "pour -> ready -> progress -> claim -> freeze -> complete" chain.

### Assessment: Does the model earn A+?

No. The partial correctness story is now best-in-class: program-level value correspondence under a clean simulation relation. But total correctness remains unaddressed for five consecutive reviews. The model proves "if it terminates, every output is correct" but not "it terminates." For a runtime model, termination is the central theorem. The building blocks are all present; assembly is the missing step.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Eval cycle decreases `nonFrozenCount` by 1 | Medium | ~50 |
| Zero `nonFrozenCount` + cell-has-frame implies `programComplete` | Medium | ~30 |
| Total correctness theorem (composition of above) | Hard | ~60 |
| Pour -> readyFrames postcondition for zero-dep programs | Medium | ~40 |

---

## Wadler (Functional Programmer): Grade A+

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

`appendOnly_trans` is factored as a named lemma. The behavioral refinement provides equational laws connecting operational yields to denotational body evaluation. `evalCycle_appendOnly` and `data_persists` now compose via `appendOnly_trans`.

### Praises

1. **`appendOnly_trans` enables algebraic composition of append-only proofs.** The lemma at line 1502 is the monoidal composition law for the append-only preorder. `evalCycle_appendOnly` now reads as clean algebraic composition: `appendOnly_trans _ _ _ h1 h2` for two steps, `appendOnly_trans _ _ _ h1 (appendOnly_trans _ _ _ h2 h3)` for three. `data_persists` uses it in the inductive step: `appendOnly_trans _ _ _ (ih hk) (always_appendOnly vt k)`. The pattern of manually threading 5 fields is eliminated from all call sites.

2. **`frameToExecFrame_outputs` and `frameToExecFrame_inputs` are definitional equalities that enable equational rewriting.** Both are `rfl` proofs (lines 527-537). They allow the behavioral refinement proofs to rewrite ExecFrame fields in terms of `yieldsToEnv` and `resolveBindings`, which are the compositional building blocks. The `frozen_frame_outputs_match` proof finishes with `rw [frameToExecFrame_outputs]; rw [frameToExecFrame_inputs]; exact hBF.outputsMatch` -- pure equational reasoning through the abstraction layers.

3. **`frozen_frame_full_correspondence` is an equational characterization of correctness.** The theorem says: for a frozen frame, the ExecFrame satisfies four equalities simultaneously -- `ef.cellName = f.cellName.val` (name), `ef.generation = f.generation` (generation), `ef.outputs = fst(dcd.body(ef.inputs))` (output correctness), `ef.inputs = interpreted bindings` (input correctness). These are four equational laws that together fully characterize the abstraction function's behavior on frozen frames. The proof composes equational lemmas without case analysis.

### Remaining Critique

1. **No commutativity for independent pours or independent freezes (three reviews running).** The claim commutativity from v6 is not extended. Independent pours (disjoint programs) and independent freezes (different frameIds) should commute. The algebraic structure of `applyOp` is still underexplored beyond claims.

2. **`output_deterministic` is still a tautology.** The v7 theorem `rw [hYieldsEq]` is unchanged. The behavioral refinement does not strengthen it because `output_deterministic` operates at the `yieldsToEnv` level, not at the body-evaluation level.

### Why A+

The algebraic story underwent a qualitative change. In v7, equational reasoning about the refinement was limited to structural equalities (`cellName`, `generation`). In v8, `frozen_frame_outputs_match` provides the equational law `ef.outputs = fst(dcd.body(ef.inputs))` -- connecting operational outputs to denotational body evaluation via equational rewriting. `appendOnly_trans` cleans up the monoidal composition pattern. The abstraction function is now algebraically characterized: it is a homomorphism from the operational model to the denotational model that preserves both structure (names, generations, dependencies) and values (outputs equal body evaluation on inputs). The `output_deterministic` tautology and missing commutativity results are blemishes, but the core algebraic contribution -- an equationally-characterized behavioral refinement -- is complete.

---

## Sussman (Systems Thinker): Grade A

**Core question:** Does the model compose? Can it be extended?

### What Changed

The behavioral refinement adds `CellBodyFaithful` and `bodiesFaithful` as extension points for verifying specific programs. `depsCorrespond` strengthens the cross-model connection. No progress on multi-program composition or Claims-Retort correspondence.

### Praises

1. **`bodiesFaithful` is a practical verification interface.** A system that wants to verify a specific program now has a clear protocol: (a) construct a `RetortConfig` with a `BodyInterp`, (b) prove `Coherent` (structural, dependency, and field correspondence), (c) prove `bodiesFaithful` (each frozen frame's yields match the denotational body's outputs). Step (c) is the new requirement and is the correct one: it forces the verifier to establish that the piston computed correctly. For hard cells (SQL bodies), `CellBodyFaithful` could be proven mechanically by interpreting the SQL as a Lean function. For soft cells (LLM bodies), it would be an axiom -- correctly reflecting the system's trust boundary.

2. **The refinement now has three cross-model connections.** (a) `cellsCorrespond` + `fieldsCorrespond`: Retort cell definitions map to denotational cell definitions. (b) `depsCorrespond`: Retort givens map to denotational deps. (c) `bodiesFaithful`: Retort yield values match denotational body outputs. Together, these cover the three aspects of cell identity: name (what it's called), structure (what it depends on), and behavior (what it computes). Each connection is independently useful: you can verify naming without verifying behavior, or verify behavior for a subset of cells.

3. **`complete_program_all_outputs_correct` composes the verification chain.** The theorem takes `Coherent`, `bodiesFaithful`, and `programComplete` and produces a universal statement over all non-stem cells. This is the system-level composition: individual cell-level faithfulness proofs (`CellBodyFaithful`) compose into program-level correctness. The proof (lines 613-660) demonstrates this composition explicitly: it iterates over cells, finds their frames, extracts faithfulness, and applies it.

### Critiques

1. **No multi-program composition theorem (three reviews running).** Two sequential pours of independently well-formed programs still have no standalone composition result. The behavioral refinement does not address this because `bodiesFaithful` and `Coherent` are defined for a single RetortConfig.

2. **No operational correspondence between Retort.lean and Claims.lean (three reviews running).** Claims.lean defines its own `State` and transition functions. Retort.lean defines `Retort` and `applyOp`. Both import Core. No projection maps `Retort` to `Claims.State`. The model now has three semantic layers (Claims, Retort, Denotational) with one cross-layer connection (Retort-Denotational refinement) but no Claims-Retort correspondence.

3. **The abstraction function is still not incremental.** `Retort.toExecTrace` recomputes the entire trace from scratch. `non_pour_frozen_preserved` shows existing ExecFrames persist after non-pour operations, but no theorem constructs the new ExecFrame incrementally.

### Assessment: Does the model earn A+?

No. The behavioral refinement strengthens the Retort-Denotational connection substantially, and `bodiesFaithful` provides a clean extension interface. But the multi-program gap (three reviews) and Claims-Retort gap (three reviews) persist. Two of three semantic layers (Claims, Retort, Denotational) are still disconnected. For a systems thinker, composition across ALL layers -- not just the two most recent ones -- is the standard.

### Path to A+

| Improvement | Difficulty | Estimated LOC |
|-------------|------------|---------------|
| Multi-program composition theorem | Medium | ~50 |
| Projection `Retort -> Claims.State` | Easy | ~15 |
| Operational correspondence (claim/freeze/release) | Medium | ~60 |
| Incremental abstraction (one-step trace update) | Medium | ~40 |

---

## Consensus

### What Improved Since v7

The model addressed five of v7's nine priority actions, including both "critical" items and all three "easy" items:

1. **`bindingsMonotone` all 5 preservation proofs (DONE, closed after seven reviews).** v7 priority #1. Five theorems, 75 lines.

2. **`appendOnly_trans` factored + summary comment updated (DONE, closed after two reviews).** v7 priority #2. Named lemma at line 1502; summary rewritten at lines 1823-1929.

3. **`depsCorrespond` strengthens `Coherent` (PARTIALLY DONE).** v7 priority #3. Dependency correspondence added; effect-level correspondence still absent.

4. **Behavioral refinement: output values correspond (DONE, closed after seven reviews).** v7 priority #4 (rated "Critical"). `CellBodyFaithful`, `bodiesFaithful`, `frozen_frame_outputs_match`, `frozen_frame_full_correspondence`, `complete_program_all_outputs_correct`. 155 lines, 6 theorems.

Four priorities persist:

5. **Total correctness (NOT DONE, five reviews).** v7 priority #5. All building blocks present; assembly missing.

6. **`generationOrdered` + `bindingsPointToFrozen` in `wellFormed` (NOT DONE, eight reviews).** v7 priority #6. DAG properties defined but unproven.

7. **`zero_nonFrozen_implies_all_frozen` -> `programComplete` (NOT DONE).** v7 priority #7.

8. **Multi-program composition + Claims-Retort projection (NOT DONE, three reviews).** v7 priorities #8-9.

### Assessment: Is This an A+ Model?

Conditionally yes. Four of seven reviewers grade A+ (Feynman, Iverson, Milner, Wadler). Three grade A (Dijkstra, Hoare, Sussman). The overall grade advances from A to A/A+.

The model earns A+ from four reviewers because:

- **The behavioral refinement is the qualitative breakthrough.** `frozen_frame_outputs_match` transforms the model from "structural correspondence" (names match) to "behavioral correspondence" (values match). This is the standard form of a simulation theorem in the PL literature: abstraction function + simulation relation + commuting diagram on values. The proof is 30 lines of genuine theorem composition, not a tautology.

- **The persistent easy items are cleared.** `bindingsMonotone` (seven reviews), `appendOnly_trans` (two reviews), and the stale summary (two reviews) are all resolved. This demonstrates the development is consolidating, not just accumulating.

- **The simulation relation has three levels.** Structural (names/fields via `cellsCorrespond`/`fieldsCorrespond`), dependency (givens/deps via `depsCorrespond`), and behavioral (values via `bodiesFaithful`). Combined in `frozen_frame_full_correspondence`. This is comprehensive enough for publication.

It does not earn A+ from three reviewers because:

- **No total correctness (five reviews running).** The model proves "if it terminates, every output is correct" but not "it terminates." For Hoare, this is the defining gap.

- **`generationOrdered`/`bindingsPointToFrozen` unproven (eight reviews running).** For Dijkstra, named-but-unproven properties in a formal model are a discipline failure.

- **Three semantic layers, one cross-layer connection.** For Sussman, Claims.lean remains an island.

### Is This Publishable?

Yes. The model is now publishable as a full research paper, not just a workshop paper.

**For a conference paper (POPL, ICFP, CPP) on "denotational-operational correspondence for a database-backed cell runtime in Lean 4":** The contribution is the three-level simulation theorem (`frozen_frame_full_correspondence`) connecting an operational state machine (Retort: claims, bindings, append-only yields) to a denotational semantics (Program: DAGs of cells with callable bodies) via a formally verified abstraction function. Supporting results include 9 invariants with 45 preservation proofs, temporal safety via `always_wellFormed`, and program-level partial correctness with value correspondence (`complete_program_all_outputs_correct`). 4,464 lines, 145 theorems, zero sorry.

**What a reviewer would note:** The absence of total correctness and the conditional nature of `bodiesFaithful` (it's an assumption, not derived). A reviewer might request the hard-cell specialization where `CellBodyFaithful` is provable. These are natural future-work items, not blocking deficiencies.

### Grade Summary

| Reviewer | v1 | v2 | v3 | v4 | v5 | v6 | v7 | **v8** | Delta v7->v8 | Key Factor |
|----------|----|----|----|----|----|----|----|----|--------------|------------|
| Feynman | B+ | B+ | A- | A- | A- | A | A | **A+** | +1 | Behavioral refinement: outputs match body evaluation |
| Iverson | B | B | B+ | B+ | B+ | A | A | **A+** | +1 | Summary fixed, appendOnly_trans factored, zero vestigial defs |
| Dijkstra | B- | B+ | A- | A- | A- | A | A | **A** | +0 | bindingsMonotone complete, but generationOrdered 8 reviews unproven |
| Milner | B | B | B+ | B+ | A- | A | A | **A+** | +1 | Three-level simulation relation; CellBodyFaithful well-typed |
| Hoare | C+ | B+ | A- | A | A | A | A | **A** | +0 | Best partial correctness yet; total correctness 5 reviews missing |
| Wadler | B- | B+ | A- | A- | A- | A | A | **A+** | +1 | Equational behavioral refinement; appendOnly_trans monoidal |
| Sussman | B | B | B+ | B+ | A- | A | A | **A** | +0 | bodiesFaithful good extension point; Claims-Retort still disconnected |

### Overall Grade: A/A+

The model advances from A to A/A+ (four reviewers at A+, three at A). The behavioral refinement is the watershed: it transforms a well-structured formalization with structural correspondence into a publishable denotational-operational correspondence with value-level soundness.

### Priority Actions for v9

| Priority | Action | Difficulty | Impact | Est. LOC | Addresses |
|----------|--------|------------|--------|----------|-----------|
| 1 | Total correctness for finite acyclic programs | Hard | Critical | ~140 | Hoare -> A+ |
| 2 | `generationOrdered` + `bindingsPointToFrozen` in `wellFormed` + preservation | Medium | High | ~140 | Dijkstra -> A+ |
| 3 | `zero_nonFrozen_implies_all_frozen` -> `programComplete` connection | Medium | Medium | ~30 | Dijkstra, Hoare |
| 4 | Multi-program composition theorem | Medium | Medium | ~50 | Sussman -> A+ |
| 5 | Projection `Retort -> Claims.State` + operational correspondence | Medium | Medium | ~75 | Sussman -> A+ |
| 6 | `bodyType <-> effectLevel` correspondence in `Coherent` | Easy | Low | ~15 | Dijkstra, Milner |
| 7 | Hard-cell specialization: `CellBodyFaithful` as theorem, not axiom | Medium | Medium | ~60 | Feynman |

**Minimum path to all-A+:** Actions 1-5 (~435 LOC). Action 1 is the single hardest remaining theorem and would push Hoare to A+. Action 2 would push Dijkstra to A+. Actions 4-5 would push Sussman to A+. Actions 6-7 are polish.

**What moved the grade:** Actions 4 (behavioral refinement) and 1-2 (clearing the backlog) from the v7 priorities. The behavioral refinement was the gate. Clearing the easy backlog demonstrated consolidation discipline. Together they pushed four reviewers from A to A+, breaking the grade plateau that held from v5 through v7.

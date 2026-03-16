# Seven Sages Review v3: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated `Retort.lean` (1581 lines, 53 theorems, zero sorries). This review evaluates the changes since the v2 review.

## Changes Since v2 Review

The v2 review identified seven priority actions. Status:

| # | Action | v2 Status | v3 Status |
|---|--------|-----------|-----------|
| 1 | Prove preservation for remaining invariants (I2-I5, I7); compose into `wellFormed_preserved` | 3 of 7 done | **DONE** -- all 7 invariants, all 5 operations, master composite proved |
| 2 | Add postcondition theorems | Missing | **DONE** -- `claim_adds_claim`, `freeze_removes_claim`, `createFrame_adds_frame` |
| 3 | Create `Core.lean` with shared types | Missing | NOT DONE |
| 4 | Prove existential progress | Missing | NOT DONE |
| 5 | Denotational-operational correspondence | Missing | NOT DONE |
| 6 | Prove commutativity of independent operations | Missing | NOT DONE |
| 7 | Constrain `stemHasDemand`; prove multi-program composition | Missing | NOT DONE |

Key additions: 6 new preconditions (`pourFramesUnique`, `createFrameUnique`, `freezeFrameExists`, `freezeBindingsRefFrames`, `freezeYieldsUnique`, `validOp` composite); 30+ invariant preservation theorems covering all 35 invariant-operation pairs; `wellFormed_preserved` master theorem; 3 postcondition theorems; `filter_remove_decreases` helper for `freeze_removes_claim`.

---

## Feynman (Physicist): Grade A-

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The `wellFormed_preserved` theorem is the qualitative leap. Previously, the model described invariants and described operations, but never connected them with a conditional statement of the form "if the system is in a good state and the operation is legitimate, the system stays in a good state." That connection is now present and mechanically verified. This is the transition from describing a machine to explaining why the machine does not break.

The postconditions add the complementary direction: not only does the machine not break, but operations accomplish their stated purpose. `claim_adds_claim` says claiming actually claims. `freeze_removes_claim` says freezing actually releases the lock. These are banal-sounding statements, but they are exactly the statements that compose into progress arguments.

### Praises

1. **The model now has a safety story with teeth.** `wellFormed_preserved` is a universal statement: for ANY retort, ANY operation, if wellFormed holds and validOp holds, then wellFormed holds after. This is not case-by-case reasoning. It is a single theorem that dispatches to 35 individual proofs. The five-way case split in the proof is honest work: each operation arm assembles 7 invariant preservation results from the correct component theorems and inline proofs. The pour case is the most informative because it requires three preconditions (valid, internally unique, frames unique) while release requires none.

2. **The preconditions are explanatory, not just restrictive.** `freezeFrameExists` says "you cannot freeze a frame that does not exist." `freezeBindingsRefFrames` says "bindings must point to real producer frames." `freezeYieldsUnique` says "a freeze cannot produce two different values for the same (frame, field)." Each precondition names a way the system could go wrong, and the preservation proof shows that excluding that failure mode is sufficient. The preconditions are the model's explanation of what makes operations safe.

### Critiques

1. **The two-model gap remains.** Retort.lean formalizes database transitions. Denotational.lean formalizes computation. There is still no refinement theorem connecting `evalStep` to `claim + freeze`. The preconditions and postconditions are internal to Retort.lean. Nothing proves that the semantic model's evaluation and the database model's state machine agree. This is still the fundamental gap: the model explains the database but not the computation. For Feynman, an explanation must connect the observable behavior (yields produced) to the mechanism (cell body execution), and that connection passes through the denotational model.

2. **`stemHasDemand` remains an unconstrained hole.** The demand predicate is `Retort -> Bool` with no restrictions. The v1 review asked for monotonicity (once demand is true, more yields cannot make it false). This is now the third review making this request. Demand is the force that drives stem cell cycling, and it has no formal characterization. A stem cell with `demandPred = fun _ => true` is consistent with the model and spins forever.

### Path to A+

Write the refinement theorem: for well-formed programs, the retort-level trace (database operations) is a faithful simulation of the denotational-level trace (cell body evaluation). Constrain demand to be monotone with respect to the yield-append ordering.

---

## Iverson (Notation Designer): Grade B+

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

The six new preconditions introduce a well-designed vocabulary. The `validOp` composite dispatches cleanly by operation constructor, aggregating the relevant preconditions for each case. The postcondition theorems are crisply named: verb_noun_effect.

### Praises

1. **The precondition naming scheme is excellent.** Each precondition names the operation and the specific safety condition: `pourFramesUnique`, `createFrameUnique`, `freezeFrameExists`, `freezeBindingsRefFrames`, `freezeYieldsUnique`. The names are self-documenting. A reader can reconstruct what each predicate requires without reading its definition. The composite `validOp` aggregates them per-operation using a match on the constructor, which is the natural structure.

2. **The preservation theorem naming is systematic and complete.** Every theorem follows the pattern `{operation}_preserves_{invariant}`. This is 31 named theorems with zero exceptions to the naming convention. The non-pour case for cellNamesUnique uses `non_pour_preserves_cellNamesUnique` which handles four operations in one proof -- a reasonable consolidation that the master theorem then uses. The uniformity makes the model navigable: to find whether operation X preserves invariant Y, search for `X_preserves_Y`.

### Critiques

1. **`GivenSpec.cellName` is still confusingly named.** Third review, same issue. It means "the cell that declares this given" (the owner/dependent), not the cell being depended on. The field `sourceCell` names the dependency target. Having both `cellName` and `sourceCell` where `cellName` is the owner, not the cell, misleads every new reader. This is a one-line rename: `cellName` to `owner`.

2. **The claim log is still dead weight.** `ClaimLogEntry` and `claimLog` appear in the model, get proven append-only, but are never queried by any function or referenced by any invariant or postcondition. The postcondition `claim_adds_claim` counts `claims.length`, not `claimLog.length`. The `freeze_removes_claim` theorem references `claims`, not `claimLog`. The claimLog field exists in the Retort structure, it gets appended to in `applyOp`, but no theorem says anything interesting about it beyond structural append-only. Either prove an audit-trail property or remove it from the formal model.

3. **`ContentAddr.resolve` and `resolveBindings` still have no convergence theorem.** Third review, same issue. A frozen frame's inputs can be resolved two ways with no proof they agree. The `wellFormed_preserved` theorem does not require or produce any relationship between these two resolution paths. The model has two definitions of "look up a value" and does not say they give the same answer.

### Path to A

Rename `GivenSpec.cellName` to `GivenSpec.owner`. Either prove an audit property about claimLog or remove it. Prove `resolve` and `resolveBindings` agree for frozen frames with witnessed bindings.

---

## Dijkstra (Formalist): Grade A-

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

This is where the model has made its most dramatic advance. The v2 review's central criticism was that preservation was proved for 3 of 7 invariants. The v3 model proves preservation for all 7, covering all 35 invariant-operation pairs, and composes them into the master theorem `wellFormed_preserved`.

### Praises

1. **`wellFormed_preserved` is the theorem I demanded.** The statement is exactly what was requested: `wellFormed r -> validOp r op -> wellFormed (applyOp r op)`. The proof dispatches on the operation constructor, and for each case assembles 7 preservation results -- one per invariant. The pour case is the most complex, requiring three preconditions. The release case is the simplest, requiring no preconditions (release only removes claims via filter, which preserves everything). This is a well-structured dispatch proof, not a monolithic tactic block.

2. **The new preservation proofs for I2-I5 and I7 are genuine.** The `freeze_preserves_yieldsWellFormed` proof handles old yields (frame still exists since frames unchanged by freeze) and new yields (frameId matches fd.frameId by `freezeValid`, and the frame exists by `freezeFrameExists`). The BEq-to-Prop conversion via `List.all_eq_true` is applied correctly. The `freeze_preserves_bindingsWellFormed` proof similarly splits on old/new bindings, using `freezeBindingsRefFrames` for producer frame existence. These are not trivial -- they require tracking which lists grow and which stay stable under each operation.

3. **The `freeze_preserves_yieldUnique` proof handles the full four-way case split.** Old-old (use existing invariant), old-new (use `freezeYieldsUnique.2` with symmetry), new-old (use `freezeYieldsUnique.2`), new-new (use `freezeYieldsUnique.1`). This is the pattern for any uniqueness-preservation proof over appended lists, and it is executed correctly. The symmetry argument in the old-new case (swapping the quantifiers and using `.symm`) is the move that would trip up an incomplete proof.

4. **The preconditions are well-calibrated.** Each precondition is exactly strong enough for its preservation proof and no stronger. `pourFramesUnique` has two conjuncts: new-vs-existing and new-vs-new. `freezeYieldsUnique` has two conjuncts: internal uniqueness and cross-set compatibility. These decompositions mirror the case splits in the proofs. The preconditions were reverse-engineered from the proof obligations, which is the correct methodology.

### Critiques

1. **DAG properties remain unproven as invariants.** `noSelfLoops`, `generationOrdered`, and `bindingsPointToFrozen` are defined (lines 1176-1191) but have no preservation proofs. They are not part of `wellFormed`. The `wellFormed_preserved` theorem says nothing about them. A freeze operation could create a binding where `consumerFrame = producerFrame` and the model would not prevent it -- `freezeValid` checks that `b.consumerFrame == fd.frameId` but does not check `b.producerFrame != fd.frameId`. The DAG is the core structural property of the dependency graph, and it is formally stated but not formally maintained.

2. **`bindingsMonotone` is outside `wellFormed` and has no preservation proof for non-freeze operations.** `freeze_preserves_bindingsMonotone` exists, but there is no `pour_preserves_bindingsMonotone`, no `createFrame_preserves_bindingsMonotone`, etc. Pour adds frames (which `bindingsMonotone` quantifies over). CreateFrame adds frames. A new frame with no bindings trivially satisfies the inner quantifier (vacuously), but this is not proved. The monotonicity invariant is proved to survive freeze but not proved to survive the full operation set. It is also not included in `wellFormed`, so `wellFormed_preserved` does not subsume it.

3. **`stemCellsDemandDriven` (I8) is defined but excluded from `wellFormed`.** Line 381-387 defines an eighth invariant, `stemCellsDemandDriven`, complete with a comment hedging its formulation. It is not included in the `wellFormed` predicate and has no preservation proofs. If it is not load-bearing, it should be removed. If it is, it should be in `wellFormed` with preservation proofs.

### Path to A+

Include `noSelfLoops` in `wellFormed` (or a separate `dagWellFormed` composite), prove it preserved by all operations with a precondition on freeze. Prove `bindingsMonotone` preserved by all 5 operations (or include it in `wellFormed`). Either delete `stemCellsDemandDriven` or include it in `wellFormed` with proofs.

---

## Milner (Type Theorist): Grade B+

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

The `validOp` predicate introduces a form of operation-indexed refinement: each operation constructor carries a different set of preconditions. This is dependent typing in spirit -- the validity of an operation depends on the current state. The master theorem's five-arm case split maps each constructor to its specific set of required preconditions.

### Praises

1. **`validOp` is a well-structured dependent predicate.** It maps each `RetortOp` constructor to its appropriate precondition conjunction: `pour` requires 3, `claim` requires 1, `freeze` requires 5, `release` requires 0, `createFrame` requires 1. The asymmetry is informative: freeze is the most complex operation because it simultaneously adds yields, adds bindings, and removes a claim. The predicate's structure reveals the operation's complexity.

2. **The precondition/postcondition pair for freeze is tight.** `freezeValid` + `freezeBindingsWitnessed` + `freezeFrameExists` + `freezeBindingsRefFrames` + `freezeYieldsUnique` (5 preconditions) together with `freeze_removes_claim` (postcondition) and 7 invariant preservation theorems fully characterize what freeze does and what it requires. This is the most thoroughly specified operation in the model.

### Critiques

1. **The type universes are still disconnected.** Retort.lean's `CellDef` has `body : String`. Denotational.lean's `CellDef M` has `body : CellBody M`. These are two unrelated types. No functor, no embedding, no morphism. `LawfulBEq` instances give the identity types algebraic structure, but they do not bridge the semantic gap between "a cell body is a string" and "a cell body is a function." The formalization remains two disconnected models.

2. **The effect lattice has no formal role in Retort.lean.** `BodyType` classifies cells as hard/soft/stem. No theorem references `BodyType` except `stemCellsDemandDriven` (which is excluded from `wellFormed`). No precondition distinguishes hard from soft cells. No preservation proof cares whether a cell is hard or soft. The classification exists in the type definitions but is invisible to the proof machinery. An effect system that the proofs ignore is documentation, not a type discipline.

3. **No composition theorem for disjoint programs.** The `pourValid` precondition ensures new cell names do not collide with existing ones within the same program. But there is no theorem that two sequential pours with disjoint program IDs yield a well-formed retort. The `pour_preserves_cellNamesUnique` theorem handles the cell-name dimension but the full `wellFormed` preservation for sequential pours of independent programs is not stated as a standalone composition result. In practice, multi-program pours are the primary use case.

### Path to A

Define an abstraction function from Denotational.lean's `CellDef M` to Retort.lean's `CellDef`. Prove a composition theorem: two pours with disjoint program IDs and individually valid data compose into a wellFormed retort. Give `BodyType` a formal role by proving some property that distinguishes hard/soft/stem at the invariant level.

---

## Hoare (Verification): Grade A-

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

This is the reviewer who demanded preconditions, postconditions, and Hoare triples. The v3 model delivers all three.

### Praises

1. **The Hoare triples are complete for safety.** For every operation and every invariant in `wellFormed`, the model provides `{P /\ Pre} op {P}` where P is the invariant and Pre is the operation's precondition. The master theorem `wellFormed_preserved` is the composite: `{wellFormed /\ validOp} applyOp {wellFormed}`. This is a textbook verified state machine. Every safety property that the model claims is mechanically proved to hold under stated preconditions.

2. **The postconditions are genuine positive-effect theorems.** `claim_adds_claim` says the claims list grows by exactly one element. `freeze_removes_claim` says the claims list strictly shrinks (with a proper proof via `filter_remove_decreases` that handles the inductive step over the list structure). `createFrame_adds_frame` says the new frame is a member of the resulting frames list. These are not preservation theorems -- they are effect theorems. They say what operations DO, not just what they do not break.

3. **The `freeze_removes_claim` proof is non-trivial.** It requires a helper lemma `filter_remove_decreases` that proves: if a list has an element that does not satisfy the filter predicate, the filtered list is strictly shorter. The proof is by induction on the list with a case split on whether the head satisfies the predicate. The key step uses `Nat.lt_succ_of_le` and `List.length_filter_le` for the false-head case and `omega` for the true-head case. This is a real data-structure lemma, not a trivial unfolding.

### Critiques

1. **No progress theorem.** The v2 review asked: "if `readyFrames r` is non-empty, there exists a valid `ClaimData` satisfying `claimValid`." This would be existential progress: the system CAN take a step when there is work to do. This is still absent. The postconditions say operations accomplish their purpose. The preconditions say when operations are valid. But nothing says that preconditions are ever satisfiable. A retort where `readyFrames` is always empty satisfies all theorems vacuously.

2. **No total correctness for finite programs at the retort level.** The denotational `nonStem_finite` (in Denotational.lean, proved in v2) says that evaluation produces at most `p.cells.length` frames. But there is no corresponding statement in Retort.lean: "given a well-formed retort with a finite acyclic program, there exists a sequence of valid eval cycles that freezes all frames." The postconditions give the pieces (`claim_adds_claim`, `freeze_removes_claim`) but the end-to-end theorem is not assembled.

3. **Postconditions are incomplete.** There is no postcondition for pour: "after a pour, all poured cells are in the retort and all poured frames are in the retort." There is no postcondition for freeze that says "after a freeze, the frame has yields" or "after a freeze, the frame's status is frozen." The existing postconditions cover three of five operations, and only in terms of list lengths and membership, not in terms of derived state (e.g., `frameStatus`).

### Path to A+

Prove existential progress: `readyFrames r != [] -> exists cd, claimValid r cd`. Add postconditions for pour and freeze in terms of derived state (`frameStatus` becomes `.frozen` after freeze with all fields). State total correctness: for a finite acyclic program, there exists a valid operation sequence leading to `programComplete`.

---

## Wadler (Functional Programmer): Grade A-

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

The `wellFormed_preserved` theorem elevates the model from a collection of individual preservation results to a closed algebraic system: the set of well-formed retorts is closed under valid operations. The postconditions add the forward direction: operations produce specific, predictable effects.

### Praises

1. **`wellFormed_preserved` gives the model algebraic closure.** The well-formed retorts form a set, and `validOp`-guarded `applyOp` is an endomorphism on that set. This is the key algebraic property: the set of good states is closed under the transition function. Every downstream theorem can assume `wellFormed` as a precondition and produce `wellFormed` as a postcondition, enabling compositional reasoning about operation sequences.

2. **The postconditions restore monotone structure.** `claim_adds_claim` says `claims.length` increases by 1. `freeze_removes_claim` says `claims.length` strictly decreases. Together with `frames_monotonic`, `yields_monotonic`, and `bindings_monotonic`, the model now characterizes how each measurable quantity changes under each operation. The claims list is the exception to monotonicity (it can shrink), and the postconditions make this precise.

3. **The proof structure is ready for abstraction.** The preservation proofs for non-modifying operations follow three patterns: (a) the list is unchanged, so the invariant holds by hypothesis rewriting; (b) the list grew by append, so old elements are preserved via `List.mem_append_left`; (c) the list shrank by filter, so remaining elements satisfy the original invariant by `List.mem_filter`. These three patterns cover 25+ of the 35 invariant-operation pairs. A generic tactic or lemma capturing "filter preserves universal properties" and "append preserves universal properties when new elements satisfy the invariant" would factor the entire preservation proof suite.

### Critiques

1. **No commutativity laws.** The v1 review asked: do independent claims commute? `applyOp (applyOp r (claim a)) (claim b) = applyOp (applyOp r (claim b)) (claim a)` when `a.frameId != b.frameId`. This is still absent after three reviews. Without commutativity, concurrent execution cannot be justified algebraically. Every interleaving must be analyzed independently. This is the theorem that would make the retort model useful for reasoning about piston concurrency.

2. **`applyOp` still returns `Retort` unconditionally.** It is a total function that accepts invalid operations silently. The preconditions exist as separate predicates, but the function itself does not enforce them. A cleaner algebraic model would have `applyOpChecked : Retort -> RetortOp -> Option Retort` or would require the precondition as a dependent argument. The current design means that `applyOp r op` always produces a `Retort`, and only the surrounding theorems distinguish valid from invalid applications. This is workable but not elegant.

3. **The preservation proofs share common patterns without common lemmas.** `freeze_preserves_claimMutex` and `release_preserves_claimMutex` are nearly identical (both use `List.mem_filter` to reduce to the original invariant). `pour_preserves_bindingsWellFormed` and `createFrame_preserves_bindingsWellFormed` are nearly identical (both use `List.mem_append_left` to lift frame membership). A "filter-preserves-forall" lemma and an "append-preserves-existential-with-left" lemma would each factor 5+ proofs. The repetition is not wrong, but it signals missing abstractions.

### Path to A+

Prove commutativity of independent claims and independent pours. Extract the three common proof patterns into reusable lemmas. Consider defining `applyOpChecked` as a wrapper, even if `applyOp` remains the primary definition.

---

## Sussman (Systems Thinker): Grade B+

**Core question:** Does the model compose? Can it be extended?

### What Changed

The `wellFormed_preserved` theorem and the `validOp` composite make the model significantly more trustworthy as a foundation for extension. Adding a new operation now has a clear checklist: add a constructor, add a case to `applyOp`, define preconditions, prove 7 preservation theorems, add a case to `validOp` and `wellFormed_preserved`. The pattern is mechanical.

### Praises

1. **The extension protocol is now fully explicit.** The `wellFormed_preserved` proof is a five-arm match. Adding a sixth operation (e.g., `archive : FrameId -> RetortOp`) requires: (a) adding the constructor, (b) defining `archiveValid`, (c) proving 7 preservation theorems (at least 5 of which will be trivial if archive only removes data), (d) adding one arm to `wellFormed_preserved`. Every existing theorem and proof remains untouched. This is the correct structure for an extensible verified system.

2. **The precondition stratification reveals operational complexity.** `validOp` maps: pour -> 3 preconditions, claim -> 1, freeze -> 5, release -> 0, createFrame -> 1. This tells a systems engineer exactly which operations are dangerous and why. Freeze is dangerous because it simultaneously mutates three lists (yields grow, bindings grow, claims shrink) with cross-list referential integrity requirements. Release is safe because it only removes entries via filter. The precondition count is a proxy for operation complexity.

### Critiques

1. **The four files remain disconnected.** Third review. `CellDef` in Retort.lean, `CellDef M` in Denotational.lean, types in StemCell.lean, and `State` in Claims.lean are independent definitions. No shared `Core.lean` exists. The v2 review noted that Claims.lean and Retort.lean prove the same mutex property on different models. This redundancy persists. Any change to a fundamental type (e.g., adding a field to `Frame`) requires coordinated edits across all four files with no compiler enforcement. This is a maintenance liability that grows with every new theorem.

2. **No multi-program composition theorem.** The retort supports multiple programs via repeated pours. `pourValid` prevents name collisions within a program. But there is no theorem showing that two sequential pours of independently well-formed programs produce a well-formed retort, even when their program IDs differ. The `wellFormed_preserved` theorem handles one pour at a time. The composition of two pours into a single well-formed retort requires showing that the second pour's preconditions are satisfiable given the first pour's effects. This is the theorem a systems engineer needs to reason about program loading.

3. **No garbage collection or archival story.** The append-only invariant and `data_persists` theorem guarantee that every frame, yield, and binding exists forever. For a stem cell producing 100,000 generations, this means 100,000 frame entries, each with yields and bindings, all provably permanent. The model has no concept of "old data that can be pruned" or "generations that are no longer reachable from active computation." The `appendOnly` invariant, as currently stated, is incompatible with any form of compaction. A production system needs a weaker invariant: "data reachable from active frames is preserved."

4. **`ValidTrace` requires operations but not their validity.** The `ValidTrace` structure records `trace` and `ops` with a step function, but does not require `validOp (trace n) (ops n)`. This means a `ValidTrace` can contain invalid operations. The `always_appendOnly` theorem holds regardless (since `all_ops_appendOnly` is unconditional), but `wellFormed_preserved` requires `validOp`. A `ValidWFTrace` that additionally requires `validOp` at each step and `wellFormed` at the initial state would enable a stronger result: `always wellFormed` on valid well-formed traces.

### Path to A

Create `Core.lean` with shared types. Define `ValidWFTrace` with `validOp` requirements and prove `always wellFormed` as an inductive corollary of `wellFormed_preserved`. Prove multi-program composition. Define a `compact` operation that removes old generations while preserving well-formedness for reachable frames.

---

## Consensus

### What Improved Since v2

The model has made substantial progress on the v2 review's top two priorities, delivering them completely:

1. **Full invariant preservation coverage.** All 7 invariants in `wellFormed` are proved preserved by all 5 operations. This is 35 invariant-operation pairs, each either proved via a named theorem or proved inline in the master theorem. The v2 model had 3 of 7 invariants covered. The v3 model has 7 of 7. This is a complete resolution of the v2 review's top priority.

2. **The `wellFormed_preserved` master theorem.** `wellFormed r -> validOp r op -> wellFormed (applyOp r op)` is the single most important theorem in the model. It transforms the formalization from "a collection of individual preservation results that a user must manually assemble" to "a closed safety system where well-formedness is compositionally maintained." Every downstream user of the model can work with `wellFormed` as a single predicate rather than tracking 7 invariants independently.

3. **Postcondition theorems.** `claim_adds_claim`, `freeze_removes_claim`, and `createFrame_adds_frame` establish the positive effects of operations. Combined with the preservation theorems, the model now characterizes both what operations preserve (invariants) and what they produce (effects). The `freeze_removes_claim` proof via `filter_remove_decreases` is genuine data-structure reasoning.

4. **Six new preconditions articulate the full safety envelope.** `pourFramesUnique`, `createFrameUnique`, `freezeFrameExists`, `freezeBindingsRefFrames`, `freezeYieldsUnique`, and the `validOp` composite give each operation a complete specification of when it is safe. The total precondition count per operation (pour: 3, claim: 1, freeze: 5, release: 0, createFrame: 1) reflects the operational complexity accurately.

### What Remains

Three systemic issues from previous reviews persist, and one structural issue is newly visible:

1. **Disconnected formalizations (three reviews running).** Four files, four type universes, zero morphisms. No `Core.lean`. The retort model and the denotational model are not linked by a refinement theorem. Claims.lean and Retort.lean model the same claim system independently. This is the oldest open issue.

2. **No liveness or progress.** The model proves safety comprehensively: invariants are preserved, data persists, mutex holds, operations have correct effects. Liveness is entirely absent: no theorem says ready frames can be claimed (existential progress), no theorem says finite programs terminate at the retort level, no fairness assumption exists. The postconditions are the building blocks for progress, but the assembly is missing.

3. **DAG properties and `bindingsMonotone` are outside `wellFormed`.** The three DAG predicates (`noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen`) are defined but have no preservation proofs. `bindingsMonotone` has a preservation proof for freeze but not for the other four operations. `stemCellsDemandDriven` is defined but excluded from `wellFormed`. The model has a tier-1 safety predicate (`wellFormed`, fully proved) and a tier-2 set of predicates (defined, partially or not proved). The tier-2 predicates include structurally important properties (acyclicity, monotonicity) that should arguably be tier-1.

4. **`stemHasDemand` is unconstrained (three reviews running).** The demand predicate is `Retort -> Bool` with no monotonicity, no dependency restriction, no characterization. This is the mechanism that drives stem cell cycling -- the most novel aspect of the system -- and it is a black box.

### Grade Summary

| Reviewer | v1 Grade | v2 Grade | v3 Grade | Delta v2->v3 | Key Factor |
|----------|----------|----------|----------|--------------|------------|
| Feynman | B+ | B+ | **A-** | +0.5 | `wellFormed_preserved` makes model explanatory; two-model gap blocks A |
| Iverson | B | B | **B+** | +0.5 | Precondition vocabulary excellent; naming/dead-weight issues persist |
| Dijkstra | B- | B+ | **A-** | +0.5 | Full invariant coverage achieved; DAG properties still outside |
| Milner | B | B | **B+** | +0.5 | `validOp` is dependent typing in spirit; type universes still disconnected |
| Hoare | C+ | B+ | **A-** | +0.5 | Hoare triples complete for safety; no progress theorem |
| Wadler | B- | B+ | **A-** | +0.5 | Algebraic closure achieved; no commutativity laws |
| Sussman | B | B | **B+** | +0.5 | Extension protocol clear; module structure still absent |

### Overall Grade: A-

The model has moved from B+ to A-. The `wellFormed_preserved` theorem and the complete invariant preservation coverage represent a qualitative transition: the model is now a closed, mechanically verified safety system for the retort state machine. Every invariant is proved preserved by every operation under stated preconditions. The postconditions establish that operations accomplish their purpose. Zero sorries, standard axioms only.

The grade does not reach A because of three persistent gaps:

- **No liveness.** Safety is proved. Progress is not. The model proves the system cannot break but does not prove it can make forward progress.
- **Disconnected formalizations.** The retort model and the denotational model exist in separate type universes with no formal connection. The proof that the database model is a faithful implementation of the semantic model is absent.
- **DAG properties are second-class.** The acyclicity and monotonicity properties that give the dependency graph its structure are defined but not maintained by the proof machinery.

The grade does not reach A+ because none of the seven reviewers gave a perfect score. The two-model gap (Feynman, Milner), the missing progress theorem (Hoare), the missing commutativity laws (Wadler), the absent module structure (Sussman), the dead-weight notation (Iverson), and the second-class DAG properties (Dijkstra) each represent genuine work that remains.

### Priority Actions for v4

| Priority | Action | Difficulty | Impact | Addresses |
|----------|--------|------------|--------|-----------|
| 1 | Prove existential progress: `readyFrames r != [] -> exists cd, claimValid r cd` | Medium | High | Hoare |
| 2 | Include DAG properties + `bindingsMonotone` in `wellFormed` (or a `dagWellFormed` predicate); prove preservation for all operations | Medium | High | Dijkstra |
| 3 | Create `Core.lean` with shared types; eliminate parallel type universes | Low | High | Sussman, Milner |
| 4 | State and prove denotational-operational correspondence (refinement theorem) | Hard | High | Feynman, Milner |
| 5 | Prove commutativity of independent claims and independent pours | Medium | Medium | Wadler |
| 6 | Constrain `stemHasDemand` with monotonicity; define `ValidWFTrace` | Low | Medium | Feynman, Sussman |
| 7 | Add remaining postconditions (pour membership, freeze produces `.frozen` status) | Low | Medium | Hoare, Iverson |

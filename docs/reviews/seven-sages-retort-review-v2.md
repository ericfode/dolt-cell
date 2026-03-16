# Seven Sages Review v2: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated formal model across four Lean files: `Retort.lean`, `Denotational.lean`, `StemCell.lean`, and `Claims.lean`. This review evaluates the changes since the v1 review, focusing on the three major improvements: operation preconditions, preservation proofs, and the elimination of all sorries.

## Changes Since v1 Review

The v1 review identified seven priority actions. Status:

| # | Action | v1 Status | v2 Status |
|---|--------|-----------|-----------|
| 1 | Add operation preconditions and prove well-formedness preservation | Missing | **DONE** -- `pourValid`, `claimValid`, `freezeValid`, `freezeBindingsWitnessed` defined; 6 preservation proofs |
| 2 | Unify type definitions across files into shared Core.lean | Missing | NOT DONE |
| 3 | Prove `bindingsMonotone` (bindings point to real data) | Stated as Prop | **DONE** -- `freeze_preserves_bindingsMonotone` proved under `freezeBindingsWitnessed` |
| 4 | Prove `nonStem_finite` (remove sorry) | `sorry` | **DONE** -- proved via helper `evalN_length_le` |
| 5 | Denotational-operational correspondence | Missing | NOT DONE |
| 6 | Constrain `stemHasDemand` with monotonicity | Missing | NOT DONE |
| 7 | Prove commutativity of independent operations | Missing | NOT DONE |

Additionally: `LawfulBEq` instances for all five identity types, enabling the precondition proofs to convert between `BEq` and `Prop` equality. Zero sorries remain across all four files.

---

## Feynman (Physicist): Grade B+

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The preconditions are a step toward explanation. `pourValid` says: "a pour is safe when new names don't collide with existing ones." `claimValid` says: "a claim is safe when the frame exists, is ready, and unclaimed." These are not just structural constraints -- they articulate WHEN operations are meaningful. The `freezeBindingsWitnessed` precondition is particularly telling: it says every binding in a freeze must have a corresponding yield, either already in the retort or being produced by this freeze. That is a physical constraint -- you cannot record that you read data that does not exist.

### Praises

1. **The preconditions make the model falsifiable.** Before, `applyOp` accepted anything and the theorems said "garbage accumulates correctly." Now, the preservation theorems say "IF the precondition holds, THEN the invariant is preserved." This is a conditional statement with teeth: if you violate the precondition, the theorem does not apply, and you know you are outside the safe envelope. This is how physical laws work -- they tell you what happens when conditions are met, and the conditions themselves are informative.

2. **The `nonStem_finite` proof via `evalN_length_le` is honest.** The helper proves that `evalN` adds at most one frame per step, so after `p.cells.length` steps you have at most that many frames. The proof sidesteps the harder question (does every cell get exactly one frame?) by proving the weaker but still useful bound. This is good physics: prove what you can prove cleanly, state what remains.

### Critiques

1. **The two models still do not talk to each other.** The fundamental gap from v1 remains: Retort.lean formalizes database transitions, Denotational.lean formalizes computation, and there is no refinement theorem connecting them. The preconditions are internal to Retort.lean. Nothing says that the semantic `evalStep` (which actually runs cell bodies) corresponds to `claim + freeze` (which shuffles table rows). This is still two half-explanations.

2. **`stemHasDemand` is still an unconstrained hole.** The demand predicate remains `Retort -> Bool` with no restrictions. The v1 review asked for monotonicity (once demand is true, more yields cannot make it false). This is still absent. Demand is the force that drives stem cell generation, and it has no characterization.

### Path to A

Write the refinement theorem connecting `evalStep` to `claim + freeze`. This would make both models load-bearing: the denotational model defines what a program means, the retort model defines how it executes, and the refinement theorem says they agree. Also constrain demand predicates: demand should depend only on yields (observable state), and should be monotone with respect to the append-only ordering.

---

## Iverson (Notation Designer): Grade B

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

The `LawfulBEq` instances are infrastructure that enables cleaner proofs. The `find?_isNone_forall_neg` helper extracts the semantic content of a failed lookup. These are notational improvements that reduce proof noise.

### Praises

1. **The precondition vocabulary is well-designed.** `pourValid`, `pourInternallyUnique`, `claimValid`, `freezeValid`, `freezeBindingsWitnessed` -- five predicates with clear names and distinct concerns. They decompose the safety conditions into independently statable and checkable pieces. `pourValid` handles cross-set collisions; `pourInternallyUnique` handles intra-set collisions. This decomposition is deliberate and useful.

2. **The `LawfulBEq` instances pay for themselves.** Every identity type (`CellName`, `ProgramId`, `FrameId`, `PistonId`, `FieldName`) gets a `LawfulBEq` instance. This is boilerplate, but necessary boilerplate: the precondition proofs need to convert between `(a == b) = true` and `a = b`, and `LawfulBEq` provides this bridge systematically. Without it, each proof would need ad-hoc BEq-to-Prop conversions.

### Critiques

1. **`GivenSpec.cellName` is still confusingly named.** The v1 review flagged that `cellName` means "the cell that declares this given" (the owner/dependent), not the cell being depended on. It should be `owner` or `dependentCell`. This has not changed.

2. **The claim log is still dead weight.** `ClaimLogEntry` and `claimLog` appear in the model, get proven append-only, but are never queried by any function or referenced by any property beyond the structural append-only theorems. No audit trail property, no replayability theorem, nothing. Either use it or cut it from the formal model.

3. **`ContentAddr.resolve` and `resolveBindings` still offer two resolution paths with no convergence.** A frame's inputs can be resolved two ways: via content addressing (find the frame, find the yield) or via bindings (look up the pre-recorded resolution). The v1 review asked for these to be defined in terms of each other or proven equivalent. Neither happened.

### Path to A

Rename `GivenSpec.cellName` to `GivenSpec.owner`. Either prove an audit-trail property about `claimLog` (e.g., it contains a complete record of all claim transitions) or remove it from the formal model. Prove that `resolve` and `resolveBindings` agree for frozen frames with recorded bindings.

---

## Dijkstra (Formalist): Grade B+

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

This is where the most significant improvement occurred. The v1 review's central critique was: "you defined `wellFormed` but never proved it is an invariant." The v2 model addresses this directly with six preservation proofs:

1. `pour_preserves_cellNamesUnique` -- under `pourValid` and `pourInternallyUnique`
2. `non_pour_preserves_cellNamesUnique` -- trivial (cells unchanged)
3. `claim_preserves_claimMutex` -- under `claimValid`
4. `freeze_preserves_claimMutex` -- unconditional (filter only removes)
5. `release_preserves_claimMutex` -- unconditional (filter only removes)
6. `freeze_preserves_bindingsMonotone` -- under `freezeBindingsWitnessed`

The `nonStem_finite` sorry has been eliminated with a clean structural proof.

### Praises

1. **The `claim_preserves_claimMutex` proof is real Lean work.** It handles four cases: both old, both new, one old + one new (two symmetric subcases). The key move is extracting from `claimValid` that no existing claim has the target frameId, then using this to derive a contradiction when an old claim and the new claim share a frameId. The BEq-to-Prop conversion via `beq_self_eq_true` is applied correctly. This is not a trivial proof -- it required understanding how `List.find?` interacts with `Option.isNone` and how `LawfulBEq` bridges the gap.

2. **The `freeze_preserves_bindingsMonotone` proof correctly handles the old/new split.** Old bindings are preserved because yields only grew (the existing `hWF` applies with `List.mem_append_left`). New bindings are handled by `freezeBindingsWitnessed`, which guarantees a matching yield exists in `r.yields ++ fd.yields`. The proof structure mirrors the operational meaning: old data is safe because append-only, new data is safe because the precondition checked it.

3. **The `nonStem_finite` proof is structurally clean.** The helper `evalN_length_le` is proved by induction on `n` with an `omega` finish. The main theorem delegates to the helper, sidestepping the harder question of whether every cell fires exactly once. This is the right factoring: prove the easy structural bound, leave the tighter semantic bound for later.

### Critiques

1. **Well-formedness preservation is proved for three of seven invariants.** Of the seven invariants (I1 through I7 plus `stemCellsDemandDriven`), preservation is proved for `cellNamesUnique` (I1), `claimMutex` (I6), and `bindingsMonotone` (not in the I1-I7 list but related). Missing: `framesUnique` (I2), `yieldsWellFormed` (I3), `bindingsWellFormed` (I4), `claimsWellFormed` (I5), `yieldUnique` (I7). The composite `wellFormed` predicate has no preservation theorem. The model proves preservation for the invariants that are hardest (mutex under concurrent claims) but leaves the simpler referential integrity invariants unproved.

2. **DAG properties remain unproven as invariants.** `noSelfLoops`, `generationOrdered`, and `bindingsPointToFrozen` are defined but have no preservation proofs. The v1 review specifically asked for `noSelfLoops` to be proven preserved by freeze. The `freezeValid` precondition checks that bindings reference the correct consumer frame, but does not check that `consumerFrame != producerFrame`. A freeze with a self-referencing binding would violate `noSelfLoops`, and the model does not prevent this.

3. **The preconditions are not proven sufficient for well-formedness preservation.** There is no master theorem: `wellFormed r -> (appropriate precondition for op) -> wellFormed (applyOp r op)`. The individual preservation proofs are components of such a theorem, but the composite statement is absent. This means a user of the model must manually assemble the right combination of preconditions and preservation theorems for each operation, with no guarantee they have not missed one.

### Path to A

Prove preservation for all seven invariants in `wellFormed`. For the referential integrity ones (I3-I5), the preconditions likely need strengthening -- e.g., `freezeValid` should require that the frame actually exists in `r.frames`. Add a `noSelfLoops` precondition to `freezeValid` or `freezeBindingsWitnessed`. State and prove the composite: `wellFormed r -> validOp r op -> wellFormed (applyOp r op)` where `validOp` dispatches to the appropriate precondition.

---

## Milner (Type Theorist): Grade B

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

The `LawfulBEq` instances give the identity types a richer algebraic structure, but the fundamental type-level disconnection between Retort.lean and Denotational.lean is unchanged.

### Praises

1. **The preconditions introduce a lightweight dependent-type discipline.** `pourValid r pd` depends on the current retort state `r`. `claimValid r cd` depends on both `r` and the claim data. These are refinement types in disguise: the operation is only meaningful when the predicate holds. The preservation proofs carry these predicates as hypotheses. This is the right structure for a verified state machine, even if it is not encoded as dependent types in Lean's type system.

2. **`freezeBindingsWitnessed` is a well-formed existential.** It quantifies over all bindings in the freeze data and requires a witness yield in `r.yields ++ fd.yields`. The disjunction (existing yield OR new yield from this freeze) is natural and covers both cases correctly. This is a proper specification, not just a structural check.

### Critiques

1. **The type universes are still disconnected.** Retort.lean's `CellDef` has `body : String`. Denotational.lean's `CellDef M` has `body : CellBody M = Env -> M (Env x Continue)`. StemCell.lean's `CellDef` has `body : String` but with different fields. Claims.lean has its own `State` with no connection to `Retort`. Four files, four type universes, zero morphisms between them. The `LawfulBEq` instances are orthogonal to this problem.

2. **The effect lattice remains advisory.** `BodyType` in Retort.lean classifies cells as hard/soft/stem. `EffectLevel` in Denotational.lean classifies cells as pure/semantic/divergent. These are two classification schemes for the same concept with no formal relationship. Neither is enforced by the type system. A "hard" cell could have an LLM prompt as its body; a "pure" cell could reference `IO`. The classifications are metadata, not types.

3. **No composition theorem.** The v1 review asked: if programs P1 and P2 are well-formed and their cell names are disjoint, does `pour P1 ; pour P2` yield a well-formed retort? The `pour_preserves_cellNamesUnique` theorem is a building block for this, but the full composition theorem is unstated. Multi-program execution is the practical use case for the retort, and it has no formal account.

### Path to A

Define an abstraction function from Denotational.lean's `CellDef M` to Retort.lean's `CellDef` (the body becomes a string representation, the effect level becomes a body type). Prove that the abstraction preserves well-formedness. Make `BodyType` and `EffectLevel` provably equivalent via a bijection. State and prove the composition theorem for disjoint programs.

---

## Hoare (Verification): Grade B+

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

This is the reviewer who asked most explicitly for preconditions, and the v2 model delivers them. The v1 critique was devastating: "No preconditions on operations. You can freeze a frame that was never claimed. You can claim a frame that does not exist." The v2 model addresses this head-on.

### Praises

1. **The preconditions are genuine Hoare-style specifications.** `claimValid r cd` is a precondition: the frame exists, is ready, and is not claimed. `claim_preserves_claimMutex` is a conditional correctness theorem: `claimMutex r -> claimValid r cd -> claimMutex (applyOp r (.claim cd))`. This is exactly `{P /\ Pre} op {P}` -- the Hoare triple for invariant preservation under precondition. The v1 model had the postcondition (`claimMutex`) but not the precondition (`claimValid`). Now both are present.

2. **`freezeBindingsWitnessed` closes the most dangerous gap.** A freeze without witnessed bindings could create bindings pointing to non-existent yields, breaking `bindingsMonotone`. The precondition requires that every binding in the freeze data has a matching yield. The preservation proof (`freeze_preserves_bindingsMonotone`) uses this to show that `bindingsMonotone` survives the transition. This is the tightest precondition-postcondition pair in the model.

3. **Zero sorries.** The `nonStem_finite` sorry was the most visible gap in v1. Its elimination means every stated theorem is mechanically verified. No axioms, no admits, no escape hatches. The development is self-contained.

### Critiques

1. **Postconditions are implicit.** The preservation theorems say "invariant X is preserved." But there are no explicit postcondition theorems of the form "after a freeze, the frame status is frozen" or "after a claim, the frame has a claim entry." These are the positive effects of operations -- what they ACCOMPLISH, not just what they PRESERVE. Without postconditions, you know that operations are safe but not that they are useful.

2. **No progress or liveness theorem.** The v1 review asked: "if a frame is ready, the system will eventually evaluate it." This is still absent. There is no fairness assumption, no scheduler model, and no theorem that ready frames make progress. The preconditions guarantee that operations CAN happen (e.g., `claimValid` implies the claim will succeed), but nothing guarantees that they WILL happen. A system that satisfies all preservation theorems but never evaluates anything is still consistent with the model.

3. **Total correctness for non-stem programs is still absent at the retort level.** `nonStem_finite` is proved in Denotational.lean for the semantic evaluator. But there is no corresponding theorem in Retort.lean: "given a well-formed retort with a finite acyclic program, some sequence of eval cycles will freeze every frame." The semantic finiteness and the operational finiteness are not connected.

### Path to A

Add postcondition theorems for each operation: `claim` adds a claim entry, `freeze` makes the frame frozen, `createFrame` adds a frame with the next generation. State and prove existential progress: "if `readyFrames r` is non-empty, there exists a valid `ClaimData` satisfying `claimValid`." State total correctness at the retort level: for a finite acyclic program, there exists a sequence of valid eval cycles that freezes all frames.

---

## Wadler (Functional Programmer): Grade B+

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

The `freeze_preserves_bindingsMonotone` theorem was the specific deliverable the v1 review requested. It is present and proved. The `nonStem_finite` sorry is eliminated, removing the proof-chain hazard.

### Praises

1. **`bindingsMonotone` preservation is algebraically clean.** The proof splits on whether the binding is old or new. For old bindings, the yield witness exists and is preserved by append-only (a monotone argument). For new bindings, `freezeBindingsWitnessed` provides the witness directly. The two cases compose without interference. This is the kind of proof that extends naturally: if you add a new operation that grows bindings, you add one case to the split.

2. **The sorry elimination restores proof-chain integrity.** In v1, `nonStem_finite` was `sorry`, which meant any theorem chain through it was vacuously true. Now every theorem in the development is grounded. The `evalN_length_le` helper factors out the structural argument cleanly, and the main theorem delegates to it. There are no hidden dependencies on `sorry`.

3. **The monotonicity proofs form a lattice.** `frames_monotonic`, `yields_monotonic`, `bindings_monotonic`, and `graph_monotonic` form a hierarchy: the first three are proved independently (per-operation case analysis), and the fourth composes them with `omega`. This is textbook algebraic structure: individual monotonicity results compose into aggregate monotonicity via arithmetic.

### Critiques

1. **No equational laws for operation commutativity.** The v1 review asked: do independent claims commute? Does `claim A ; claim B = claim B ; claim A` when `A.frameId != B.frameId`? This is still absent. Without commutativity, you cannot reason about concurrent execution algebraically. You must reason about all possible interleavings, which does not scale.

2. **`applyOp` still conflates valid and invalid transitions.** The v1 review asked for `applyOp` to return `Option Retort`. It still returns `Retort` unconditionally. The preconditions are separate predicates, not enforced by the return type. This means every theorem that uses `applyOp` must separately ensure the precondition holds. A partial function (or a dependent type requiring the precondition) would make this structural.

3. **The preservation proofs are not compositional across operations.** There is no generic tactic or lemma schema that says "if operation X only appends to list L and does not touch list M, then any invariant about M is preserved." Each preservation proof is hand-written. The `freeze_preserves_claimMutex` and `release_preserves_claimMutex` proofs are nearly identical (both use `List.mem_filter`) but share no common lemma. A single "filter preserves universals" lemma would factor both.

### Path to A

Prove commutativity of independent claims (and independent pours for disjoint programs). Refactor `applyOp` into a checked variant `applyOpChecked : Retort -> RetortOp -> Option Retort` that returns `none` on precondition violation, and restate the preservation theorems in terms of it. Extract the common "filter preserves forall" pattern into a reusable lemma.

---

## Sussman (Systems Thinker): Grade B

**Core question:** Does the model compose? Can it be extended?

### What Changed

The preconditions and preservation proofs make the model more trustworthy as a foundation. But the structural issues (disconnected files, no module system, no garbage collection story) are unchanged.

### Praises

1. **The precondition structure is extension-friendly.** Adding a new operation (e.g., `archive : FrameId -> RetortOp` for moving old frames to cold storage) would require: (a) adding a constructor to `RetortOp`, (b) adding a case to `applyOp`, (c) defining `archiveValid`, (d) proving preservation for each invariant. The pattern is clear and mechanical. The existing proofs for other operations are not affected. This is a well-designed extension point.

2. **The `freezeBindingsWitnessed` pattern generalizes.** Any new operation that adds to an append-only list and must maintain referential integrity can use the same pattern: require a precondition that all new entries reference existing (or concurrently added) entries, then prove preservation by case-splitting on old vs. new. This pattern could be extracted into a library.

### Critiques

1. **The four files are still four disconnected formalizations.** `CellDef` in Retort.lean, `CellDef M` in Denotational.lean, `CellDef` and `CellDef5` in StemCell.lean, and the `State` type in Claims.lean are all independent types with no imports, no morphisms, and no shared foundation. The v1 review's priority-2 action (create `Core.lean` with shared types) was not attempted. Any refactoring of a shared concept (e.g., changing the representation of `FrameId`) requires coordinating across all four files manually.

2. **No story for multi-program composition.** The retort holds cells from multiple programs (via repeated `pour` operations). The `pourValid` precondition ensures name uniqueness within a program. But there is no theorem about what happens when two programs have cells with overlapping names in different programs, or when one program's cell depends on another program's cell via givens. Multi-program interaction is the production use case, and it is formally uncharacterized.

3. **No garbage collection or archival model.** Append-only means unbounded growth. The model proves `data_persists` -- data from time T exists at all future times. This is a safety property, but it is also a scalability liability. A stem cell producing 100,000 generations creates 100,000 frame rows, each with yields and bindings. The model has no concept of "this generation is no longer reachable" or "these old frames can be compacted." The v1 review asked for this; it remains absent.

4. **Claims.lean and Retort.lean model the same claim system independently.** Claims.lean proves `always_mutex_on_valid_trace` using its own `State` type and `claimStep`/`releaseStep`/`freezeStep` transitions. Retort.lean proves `claim_preserves_claimMutex` using its own `Retort` type and `applyOp`. These are two proofs of the same property on two models of the same system. They should be one proof on one model.

### Path to A

Create `Core.lean` with shared types and have the other files import it. Prove multi-program composition: if two pours have disjoint program IDs and each is internally valid, the composite retort is well-formed. Define a `compact` operation that removes frames older than generation G for a given cell, preserving well-formedness for the reachable subset. Unify the Claims.lean and Retort.lean claim systems into a single model.

---

## Consensus

### What Improved Since v1

The model has made targeted, meaningful progress on the v1 review's top priority. The three most significant changes:

1. **Operation preconditions exist and are used.** `pourValid`, `claimValid`, `freezeValid`, and `freezeBindingsWitnessed` transform `applyOp` from "accepts anything, garbage in garbage out" to "meaningful when preconditions hold, invariants preserved." The preservation proofs are conditional on these preconditions, which is the correct structure.

2. **`bindingsMonotone` is proved, not just stated.** The v1 model defined `bindingsMonotone` as a `Prop` and claimed it held. The v2 model proves `freeze_preserves_bindingsMonotone` under `freezeBindingsWitnessed`. This closes the gap between "bindings point to real data" (claimed) and "bindings point to real data" (proved).

3. **Zero sorries.** The `nonStem_finite` sorry in Denotational.lean was the most visible credibility gap. Its elimination, via the clean `evalN_length_le` helper, means the entire development is mechanically verified. No admitted theorems, no axioms, no escape hatches.

Additionally, the `LawfulBEq` infrastructure is the kind of unglamorous work that enables everything else. Without it, the precondition proofs would be cluttered with ad-hoc BEq conversions.

### What Remains

Three systemic issues from v1 persist, and one new issue emerged:

1. **Disconnected formalizations.** Four files, four type universes, zero morphisms. The retort model and the denotational model are not linked by a refinement theorem. Claims.lean and Retort.lean prove the same property on different models. The shared `Core.lean` was not created.

2. **Incomplete well-formedness preservation.** Three of seven invariants have preservation proofs (I1, I6, plus `bindingsMonotone`). The referential integrity invariants (I3-I5), `framesUnique` (I2), and `yieldUnique` (I7) lack preservation proofs. The DAG properties (`noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen`) are defined but not proved invariant.

3. **No liveness or progress.** The model proves safety exhaustively (invariants are preserved, data persists, mutex holds). Liveness is entirely absent: no theorem says ready frames will eventually be evaluated, no theorem says finite programs will terminate at the retort level, no fairness assumption exists for the scheduler.

4. **(New) No postcondition theorems.** The preservation proofs say operations do not break things. But no theorem says operations accomplish their purpose: that claiming actually adds a claim, that freezing actually makes a frame frozen, that createFrame actually adds a frame with the expected generation. These positive-effect theorems are needed to prove progress.

### Grade Summary

| Reviewer | v1 Grade | v2 Grade | Delta | Key Factor |
|----------|----------|----------|-------|------------|
| Feynman | B+ | B+ | -- | Two-model gap still open |
| Iverson | B | B | -- | Naming and dead-weight issues unchanged |
| Dijkstra | B- | **B+** | +1 | Preconditions and 6 preservation proofs |
| Milner | B | B | -- | Type universes still disconnected |
| Hoare | C+ | **B+** | +1.5 | Preconditions directly addressed concerns |
| Wadler | B- | **B+** | +1 | `bindingsMonotone` proved, sorry eliminated |
| Sussman | B | B | -- | Module structure unchanged |

### Overall Grade: B+

The model has moved from a solid B to a solid B+. The preconditions and preservation proofs represent the most important single improvement the model could have made: they transform the verified development from "structural invariants hold" to "conditional correctness of individual operations." The sorry elimination gives the development full mechanical credibility.

The grade does not reach A- because the three systemic gaps (disconnected files, incomplete invariant coverage, no liveness) are all load-bearing for a production-quality formalization. The model proves that individual operations are safe in isolation. It does not yet prove that the system as a whole works: that programs terminate, that ready frames make progress, that the semantic model and the database model agree, or that well-formedness holds end-to-end through arbitrary operation sequences.

### Priority Actions for v3

| Priority | Action | Difficulty | Impact | Addresses |
|----------|--------|------------|--------|-----------|
| 1 | Prove preservation for remaining invariants (I2-I5, I7) and compose into `wellFormed_preserved` | Medium | High | Dijkstra, Hoare |
| 2 | Add postcondition theorems (claim adds claim, freeze makes frozen, etc.) | Low | High | Hoare, Wadler |
| 3 | Create `Core.lean` with shared types; unify Claims.lean claim model into Retort.lean | Medium | High | Sussman, Milner |
| 4 | Prove existential progress: non-empty readyFrames implies valid ClaimData exists | Medium | High | Hoare |
| 5 | State and prove denotational-operational correspondence | Hard | High | Feynman, Milner |
| 6 | Prove commutativity of independent operations | Medium | Medium | Wadler |
| 7 | Constrain `stemHasDemand` with monotonicity; prove multi-program composition | Medium | Medium | Feynman, Sussman |

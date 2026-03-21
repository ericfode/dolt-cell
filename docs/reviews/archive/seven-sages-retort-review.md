# Seven Sages Review: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the complete formal model across four Lean files: `Retort.lean` (the unified runtime model), `Denotational.lean` (semantics), `StemCell.lean` (identity exploration), and `Claims.lean` (temporal logic of the claim system). This review focuses on the Retort model as the culmination of the previous work, evaluating what was addressed from the prior review and what remains.

## Changes Since Last Review

The prior review called for four immediate changes. Status:

1. **Unify cell kinds** -- DONE. `CellBody M = Env -> M (Env x Continue)` in Denotational.lean. `BodyType` in Retort.lean is now a classifier (hard/soft/stem), not a separate type. One cell kind.
2. **Parameterize M properly** -- PARTIAL. Denotational.lean keeps M abstract in signatures but still instantiates to Id for evalStep. Retort.lean does not parameterize at all; it operates at the database level where M is irrelevant.
3. **Prove termination** -- NOT DONE. No variant function, no well-founded ordering.
4. **Prove monotonicity via bindings** -- DONE. Bindings table fixes resolution at claim time. `resolveBindings` replaces `latestFrozenFrame` for input lookup. `bindingsMonotone` stated as a proposition.

Additional changes: effect lattice (pure < semantic < divergent), bottom propagation in Denotational.lean, content addressing with `ContentAddr`, explicit DAG properties (`noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen`), valid traces with transitive data persistence (`data_persists`), graph monotonicity theorems.

---

## Feynman (Physicist): Grade B+

**Core question:** Does the model explain the system, or does it just describe it?

### Praises

1. **The retort state is on one blackboard.** Seven fields, one structure. Cells, givens, frames, yields, bindings, claims, claimLog. I can hold it in my head. The separation between immutable data (everything) and mutable coordination (claims only) is clean and honest.

2. **Derived state is never stored.** `FrameStatus` is computed from yields and claims. `frameReady` is computed from givens and yields. This is the right instinct -- don't store what you can derive, because stored derived state is a lie waiting to go stale.

### Critiques

1. **The model explains the database, not the computation.** Retort.lean is a formalization of SQL table operations. It tells me that frames grow and yields accumulate. It does not tell me what a cell COMPUTES. The denotational semantics (Denotational.lean) does, but the two files are not connected. There is no theorem relating `evalStep` in Denotational.lean to `applyOp` in Retort.lean. You have two models of the same system that never talk to each other. That is two half-explanations.

2. **`stemHasDemand` is a hole, not a definition.** It takes a `demandPred : Retort -> Bool` argument -- an arbitrary function. This punts the hardest question (what constitutes demand?) entirely out of the model. A stem cell's behavior is determined by its demand predicate, and you made the demand predicate a parameter with no constraints. You could pass `fun _ => true` and get an always-spinning stem cell. Where is the characterization of well-formed demand?

3. **String typing is acknowledged but never resolved.** All values are strings. All identities are strings wrapped in newtypes. The comment in Denotational.lean says "This is a design limitation we'll identify below." You identified it. Three files ago. It is still strings.

### Suggested Improvements

- Write a refinement theorem: show that for a well-formed program, the Retort trace (database-level) is a faithful implementation of the denotational trace (semantic-level). This is the abstraction relation that makes both models useful.
- Constrain `stemHasDemand`: at minimum, demand should depend only on the yields of other cells (not on internal state of the retort), and should be monotone (once demand is true, adding more yields cannot make it false).

---

## Iverson (Notation Designer): Grade B

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### Praises

1. **The operation algebra is clean.** Five operations: pour, claim, freeze, release, createFrame. Each maps `Retort -> Retort`. The `RetortOp` sum type enumerates exactly the legal transitions. This is a well-designed instruction set.

2. **`EvalCycle` composes primitives without introducing new concepts.** It is claim followed by freeze, optionally followed by createFrame. The eval cycle is a macro, not a new primitive. Good discipline.

### Critiques

1. **`GivenSpec` carries redundant information.** It has both `cellName` (the cell that declares this given) and `sourceCell` (the cell whose yield is read). The field name `cellName` is confusing -- it is NOT the cell being depended on, it is the cell that HAS the dependency. This should be `ownerCell` or `dependentCell`. The naming misleads.

2. **`ContentAddr` duplicates frame lookup logic.** `Retort.resolve` looks up a frame by `(cellName, generation)`, then looks up a yield by `(frameId, field)`. But `resolveBindings` already does the second step via the bindings table. These are two resolution mechanisms for the same underlying operation. One should be defined in terms of the other, or one should be eliminated. Currently they can disagree -- `resolve` uses the latest frame, `resolveBindings` uses the bound frame.

3. **The claim log has no consumers.** `ClaimLogEntry` and `claimLog` are defined, proven append-only, but never queried. No function reads the claim log. No property references it. It is dead weight in the formal model. Either use it (e.g., to prove liveness properties) or remove it.

### Suggested Improvements

- Rename `GivenSpec.cellName` to `GivenSpec.owner` to disambiguate from `sourceCell`.
- Define `ContentAddr.resolve` in terms of bindings when a frame is frozen, and directly only when the frame is declared/computing. Make the two resolution paths converge by construction.
- Either prove something about the claim log (audit completeness, replayability) or drop it from the formal model. Include it in the implementation, not in the theory.

---

## Dijkstra (Formalist): Grade B-

**Core question:** Are the invariants actually maintained? Are the proofs real?

### Praises

1. **The append-only proofs are complete and compositional.** Every operation gets its own theorem. The master theorem `all_ops_appendOnly` dispatches by case. `evalCycle_appendOnly` composes via transitivity. `data_persists` lifts to arbitrary future times by induction. This is the right structure. The proof of `data_persists` handles the base case, inductive case, and reflexive case correctly.

2. **`content_addr_distinct_gens` is a real theorem.** It says: if you resolve the same cell and field at two different generations and both succeed, the values come from different frames. The proof extracts witnesses from `List.find?`, converts BEq to Prop, and constructs the existential. This is genuine Lean work, not just `rfl`.

### Critiques

1. **`wellFormed` is stated but never proven to be an invariant.** You define seven well-formedness conditions (I1-I7) and bundle them into `wellFormed`. You prove append-only for every operation. But you never prove `wellFormed r -> applyOp r op -> wellFormed r'`. This is the critical gap. Append-only is a structural property. Well-formedness is a semantic property. You proved the easy one. Example: does `pour` preserve `cellNamesUnique`? Only if the poured cells have unique names AND don't collide with existing cells. This precondition is nowhere in the model. The operation `applyOp r (.pour pd)` blindly concatenates -- it does not check for name collisions.

2. **`bindingsMonotone` is stated as `Prop`, never proven.** It asserts that for every binding, the producer's yield exists. This is the key safety property of the bindings system -- that bindings point to real data. But it is `def`, not `theorem`. There is no proof. The comment says "Key consequence: resolveBindings returns the same values at any later time" but this consequence is also not proven. You have stated an important property and left it as an axiom.

3. **DAG properties are stated, never proven invariant.** `noSelfLoops`, `generationOrdered`, and `bindingsPointToFrozen` are predicates. There is no theorem showing that any operation preserves them. A freeze operation could in principle create a self-loop (binding where consumer = producer). You say "enforced by construction" in a comment, but the `applyOp` function does not check this. The gap between "enforced by construction" and "enforced by proof" is the gap between engineering and mathematics.

4. **`nonStem_finite` uses `sorry`.** The theorem that non-stem programs produce at most `p.cells.length` frames is admitted. This is a termination-adjacent result and its absence is noted.

### Suggested Improvements

- Prove `wellFormed_preserved`: `wellFormed r -> (preconditions on op) -> wellFormed (applyOp r op)`. This will force you to articulate preconditions for each operation.
- Prove `bindingsMonotone` or remove the claim. If it requires preconditions on freeze (e.g., "all bindings in FreezeData reference frozen frames"), make those preconditions explicit.
- Prove at least `noSelfLoops` is preserved by freeze, with an explicit precondition on FreezeData.
- Replace the `sorry` with a proof or mark it explicitly as a conjecture.

---

## Milner (Type Theorist): Grade B

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### Praises

1. **The effect lattice is in place.** `EffectLevel` with `pure < semantic < divergent` and a total ordering. This was a key recommendation from the prior review. The ordering is correct: pure cells compose deterministically, semantic cells introduce non-determinism, divergent cells may not terminate.

2. **The unified cell body parametric over M is correct.** `CellBody M = Env -> M (Env x Continue)` in Denotational.lean cleanly handles the spectrum from hard cells (M = Id) through soft cells (M = IO or nondeterminism) to stem cells (Continue = .more). The Continue signal replacing a separate RecBody type is an improvement.

### Critiques

1. **Retort.lean and Denotational.lean have incompatible type universes.** Denotational.lean defines `CellDef M` parameterized over a monad. Retort.lean defines `CellDef` as a flat structure with `body : String`. These are two unrelated types that happen to share a name. There is no functor, no embedding, no morphism connecting them. The formalization is two disconnected models that should be one model at two levels of abstraction.

2. **The effect lattice has no enforcement.** `EffectLevel` classifies cells but nothing prevents a `pure` cell from having a body that performs IO. The lattice is advisory, not structural. In Milner's tradition, an effect annotation that the system cannot check is not an effect system -- it is a comment.

3. **No compositionality theorem.** The model defines programs as lists of cells and evaluation as sequential stepping. But there is no theorem showing that two well-formed programs can be composed (e.g., one program's outputs feeding another's inputs) while preserving well-formedness. The retort model supports this operationally (multiple programs share a retort), but there is no formal account of program composition.

### Suggested Improvements

- Define an abstraction relation `CellDef M ~~> Retort.CellDef` that maps the denotational definition to the database representation. Prove that `evalStep` on the denotational side corresponds to `claim + freeze` on the retort side.
- Make the effect lattice structural: `CellBody .pure = Env -> (Env x Continue)` (no monad), `CellBody .semantic = Env -> IO (Env x Continue)`, etc. Use dependent types to enforce the classification.
- State and prove a composition theorem: if programs P1 and P2 are well-formed and their cell names are disjoint, then `pour P1 ; pour P2` yields a well-formed retort.

---

## Hoare (Verification): Grade C+

**Core question:** Are preconditions, postconditions, and total correctness established?

### Praises

1. **Claims.lean proves real temporal properties.** `always_mutex_on_valid_trace` is an inductive proof that mutual exclusion holds at every step of every valid trace. The proof structure (base case: init satisfies mutex; inductive case: every operation preserves mutex) is textbook. Similarly for `always_yields_preserved_on_valid_trace`. These are LTL box-properties, mechanically verified.

2. **The release-frees-frame theorem under mutex is a genuine liveness result.** It shows that releasing a claim actually produces a free frame, not just that "something happens." Combined with `unclaimed_claim_succeeds`, you get a progress guarantee: free frames can be claimed, and released frames become free.

### Critiques

1. **No preconditions on operations.** `applyOp` accepts ANY operation at ANY time. You can freeze a frame that was never claimed. You can claim a frame that does not exist. You can create a frame for a cell that was never poured. The operations have implicit preconditions that are nowhere in the formal model. Without preconditions, the append-only theorems prove that garbage accumulates correctly.

2. **No liveness/progress theorem for the eval loop.** You prove that every individual step preserves safety properties. But there is no theorem saying: "if a frame is ready, the system will eventually evaluate it." The `EvalCycle` structure shows the shape of progress, but there is no fairness assumption, no scheduler model, and no theorem that ready frames make progress. A system that satisfies all your safety properties but never evaluates anything is consistent with the model.

3. **No total correctness for non-stem programs.** The combination of "all non-optional givens satisfied implies frame is ready" and "ready frames can be claimed and frozen" should yield: "a well-formed acyclic program with all non-stem cells will eventually have all frames frozen." This is the fundamental soundness theorem of the eval loop. It is absent. The `nonStem_finite` theorem in Denotational.lean is marked `sorry`.

### Suggested Improvements

- Add precondition predicates: `canPour r pd`, `canClaim r cd`, `canFreeze r fd`, `canCreateFrame r cfd`. Prove that when preconditions hold, operations produce well-formed states.
- State and prove progress: given a well-formed retort with a non-empty `readyFrames`, there exists a valid `EvalCycle` that can execute. This does not require a scheduler -- just existential progress.
- State total correctness for finite programs: if the program DAG is acyclic and all cells are non-stem, then `evalN p p.cells.length` produces a trace where every cell has a frozen frame. Remove the `sorry`.

---

## Wadler (Functional Programmer): Grade B-

**Core question:** Are there algebraic laws? Does equational reasoning work?

### Praises

1. **Append-only has clean algebraic structure.** `appendOnly` is a preorder on `Retort` values (reflexive by construction, transitive by `data_persists`). Every operation is monotone with respect to this preorder. The frame count, yield count, and binding count are monotone natural-number functions. `graphSize` is their sum, also monotone. This is a well-behaved algebraic setup.

2. **The proof style is uniform and refactorable.** Every `_appendOnly` theorem follows the same pattern: unfold, refine into components, prove each component by `List.mem_append_left` or identity. The `evalCycle_appendOnly` proof composes them transitively. This uniformity suggests the proofs could be generated by a tactic or derived generically.

### Critiques

1. **No equational laws for operations.** There is no commutativity result (e.g., "claiming frame A then claiming frame B gives the same state as claiming B then A, when A != B"). There is no idempotence result (e.g., "pouring the same cells twice is equivalent to pouring them once plus duplicates"). These laws would characterize the algebraic structure of the retort. Currently, `applyOp` is an opaque state transformer -- you can verify preservation properties but you cannot reason equationally about operation sequences.

2. **The `applyOp` function conflates valid and invalid transitions.** Pouring duplicate cells, freezing unclaimed frames, and creating frames for non-existent cells all "succeed" silently. In a clean algebraic model, invalid operations would return `Option Retort` or carry a proof of their precondition. The current design forces every consumer to separately verify that the transition was meaningful.

3. **The `sorry` in `nonStem_finite` breaks the proof chain.** Every downstream theorem that depends on finite program termination is ungrounded. In a proof assistant, `sorry` is not "TODO" -- it is `axiom False`. The entire verified development could be rendered vacuously true if this admitted theorem is used carelessly.

### Suggested Improvements

- Prove commutativity of independent operations: `applyOp (applyOp r (claim a)) (claim b) = applyOp (applyOp r (claim b)) (claim a)` when `a.frameId != b.frameId`. This is the key law enabling concurrent execution.
- Refactor `applyOp` to return `Option Retort`, rejecting invalid transitions. Then `all_ops_appendOnly` becomes: "when an operation succeeds, it preserves append-only." This is a stronger and more honest statement.
- Either prove `nonStem_finite` or quarantine it. Do not import or reference it from other proofs. Mark it with a doc comment explaining what is needed for the proof.

---

## Sussman (Systems Thinker): Grade B

**Core question:** Does the model compose? Can it be extended?

### Praises

1. **The five-operation algebra is extensible.** `RetortOp` is an inductive type. Adding a new operation (e.g., `archive : FrameId -> RetortOp` for garbage collection, or `compose : ProgramId -> ProgramId -> RetortOp` for program linking) requires adding one constructor and one case to `applyOp`. Every existing theorem remains valid for existing operations. The proofs are closed under extension. This is good language design.

2. **StemCell.lean is an honest exploration.** It evaluates five approaches, rejects three with proofs (`spawn_violates_bounded`), and arrives at Approach 5 through reasoned debate. The exploration IS the documentation. The rejected approaches and their failure modes are more valuable than the final answer alone because they explain WHY the final design is what it is.

### Critiques

1. **The four Lean files do not form a module system.** They share type names (`CellDef`, `Frame`, `Yield`) but define them independently with incompatible definitions. StemCell.lean defines `CellDef5`, `Frame5`, `Yield5`, `Edge5` -- a parallel universe of types. Claims.lean defines `StoredYield` and its own `State`. Retort.lean defines `CellDef`, `Frame`, `Yield`. These are three formalizations of the same system that cannot import each other. In a real Lean development, there would be a shared `Core.lean` defining the base types, and each file would build on it.

2. **No mechanized connection between StemCell.lean's schema and Retort.lean's types.** StemCell.lean concludes with an SQL schema for the "winning approach." Retort.lean implements that approach in Lean. But there is no theorem or embedding showing that Retort.lean's types faithfully represent StemCell.lean's schema. The exploration informed the design, but the formal link is missing.

3. **No story for garbage collection or archival.** Append-only means unbounded growth. The model proves that data persists forever. But in practice, stem cells producing 10,000 generations need archival. The model has no concept of "this data is no longer needed" or "this data can be moved to cold storage." The `appendOnly` invariant, taken literally, prevents optimization. A more nuanced model would distinguish between "reachable from current computation" and "historical."

### Suggested Improvements

- Create `Core.lean` with shared type definitions. Have `Retort.lean`, `Claims.lean`, and `Denotational.lean` import it. Eliminate the parallel type universes.
- Define a "compaction" operation that archives old generations while preserving the content-addressability of currently-referenced frames. Prove it preserves `wellFormed` for the reachable subset.
- Add a module composition operation: given two retorts with disjoint program IDs, produce a merged retort. Prove it preserves well-formedness. This is the formal foundation for multi-program execution.

---

## Consensus

### What Improved

The model has taken a significant step forward from the denotational review. The unification of cell kinds, the binding-based resolution mechanism, the effect lattice, and the proven append-only/persistence properties address four of the five most critical issues raised previously. The `data_persists` theorem (data from time T exists at all future times) and `content_addr_distinct_gens` (different generations produce different frames) are genuine verification results. The model is no longer just "proving the easy parts" -- the content-addressing theorem required real Lean work with BEq conversion and existential witnesses.

### What Remains

Three systemic issues persist:

1. **The model lacks operation preconditions.** Every operation silently accepts invalid inputs. This means the append-only proofs prove that ill-formed data accumulates correctly. The gap between "operations preserve structure" and "operations produce correct results" is the gap between a type-safe program and a correct program.

2. **The four files are disconnected formalizations.** They share concepts but not types. The denotational semantics and the retort model are never linked by a refinement or simulation theorem. The StemCell exploration and the final Retort model are connected only by human intent, not by proof.

3. **No progress/termination results.** Safety is well-covered (mutex, append-only, immutability). Liveness is absent (ready frames make progress, finite programs terminate, stem cells respond to demand). The `sorry` in `nonStem_finite` is the visible tip of this gap.

### Overall Grade: B

The model is a solid B. It is structurally sound, the proofs are real (not trivial), and the design decisions are well-motivated. The unification of cell kinds, the binding-based resolution, and the temporal persistence proof represent genuine progress. But the model stops short of the theorems that would make it load-bearing for the implementation: operation preconditions, well-formedness preservation, denotational-operational correspondence, and progress. These are not "nice to haves" -- they are the theorems that would let you refactor the SQL implementation with confidence that you have not broken the invariants.

The grade reflects that the model does what it does well (structural invariants, append-only guarantees, content addressing) but does not yet do what it needs to (correctness of the eval loop, safety of individual operations, connection between the semantic and database models).

### Priority Actions

| Priority | Action | Difficulty | Impact |
|----------|--------|------------|--------|
| 1 | Add operation preconditions and prove well-formedness preservation | Medium | High |
| 2 | Unify type definitions across the four Lean files into a shared Core.lean | Low | High |
| 3 | Prove `bindingsMonotone` (bindings point to real data) | Medium | High |
| 4 | Prove progress for finite programs (remove `sorry` from `nonStem_finite`) | Hard | Medium |
| 5 | State and prove denotational-operational correspondence | Hard | High |
| 6 | Constrain `stemHasDemand` with monotonicity requirement | Low | Medium |
| 7 | Prove commutativity of independent operations (concurrency foundation) | Medium | Medium |

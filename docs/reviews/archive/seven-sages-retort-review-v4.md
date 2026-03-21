# Seven Sages Review v4: Retort Formal Model

Date: 2026-03-16

Seven reviewers (modeled after Feynman, Iverson, Dijkstra, Milner, Hoare, Wadler, Sussman) reviewed the updated `Retort.lean` (1702 lines, 60 public + 7 private theorems, zero sorries). This review evaluates the changes since the v3 review.

## Changes Since v3 Review

The v3 review identified seven priority actions. Status:

| # | Action | v3 Status | v4 Status |
|---|--------|-----------|-----------|
| 1 | Prove existential progress: `readyFrames` non-empty implies valid `ClaimData` exists | NOT DONE | **DONE** -- `progress` theorem with `framesCellDefsExist` precondition |
| 2 | Include DAG properties + `bindingsMonotone` in `wellFormed`; prove preservation for all operations | NOT DONE | NOT DONE |
| 3 | Create `Core.lean` with shared types | NOT DONE (three reviews) | NOT DONE (four reviews) |
| 4 | State and prove denotational-operational correspondence | NOT DONE (three reviews) | NOT DONE (four reviews) |
| 5 | Prove commutativity of independent claims and pours | NOT DONE (three reviews) | NOT DONE (four reviews) |
| 6 | Constrain `stemHasDemand` with monotonicity; define `ValidWFTrace` | NOT DONE (three reviews) | NOT DONE (four reviews) |
| 7 | Add remaining postconditions (pour membership, freeze produces `.frozen` status) | NOT DONE | **DONE** -- `pour_adds_cells`, `pour_adds_frames`, `freeze_makes_frozen` |

Key additions: `framesCellDefsExist` predicate (every frame has a cell definition); `declared_of_some_implies_no_claim` helper (frameStatus = declared implies no active claim); `FrameStatus.eq_of_beq_true` (BEq-to-Prop bridge for FrameStatus); `progress` theorem (liveness); `pour_adds_cells`, `pour_adds_frames`, `freeze_makes_frozen` postconditions. Total: 67 theorems (60 public, 7 private), up from ~56 in v3.

---

## Feynman (Physicist): Grade A-

**Core question:** Does the model explain the system, or does it just describe it?

### What Changed

The `progress` theorem adds a forward direction to the model's explanatory power. Previously, the model explained why the system does not break (safety via `wellFormed_preserved`). Now it also explains why the system can move: if there is a ready frame, there exists a valid claim operation. The `freeze_makes_frozen` postcondition explains what freeze accomplishes: it produces a frozen frame status when all fields are covered.

### Praises

1. **The progress theorem connects readiness to actionability.** The statement `f in r.readyFrames -> framesCellDefsExist r -> exists cd, claimValid r cd` is the missing link between "the system has work to do" and "the system can do work." The proof is well-structured: it decomposes `readyFrames` membership into frame membership and the `frameReady` predicate, then uses `declared_of_some_implies_no_claim` to show the frame is unclaimed. The witness construction is explicit: `ClaimData` with `f.id` and a dummy piston ID. This is the statement Hoare demanded, and its proof is genuine -- the `declared_of_some_implies_no_claim` helper does real work, case-splitting on `frameClaim` and deriving a contradiction from the FrameStatus three-way branch when a claim exists but the status is declared.

2. **`freeze_makes_frozen` explains the freeze lifecycle transition.** After freeze, if the cell definition exists and the freeze yields cover all declared fields, the frame's derived status becomes `.frozen`. This is the postcondition that ties the operational model (yields appended) to the derived state model (FrameStatus computed). The proof unfolds `frameStatus`, substitutes the cell definition, and shows the `if` condition matches `hCovers`. Simple but load-bearing: this is the first theorem that connects applyOp to FrameStatus.

### Critiques

1. **The two-model gap persists (fourth review).** Retort.lean and Denotational.lean remain disconnected type universes. The `progress` theorem is internal to Retort.lean. No refinement theorem connects the retort-level progress (a valid claim exists) to the denotational-level progress (the cell body can be evaluated). The model now explains "the database can take a step" but still does not explain "the step computes the right thing." This gap has been open since v1.

2. **`stemHasDemand` remains unconstrained (fourth review).** The demand predicate is `Retort -> Bool` with no restrictions. The progress theorem does not apply to stem cells specifically -- it applies to any frame in `readyFrames`. A stem cell with `demandPred = fun _ => true` still spins forever. The mechanism that drives the most novel aspect of the system has no formal characterization.

### Path to A+

Write the refinement theorem. Constrain demand to be monotone. These are the same requests as v1-v3.

---

## Iverson (Notation Designer): Grade B+

**Core question:** Is every definition pulling its weight? Is the notation systematic?

### What Changed

Three new postconditions (`pour_adds_cells`, `pour_adds_frames`, `freeze_makes_frozen`) fill the gaps in the postcondition vocabulary. The naming follows the established pattern: verb_noun_effect. The `framesCellDefsExist` predicate introduces a natural well-formedness concept.

### Praises

1. **The postcondition vocabulary is now complete across all operations.** Pour: `pour_adds_cells`, `pour_adds_frames` (membership). Claim: `claim_adds_claim` (length). Freeze: `freeze_removes_claim` (length decrease), `freeze_makes_frozen` (derived status). Release: inherits from filter semantics. CreateFrame: `createFrame_adds_frame` (membership). Every operation has at least one postcondition theorem. The coverage is exhaustive.

2. **`framesCellDefsExist` is a well-named natural predicate.** It says exactly what it means: every frame has a corresponding cell definition. This is the kind of invariant that should arguably be in `wellFormed` (it is a referential integrity constraint like I3-I5), but as a standalone predicate it reads clearly and its role in the `progress` theorem is self-documenting.

### Critiques

1. **`GivenSpec.cellName` is still confusingly named (fourth review).** It means "the cell that owns this given" (the dependent), not the cell being depended on. The field `sourceCell` names the dependency target. This has been flagged since v1. It is a one-line rename to `owner` or `ownerCell`.

2. **The claim log is still dead weight (fourth review).** `ClaimLogEntry` and `claimLog` appear in the model, get appended to in `applyOp`, are proven append-only, but no theorem queries them or proves anything interesting about them. The v3 review made this exact critique. No change.

3. **`framesCellDefsExist` is outside `wellFormed`.** This is a referential integrity property (frames reference cells that exist) that sits alongside I3 (yields reference frames), I4 (bindings reference frames), and I5 (claims reference frames). Its structural role is identical. Either include it in `wellFormed` or explain why frames-to-cells is different from yields-to-frames. Currently, the `progress` theorem requires it as a separate hypothesis, which means a user of `wellFormed_preserved` cannot derive progress without additionally proving `framesCellDefsExist` is preserved. And there is no `pour_preserves_framesCellDefsExist` theorem.

### Path to A

Rename `GivenSpec.cellName` to `GivenSpec.owner`. Either include `framesCellDefsExist` in `wellFormed` with preservation proofs, or prove it preserved separately by all 5 operations. Remove `claimLog` from the formal model or prove an audit property.

---

## Dijkstra (Formalist): Grade A-

**Core question:** Are the invariants actually maintained? Are the proofs real?

### What Changed

No changes to the invariant preservation machinery. The 7 invariants in `wellFormed` are still proved preserved by all 5 operations (35 pairs). The new work is in liveness (`progress`) and postconditions, which are outside Dijkstra's primary concern (invariant maintenance) but relevant to the overall proof architecture.

### Praises

1. **The `declared_of_some_implies_no_claim` lemma is a genuine semantic result.** It proves that when a cell definition exists (cellDef returns `some cd`) and the frame status is `.declared`, the frame has no active claim. The proof case-splits on `frameClaim` and shows that `some c` leads to a contradiction: frameStatus would return either `.frozen` (if all fields present) or `.computing` (if claimed), never `.declared`. This is the first theorem that exploits the three-way case structure of `frameStatus` for a semantic conclusion. It is the key lemma enabling the progress theorem.

2. **The progress proof is structurally sound.** It decomposes readyFrames membership into frame membership and the `frameReady` boolean predicate, converts the BEq status check to a Prop equality via `FrameStatus.eq_of_beq_true`, uses `framesCellDefsExist` to obtain a cell definition, applies `declared_of_some_implies_no_claim` to show no active claim, and constructs the witness. Every step is justified. The witness uses a dummy piston ID (`"progress_witness"`), which is valid because `claimValid` does not constrain the piston ID beyond its existence.

### Critiques

1. **DAG properties remain unproven as invariants (fourth review).** `noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen` are defined (lines 1290-1305) with no preservation proofs and no inclusion in `wellFormed`. This is unchanged from v3. The `wellFormed_preserved` theorem says nothing about acyclicity.

2. **`bindingsMonotone` still lacks full preservation coverage (fourth review).** `freeze_preserves_bindingsMonotone` exists. Pour, createFrame, claim, release do not have corresponding proofs. This is unchanged from v3.

3. **`framesCellDefsExist` has no preservation proofs.** The `progress` theorem requires `framesCellDefsExist r`. But there is no theorem showing that any operation preserves this predicate. Pour adds cells and frames simultaneously -- does it maintain the relationship? CreateFrame adds a frame -- is its cell guaranteed to exist? Without preservation proofs, the `progress` theorem is usable only for retorts where `framesCellDefsExist` is proved by construction, not as part of a chain of operations via `wellFormed_preserved`. This is a gap in the proof architecture: the progress result cannot be composed with the safety result without additional work.

4. **`stemCellsDemandDriven` (I8) remains defined and excluded from `wellFormed` (fourth review).** No change from v3.

### Path to A+

Include `framesCellDefsExist` in `wellFormed` (it is referential integrity, like I3-I5) and prove preservation by all 5 operations. This would make `progress` composable with `wellFormed_preserved`. Include `noSelfLoops` in `wellFormed` (or a `dagWellFormed` composite) with preservation proofs. Delete or integrate `stemCellsDemandDriven`.

---

## Milner (Type Theorist): Grade B+

**Core question:** Is the typing discipline sound? Do the abstractions compose?

### What Changed

The `progress` theorem is an existential result: it constructs a witness of type `ClaimData` satisfying `claimValid`. This is the first existential construction in the model (previous theorems were universal preservation results). The `freeze_makes_frozen` theorem connects operational effects (yield appending) to derived types (FrameStatus), which is the first cross-layer typing result.

### Praises

1. **The progress witness construction is type-theoretically clean.** The theorem constructs `ClaimData` with `f.id` as frameId and a fresh PistonId. The existential is packed with a proof of `claimValid`, which requires both a frame existence witness (from `readyFrames` membership) and a no-claim witness (from `declared_of_some_implies_no_claim`). The `refine` + `constructor` proof structure cleanly separates the two conjuncts. This is textbook dependent pair construction.

2. **`freeze_makes_frozen` bridges the operational and derived layers.** The theorem statement quantifies over a frame `f`, a cell definition `cd`, a membership proof, an identity proof, a cell definition lookup in the post-state, and a coverage condition. The proof shows that after unfolding `frameStatus` and substituting the cell definition, the `if` condition reduces to the coverage hypothesis. This is the first theorem that connects `applyOp` to `frameStatus` -- previously, the two were defined independently with no formal relationship.

### Critiques

1. **The type universes remain disconnected (fourth review).** Retort.lean's `CellDef` has `body : String`. Denotational.lean's `CellDef M` has `body : CellBody M`. No morphism. The progress theorem says a `ClaimData` exists. It does not say the cell body can be evaluated to produce yields. The typing discipline stops at the database boundary.

2. **The effect lattice has no formal role (fourth review).** `BodyType` (hard/soft/stem) is not referenced by any theorem except the excluded `stemCellsDemandDriven`. The progress theorem applies uniformly to all body types. No theorem distinguishes hard from soft cells. This is unchanged from v3.

3. **`framesCellDefsExist` introduces a new typing obligation without integration.** It is a referential integrity property that morally belongs with I3-I5 in `wellFormed`. As a standalone predicate, it creates a bifurcated typing discipline: safety properties compose via `wellFormed_preserved`, but liveness requires an additional type (`framesCellDefsExist`) that is not preserved by the same machinery. The two type predicates should be unified.

### Path to A

Define an abstraction function from Denotational.lean's `CellDef M` to Retort.lean's `CellDef`. Integrate `framesCellDefsExist` into `wellFormed`. Give `BodyType` a formal role.

---

## Hoare (Verification): Grade A

**Core question:** Are preconditions, postconditions, and total correctness established?

### What Changed

This is the reviewer whose two central demands in v3 were (1) prove existential progress, and (2) complete the postcondition coverage. Both are delivered.

### Praises

1. **The progress theorem is exactly the statement demanded.** The v3 review asked: "if `readyFrames r` is non-empty, there exists a valid `ClaimData` satisfying `claimValid`." The v4 model delivers: `progress : f in r.readyFrames -> framesCellDefsExist r -> exists cd, claimValid r cd`. The statement is stronger in one way (it takes a specific frame, not just non-emptiness) and conditional in one way (it requires `framesCellDefsExist`). The frame-specific formulation is better: it says which frame drives the progress. The `framesCellDefsExist` precondition is natural and should be part of `wellFormed`.

2. **The postcondition coverage is now complete.** Five operations, at least one postcondition each:
   - Pour: `pour_adds_cells` (cells appear), `pour_adds_frames` (frames appear)
   - Claim: `claim_adds_claim` (claims grow by 1)
   - Freeze: `freeze_removes_claim` (claims shrink), `freeze_makes_frozen` (status becomes frozen when fields covered)
   - Release: claim removed (implicit from filter semantics)
   - CreateFrame: `createFrame_adds_frame` (frame appears)

   The v3 review specifically asked for pour membership and freeze status postconditions. Both are delivered. The `freeze_makes_frozen` postcondition is particularly valuable: it is the first theorem that says "after this operation, the derived state has a specific value." All prior postconditions were about list lengths or membership. This one is about computed status.

3. **The progress proof demonstrates the Hoare triple composition pattern.** The proof chains: (a) readyFrames membership implies frame membership and `frameReady`, (b) `frameReady` implies `frameStatus = .declared`, (c) `framesCellDefsExist` implies `cellDef` is `some`, (d) declared + some implies no claim, (e) frame exists + ready + no claim implies `claimValid`. This is a five-step Hoare-style chain where each step's postcondition is the next step's precondition. The model now demonstrates that its postconditions compose into progress arguments, which is what Hoare triples are for.

### Critiques

1. **No total correctness at the retort level.** The postconditions and progress theorem provide the pieces: `progress` says a step can be taken, `claim_adds_claim` says claiming happens, `freeze_removes_claim` says freeze releases the lock, `freeze_makes_frozen` says the frame becomes frozen. But the end-to-end theorem -- "given a finite acyclic program, there exists a sequence of valid operations that reaches `programComplete`" -- is not assembled. The building blocks are all present. The integration is missing.

2. **`framesCellDefsExist` is not preserved, limiting progress composability.** The progress theorem requires `framesCellDefsExist`. The `wellFormed_preserved` theorem does not produce `framesCellDefsExist` as a postcondition. This means: after proving `wellFormed` holds and applying an operation, you can prove `wellFormed` still holds, but you cannot immediately prove `progress` applies to the result. You need a separate proof that the operation preserved `framesCellDefsExist`. Without preservation theorems for this predicate, the progress result is a one-shot theorem rather than a composable piece of the safety-liveness story.

3. **The progress witness uses a dummy piston ID.** The constructed `ClaimData` uses `PistonId.mk "progress_witness"`. This is valid for the existential statement (some valid claim exists), but it means the theorem does not address piston scheduling. In a system with multiple pistons, the relevant question is not "does some claim exist" but "does a claim exist that a specific piston can execute." This is a refinement for the future, not a defect.

### Path to A+

Prove total correctness: for a finite acyclic program with `wellFormed` and `framesCellDefsExist`, there exists a valid operation sequence reaching `programComplete`. This requires composing `progress`, `claim_adds_claim`, `freeze_makes_frozen`, and showing that each freeze strictly reduces the number of non-frozen frames. Include `framesCellDefsExist` in `wellFormed` to make progress composable with preservation.

---

## Wadler (Functional Programmer): Grade A-

**Core question:** Are there algebraic laws? Does equational reasoning work?

### What Changed

The new postconditions add forward equational content. `freeze_makes_frozen` is the first theorem that equates a derived function application (`frameStatus`) to a specific constructor (`.frozen`). `pour_adds_cells` and `pour_adds_frames` are membership equalities. The progress theorem is existential rather than equational, which does not add algebraic structure directly.

### Praises

1. **`freeze_makes_frozen` is the model's first equational postcondition.** Previous postconditions spoke about list lengths (`claim_adds_claim`) or membership (`createFrame_adds_frame`). `freeze_makes_frozen` says `(applyOp r (.freeze fd)).frameStatus f = .frozen`. This is a genuine equation: the result of composing `applyOp` with `frameStatus` equals a specific value. It is the kind of law that enables equational reasoning about derived state: "after freeze, if I know the fields are covered, I can rewrite `frameStatus` to `.frozen` in any downstream goal."

2. **The postcondition suite now supports a termination measure.** `freeze_makes_frozen` shows that freeze changes a frame's status from non-frozen to `.frozen`. `freeze_removes_claim` shows that freeze removes a claim. `claim_adds_claim` shows that claim adds one. Together: each eval cycle (claim + freeze) nets one newly frozen frame and zero change in claim count. This is the raw material for a termination argument: the count of non-frozen non-stem frames decreases with each successful eval cycle. The algebraic structure for termination is present even though the termination theorem is not.

### Critiques

1. **No commutativity laws (fourth review).** `applyOp (applyOp r (claim a)) (claim b) = applyOp (applyOp r (claim b)) (claim a)` when `a.frameId != b.frameId` is still absent. This has been requested since v1. Without it, concurrent piston execution cannot be justified algebraically. Each interleaving must be analyzed independently. This remains the most impactful missing algebraic property.

2. **`applyOp` is still total and unchecked (fourth review).** It silently accepts invalid operations. The preconditions exist as separate predicates. No `applyOpChecked` wrapper exists. Unchanged from v3.

3. **The common proof patterns are still not factored (fourth review).** Filter-preserves-forall, append-preserves-existential-with-left, and append-preserves-uniqueness are still repeated across multiple proofs rather than extracted into reusable lemmas. The `mem_append_of_mem_left` and `mem_append_of_mem_right` helpers exist but the higher-level patterns (e.g., "if P holds for all elements of L, and L' = L.filter q, then P holds for all elements of L'") are not abstracted. Unchanged from v3.

### Path to A+

Prove commutativity of independent claims and independent pours. Extract the common proof patterns. The termination measure is implicit in the postconditions -- stating it explicitly as a well-founded relation on (count of non-frozen frames) would be the algebraic capstone.

---

## Sussman (Systems Thinker): Grade B+

**Core question:** Does the model compose? Can it be extended?

### What Changed

The new theorems improve the model's usability without changing its structure. `progress` tells a systems engineer "if there is work, the system can act." `freeze_makes_frozen` tells a systems engineer "after freeze, the frame is done." These are the operational guarantees a systems engineer needs. The extension protocol (add constructor, add preconditions, prove 7 invariant preservations, add arm to `wellFormed_preserved`) is unchanged.

### Praises

1. **The `progress` theorem is the first systems-level guarantee.** Previous theorems were structural (invariants preserved, data persists). `progress` is operational: it says the system can make forward progress when work exists. For a systems engineer designing a scheduler, this is the theorem that justifies the scheduler loop: "while readyFrames is non-empty, pick a frame, claim it, evaluate, freeze." The theorem guarantees the claim step will succeed.

2. **`freeze_makes_frozen` closes the eval cycle loop.** Combined with `progress` (a ready frame can be claimed) and `claim_adds_claim` (the claim is recorded), `freeze_makes_frozen` says the frame reaches its terminal state. The eval cycle is now fully characterized at the postcondition level: claim (claim recorded) -> freeze (status frozen, claim released) -> optionally createFrame (next generation exists). A systems engineer can trace the full lifecycle.

### Critiques

1. **The four files remain disconnected (fourth review).** No `Core.lean`. Retort.lean, Denotational.lean, StemCell.lean, Claims.lean define parallel type universes. This has been flagged since v1. No change.

2. **No multi-program composition theorem (fourth review).** Two sequential pours of independently well-formed programs still have no standalone composition result. No change.

3. **`ValidTrace` still does not require `validOp` (fourth review).** A `ValidTrace` can contain invalid operations. No `ValidWFTrace` exists. No change.

4. **`framesCellDefsExist` creates an integration gap.** A systems engineer building on this model would use `wellFormed_preserved` to maintain safety across operations, and `progress` to justify the scheduler. But `progress` requires `framesCellDefsExist`, which is not part of `wellFormed` and has no preservation proofs. The systems engineer must prove `framesCellDefsExist` holds after each operation manually. This is the same kind of gap that existed before `wellFormed_preserved`: individually proved properties that must be manually composed. The fix is straightforward (add it to `wellFormed`), which makes the omission more puzzling.

### Path to A

Create `Core.lean`. Include `framesCellDefsExist` in `wellFormed`. Define `ValidWFTrace` with `validOp` and `wellFormed` requirements. Prove multi-program composition.

---

## Consensus

### What Improved Since v3

The model has addressed two of the v3 review's seven priority actions, both completely:

1. **Existential progress (liveness).** The `progress` theorem proves that if a ready frame exists and every frame has a cell definition, a valid claim operation exists. This is the liveness result that was absent through v1-v3. The proof is genuine: it requires a semantic helper (`declared_of_some_implies_no_claim`) that exploits the three-way branching structure of `frameStatus`. The theorem transforms the model from a pure safety verification into a safety+liveness verification. The `framesCellDefsExist` precondition is natural (it is referential integrity) but its separation from `wellFormed` creates an integration gap.

2. **Complete postcondition coverage.** `pour_adds_cells`, `pour_adds_frames`, and `freeze_makes_frozen` fill the gaps identified in v3. Every operation now has at least one postcondition theorem. The `freeze_makes_frozen` theorem is qualitatively new: it is the first theorem connecting `applyOp` to `frameStatus`, bridging the operational layer (list mutations) and the derived layer (computed status). The postcondition suite now contains the raw ingredients for a termination argument.

3. **Line count and theorem count growth.** 1702 lines (up from 1581), 67 theorems (up from ~56), zero sorries. The growth is measured and purposeful: every new line serves a specific proof goal.

### What Remains

The v3 review identified seven priority actions. Two were completed. Five persist unchanged:

1. **Disconnected formalizations (four reviews running).** Four files, four type universes, zero morphisms. No `Core.lean`. No refinement theorem. This is the oldest open issue. Every review has flagged it. It has never been addressed.

2. **DAG properties outside `wellFormed` (four reviews running).** `noSelfLoops`, `generationOrdered`, `bindingsPointToFrozen` remain defined-but-unproven. `bindingsMonotone` has freeze-only preservation. `stemCellsDemandDriven` is defined and excluded. None of this has changed since v2.

3. **No commutativity laws (four reviews running).** Independent operations do not commute provably. Every review since v1 has asked for this. It has never been addressed.

4. **`stemHasDemand` unconstrained (four reviews running).** The demand predicate is `Retort -> Bool` with no monotonicity. Every review since v1 has asked for constraints. None have been added.

5. **`framesCellDefsExist` integration gap (new).** The progress theorem requires a predicate that is not in `wellFormed` and has no preservation proofs. This means the safety story (`wellFormed_preserved`) and the liveness story (`progress`) do not compose without manual bridging work. This is the v4 model's most actionable structural flaw: including `framesCellDefsExist` in `wellFormed` would make progress a corollary of well-formedness with no additional hypotheses, and prove preservation would be straightforward (pour adds cells and frames together, createFrame adds a frame for an existing cell, other operations do not modify cells or frames).

### Assessment: Did Progress Address Hoare?

Yes. Hoare's central v3 demand was "prove existential progress: `readyFrames r != [] -> exists cd, claimValid r cd`." The `progress` theorem delivers this with a natural precondition (`framesCellDefsExist`). Hoare moves from A- to A. The remaining gap to A+ is total correctness (a valid operation sequence reaching `programComplete`), which requires composing progress with the postconditions and proving a termination measure. The building blocks are all present.

### Assessment: Did Postconditions Address Iverson?

Partially. Iverson's v3 demand was "rename `GivenSpec.cellName`, prove audit property or remove `claimLog`, prove `resolve`/`resolveBindings` convergence." None of these were addressed. The new postconditions (`pour_adds_cells`, `pour_adds_frames`, `freeze_makes_frozen`) were Hoare's request, not Iverson's. Iverson's notation concerns (naming, dead weight, convergence) persist from v1. Iverson stays at B+.

### Assessment: What Moved the Needle?

The progress theorem is the single most important addition in v4. It transforms the model from a safety-only verification into a safety+liveness verification. The postcondition completions are valuable but incremental. The net effect is that Hoare's grade improves (the reviewer whose demands were met) while the other reviewers' grades stay constant (their demands were not addressed).

The model is reaching diminishing returns on the safety axis. All 7 invariants are preserved, all 5 operations have postconditions, progress is proved. The remaining gaps are all on different axes: algebraic structure (commutativity), modularity (Core.lean), correspondence (denotational-operational refinement), and classification (BodyType, DAG properties). Moving from A- to A+ requires broadening, not deepening.

### Grade Summary

| Reviewer | v1 Grade | v2 Grade | v3 Grade | v4 Grade | Delta v3->v4 | Key Factor |
|----------|----------|----------|----------|----------|--------------|------------|
| Feynman | B+ | B+ | A- | **A-** | +0.0 | Progress is internal to Retort; two-model gap unchanged |
| Iverson | B | B | B+ | **B+** | +0.0 | Postcondition vocabulary complete; naming/dead-weight issues persist |
| Dijkstra | B- | B+ | A- | **A-** | +0.0 | Progress proof is sound; DAG/framesCellDefsExist gaps remain |
| Milner | B | B | B+ | **B+** | +0.0 | Existential construction clean; type universes still disconnected |
| Hoare | C+ | B+ | A- | **A** | +0.5 | Progress delivered; postconditions complete; total correctness next |
| Wadler | B- | B+ | A- | **A-** | +0.0 | Equational postcondition (freeze_makes_frozen); no commutativity |
| Sussman | B | B | B+ | **B+** | +0.0 | Operational guarantees improved; module structure unchanged |

### Overall Grade: A-

The model holds at A-. The progress theorem and completed postconditions are genuine improvements, but they address one reviewer's concerns (Hoare) while leaving six reviewers' long-standing issues untouched. Hoare moves from A- to A, which is meaningful: the safety+liveness combination is qualitatively stronger than safety alone. But the overall grade does not shift because the systemic issues (disconnected formalizations, no commutativity, no DAG maintenance, unconstrained demand) are unchanged for the fourth consecutive review.

The grade does not reach A because:

- **No composability between safety and liveness.** `wellFormed_preserved` and `progress` require different predicates (`wellFormed` vs `wellFormed + framesCellDefsExist`). Integrating `framesCellDefsExist` into `wellFormed` is low-effort, high-impact.
- **Disconnected formalizations (four reviews).** The retort model and denotational model exist in separate type universes.
- **No algebraic structure for concurrency (four reviews).** Commutativity of independent operations is absent.
- **DAG properties are second-class (four reviews).** The dependency graph's structural properties are defined but not maintained.

The grade does not reach A+ because no reviewer gave a perfect score, and the longest-running requests (Core.lean, commutativity, stemHasDemand constraints, denotational-operational correspondence) have never been addressed across four review cycles.

### Priority Actions for v5

| Priority | Action | Difficulty | Impact | Addresses |
|----------|--------|------------|--------|-----------|
| 1 | Include `framesCellDefsExist` in `wellFormed`; prove preservation by all 5 ops | Low | High | Dijkstra, Hoare, Sussman (composability of safety+liveness) |
| 2 | Include `noSelfLoops` + DAG properties in `wellFormed`; prove preservation | Medium | High | Dijkstra |
| 3 | Prove commutativity of independent claims and independent pours | Medium | High | Wadler |
| 4 | Create `Core.lean` with shared types; eliminate parallel type universes | Low | High | Sussman, Milner |
| 5 | State and prove denotational-operational correspondence | Hard | High | Feynman, Milner |
| 6 | Prove total correctness: finite acyclic program reaches `programComplete` | Hard | High | Hoare |
| 7 | Constrain `stemHasDemand`; define `ValidWFTrace`; rename `GivenSpec.cellName` | Low | Medium | Feynman, Sussman, Iverson |

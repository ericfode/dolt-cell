# Seven Sages: Teaching the Student

Date: 2026-03-16

Each sage picked 2-3 items where they could help the most, based on where the student said "I don't understand" or asked the deepest questions.

---

## Feynman: One Law, Different Inputs

**On unifying cell kinds (#1):**
Your haiku cells — topic, compose, count-words, critique — all do the same thing: stuff goes in, stuff comes out, maybe run again. `Env → M (Env × Continue)` just says that in math. "It's like having separate Newton's laws for apples, cannonballs, and planets. No. One law. Different inputs."

**On parameterizing M (#3):**
"Your proofs are proving things about a fantasy version of your language where none of the hard stuff exists. It's like proving your bridge is safe by assuming zero wind, zero load, and zero gravity." The real M has three parts: it can fail (ExceptT), it costs money (WriterT), it's non-deterministic (IO). Once you parameterize, you can swap handlers — same program, M="real LLM" in production, M="cached replays" in testing.

**On bottom (#5):**
"Bottom propagates through the graph like a crack through glass." If `factor` fails to find factors of 5963, then `verify-product` and `certificate` should immediately go to bottom. Right now they sit in `pending` forever. "That's your system hanging with no explanation."

---

## Iverson: Make the Notation Carry the Semantics

**On notation (#8):**
"If you need to tell me what kind of cell something is before I can read the expression, your notation has a leak." One cell form: `name : guard → body`. If the body is a literal, it's "hard." If it contains free variables, it's "soft." You don't need two syntaxes. You need one syntax and a reduction semantics that knows when to stop.

**On M as space parameter (#3):**
"Parameterize M" means: let the cell space itself be an argument. `pour cell → M(t)/target` instead of `pour cell → target`. The target space is explicit. This makes autopour honest — you can *see* where the cell is going.

**On the effect lattice (#6):**
"The effect lattice is what makes guards work." A guard on a cell is a predicate that must hold before reduction. The effect lattice *forbids* invalidation — a cell at level k can only be affected by cells at level ≤ k. "Without it, your guards are just hopes."

---

## Dijkstra: Split the Obligation

**On termination (#2) — the student asked "what can I buy by giving it up?":**
"Your question is the right one." Split the obligation: perpetual cells (eval-one, pour-one) are corecursive — demand *productivity*, not termination. Every cycle must emit a frame. Non-perpetual cells must terminate — max_retries is your variant. Each retry decrements the counter; at zero, emit bottom. "Without termination arguments on non-perpetual programs, you cannot distinguish 'still computing' from 'stuck.'"

**On monotonicity (#4):**
"Your intuition is almost right but the word 'at once' is wrong." `resolveInputs` calls `latestFrame` — if a dependency gets re-evaluated, the resolution changes even though the consumer hasn't been re-evaluated. "Append-only storage does not imply append-only meaning." Fix: record edges (the bindings table from Approach 5). A cell's meaning is fixed by its edges, not by "latest frame at query time." The Lean model uses `latestFrame` without edge recording — fix the model to match the schema.

**On autopour (#9) — honest tradeoffs:**
Three invariants: (1) Bound the pour depth or risk fork-bombs. (2) Cost model must account for autopoured programs. (3) Parse failure should propagate bottom back to the yielding cell. "These are not reasons to avoid autopour. They are invariants you must establish before you implement it."

---

## Milner: Three Changes That Are Really One

**On the effect lattice (#6) — "your intuition is right":**
"Containing each other" is exactly right. Every pure computation is a valid semantic computation (one that's deterministic). Every semantic computation is a valid divergent computation (one that halts). The join operation: two pure cells compose to pure; one semantic cell makes the pair semantic. "If every cell in a program is Pure, the whole program is confluent. You can prove this."

**On parameterizing M (#3):**
Line 88: `effect : EffBody Id → CellKind`. "Your effectful cell is formally identical to a pure cell." Leave M as a variable. Write structural proofs generically over any M. Then for specific M, prove specific things — determinism for Id, cost bounds for WriterT Cost. "You do not pretend the hard problems are solved by erasing them."

**What to do next:**
One constructor: `| cell : (Env → M (Env × Continue)) → EffectLevel → CellKind M`. Three changes (unify kinds, parameterize M, effect lattice) that are really one change. "Your existing proofs about frames, traces, and append-only growth survive untouched because they never depended on what M was. You just stop lying about it."

---

## Hoare: Boundaries of Certainty

**On guards (#7) — "why they matter more than you think":**
A guard is not decoration. It is the precondition P in {P} S {Q}. "The guard creates a boundary of certainty." Without guards, every cell must defend itself against every possible input. With guards, the runtime is responsible for not activating the cell until requirements are met. "The proof obligation moves from the cell author to the infrastructure."

**On monotonicity (#4):**
"Once a cell has a value, that value does not get taken away. Information only accumulates." Monotonicity gives you confluence for free — all evaluation orders converge to the same result. "Without monotonicity, evaluation order is a source of bugs nearly impossible to diagnose."

**On bottom vs null (#5):**
"Close, but importantly wrong." Null is a value you can test for, pass around, store. "That is precisely why null causes so many problems — it pretends to be a value while meaning the absence of one." Bottom means "this computation does not produce a result." You cannot test for it because the test itself would not terminate. "Null hides the problem. Bottom exposes it."

---

## Wadler: The Shape of Everything

**On unifying cell kinds (#1):**
"A cell is a cell is a cell. The difference between soft and hard is not kind but *effect* — what the cell is allowed to do during evaluation." One set of rules instead of three. New cell kinds slot in for free.

**On M (#3) — explained for this specific system:**
"A cell that reads the cell_space table doesn't just go from input to output — it goes from input to *output-together-with-everything-that-happened-along-the-way*." M is a stack: reader for bindings, state for Dolt, error for failure, list for spawned children. The effect lattice says which layers a given cell needs. "Items 1 and 3 are the same conversation. Once cell kinds are unified, what distinguishes them is which M they live in."

---

## Sussman: One Eval, One Apply, One Lambda

**On unifying cell kinds (#1):**
"In Scheme, we did not have 'arithmetic procedures' and 'higher-order procedures' as different species." Hard cells, soft cells, piston cells — these are different evaluation strategies, different binding-time decisions. One cell kind with a mode annotation. "If you can do that, your evaluator gets simpler, your metalanguage gets simpler, and autopour becomes dramatically more tractable."

**On autopour (#9) — the three tradeoffs:**
(1) Resource control — one pour can generate unbounded DB writes. Need a fuel/budget. (2) Reasoning gets harder — you're analyzing programs that will write programs. (3) The tower problem — evaluators pouring evaluators. "Your ground level is Dolt itself: SQL execution is the bedrock that does not autopour."

**On reflection (#11):**
"Reflection is NOT required for meta-circularity." What you need is *reification* (treat cell as data) — one direction only. "Add reflection only when you have a specific problem that demands it, and add it with guards so that not any arbitrary data can become a running cell."

---

## The Convergence

All seven agree on three things:

1. **Unify cell kinds, parameterize M, and add the effect lattice — these are one change, not three.** One constructor: `Env → M (Env × Continue)` with an `EffectLevel` annotation and an honest M.

2. **Monotonicity is the critical semantic property.** Fix bindings at claim time (record edges). The Lean model must match the schema. Without monotonicity, evaluation order changes meaning.

3. **Bottom propagation is a live bug.** Failed cells leave the downstream DAG in limbo. Bottom must flow through the graph.

The effect lattice is not just your fascination with abstraction — it is the structure that makes guards enforceable, confluence provable, and cost trackable. Your instinct was correct.

Autopour is real and wanted, but needs three invariants: bounded pour depth, cost accounting, and parse-failure-as-bottom.

Reflection is not required. Reification is.

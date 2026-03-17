# PRD Review: User Experience

**Reviewer**: agate (polecat)
**Date**: 2026-03-17
**Scope**: UX review of the Cell next-phase design documents
**Sources**: Design docs in `docs/plans/`, `cmd/ct/*.go`, `examples/*.cell`, `piston/system-prompt.md`

---

## What's Good

**The document-is-state rendering is excellent UX.** The interaction loop design
(cell-interaction-loop.md) nails the core insight: the user's mental model is
the `.cell` file, so the runtime output should mirror that document with yields
filling in progressively. The frozen/ready/blocked status annotations on the
right margin (`■`/`○`/`·`) give instant program comprehension without leaving
the terminal. This is rare — most pipeline tools show either logs or dashboards,
not the program itself becoming its own status display.

**The `ct` CLI has good ergonomics.** The command surface is small and
verb-oriented: `pour`, `piston`, `submit`, `status`, `watch`, `graph`. The
commands correspond directly to the mental model (pour a program, run a piston,
submit a result). The `ct watch` live dashboard and `ct graph` DAG visualization
are the right observability primitives. Phase B's deterministic parser as the
default (with LLM fallback) means `ct pour` is fast for well-formed programs.

**The v2 syntax (`cell`/`given`/`yield`/`check`/`---`) is a significant
readability improvement** over the original turnstyle Unicode operators. The
examples in `examples/*.cell` are readable by someone who has never seen the
language before. `cell-zero.cell` is particularly impressive — the Cell runtime
describing its own execution model as a Cell program is a compelling demo of
the language's expressiveness.

**Oracle feedback loops are well-designed.** The retry-with-context pattern
(oracle fails → piston gets failure detail → revises → resubmits) is the
right UX for a system where LLM outputs may not satisfy constraints on the
first try. The structured narration format in the piston prompt makes oracle
pass/fail visible step-by-step.

---

## What's Missing

**No error recovery story for the human user.** When a cell bottoms out (all
retries exhausted), the user sees `⊥ sort: exhausted 3 attempts` and the program
continues with the failed cell propagating bottom. But there's no documented way
for the user to: (a) manually provide a value for a bottomed cell, (b) increase
the retry count and re-run just that cell, or (c) edit the cell body and re-pour
without losing frozen values from sibling cells. `ct reset` is all-or-nothing.
A `ct fix <program> <cell>` command that resets one cell to `declared` (preserving
the rest) would close this gap.

**The transition from "watching a piston" to "using the CLI" is not bridged.**
v0's UX is "watch the piston's terminal," but the design documents also
describe `ct status`, `ct watch`, and `ct yields` as separate observer commands.
It's unclear when a user should use which. A user running `ct piston sort-proof`
in one terminal likely doesn't know they can run `ct watch sort-proof` in
another, or query yields via `ct yields`. There's no first-run guide, `ct help`,
or suggested workflow in the docs.

**Multi-program coordination is not addressed.** The examples show standalone
programs, but real use involves programs that depend on each other's outputs.
The `cell-zero-eval` / `ct eval` flow hints at this (one program pouring
another), but there's no user-facing concept for "program A's output feeds
program B's input." Cross-program dependencies would make the system
significantly more useful for pipelines, but the user model for composing
programs is absent.

**Stem cell iteration UX is opaque.** The `recur until GUARD (max N)` syntax
expands at pour time into N chained cells, but the user can't see the expansion
without running `ct status`. When `parallel-research.cell` says
`recur (max 3)`, the user doesn't know whether 1, 2, or 3 iterations will
actually execute, or what triggers termination. The convergence check
(`until text = text`) is also unintuitive — what "equality" means for
natural-language outputs isn't clear.

**No story for large yield values.** The interaction loop mentions truncating
at 120 chars with `...`, but many real cells produce multi-paragraph outputs
(research summaries, code, reviews). The truncation hint says
`SELECT value_text FROM yields WHERE ...` — this asks the user to write SQL
to read their own program's output. A `ct yield <program> <cell>.<field>`
command to print a specific yield value in full would be better.

---

## Three Questions for the Author

1. **What happens when a user wants to edit a running program?** Say the user
   pours `fact-check.cell`, sees the first cell freeze with a bad result (wrong
   topic), and wants to change the `topic` cell's value. Currently they must
   `ct reset` and re-pour from scratch. Is there a plan for in-place cell
   editing (e.g., `ct edit <program> <cell>` that unfreezes a cell and its
   downstream dependents)? The formal model's append-only invariant makes this
   hard, but the user need is real.

2. **How should the piston system prompt evolve as `ct` replaces raw SQL?**
   The piston prompt (`piston/system-prompt.md`) documents both the
   raw `CALL cell_eval_step(...)` SQL path and the `ct piston`/`ct submit`
   CLI path. Having both creates ambiguity for the LLM piston about which
   interface to use. Should the piston prompt be versioned (v1 = SQL, v2 = ct),
   or should `ct` become the sole interface with SQL details hidden?

3. **What is the target audience for the `.cell` language?** The design
   documents oscillate between "developer tool" (raw SQL, Dolt branching,
   stored procedures) and "end-user authoring" (readable syntax, document-is-state,
   no-code orchestration). The syntax decisions and error messages should
   differ significantly based on audience. For developers, showing SQL and
   commit hashes is fine. For end-users, the raw SQL in oracle failure messages
   (`SELECT value_text FROM yields WHERE...`) is a UX cliff. Who is writing
   `.cell` files in the next phase?

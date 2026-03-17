# PRD Review: Integration Perspective — Cell Next Phase

**Reviewer:** mica (integration)
**Date:** 2026-03-17
**Sources reviewed:** `docs/plans/2026-03-16-cell-zero-bootstrap-design.md`,
`docs/plans/2026-03-16-full-migration-plan.md`,
`docs/plans/2026-03-17-bug-fix-analysis.md`,
`cmd/ct/*.go`, `examples/*.cell`, `piston/system-prompt.md`,
`formal/Retort.lean`

> **Note:** `docs/plans/cell-next-phase-prd.md` does not exist. This review is
> synthesized from the design documents and codebase that collectively define the
> "Cell next phase" direction.

---

## What's Good

**Frame migration is the right keystone.** The bug-fix analysis correctly
identifies the `cell_id` → `frame_id` re-keying as the single highest-leverage
change, automatically resolving 13 of 25 Lean-to-Go conformance bugs. The
phased migration (A → B → C) that has already landed — stop deleting rows,
add frame_id to yields, key claims on frame_id — is a clean incremental path
that avoids a big-bang rewrite. The Go implementation and formal Lean model
are converging, which is rare and valuable.

**cell-zero-eval's bootstrapping ladder is architecturally sound.** Moving the
eval orchestrator into cell-space (cell-zero) creates a self-hosting path:
Level 1 (cell-zero orchestrates), Level 2 (pour becomes a perpetual cell),
Level 3 (self-modification). The `ct piston` → `ct next` → `ct submit` tool
surface is already clean enough that the piston system-prompt works without
escape hatches. The examples (`haiku.cell`, `haiku-refine.cell`,
`cell-zero-eval.cell`) demonstrate real programs running end-to-end through
the same plumbing.

**Formal-implementation duality is enforced.** The `formal/Retort.lean` model
defines exactly 5 operations (pour, claim, freeze, release, createFrame), all
proven append-only. The `resetProgram` function in `pour.go` is explicitly
documented as a formal deviation with epoch boundary tracking. This discipline
— flagging every deviation instead of quietly diverging — makes the gap
auditable.

---

## What's Missing

**No integration contract between `ct` CLI and the piston system-prompt.** The
piston prompt tells the LLM to use raw SQL (`CALL cell_eval_step(...)`,
`CALL cell_submit(...)`) while `ct` wraps those same procedures in Go. When
the frame migration changes the stored procedure signatures or yield schemas,
both `eval.go` and `piston/system-prompt.md` must update in lockstep. There is
no test, schema version check, or contract test that verifies the piston prompt
stays consistent with the underlying procedures. A single column rename would
silently break every running piston.

**Multi-piston coordination is unspecified.** `findReadyCell` uses `INSERT
IGNORE INTO cell_claims` for optimistic locking, but there is no specification
for: (a) what happens when two pistons race to claim the same frame, (b) stale
claim reaping beyond the `cell_reap_stale` stored procedure, (c) piston
heartbeat enforcement (the system-prompt mentions `piston_heartbeat` but
`eval.go` never calls it). The cell-zero-eval design assumes a single piston
loop; scaling to N pistons will surface these gaps.

**No migration path for existing programs across schema changes.** The frame
migration adds columns and re-keys tables, but programs poured before the
migration have yields without `frame_id` and no entries in the `frames` table.
`ensureFrames` in `pour.go` backfills gen-0 frames, but only when `ct pour`
is called. Programs poured before the migration but not re-poured have orphan
yields. There is no `ct migrate` command or automatic backfill on `ct status`.

**Piston system-prompt still references mutable patterns.** Lines like
`UPDATE cells SET state = 'computing'` and `DELETE FROM cell_claims` in the
`cell-zero-eval.cell` body directly contradict the append-only formal model.
When a piston follows these instructions literally, it violates the invariants
the Lean proofs guarantee. The piston prompt needs to be updated to match the
frame-based model or these instructions will be the primary source of runtime
invariant violations.

**No observability story.** `ct watch` gives a terminal dashboard, but there
is no structured logging, metrics export, or event stream for: eval step
latency, claim contention rate, oracle failure rate, program completion time.
For multi-piston deployment, operators will have no visibility into system
health.

---

## Three Specific Questions for the Author

1. **Schema versioning:** When the frame migration lands its final phase
   (derived state, drop `cells.state`), every stored procedure signature
   changes. How will running pistons discover the new schema? Is the plan to
   require all pistons to stop and restart, or will there be a version
   negotiation protocol (e.g., `ct version` returns schema epoch, piston
   prompt includes `IF schema_version >= N THEN ...`)?

2. **cell-zero-eval self-spawn correctness:** `cell-zero-eval.cell`'s
   `eval-one` body includes raw SQL to `INSERT INTO cells` and `INSERT INTO
   yields` for spawning successors. This bypasses `ct pour` and the Phase B
   parser entirely. When the schema adds `frame_id` as a required FK on
   yields, these hand-crafted INSERTs will fail silently (no frame row
   created). Is the plan to (a) rewrite cell-zero-eval to use `ct` commands
   instead of raw SQL, (b) make the stored procedures handle spawn internally
   (as `replRespawnStem` already does for stem cells via `ct submit`), or
   (c) accept that cell-zero-eval is a bootstrap artifact that will be
   replaced by Level 2?

3. **Oracle atomicity (do-7i1.24):** The bug-fix analysis flags this as
   "design decision needed" — semantic oracles via judge cells evaluate AFTER
   the original cell freezes, creating a window where frozen frames have
   unverified outputs. The full-migration plan (Task 8) asks for the formal
   model to be reviewed by Seven Sages, but the oracle atomicity question is
   architectural, not a proof gap. Will the next phase commit to blocking
   oracles (judge must freeze before the original cell freezes) or async
   oracles (frozen frames can have pending verdicts, downstream cells check
   verdict before reading)? This affects the Lean model, the stored
   procedures, and the piston prompt simultaneously.

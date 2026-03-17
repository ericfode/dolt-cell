# Cell UX Notes — Eating Our Own Dogfood

Date: 2026-03-17
Program: bug-to-perfect.cell (poured as fix-parser-bleed)

## Experience Report

### Problem 1: Stale claims block everything
When a piston dies mid-evaluation, the cell stays in `computing` with a stale claim.
No other piston can claim it. Manual SQL intervention needed every time.
**Need:** automatic stale claim reaping, or `ct release` that's easy to discover.

### Problem 2: State reset requires raw SQL
`ct reset` nukes the whole program. There's no way to reset ONE cell.
The `ct thaw` idea from the sages would fix this.
Needed to run raw SQL (`UPDATE cells SET state = 'declared'`) multiple times.
**Need:** `ct thaw <program> <cell>` or `ct release <program> <cell>`.

### Problem 3: ready_cells view vs Go code disagree
The SQL `ready_cells` view shows diagnose as ready.
But `ct piston` and `ct next` return QUIESCENT.
The Go `findReadyCell` / `replEvalStep` must have a different readiness check.
Polecat migrations may have changed the Go code without updating readiness logic.
**Need:** single source of truth for readiness — either the view OR the Go code, not both.

### Problem 4: No visibility into WHY quiescent
`ct piston` just prints "QUIESCENT" with no explanation.
Is it because no ready cells? Stale claims? Schema mismatch?
**Need:** `ct piston --verbose` or `ct why <program>` that explains blocking.

### Problem 5: recur expansion creates ALL iterations upfront
`recur until grade = "A" (max 3)` creates review-1, review-2, review-3 at pour time.
But lazy semantics says review-2 should only exist if review-1 didn't satisfy the guard.
The static expansion wastes resources and makes status output noisy.
**Need:** dynamic iteration — create review-N only when review-(N-1) doesn't satisfy guard.

### Problem 6: Stem cells auto-claimed before piston is ready
When pouring, `diagnose` was immediately claimed by the pour process's piston registration.
The piston session wasn't ready to evaluate it, so it got stuck in computing.
**Need:** don't auto-claim on pour. Let the piston explicitly claim via `ct next`.

### What Worked Well
- The .cell syntax is readable and the DAG visualization (ct graph) is excellent
- Hard cells (bug.id, bug.description) auto-freeze perfectly
- The pipeline concept (diagnose → implement → review → ship) maps naturally to cells
- Pour was fast and the parser handled the program correctly

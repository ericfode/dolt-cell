# Systems Review: Cell Runtime Design v2 — Dolt IS the Runtime

**Reviewer**: Kai (Systems Architect, Gas Town)
**Document**: `docs/plans/2026-03-14-cell-repl-design-v2.md`
**Prior review**: `docs/reviews/kai-systems-review.md` (v1 review)
**Date**: 2026-03-14
**Verdict**: v2 resolves all four of my blocking concerns from v1. The stored
procedure architecture is a genuinely better design than what I proposed. New
concerns exist but they are engineering problems, not architectural mistakes.

---

## Part 1: Resolution of v1 Concerns

### 1.1 Formula Type Mismatch — RESOLVED

v1 proposed 10 "runtime formulas" that were functions pretending to be
workflows. I argued that Gas Town formulas are multi-step TOML workflows with
pour/squash lifecycle, not callable subroutines. I recommended `bd cell *`
CLI commands instead.

v2 goes further than my recommendation. Instead of CLI commands, the runtime
operations are Dolt stored procedures: `cell_eval_step()`, `cell_submit()`,
`cell_pour()`, `cell_status()`. No formulas. No CLIs wrapping formulas. SQL
procedures called via `CALL`.

This is better than `bd cell *` commands for two reasons:

1. **Atomicity.** A stored procedure runs inside a database transaction. The
   claim-and-mark-computing step in `cell_eval_step` uses `SELECT ... FOR
   UPDATE` to atomically claim a cell. A CLI command would need to open a
   connection, issue the SELECT, issue the UPDATE, and hope no other process
   intervened. The procedure does it in one shot.

2. **No process boundary.** `bd cell ready` as a CLI command means: spawn
   process, connect to Dolt, run query, serialize JSON, exit, caller parses
   JSON. `CALL cell_eval_step()` means: the LLM's SQL connection calls the
   procedure and gets the result set back. No process spawn, no serialization
   overhead. For a loop that runs 50-100 times per program, this matters.

The formula engine is no longer involved. This concern is fully resolved.

### 1.2 Retort Schema Kept — RESOLVED

v1's most emphatic recommendation was "keep Retort." The Retort schema has
normalized tables (`cells`, `givens`, `yields`, `oracles`) with proper indices,
foreign keys, and the `ready_cells` VIEW. I argued against flattening this into
bead metadata JSON.

v2 keeps the Retort schema intact. The resolved concerns table says it
explicitly: "Using Retort schema with proper tables/indices." The `ready_cells`
VIEW is preserved. The `trace` table with `DoltIgnoreTrace` is preserved. New
additions (stored procedures, hard cell views) are layered on top, not
replacements.

This concern is fully resolved.

### 1.3 Beads Namespace Pollution — RESOLVED

v1 warned that mapping cells to beads would create 72+ mechanical beads per
20-cell program, polluting `bd list`, `bd ready`, and the Witness patrol. I
recommended either a separate Dolt database or hierarchical namespacing.

v2 uses the Retort schema as its own namespace. Cell state lives in Retort
tables, not in beads. The resolved concerns table says "Using Retort (separate
schema). Beads for coordination only." Cell beads do not appear in `bd list`.
The Witness patrol does not scan cell computation state. The `bead_bridge`
integration point (which the original Retort schema designed) is preserved for
the cases where Cell dispatches to polecats.

This concern is fully resolved.

### 1.4 Control Flow Inversion — RESOLVED

v1 argued that "the LLM IS the runtime" was a liability because the LLM was
doing mechanical orchestration poorly. Ravi's review made this case even more
forcefully and recommended inverting control: the deterministic runtime drives,
the LLM is called only when semantic work is needed.

v2 inverts control completely. The stored procedures drive. `cell_eval_step()`
decides what to evaluate next, resolves inputs, interpolates references, and
returns a prompt to the LLM. The LLM thinks and calls `cell_submit()`. The
procedure handles oracle checking, state transitions, and commits. The LLM
"holds NO state" (v2's own emphasis). The procedure maintains everything.

This is the right architecture. The piston metaphor is apt: the crankshaft
(stored procedures) converts the piston's force (LLM output) into rotation
(program evaluation). The piston does not decide when to fire.

---

## Part 2: What IS the Piston?

The v2 design describes the piston as "instructions to the LLM" with a loop:
`CALL cell_eval_step()`, think, `CALL cell_submit()`, repeat. In Gas Town
terms, this needs to be mapped to our agent types.

### 2.1 The Piston Is a Crew Member Following a Procedure

A piston is a Claude Code session executing a tight loop of SQL calls and
reasoning. In Gas Town's taxonomy:

- It is NOT a polecat. Polecats have full lifecycle: tmux session, git
  worktree, `gt prime`, `mol-polecat-work` formula, `gt done`, merge queue.
  That machinery is for multi-hour work items with code artifacts. A piston
  doing `CALL cell_eval_step(); think; CALL cell_submit()` does not need a
  worktree, does not push branches, does not enter a merge queue.

- It is NOT a dog. Dogs run maintenance formulas (reaper, refinery, sweep).
  A piston is doing primary computation, not maintenance.

- It IS closest to a crew member following a procedure. Like Helix following a
  design review checklist, or the Deacon running a patrol. The procedure is
  simple enough to be a hook or a short set of instructions, not a full
  formula.

### 2.2 Integration with Gas Town Agent Lifecycle

The piston needs:

1. **A connection to the Dolt server.** It runs SQL. The existing Dolt
   sql-server that beads uses can host the Retort database. The piston connects
   via mysql client protocol, same as `bd` does.

2. **LLM capabilities.** It needs to read prompts from `cell_eval_step()`
   output and reason about them. A Claude Code session provides this.

3. **Tool access.** For complex soft cells ("review this codebase"), the piston
   needs grep, read, bash -- the full Claude Code toolset. This is already
   available in a Claude Code session.

4. **No Git lifecycle.** The piston does not commit code, push branches, or
   enter merge queues. It writes to the Retort database via SQL. Git operations
   are irrelevant.

**Recommendation: Define a `piston` agent type in Gas Town.** It is lighter
than a polecat (no worktree, no formula lifecycle) but heavier than a bare
Claude Code session (it has a defined loop and a Dolt connection). The spawn
mechanism could be as simple as `gt piston start <program-id>` which launches a
Claude Code session with the piston instructions injected as context and a SQL
connection pre-configured.

### 2.3 What the Piston Instructions Look Like

The piston instructions are something like:

```
You are a Cell piston. Your job is to evaluate soft cells in program
{program_id}. Loop:

1. Run: CALL cell_eval_step('{program_id}')
2. If result is 'quiescent', stop.
3. If result is 'dispatch', read the prompt and resolved inputs.
4. Think about the prompt. Use your tools if needed.
5. Run: CALL cell_submit('{cell_id}', '{field}', '{value}')
6. If result is 'frozen', go to 1.
7. If result is 'oracle_fail', read the failure reason, retry from 4.
8. If result is 'exhausted', go to 1 (the procedure handled the bottom).
```

This fits in a system prompt. No formula needed. No formula lifecycle.

---

## Part 3: Retort Database vs Beads Database — Coexistence

### 3.1 Separate Databases on the Same Server

The Dolt sql-server can host multiple databases. Beads uses one database
(typically named after the workspace). Retort should be a separate database.

```sql
CREATE DATABASE IF NOT EXISTS retort;
USE retort;
-- Apply Retort schema here
```

The piston connects to `retort`. Beads operations connect to the workspace
database. No cross-contamination. Different `dolt_commit` histories. Different
branch namespaces.

This is the clean path. One Dolt server process, two databases, independent
version histories.

### 3.2 Will Stored Procedures Conflict with Beads Operations?

**Write contention**: No. Different databases have independent write locks in
Dolt sql-server. A `DOLT_COMMIT` in `retort` does not block a `DOLT_COMMIT`
in the workspace database. Polecats writing beads and pistons writing cells
operate on different databases.

**Connection pool**: Possible concern. If the Dolt sql-server has a connection
limit, pistons and beads operations compete for connections. In practice, Gas
Town runs a modest number of concurrent agents (3-5 polecats, 1 witness, 1-2
dogs). Adding 1-3 pistons is within normal connection capacity.

**Dolt server restarts**: When the Dolt server restarts, both databases come
back. Retort stored procedures are stored in the database, so they survive
restarts. No separate deployment step.

### 3.3 The bead_bridge in Practice

The `bead_bridge` table maps Retort cell IDs to beads IDs. It lives in the
Retort database. In practice, the bridge is used when:

1. **A complex soft cell needs polecat isolation.** The piston decides (or the
   cell's `model_hint` indicates) that this cell needs a full polecat with a
   worktree. The piston:
   - Creates a bead in the workspace database via `bd create`
   - Records the mapping in `bead_bridge`: `(cell_id, bead_id)`
   - Dispatches via `gt sling`
   - Polls the bead for completion (or waits for mail)
   - Reads the result from the bead
   - Calls `cell_submit()` with the result

2. **Reporting.** A status view can join across databases to show Cell programs
   alongside workspace work items. Dolt sql-server supports cross-database
   queries.

The bridge is a thin mapping table, not a synchronization protocol. Most cells
will never touch it because most cells evaluate inline (the piston thinks and
submits, no bead needed).

**Concern**: The design does not specify who creates the `bead_bridge` entry
or when. This should be documented as part of the polecat dispatch flow inside
`cell_eval_step`, or as a separate procedure `cell_dispatch_polecat()`.

---

## Part 4: Multiple Pistons — Polecats or a New Agent Type?

### 4.1 Pistons Are Not Polecats

The v2 design describes multiple pistons connecting to the same Retort database,
with the stored procedure handling atomic assignment via `SELECT ... FOR UPDATE`.
This is a worker pool pattern.

Gas Town polecats are also a worker pool (dispatched via `gt sling`, work from
the bead queue). But the polecat infrastructure has specific properties that
pistons do not need:

| Polecat Property | Piston Needs It? | Why |
|-----------------|-----------------|-----|
| Git worktree | No | Pistons write to Retort, not to code files |
| tmux session | Maybe | Depends on spawn mechanism |
| `gt prime` + hook | Maybe | Could use a simpler init |
| `mol-polecat-work` formula | No | Pistons follow a 8-line instruction set |
| `gt done` + merge queue | No | Pistons call `cell_submit()`, not `gt done` |
| Witness patrol monitoring | YES | Session death detection is critical (see Part 6) |
| Agent bead | Maybe | Useful for tracking piston lifetime |

### 4.2 Reuse the Spawn Infrastructure, Not the Lifecycle

The existing `gt sling` spawns tmux sessions with worktrees. Pistons do not
need worktrees but they do need:

- A Claude Code session
- Connection details for the Retort database
- The piston instructions (what program to evaluate)
- A way to detect session death

**Recommendation**: Create a `gt piston` command that:

1. Spawns a Claude Code session (tmux session, no worktree)
2. Injects piston instructions as context
3. Registers the piston in a `pistons` table in Retort:
   `INSERT INTO pistons (id, program_id, started_at, status)`
4. The piston updates its heartbeat periodically:
   `UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?`

The Witness (or a Cell-specific witness) monitors the `pistons` table for
stale heartbeats. More on this in Part 6.

### 4.3 Model Routing and Affinity

v2 describes `model_hint` on cells: some cells want Haiku (cheap, fast), some
want Opus (deep reasoning). Different pistons can filter by affinity:

```sql
-- Inside cell_eval_step, with affinity parameter:
SELECT id INTO ready_id FROM ready_cells
WHERE program_id = ? AND state = 'declared'
  AND (model_hint IS NULL OR model_hint = ?)
LIMIT 1 FOR UPDATE;
```

Three Haiku pistons churn cheap cells. One Opus piston handles complex ones. A
piston with no affinity filter takes whatever is available.

This is elegant and maps well to Gas Town's rig concept. Different rigs have
different capabilities (language model tiers). Pistons are rigs with model
affinity.

**Concern**: What if no piston with the right affinity is running? The cell sits
in `declared` state forever. The `cell_eval_step` for a mismatched piston
returns it as ready (because it is ready), but the piston should skip it. The
procedure needs a `SKIP` return alongside `dispatch` and `quiescent` to
indicate "there are ready cells but none match your affinity."

---

## Part 5: Session Death and Recovery

### 5.1 The Stuck-in-Computing Problem

If a piston dies mid-evaluation, the cell it was working on is stuck in
`computing` state. The procedure marked it `computing` in `cell_eval_step`
but the piston never called `cell_submit`. The cell is now invisible to other
pistons (it is not `declared`, so `ready_cells` does not return it).

This is the piston equivalent of the polecat zombie problem, which the Witness
patrol's zombie detection handles with approximately 200 lines of formula logic.

### 5.2 Who Detects Stale Computing Cells?

Three options:

**Option A: Heartbeat + Reaper in the Stored Procedure Layer.**

Add a `computing_since` timestamp and `assigned_piston` to the `cells` table.
When `cell_eval_step` claims a cell, it records:

```sql
UPDATE cells
SET state = 'computing',
    computing_since = NOW(),
    assigned_piston = ?
WHERE id = ready_id;
```

A scheduled procedure (or a SQL event) runs periodically:

```sql
-- Reset cells stuck in computing for more than N minutes
UPDATE cells
SET state = 'declared',
    computing_since = NULL,
    assigned_piston = NULL,
    retry_count = retry_count  -- do NOT increment retry count for piston death
WHERE state = 'computing'
  AND computing_since < NOW() - INTERVAL 10 MINUTE;
```

This is self-contained within Retort. No external agent needed. Dolt does not
natively support scheduled events, but a simple cron job or a dog could run
`CALL cell_reap_stale()` every 5 minutes.

**Option B: The Witness Monitors Pistons.**

The existing Witness patrol runs every 30 seconds. Add a step to
`mol-witness-patrol` that checks the `pistons` table for stale heartbeats and
resets any cells assigned to dead pistons.

This reuses existing infrastructure but couples Cell operations to the Witness
formula, which is already 9 steps and 200+ lines.

**Option C: A Cell Witness (Cell-specific patrol).**

A dedicated patrol formula `mol-cell-witness` that:
1. Checks `pistons` heartbeats
2. Resets stale `computing` cells
3. Detects quiescent programs and reports
4. Cleans up completed program state

This is the cleanest separation of concerns but adds another running agent.

**Recommendation**: Option A for the minimum viable system. A stored procedure
`cell_reap_stale()` that any agent can call. No external monitoring needed for
basic recovery. Option C when the system matures and needs active health
monitoring.

### 5.3 Recovery Semantics

When a cell is reset from `computing` to `declared` due to piston death:

- **Do not increment `retry_count`.** Piston death is not an evaluation failure.
  The cell has not been evaluated. Incrementing retry count penalizes the cell
  for infrastructure failures.
- **Clear any partial tentative values.** If the piston wrote a tentative yield
  before dying, it should be discarded.
- **Log the recovery.** Insert a trace row: "cell X reset from computing to
  declared, reason: piston timeout."
- **The cell becomes ready again.** Another piston will pick it up on its next
  `cell_eval_step` call.

### 5.4 Program-Level Recovery

If a piston was the only one running a program and it dies, the program is
orphaned. No piston is calling `cell_eval_step` for it. The stale reaper
(Option A) handles the cells, but nobody restarts the piston.

This is where Gas Town's respawn infrastructure applies. The mechanism that
detects a dead piston (heartbeat timeout) should also trigger piston respawn:

```
cell_reap_stale() resets cells
  + detects orphaned programs (programs with no active pistons)
  + signals for piston respawn (mail to Witness, or a flag in a table)
```

The Witness or a crew member sees the signal and runs `gt piston start
<program-id>` to spawn a replacement.

---

## Part 6: Dolt Commit Strategy

### 6.1 v2 Says Each Freeze is a Commit

The design says "Each freeze = commit. Time travel via AS OF." This is the same
commit-per-cell strategy I flagged in v1. For a 50-cell program, that is 50
Dolt commits.

However, v2's resolved concerns table says "Batch commits per eval round in
`cell_eval_step`." These two statements contradict each other. The architecture
diagram says freeze = commit. The resolved concerns say batch.

**Clarify this.** The batching strategy matters for performance:

- **Commit per freeze**: 50 commits for 50 cells. Fine granularity for time
  travel. High overhead (50 * 100-200ms = 5-10 seconds).
- **Commit per round**: Evaluate all ready cells in a wave, commit once. Fewer
  commits (typically 5-10 rounds for 50 cells). Less overhead. Coarser time
  travel.
- **Commit per piston cycle**: Each piston commits after its `cell_submit`
  returns. With 3 pistons running concurrently, commits interleave but each
  piston is a single writer for its own cell.

**Recommendation**: Commit per piston cycle is the natural unit. When the piston
calls `cell_submit()`, the procedure freezes the cell and commits. One commit
per cell evaluation. This is fine for programs up to ~100 cells. For larger
programs, the procedure should support a batch mode where multiple cells are
frozen before a single commit.

### 6.2 Concurrent Piston Commits

With multiple pistons, Dolt's global write lock applies within a single
database. If pistons A and B both call `cell_submit()` at the same time, one
blocks on the commit. Since Cell evaluations take seconds to minutes (LLM
thinking time), the probability of simultaneous commits is low. The serialized
commit adds 100-200ms of latency, which is negligible compared to LLM call
time.

This is a non-issue for the expected scale (1-5 pistons). If you ever run 20+
pistons, you will need Dolt branches per piston with periodic merges, but that
is a scaling problem for later.

---

## Part 7: New Concerns in v2

### 7.1 Hard Cells as Views — Schema Explosion Risk

v2 says hard cells become `CREATE VIEW` statements. A 50-cell program with 30
hard cells creates 30 views in the database schema. Five programs create 150
views. The Dolt `INFORMATION_SCHEMA.VIEWS` fills up with cell computation
views alongside any other views the database uses.

**Mitigation**: Namespace the views. `cell_{program}_{cellname}` as the naming
convention. The `cell_` prefix makes them filterable. Or better: create hard
cell views in a program-specific schema if Dolt supports multiple schemas per
database.

**Lifecycle concern**: When a program completes (reaches quiescence and the
user is done with it), who drops the views? The `cell_status` procedure should
include a cleanup mode: `CALL cell_cleanup('sort-proof')` that drops all views
prefixed with `cell_sort_proof_*`.

### 7.2 Stored Procedure Debugging

Stored procedures in Dolt are opaque during execution. If `cell_eval_step()` has
a bug (wrong readiness logic, incorrect state transition, race condition in the
`FOR UPDATE` claim), debugging it requires reading the procedure source and
mentally tracing execution. There is no `EXPLAIN PROCEDURE`, no step-through
debugger, no breakpoints.

Gas Town's existing infrastructure is debuggable: `bd` commands print output,
formulas have step-level logging, polecats have transcripts. Stored procedures
have... the trace table, if someone remembers to INSERT into it.

**Mitigation**: The stored procedures should be written defensively with
extensive trace logging. Every state transition, every claim, every commit
should INSERT a trace row. The `DoltIgnoreTrace` flag keeps this out of version
history. This is the Retort engine's existing pattern and it should carry
forward.

### 7.3 Stored Procedure Versioning

The stored procedures are "stored in Dolt, versionable, inspectable." True.
But updating a stored procedure requires `DROP PROCEDURE` + `CREATE PROCEDURE`.
If a bug is found in `cell_eval_step()` while a program is mid-execution, you
cannot just deploy the fix. The running pistons are mid-loop. They will call
the new procedure on their next iteration. This is usually fine for backward-
compatible changes but dangerous for schema-altering changes.

**Mitigation**: Version the procedures. `cell_eval_step_v1()`,
`cell_eval_step_v2()`. The piston instructions reference a specific version.
Deploying a new version does not break running pistons. New pistons use the
new version. Old pistons finish with the old version.

This is overhead but prevents a class of upgrade disasters.

### 7.4 Dolt Stored Procedure Capabilities

The v2 design assumes Dolt's stored procedure support is sufficient for the
`cell_eval_step` logic, which includes:

- `SELECT ... FOR UPDATE` (row-level locking)
- Conditional branching (`IF ... THEN ... ELSE`)
- Variable assignment and return
- String interpolation for prompt construction
- Transaction control
- Calling `DOLT_COMMIT()` from within a procedure

Dolt's stored procedure support is a subset of MySQL's. Some features that
the procedures might need:

- **Cursors**: If `cell_eval_step` needs to iterate over multiple ready cells
  (for batch operations).
- **Dynamic SQL** (`PREPARE` / `EXECUTE`): If hard cell evaluation involves
  constructing SQL from the cell's body column.
- **Exception handling** (`DECLARE HANDLER`): For graceful error recovery
  inside procedures.
- **JSON functions**: For parsing `value_json` in yields.

**Recommendation**: Before writing the procedures, validate that Dolt supports
the specific MySQL stored procedure features needed. Write a proof-of-concept
`cell_eval_step` and run it against the Dolt sql-server. Discover capability
gaps early, not after the architecture is committed.

### 7.5 The `exec:` Escape Hatch

v2 describes hard cell executors with an `exec:./tools/transform` prefix that
shells out to an external binary. This is a security boundary crossing: the
database server executing arbitrary shell commands.

In Gas Town, tool execution happens in agent sessions (polecat tmux sessions,
Claude Code bash tool). The agent is sandboxed by its session permissions. A
stored procedure calling `exec:` runs with the Dolt server's permissions,
which are typically broader.

**Mitigation options**:

- **Do not implement `exec:` in stored procedures.** Route `exec:` cells to
  pistons, which shell out in their own session. The procedure returns
  `dispatch` with `executor_type = 'exec'` and the piston runs the command.
  This keeps shell execution in agent sessions, not in the database server.

- **If `exec:` must be in procedures**, use an allow-list of permitted
  executables. No arbitrary paths.

### 7.6 Molecule Lifecycle — Still Unresolved

v1 flagged that Cell programs do not terminate and therefore molecules never
squash. v2 does not address this directly. The v2 design does not use beads
molecules for Cell programs (Cell state is in Retort), so the molecule lifecycle
concern is partially sidestepped: there is no Gas Town molecule to squash.

But the question remains in Retort terms: when is a Cell program "done"? The
Retort `programs` table (from schema.go) presumably has program-level state.
Quiescence is the natural endpoint, but as I noted in v1, quiescence is not
termination. A quiescent program can become non-quiescent when new cells are
added.

**Recommendation**: Add explicit program lifecycle states to Retort:

```sql
ALTER TABLE programs ADD COLUMN status
  ENUM('active', 'quiescent', 'completed', 'archived') DEFAULT 'active';
```

- `active`: Pistons should process this program.
- `quiescent`: No ready cells. Pistons skip it. Can become `active` if cells
  are added.
- `completed`: User explicitly marks done. Results are final. Views can be
  retained or dropped.
- `archived`: Cleanup complete. Views dropped. Trace data retained for
  history.

The transition from `quiescent` to `completed` is a user action, not
automatic. This separates "nothing to do right now" from "we are done."

---

## Summary

| v1 Concern | v2 Resolution | Status |
|------------|---------------|--------|
| Formulas are not functions | Stored procedures, not formulas | RESOLVED |
| Keep Retort | Retort schema preserved and extended | RESOLVED |
| Beads namespace pollution | Retort is separate; beads for coordination only | RESOLVED |
| Control flow inversion | Procedure drives, LLM is piston | RESOLVED |
| Polecat dispatch too slow | Inline evaluation by piston | RESOLVED |
| Commit overhead | Batching mentioned but contradicted; needs clarification | OPEN |
| Molecule lifecycle | Partially sidestepped; program lifecycle states needed | OPEN |

| New Concern | Severity | Recommendation |
|-------------|----------|----------------|
| Hard cell views pollute schema | Medium | Namespace views; add cleanup procedure |
| Stored procedure debugging | Medium | Defensive trace logging in all procedures |
| Stored procedure versioning | Medium | Version procedure names; old pistons use old versions |
| Dolt SP feature gaps | High | PoC the procedures against Dolt before committing |
| `exec:` security boundary | High | Route to pistons, not database server |
| Program lifecycle states | Medium | Add status enum to programs table |
| Piston agent type | Medium | Define `gt piston` spawn command |
| Stale computing recovery | High | `cell_reap_stale()` procedure + heartbeat table |
| Model affinity gaps | Low | Add SKIP return for affinity mismatch |
| Commit strategy contradiction | Medium | Clarify: per-freeze or per-round? |

### Overall Assessment

v2 is architecturally sound. The stored procedure approach gives you atomicity,
composability, and debuggability (via Dolt time travel) that neither CLI commands
nor formulas could provide. The piston model cleanly separates deterministic
orchestration (SQL) from semantic work (LLM). The Retort schema provides the
normalized, indexed data model that Cell computation needs.

The highest-priority action items are:

1. **Validate Dolt SP capabilities** with a working `cell_eval_step` prototype.
   This is the make-or-break for the entire architecture. If Dolt's stored
   procedures cannot handle `SELECT ... FOR UPDATE`, conditional branching, and
   `DOLT_COMMIT` in the same procedure, the design needs a fallback.

2. **Define piston death recovery.** The `cell_reap_stale()` procedure is
   straightforward to implement and prevents the single worst failure mode
   (cells stuck in `computing` forever).

3. **Clarify the commit strategy.** The design says two different things. Pick
   one and document it.

4. **Route `exec:` cells through pistons.** Do not let the database server
   shell out.

The path from here is implementation: write the stored procedures, test them
against Dolt, spawn a piston, run a 5-cell program end to end. The design
is ready for that.

--- Kai

# Design: Gas Town Integration — Cell Next Phase

**Author:** shale (polecat)
**Date:** 2026-03-17
**Status:** Design proposal
**Sources:** `prd-review-integration.md`, `prd-review-user-experience.md`,
`cell-zero-bootstrap-design.md`, `full-migration-plan.md`, `bug-fix-analysis.md`,
`pour-as-cell-design.md`, `oracle-system-design.md`, `retort-schema-v2.md`,
`cmd/ct/*.go`, `examples/*.cell`, `piston/system-prompt.md`

---

## Summary

This document designs the integration between Gas Town (multi-agent workspace) and
Cell (structured computation runtime). It covers four dimensions:

1. **Event triggers** — How Gas Town events (escalations, mail, bead state changes) trigger Cell programs
2. **Completion beads** — How Cell program completion feeds back into Gas Town's bead system
3. **Cross-program composition** — How one Cell program's output becomes another program's input
4. **`gt cell` command** — Gas Town's user-facing interface to the Cell runtime

---

## Architecture Principle: Two Databases, One Dolt Server

Gas Town uses Dolt on port 3307 (beads database). Cell/Retort uses Dolt on port
3308 (retort database). Both share a Dolt server but are separate databases.

**The bridge is SQL.** Cell hard cells with `sql:` body type can query any
database the Dolt server exposes. This means a Cell program can read Gas Town
beads directly:

```sql
-- Hard cell reading a bead's status
sql:SELECT status FROM `beads/doltcell`.issues WHERE id = 'do-xyz'
```

This is the integration primitive. No new RPC layer, no event bus — just SQL
across databases on the same server. Dolt's transactional semantics guarantee
consistency.

**Constraint:** Cell programs MUST NOT write to the beads database directly.
Writes flow through `bd` (beads CLI) or `gt` (Gas Town CLI) to maintain audit
trails and Dolt commit discipline. Cell programs read beads state; Gas Town
commands write beads state.

---

## 1. Event Triggers: Gas Town -> Cell

### 1.1 The Trigger Model

Gas Town events that should launch Cell programs:

| Gas Town Event | Trigger Mechanism | Cell Program |
|----------------|-------------------|--------------|
| Escalation (`gt escalate`) | `gt cell pour` in escalation handler | `incident-response.cell` or custom |
| Bead creation with `cell:` label | Witness scan (poll `bd list --label cell:*`) | Program named in label value |
| Mail with `.cell` attachment | Mail handler calls `ct eval` | Attached program |
| Manual request | `gt cell run <program> <file.cell>` | Specified program |

### 1.2 Escalation -> Pour

When `gt escalate` is called with severity HIGH or CRITICAL, Gas Town can
automatically pour an incident-response Cell program:

```
gt escalate -s HIGH "Dolt: server unreachable"
    |
    v
[witness receives escalation bead]
    |
    v
[witness checks: does escalation template exist?]
    |  YES: pour from template
    v
ct pour incident-${bead_id} templates/incident-response.cell
    |
    v
[hard cell `incident` pre-filled with escalation context]
    |
    v
ct piston incident-${bead_id}   # or delegate to a polecat
```

**How context flows into the program:**

The witness (or helix, or a dedicated "cell-dispatcher" agent) generates a
modified `.cell` file with the escalation context injected into hard cells:

```
cell incident
  yield description = "${escalation_description}"
  yield severity = "${escalation_severity}"
  yield bead_id = "${source_bead_id}"
```

This is template substitution at pour time, not a new runtime feature. The
`.cell` file is the contract between Gas Town and Cell.

### 1.3 Trigger Registration

Rather than building an event bus, use a **trigger table** in the beads database:

```sql
CREATE TABLE cell_triggers (
  id VARCHAR(64) PRIMARY KEY,
  event_type ENUM('escalation', 'bead_created', 'bead_status_change', 'mail_received'),
  filter_expr TEXT,          -- e.g., "severity >= HIGH" or "label LIKE 'cell:%'"
  template_path TEXT,        -- path to .cell template file
  var_mapping TEXT,           -- JSON: {"incident.description": "$.description"}
  enabled BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP
);
```

The witness polls this table periodically (or a dedicated trigger-watcher does).
When an event matches a filter, the watcher:

1. Reads the template `.cell` file
2. Substitutes variables from the event payload using `var_mapping`
3. Calls `ct pour <generated-name> <temp-file>` or `ct eval <name> <temp-file>`
4. Records the pour in the trigger's execution log

**Why polling, not push:** Dolt has no native triggers or LISTEN/NOTIFY.
Polling at 5-10s intervals is fine for the event types listed above — none
require sub-second latency. The witness already polls for health checks.

### 1.4 Piston Assignment

Once a Cell program is poured, who evaluates it?

| Strategy | When to Use |
|----------|-------------|
| **Inline piston** | Witness/helix runs `ct piston <prog>` in same session — fast, simple |
| **Sling polecat** | Spawn a dedicated polecat with hook pointing to Cell program — isolated |
| **cell-zero-eval** | Submit via `ct eval` — work queued for cell-zero's perpetual eval-one loop |

For escalations (time-sensitive), use **inline piston** or **sling polecat**.
For routine work (label-triggered), use **cell-zero-eval** (queued, async).

---

## 2. Completion Beads: Cell -> Gas Town

### 2.1 Program Completion Detection

Cell programs complete when all non-stem cells are frozen or bottom. The
`program_lifecycle` view already tracks this:

```sql
SELECT lifecycle FROM program_lifecycle WHERE program_id = ?
-- Returns: active, quiescent (all frozen/bottom), completed, archived
```

Quiescence with `quiescence_type = 'clean'` (all frozen, zero bottom) is
success. `quiescence_type = 'partial'` (some bottom) is partial failure.
`quiescence_type = 'stuck'` (declared cells with no ready cells) is deadlock.

### 2.2 Completion -> Bead Flow

When a Cell program reaches quiescence, the entity that poured it (or a
completion-watcher) creates or updates a bead:

```
[Cell program quiesces]
    |
    v
[completion-watcher detects via program_lifecycle query]
    |
    v
[reads frozen yields — these are the program's output]
    |
    v
[creates completion bead in Gas Town]
    |
    bd create --title "Cell: ${program_name} complete" \
              --type task \
              --notes "$(ct yields ${program_id})" \
              --label "cell:completion"
    |
    v
[if program was triggered by an escalation bead, link them]
    bd dep add ${completion_bead} ${escalation_bead}
    |
    v
[if program produced actionable output, create follow-up beads]
```

### 2.3 Structured Completion Protocol

For programs that follow a convention, the completion bead can be richer.
Define a **completion cell** convention:

```
cell _completion
  given root-cause.confirmed_cause   -- or whatever the final output is
  given remediation.plan
  yield status                       -- "success" | "partial" | "failed"
  yield summary                      -- human-readable summary
  yield action_items                 -- JSON array of follow-up tasks
  ---
  Summarize the program results...
```

The completion-watcher reads `_completion.status`, `_completion.summary`, and
`_completion.action_items` to create structured beads:

```go
// Pseudo-code for completion-watcher
yields := queryYields(db, progID, "_completion")
if yields["status"] == "success" {
    bd.Close(triggerBead, "Cell program completed successfully: " + yields["summary"])
} else {
    bd.Update(triggerBead, "--notes", "Cell partial: " + yields["summary"])
    for _, item := range parseJSON(yields["action_items"]) {
        bd.Create("--title", item.Title, "--type", "task")
    }
}
```

### 2.4 The `claim_log` as Audit Trail

The Cell runtime already records every claim lifecycle event in `claim_log`
(frame_id, piston_id, action: claimed/completed). Combined with the `trace`
table (event_type, detail, created_at), this provides a full audit trail.

The completion bead should link to this audit trail:

```
bd update ${completion_bead} --notes "Trace: SELECT * FROM retort.trace WHERE program_id = '${prog_id}' ORDER BY created_at"
```

This lets any Gas Town agent reconstruct the Cell program's execution history
by querying the retort database.

---

## 3. Cross-Program Composition

### 3.1 The Problem

Cell programs are self-contained DAGs. There is no built-in mechanism for
"program A's output feeds program B's input." The reviews (prd-review-integration
and prd-review-user-experience) both flag this as a gap.

### 3.2 Three Composition Patterns

**Pattern A: Sequential pour with injection (simplest, recommended for v0)**

Program A completes. A completion-watcher reads A's yields, generates a new
`.cell` file for program B with A's outputs as hard cell values, and pours B.

```
Program A (fact-check.cell) completes
    |
    v
Read A's yields: verified_claims = "[...]"
    |
    v
Generate program B input:
    cell source-claims
      yield claims = "${A.verified_claims}"
    cell write-article
      given source-claims.claims
      ...
    |
    v
ct pour write-article /tmp/write-article-gen.cell
```

This is template-based composition. No new runtime feature needed. The
completion-watcher is the composition engine.

**Pros:** Zero runtime changes. Easy to debug (each program is standalone).
Clear provenance (the generated `.cell` file records where inputs came from).

**Cons:** Latency (must wait for A to complete before B starts). No streaming.
Requires a coordinator (completion-watcher or explicit orchestration code).

**Pattern B: Shared yields via SQL hard cells (medium complexity)**

Program B contains hard cells that query program A's yields directly:

```
cell source-claims
  yield claims = sql:SELECT value_text FROM retort.yields WHERE cell_id = 'fact-check-verify' AND field_name = 'verified_claims' AND is_frozen = 1
```

This works because both programs share the same Retort database. Program B
blocks on the `sql:` cell until A's yield is frozen (the query returns no
rows while A is running, so B's cell stays `declared`).

**Pros:** Programs can start concurrently. B's SQL cell naturally blocks
until A's output is available. No coordinator needed.

**Cons:** Tight coupling (B must know A's internal cell/field names). No formal
binding tracking (the dependency is in SQL, not in the `givens` table). If A
is reset or re-poured, B may read stale data.

**For v0, use Pattern B only when programs are designed together and share
an explicit interface contract (documented yield names).**

**Pattern C: cell-zero-eval as universal compositor (future)**

cell-zero-eval's `eval-one` already evaluates cells across all programs. If
a cross-program `given` syntax is added:

```
cell summarize
  given fact-check/verify.verified_claims    -- cross-program reference
  yield summary
```

Then `eval-one` resolves cross-program dependencies the same way it resolves
intra-program dependencies: check if the referenced yield is frozen, and if
so, pass it as a resolved input.

**This requires a parser change** (accept `program/cell.field` in `given`
declarations) and a schema change (`givens.source_program` column). It is
the clean long-term solution but not needed for v0.

### 3.3 Recommended Approach

**v0:** Pattern A (sequential pour with injection). The completion-watcher
already exists as part of the trigger system (Section 1). Adding composition
is just reading yields and generating a new `.cell` template.

**v1:** Pattern B for co-designed program pairs. Document the shared yield
interface in the `.cell` file headers.

**v2:** Pattern C with cross-program `given` syntax. This requires parser
and schema work that should be planned as a separate bead.

---

## 4. The `gt cell` Command

### 4.1 Design Principles

`gt cell` is the Gas Town wrapper around `ct`. It adds:
- **Identity:** Tracks which agent/polecat poured and evaluated
- **Beads integration:** Creates beads for programs, links to triggers
- **Routing:** Uses Gas Town's Dolt infrastructure (port 3308)
- **Conventions:** Enforces naming, labeling, completion protocol

`ct` remains the low-level plumbing. `gt cell` is the porcelain.

### 4.2 Command Surface

```
gt cell pour <name> <file.cell>     Pour a Cell program (creates bead, calls ct pour)
gt cell run <name> <file.cell>      Pour + start piston in one command
gt cell status [<name>]             Program status (wraps ct status + bead info)
gt cell watch [<name>]              Live dashboard (wraps ct watch)
gt cell yields <name>               Show frozen yields
gt cell trigger <event> <template>  Register an event trigger
gt cell triggers                    List registered triggers
```

### 4.3 `gt cell pour`

```bash
gt cell pour incident-resp incident-response.cell
```

1. Validates the `.cell` file (calls `ct lint`)
2. Creates a bead: `bd create --title "Cell: incident-resp" --label "cell:program" --type task`
3. Calls `ct pour incident-resp incident-response.cell`
4. Records the bead ID and program ID mapping
5. If triggered by another bead, links with `bd dep add`

### 4.4 `gt cell run`

```bash
gt cell run incident-resp incident-response.cell
```

Combines pour + piston launch:

1. `gt cell pour incident-resp incident-response.cell`
2. Spawns piston: either inline (`ct piston incident-resp`) or via sling
3. Monitors for completion (polls `program_lifecycle` view)
4. On completion, runs completion protocol (Section 2.2)

### 4.5 `gt cell status`

```bash
gt cell status incident-resp
```

Shows both Cell runtime state and Gas Town bead state:

```
Cell Program: incident-resp
  Status: active (3/7 frozen, 1 computing, 3 declared)
  Piston: piston-a1b2c3d4 (active, 45s since heartbeat)
  Bead: do-abc (in_progress)
  Trigger: escalation do-xyz
  Runtime: 2m 15s
```

### 4.6 `gt cell trigger`

```bash
gt cell trigger escalation templates/incident-response.cell \
  --filter "severity >= HIGH" \
  --var "incident.description=$.description" \
  --var "incident.severity=$.severity"
```

Registers a trigger in the `cell_triggers` table (Section 1.3). The witness
or a dedicated trigger-watcher evaluates these periodically.

---

## 5. Piston Identity and Gas Town Agents

### 5.1 Piston = Agent Session

A Cell piston is a Claude Code session that evaluates soft cells. In Gas Town
terms, this is an agent session (polecat, witness, helix, etc.). The mapping:

| Cell Concept | Gas Town Concept |
|-------------|------------------|
| Piston ID | Agent session ID (`piston-<hex>`) |
| `piston_registry` | Agent health tracking (witness monitors) |
| Piston heartbeat | Agent liveness signal |
| Piston model_hint | Agent capability tier (haiku/sonnet/opus) |

### 5.2 Agent as Piston

A polecat working on a Cell-triggered bead runs `ct piston` as part of its
work. The polecat's session IS the piston. When the polecat calls `gt done`,
the Cell program should already be complete (or the polecat hands off).

For long-running Cell programs (many cells, stem iteration), the polecat may:
1. Run `ct piston` inline until quiescence
2. If session is filling, `gt handoff` with Cell program state
3. Next polecat session picks up via `ct piston` (eval-one finds remaining work)

### 5.3 Multi-Piston Scaling

Multiple polecats can evaluate the same program concurrently. The frame-level
claim mutex (`INSERT IGNORE INTO cell_claims WHERE frame_id = ?`) prevents
double-evaluation. This is already implemented.

For scaling:
- Pour the program once
- Sling N polecats, each running `ct piston <program-id>`
- Cells are claimed and evaluated in parallel
- Dependencies enforce ordering (a cell with unresolved givens stays declared)

---

## 6. Observability and Error Handling

### 6.1 Events as Trace Entries

The `trace` table in Retort records every Cell operation. Gas Town can query
this for observability without adding a new event system:

```sql
-- Recent activity across all programs
SELECT event_type, cell_id, detail, created_at
FROM retort.trace
ORDER BY created_at DESC
LIMIT 50
```

### 6.2 Error -> Escalation Flow

When a Cell program encounters a persistent failure:

1. **Oracle failure (max retries exhausted):** Cell goes to bottom state.
   Trace records `oracle_fail` events. Completion-watcher sees
   `quiescence_type = 'partial'` and creates an escalation bead.

2. **Piston death (heartbeat timeout):** `cell_reap_stale()` releases the
   claim. Another piston can claim the cell. If no pistons are available,
   the program stays `active` with `stuck` quiescence type. Witness detects
   and escalates.

3. **Deadlock (stuck quiescence):** Declared cells exist but no cell is
   ready (circular dependency or missing input). Completion-watcher detects
   `quiescence_type = 'stuck'` and escalates.

### 6.3 Monitoring Queries

```sql
-- Programs that need attention
SELECT program_id, quiescence_type
FROM retort.quiescence_report
WHERE quiescence_type IN ('partial', 'stuck');

-- Stale claims (dead pistons)
SELECT cell_id, piston_id, claimed_at
FROM retort.cell_claims
WHERE heartbeat_at < NOW() - INTERVAL 5 MINUTE;

-- Oracle failure rate
SELECT COUNT(*) as failures
FROM retort.trace
WHERE event_type = 'oracle_fail'
AND created_at > NOW() - INTERVAL 1 HOUR;
```

---

## 7. Schema Versioning and Migration

### 7.1 The Problem (from prd-review-integration Q1)

When the frame migration lands, stored procedure signatures change. Running
pistons that use raw SQL (the piston system-prompt documents `CALL
cell_eval_step(...)`) will break.

### 7.2 Solution: Schema Epoch

Add a `schema_epoch` to the retort database:

```sql
CREATE TABLE retort_meta (
  key_name VARCHAR(64) PRIMARY KEY,
  value_text TEXT
);
INSERT INTO retort_meta VALUES ('schema_epoch', '2');
```

The piston system-prompt includes: "Before starting, check schema epoch:
`SELECT value_text FROM retort_meta WHERE key_name = 'schema_epoch'`.
If epoch != the one you were trained on, call `ct status --schema` to get
updated procedure signatures."

`ct piston` checks schema epoch at startup and prints a warning if the
piston prompt is outdated.

### 7.3 Migration Path

Existing programs poured before the frame migration have yields without
`frame_id`. The `ensureFrameForCell` function in `pour.go` backfills gen-0
frames. This should be extended to run automatically when any `ct` command
touches a program:

```go
// In cmdRun, cmdStatus, cmdPiston — before operating on a program:
ensureAllFrames(db, programID)  // backfill any cells missing frame rows
```

This is a no-op for programs poured after the migration.

---

## 8. Answers to Review Questions

### From prd-review-integration

**Q1 (Schema versioning):** Schema epoch in `retort_meta` table, checked by
piston at startup. See Section 7.

**Q2 (cell-zero-eval self-spawn correctness):** cell-zero-eval's raw SQL
INSERTs should be rewritten to use `ct` commands (option a). The pour-as-cell
design already shows how: the parse cell's output is SQL, but it goes through
`ct pour` for execution, not direct INSERTs. The eval-one cell should use
`ct submit` instead of raw `INSERT INTO yields`. This is a mechanical change
once `ct` commands are available as piston tools.

**Q3 (Oracle atomicity):** For v0, use **async oracles** — frozen frames can
have pending verdicts, and downstream cells check verdict before reading.
This matches the current implementation (judge cells auto-generated, verdict
wired as optional input). The formal model should add `OracleVerdict` as a
new operation type that annotates an existing frozen frame without unfreezing
it. This avoids blocking the computation pipeline while preserving formal
verification.

### From prd-review-user-experience

**Q1 (Editing running programs):** `ct edit <program> <cell>` should unfreeze
a cell and its downstream dependents by creating new frames (gen+1) for the
edited cell and all cells that transitively depend on it. This preserves
append-only semantics (old frames remain frozen) while enabling re-evaluation.
This is a v1 feature — design it after the frame migration lands.

**Q2 (Piston system-prompt evolution):** `ct` becomes the sole interface. The
piston prompt should be versioned (v2 uses `ct next` + `ct submit`, v1 SQL
path deprecated). See Section 7 for epoch-based versioning.

**Q3 (Target audience):** For the next phase, `.cell` files are authored by
developers and agents. The syntax is designed for readability (v2 keywords),
but the error messages and observability tools assume familiarity with Dolt
and SQL. End-user authoring is a v2+ goal after the developer experience
solidifies.

---

## 9. Implementation Sequence

| Phase | What | Depends On |
|-------|------|-----------|
| **v0.1** | `gt cell pour` and `gt cell status` commands | Frame migration complete |
| **v0.2** | Completion-watcher (poll `program_lifecycle`, create beads) | v0.1 |
| **v0.3** | Trigger registration (`gt cell trigger`, `cell_triggers` table) | v0.2 |
| **v0.4** | Escalation -> pour integration (witness handler) | v0.3 |
| **v1.0** | Cross-program composition via SQL hard cells (Pattern B) | v0.2 |
| **v1.1** | `gt cell run` (pour + piston + completion in one command) | v0.4 |
| **v1.2** | Schema epoch and migration tooling | Frame migration |
| **v2.0** | Cross-program `given` syntax (Pattern C) | v1.0, parser work |
| **v2.1** | `ct edit` for cell re-evaluation | Frame migration |

Each phase is independently useful. v0.1-v0.4 gives Gas Town basic Cell
integration. v1.x makes it practical for production workflows. v2.x makes
it ergonomic.

---

## 10. Non-Goals

- **Real-time event streaming.** Dolt doesn't support LISTEN/NOTIFY. Polling
  at 5-10s is sufficient for all current use cases.
- **Cell programs writing to beads.** The one-way flow (Gas Town -> Cell for
  triggers, Cell -> Gas Town for completion beads) avoids bidirectional
  coupling. Cell programs read beads state via SQL; Gas Town commands write it.
- **Custom piston runtimes.** All pistons are Claude Code sessions for now.
  Supporting non-LLM pistons (e.g., Go functions) is a v2+ consideration.
- **Cell program versioning.** Programs are immutable once poured (append-only).
  "Versioning" is just pouring a new program with a new name. Content-addressed
  pour (hash-based) handles deduplication.

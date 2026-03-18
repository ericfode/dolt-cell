# Deltas: Cell Runtime Exploration (do-6b8)

**Author**: obsidion (crew)
**Date**: 2026-03-18
**Context**: First comprehensive stress-test of the cell language runtime — 17+ programs poured and run, 6 bugs filed.

This document captures everything I felt I should have had but didn't. Gaps in docs, tooling, schema, onboarding, and runtime behavior that slowed me down or surprised me.

---

## 1. Schema & Database

### 1.1 No schema versioning or migration tooling
The `retort` database has no version tracking. The `schema/retort-init.sql` defines the canonical schema, but the running Dolt instance can drift silently. I hit this when `yields` was missing `frame_id` on port 3307 — the schema file had it, the DB didn't. There's no `ALTER TABLE IF NOT EXISTS` migration path; you either nuke and recreate or manually discover what's missing.

**Want**: A `ct migrate` or `ct schema-check` command that diffs the running DB against `retort-init.sql` and reports/applies missing columns, indices, and views.

### 1.2 Stored procedures can't be installed via `dolt sql`
DELIMITER is not supported by `dolt sql` CLI. The procedures.sql file says "use a MySQL client or the Go installer" but the Go installer path (`tools/install-procedures.go`) is named `init-retort.go` and lives in `tools/`, not where the comment says. I had to discover this by grepping.

**Want**: The comment in `procedures.sql` should point to the actual file (`tools/init-retort.go`). Or better: `ct init` should install everything (schema + procedures) as a single command.

### 1.3 Retort DB not present on port 3308 after server move
When the Dolt server moved to port 3308, it had no `retort` database — tables were missing entirely. The `ct` binary's `autoInitRetort` function exists but only runs when the DB doesn't exist at all. There's no check for "DB exists but is empty."

**Want**: `ct` should detect an empty retort database (no tables) the same way it detects a missing one.

### 1.4 `dolt_transaction_commit` set to 0 globally on port 3308
The server on 3308 had `@@dolt_transaction_commit = 0` as the global default. This means `CALL DOLT_COMMIT(...)` calls are required after every mutation, but if any code path omits them, changes are invisible to other sessions. The e2e tests on port 3307 also failed for related reasons.

**Want**: Document the expected server configuration. Either the server should run with `dolt_transaction_commit = 1` (auto-commit on every statement) or all code paths need explicit `DOLT_COMMIT` calls.

---

## 2. Connection Pool & Session State

### 2.1 `resetProgram` taints connection pool
`resetProgram()` calls `mustExec(db, "SET @@dolt_transaction_commit = 0")` which sets a session variable on one pooled connection. Subsequent queries from the same `*sql.DB` pool may or may not get that connection. In tests, this caused `cellsToSQL` output to execute on a connection where Dolt autocommit was off, making the pour data invisible.

**Want**: Either `resetProgram` should restore `dolt_transaction_commit` to its previous value when done, or tests should use separate `*sql.DB` pools (which I had to discover by trial and error). Document this pitfall.

### 2.2 No test isolation guidance
The e2e tests use the production Dolt server and the production `retort` database. There's no test database, no transaction rollback wrapper, no cleanup guarantee. Programs from test runs persist and can collide with each other (e.g., SQL cells querying by `c.name = 'analyze'` without a program_id filter will match cells from other programs).

**Want**: Either a test-specific database or a documented convention for test program naming that avoids collisions. The concurrency test needed separate DB pools — this should be documented.

---

## 3. Runtime Bugs (filed as beads)

### 3.1 Stem completion bug (do-92tf)
Programs report COMPLETE when all non-stem cells are frozen, even if stem cells (judges, recur iterations) haven't run. This means:
- Semantic oracles (`check~`) generate judge cells that never execute
- `recur` programs where the seed is hard and all iterations are stems complete immediately
- The `fact-check.cell` example completes with 2/6 cells processed

**Impact**: High. Semantic oracles are effectively decorative — they're parsed and stored but never evaluated. Users get no feedback on whether their oracle assertions hold.

### 3.2 Guard skip poisons downstream (do-71ms)
When `recur until` converges (guard satisfied), remaining iterations are bottomed with "guard skip." But `hasBottomedDependency` doesn't distinguish between failure-bottoms and guard-skip-bottoms. Downstream cells that depend on `reflect[*]` (fan-in from all iterations) see the guard-skipped iterations as poisoned inputs and bottom themselves.

**Impact**: High. The `haiku-refine.cell` program — the flagship example of iterative refinement — can never produce a final `poem` or `evolution` output because they bottom-propagate from skipped iterations.

### 3.3 Guillemet ambiguity (do-6lo7)
When two givens have the same field name (e.g., `argue-for.argument` and `argue-against.argument`), the body template `«argument»` resolves to both values concatenated. The `chain-reason.cell` example shows both FOR and AGAINST arguments in both positions.

**Want**: Either qualify guillemets as `«argue-for.argument»` (cell.field syntax), or error at parse time when a body references an ambiguous field name.

### 3.4 Other bugs
- **do-6r9v**: SQL hard cells with hardcoded `program_id` break when poured under a different name. Need dynamic `@program_id` variable.
- **do-gxd8**: `yield x = ""` stores `_` instead of empty string (parser treats empty prebound as unset).
- **do-pjkp**: `ct run` fails with `@_cl_frame_id` variable not found in stored procedure — Dolt v1.83 variable bug.

---

## 4. Documentation

### 4.1 No project-level CLAUDE.md
The repo has no CLAUDE.md. The parent `~/gt/CLAUDE.md` covers Gas Town infra (Dolt server ops, escalation) but nothing about the cell language, ct commands, testing, or development workflow.

**Want**: A CLAUDE.md covering:
- How to build `ct` (`cd cmd/ct && go build .`)
- How to initialize the retort DB (`go run tools/init-retort.go`)
- Required env var: `RETORT_DSN`
- How to run tests (`RETORT_DSN=... go test ./cmd/ct/ -run TestE2E`)
- Known issues (stem completion, stored procedure bugs)

### 4.2 No README beyond "# dolt-cell"
The README is one line. New contributors have no entry point. The extensive docs in `docs/plans/` and `docs/research/` are valuable but undiscoverable without guidance.

### 4.3 AGENTS.md references nonexistent QUICKSTART.md
`AGENTS.md` mentions `docs/QUICKSTART.md` but it doesn't exist.

### 4.4 No test running instructions
I had to discover:
- Tests need `RETORT_DSN` set
- Tests need a live Dolt server
- Tests need the retort schema initialized
- The `e2e_test.go` tests are flaky depending on server config
- Shell tests exist in `test/` and `poc/` but no guidance on when to use which

---

## 5. Tooling

### 5.1 `bd show` broken
`bd show do-6uf` fails with `column "no_history" could not be found`. The beads schema on the Dolt server is out of date. I had to query the `do` database directly via `dolt sql` to see my bead.

### 5.2 `ct run` vs `ct piston` confusion
`ct run` uses stored procedures (broken on current Dolt). `ct piston` uses Go-native SQL (works). The help text lists both but doesn't indicate which is recommended or which has known issues. I wasted time trying `ct run` before discovering `ct piston` is the working path.

**Want**: Either fix the stored procedures or deprecate `ct run` with a message pointing to `ct piston`.

### 5.3 No `ct lint` for .cell files
I had to pour programs to discover parse errors (e.g., `given config.mode (optional)` vs `given? config.mode`). A dry-run parse command would catch syntax errors without touching the DB.

**Want**: `ct lint <file.cell>` — parse and validate without pouring.

### 5.4 No `ct test` for running programs non-interactively
Testing soft cells requires manual `ct submit` for each yield. For hard-cell-only programs this is fine (piston freezes them inline), but any program with soft cells requires a human in the loop. There's no way to run a program with pre-scripted submissions.

**Want**: `ct test <program> <answers.json>` — pour, run with scripted yield values, verify final state.

---

## 6. DSL / Language

### 6.1 No dynamic `program_id` in SQL cells
SQL hard cells that query `retort` tables need to hardcode the program name in WHERE clauses. This breaks when the same .cell file is poured under different names. There's no `@program_id` session variable or template expansion in SQL bodies.

### 6.2 No `given` syntax for cell-qualified fields
`given analyze.summary` works but there's no way to say `given analyze.summary as analysis_summary` to disambiguate when multiple givens share a field name.

### 6.3 Oracle parsing is opaque
`check X is valid json array` is deterministic, but `check X contains at least 3 bullet points` becomes semantic (spawns a judge). The boundary isn't documented. I had to observe which oracles spawned judges vs. which were checked inline.

**Want**: Document the deterministic oracle patterns (`is not empty`, `is valid json array`, `is a valid JSON array`, `is one of ...`, etc.) so authors know which checks are cheap/inline vs. expensive/LLM-judged.

---

## 7. What Worked Well

For balance — things that were solid:
- **Parser**: Correctly handled all DSL features I threw at it (guillemets, multi-yield, optional givens, recur, oracles, stems, guards)
- **Claim mutex**: The `INSERT IGNORE + UNIQUE(frame_id)` pattern held under concurrent goroutine stress (5 pistons, 3 runs, 0 failures)
- **Bottom propagation**: Cascading failures from SQL errors worked exactly right
- **Special characters**: Quotes, emoji, JSON, guillemets all survived the pour→freeze→resolve round-trip
- **ct piston**: Reliable single-step dispatch, clean output format
- **ct graph/history/frames**: Good observability into program state
- **Pour is additive**: Clear error when re-pouring, requires explicit reset
- **Deterministic oracles**: JSON validation correctly rejected invalid input and allowed retry

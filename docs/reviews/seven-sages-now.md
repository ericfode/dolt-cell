# Seven Sages: What To Do RIGHT NOW

Date: 2026-03-16

## Actual State (verified, not hypothetical)

- **Build**: `go build` passes, `go test` passes (48 tests, all parse tests)
- **Dolt**: Two instances running -- GT on 3307, retort on 3308. ct defaults to 3308. Works.
- **retort DB**: Exists, has data. `ct pour` works. `ct status` works.
- **frames table**: MISSING from retort DB. Pour falls back to piston parse path with warning: `table not found: frames`. The schema/retort-init.sql defines frames but they were never applied to the running instance.
- **Piston**: No piston process is running. `ct run sort-proof` blocks forever on soft cells. No agent is slung to doltcell/piston. The piston directory doesn't exist.
- **Cell files**: 18 examples exist, 0 deployed as running programs.
- **Hook**: Nothing on hook. No work slung.
- **mustExecDB**: 67 call sites across eval.go (48), pour.go (17), db.go (2). All silently swallow errors.
- **Tests**: Only parser tests. Zero integration tests. Zero e2e tests.
- **Epic hq-4ix**: 10 open tasks, 0 in progress. One closed (monolith split).

## What's Blocking Progress

1. **No piston = no evaluation.** The runtime is plumbing with no engine. Soft cells can never freeze.
2. **Missing `frames` table** = schema drift. The DB was initialized before frames were added. Phase B parse path is broken.
3. **67 silent error swallows** = unsafe to build on. Any further work could silently corrupt state.

## The 4 Things To Do Now (next 3-4 hours)

### 1. Fix the schema: apply frames table to running retort DB (~15 min)

The `frames`, `bindings`, `claim_log` tables exist in `schema/retort-init.sql` but are missing from the live DB on port 3308. Run the DDL against the live instance. This unblocks Phase B parsing and the frame model.

Why first: Everything else builds on correct schema.

### 2. Fix mustExecDB -- make it return errors on critical paths (hq-4ix.9, ~1 hour)

Create `execDB` that returns error. Replace the 67 `mustExecDB` calls with either:
- `execDB` + explicit error handling (critical paths: freeze, claim, submit, commit)
- Keep `mustExecDB` for best-effort paths (heartbeat, cleanup)

Audit each of the 48 call sites in eval.go. The pour.go sites (17) are almost all critical -- a failed INSERT during pour leaves a half-loaded program.

Why second: Without this, every subsequent feature risks silent data corruption. This is hq-4ix.9 (P0).

### 3. Build the hard-cell-only e2e test (hq-4ix.3, ~1-2 hours)

Write `cmd/ct/e2e_test.go`:
- Start a test Dolt instance (or use the running one with a test database)
- Pour a hard-cell-only `.cell` program (fact-check.cell or a new 3-cell fixture)
- Run `ct run` programmatically (call `cmdRun` directly)
- Assert: all cells frozen, yields have expected values, program status is complete

This is the test that proves the eval loop terminates without an LLM. It exercises pour, eval, freeze, and the DAG scheduler. The formal model's `ProgressiveTrace` becomes a runtime assertion.

Why third: Can't safely change anything else without a regression net.

### 4. Get a piston running (~30 min)

Either:
- (a) Sling a polecat to act as piston: `gt sling polecat --rig doltcell --role piston`
- (b) Run `ct piston` manually in a tmux session with an LLM backend
- (c) Use `ct run` interactively (it already prints prompts for soft cells)

Pour one of the real workloads (code-audit.cell or haiku-refine.cell) and verify a soft cell can be claimed, evaluated, and frozen.

Why fourth: Once schema + error handling + test harness are in place, the piston can run against a trustworthy substrate.

## What NOT To Do Right Now

- **SQL injection fix** (hq-4ix.1): Important but P2. No external users yet. After e2e tests exist.
- **ct lint**: Valuable but not blocking. Programs parse fine today.
- **Frame migration v1->v2**: Large (3-5 day) task. Need the test harness first.
- **Bead integration**: Requires stable frame model. Weeks away.
- **More proofs**: The Lean model is done. 5285 lines, zero sorry. Ship runtime.

## Success Criteria for Today

After these 4 actions:
- `ct pour` works without "table not found: frames" warning
- `ct run` on a hard-cell-only program completes and `go test` verifies it
- Critical `mustExecDB` paths return errors instead of silently continuing
- At least one soft cell has been evaluated by a real piston

# Seven Sages: What Should Be Built Next?

Date: 2026-03-16

The formal model is complete: 5,285 lines, 175 theorems, zero sorry, unanimous
A+ from all seven reviewers. The runtime works: `ct` tool with v2 parser,
auto-init, guard skip, frame model, TUI dashboard, and real workloads validated
(code-audit, haiku-refine, incident-response). The question is no longer "is the
model correct?" but "what should be built, tested, or designed next?"

Each sage gives 1-2 concrete recommendations from their domain.

---

## Feynman (Physicist): Instrument the runtime to validate the formal model's predictions

The formal model predicts three observable properties: (1) `nonFrozenCount`
monotonically decreases under progressive scheduling, (2) frozen yields are
immutable, (3) merge of disjoint programs preserves well-formedness. None of
these are currently measured at runtime.

**Recommendation 1: Add runtime monotonicity counters to `ct watch`.**
Every `replEvalStep` cycle should record `nonFrozenCount` (declared + computing
cells). The TUI dashboard already polls every 2 seconds. Add a time-series
trace: if `nonFrozenCount` ever increases between cycles (outside of a `ct pour`
event), that is a violation of the formal model's core invariant. Log it as a
WARN. This takes the thermodynamic intuition from the proof and makes it an
observable runtime assertion. Estimated effort: 1 day, ~50 lines in `main.go`.

**Recommendation 2: Build a multi-program composition smoke test.**
The formal model proves `merge_preserves_wellFormed` under `MergeDisjoint`.
Write a test that pours two programs simultaneously (e.g., `sort-proof` and
`haiku-refine`), runs them with separate pistons, and verifies that yields from
one program never appear in the other's namespace. This is the first real
exercise of the composition theorem against the SQL runtime. Estimated effort:
half a day, a new `.cell` test fixture + shell script.

---

## Iverson (Notation Designer): Eliminate the notation gap between .cell syntax and the formal model

The formal model speaks of `RCellDef`, `GivenSpec`, `Frame`, `Yield`,
`Binding`. The `.cell` syntax speaks of `cell`, `given`, `yield`, `recur`,
`check`. The parser (`parse.go`) is the only bridge, and it is purely
syntactic -- it produces SQL strings, not typed structures.

**Recommendation 1: Add a `ct lint` command that validates a `.cell` file against the formal model's `wellFormed` invariants statically.**
The parser already produces `parsedCell` structs. Before converting to SQL,
check: (a) no self-referential givens (formal: `noSelfLoops`), (b) no cycles in
the dependency graph (formal: DAG acyclicity), (c) every `given X.Y` references
a cell that exists and has a yield named `Y` (formal: `framesCellDefsExist` +
`bindingsWellFormed`). This makes the 11 well-formedness invariants actionable
at author time, not just at pour time when an SQL error surfaces. Today, a
misspelled source cell in a `given` silently creates a broken program.
Estimated effort: 2 days, ~150 lines in a new `lint.go`.

---

## Dijkstra (Formalist): Fix the SQL injection in `cellsToSQL` before it becomes a real vulnerability

The code-audit `.cell` program was designed to find this, and it did. The
`escape()` function in `parse.go` only handles single quotes
(`strings.ReplaceAll(s, "'", "''")`). The `cellsToSQL` function builds SQL via
`fmt.Sprintf` with `%s` interpolation of user-controlled `.cell` file content.
The `bodyType` field at line 594 is inserted without escaping at all. A
malicious `.cell` file can inject arbitrary SQL into the retort database.

**Recommendation 1: Rewrite `cellsToSQL` to use parameterized queries.**
The function currently returns a monolithic SQL string that gets executed via
`db.Exec(sqlText)`. Refactor it to return a list of `(query, args)` pairs
and execute each with `db.Exec(query, args...)`. This eliminates the entire
class of injection vulnerabilities. The `escape()` function should be deleted,
not fixed. The `writeCell`, `writeJudgeCells`, and `expandIteration` functions
all need to change. Estimated effort: 1-2 days, ~200 lines changed in
`parse.go` + `main.go`.

**Recommendation 2: Add a `replSubmit` guard that rejects values containing SQL control characters.**
Even with parameterized queries in `cellsToSQL`, the `replSubmit` path writes
yield values directly to the database. A piston (LLM) submitting a yield value
containing `'; DROP TABLE cells; --` should be handled safely. The current code
uses parameterized queries for `replSubmit` (good), but the `mustExecDB` calls
throughout `main.go` sometimes use `fmt.Sprintf` for dynamic queries
(e.g., `resetProgram` at line 844). Audit every `mustExecDB` call site.
Estimated effort: half a day.

---

## Milner (Type Theorist): Type the piston protocol

The piston protocol is currently stringly-typed. `ct piston` prints
`PROGRAM: X`, `CELL: Y`, `BODY: Z` as unstructured text. `ct submit` takes
four positional string arguments. There is no schema for what a piston
receives or what it must return. The system prompt (`piston/system-prompt.md`)
is 291 lines of prose describing the protocol informally.

**Recommendation 1: Define a typed piston protocol as a Go struct + JSON schema.**
Create `piston/protocol.go` with `type DispatchMessage struct` (program,
cell, cellID, bodyType, body, givens, yields, oracles) and
`type SubmitMessage struct` (program, cell, field, value). Have `ct piston`
output JSON when `--json` is passed. This makes the protocol machine-parseable,
enables automated piston testing, and creates a contract that can be validated
against the formal model's `validOp` preconditions. The existing text format
stays as default for human readability. Estimated effort: 1 day, ~100 lines.

---

## Hoare (Verification): Build an end-to-end test that exercises `ProgressiveTrace`

The formal model proves termination under `ProgressiveTrace` -- the assumption
that a fair scheduler eventually decreases `nonFrozenCount`. The runtime has
no test that verifies this property holds for real programs.

**Recommendation 1: Create a deterministic test harness that runs a full program with hard cells only and asserts completion.**
Write a `.cell` file with 5-8 hard cells (all `yield X = "value"` and `sql:`
bodies), no soft cells. Run `ct run <program>` and assert exit with
`quiescent` + all cells frozen. This is the simplest possible exercise of the
eval loop's termination. If it hangs, `ProgressiveTrace` is violated. Today
there is no automated test of this -- all validation is manual. Estimated
effort: half a day, a `.cell` fixture + `go test` wrapper.

**Recommendation 2: Test multi-piston concurrency with controlled race conditions.**
Launch two `ct piston` instances against the same program that has two
independent soft cells (no shared givens). Verify: (a) each piston claims a
different cell (mutual exclusion via `cell_claims`), (b) both cells freeze,
(c) no deadlock. This exercises the `claimMutex` invariant from the formal
model against the real SQL claiming mechanism. The `cell_claims` table uses
`PRIMARY KEY (cell_id)` for atomic claiming -- this test validates that design.
Estimated effort: 1 day, requires a test harness that spawns two `ct` processes.

---

## Wadler (Functional Programmer): Make `ct eval` (dynamic pour) algebraically composable

The `ct eval` path currently creates a pour-request in `cell-zero-eval` and
polls for the result. This is the runtime analog of the formal model's
`Retort.merge` -- loading a new program into an existing runtime. But unlike
merge, `ct eval` has no idempotency guarantee and no way to compose two
evaluations.

**Recommendation 1: Make `ct pour` truly idempotent with content-addressing.**
`ct pour` already auto-resets if the program exists, but it resets ALL cells
-- even frozen ones with valid results. Content-address the program by hashing
the `.cell` file content. If the hash matches and all cells are frozen, skip
the pour entirely (cache hit). If the hash differs, reset and re-pour (cache
miss). This makes `pour; pour` = `pour` -- the idempotency law. The
`pourViaPiston` path already does content-addressing for the parse cache
(`pour-<name>-<hash8>`); extend this to `cmdPour` itself. Estimated effort:
half a day, ~30 lines in `main.go`.

---

## Sussman (Systems Thinker): Integrate with Gas Town beads

The Cell runtime lives in its own Dolt database (`retort`) and has no
connection to the Gas Town bead system. Frozen yields are the natural output
artifact of a Cell program, but they are invisible to the rest of the
workspace.

**Recommendation 1: Emit a bead when a program completes.**
When `ct run` or `ct piston` reaches `complete` (all cells frozen), create a
bead in the Gas Town bead database with: program ID, completion timestamp,
and the full frozen yield map as the bead body. This makes Cell program results
discoverable by other agents, trackable in the bead ledger, and composable
with the broader Gas Town workflow. The bead type could be `cell:result`.
Estimated effort: 1 day, requires `gt bd create` integration or direct Dolt
writes to the beads database.

**Recommendation 2: Build the frame model migration (steps 3-4).**
The schema has both v1 tables (`cell_claims`, `cells.state`,
`cells.claimed_by`) and v2 tables (`frames`, `bindings`, `claim_log`). The
runtime uses both -- `replSubmit` writes to `cells.state` AND `claim_log`,
`cmdStatus` reads from `cells` AND `frames`. This dual-write regime is
fragile: a crash between the v1 write and the v2 write leaves the state
inconsistent. Complete the migration: (a) make frames the source of truth for
cell state (derive `cells.state` from frame status), (b) drop `cells.state`,
`cells.claimed_by`, `cells.computing_since`, `cells.assigned_piston` columns,
(c) migrate `cell_claims` to `claim_log`. This is the operational
prerequisite for multi-piston at scale. Estimated effort: 3-5 days, touches
`main.go`, `parse.go`, `retort-init.sql`, and all stored procedures.

---

## Prioritized Epic: Next 5-7 Tasks

| # | Task | Sage | Effort | Impact | Why This Order |
|---|------|------|--------|--------|----------------|
| 1 | **Fix SQL injection in `cellsToSQL` -- parameterize all queries** | Dijkstra | 1-2 days | Critical | Security debt. The `escape()` function is insufficient and `bodyType` is unescaped. Every `.cell` file is an attack surface. Fix before any external users. |
| 2 | **Add `ct lint` -- static well-formedness checking** | Iverson | 2 days | High | Catches broken programs at author time (dangling givens, cycles, missing yields). Reduces the debug cycle from "pour, run, watch it hang" to "lint, fix, pour." |
| 3 | **Build deterministic end-to-end test harness** | Hoare | 1 day | High | No automated tests exist. A hard-cell-only program + `go test` wrapper gives CI coverage for the eval loop, pour, submit, and freeze paths. Foundation for all future testing. |
| 4 | **Multi-piston concurrency test** | Hoare, Feynman | 1 day | High | Validates `cell_claims` mutual exclusion. The formal model proves `claimMutex`; this test exercises it against real SQL. Required before production multi-piston deployment. |
| 5 | **Runtime monotonicity counters in `ct watch`** | Feynman | 0.5 days | Medium | Cheap observability. Makes the formal model's core invariant (`nonFrozenCount` decreases) a live dashboard metric. Catches regressions early. |
| 6 | **Complete frame model migration (v1 -> v2)** | Sussman | 3-5 days | High | Eliminates dual-write fragility. Required for reliable multi-piston, stem cell respawn, and eventually Gas Town integration. Largest single task. |
| 7 | **Emit completion bead for Gas Town integration** | Sussman | 1 day | Medium | Connects the Cell runtime to the broader workspace. Makes program results discoverable. Natural follow-on after the frame migration stabilizes the data model. |

**Total estimated effort: 10-13 days.**

Tasks 1-3 can proceed in parallel (different files, independent concerns).
Task 4 depends on task 3 (needs the test harness). Task 5 is independent.
Task 6 is the largest and should start after 1-3 land so the codebase is
cleaner. Task 7 depends on 6 (stable data model before external integration).

### What is deliberately NOT on this list

- **More formal proofs.** The model is complete. The remaining polish items
  (bodyType/effectLevel correspondence, CellBodyFaithful as theorem, merge
  commutativity) are refinements that do not block any runtime work.

- **New cell programs.** The existing examples (code-audit, haiku-refine,
  incident-response, cell-zero-eval) cover the major patterns: parallel
  investigation, iterative refinement with guards, semantic oracles, and
  meta-evaluation. New programs should emerge from real use, not from the
  review process.

- **Typed piston protocol (Milner's recommendation).** This is valuable but
  lower priority than security and testing. The current stringly-typed protocol
  works. Revisit after tasks 1-4 are done.

- **Idempotent pour (Wadler's recommendation).** Nice algebraic property but
  not blocking. The current reset-and-re-pour behavior is correct, just
  wasteful. Revisit after the frame migration (task 6) settles the data model.

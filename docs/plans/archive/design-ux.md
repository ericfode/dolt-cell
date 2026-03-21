# Design: UX Dimension — Cell Next Phase

**Author:** mica (polecat)
**Date:** 2026-03-17
**Bead:** do-h5y
**Sources:** `docs/plans/prd-review-user-experience.md`, `docs/plans/prd-review-integration.md`,
`docs/plans/2026-03-14-cell-interaction-loop.md`, `docs/plans/2026-03-16-cell-zero-bootstrap-design.md`,
`docs/plans/2026-03-17-bug-fix-analysis.md`, `docs/plans/2026-03-17-frame-migration.md`,
`cmd/ct/*.go`, `piston/system-prompt.md`, `examples/*.cell`

---

## Scope

Four UX surfaces identified by the review documents as missing or incomplete:

1. **`ct thaw` workflow** — single-cell recovery for bottomed or mis-frozen cells
2. **Error messages with frame IDs** — actionable diagnostics, not raw SQL
3. **`ct help` and first-run guide** — onboarding for new users
4. **Iteration visibility** — convergence display for stem cells with `recur`

---

## 1. `ct thaw`: Single-Cell Recovery

### Problem

The UX review (prd-review-user-experience.md, issue 1) identifies a critical gap:
when a cell freezes with a bad value or bottoms out, the user's only option is
`ct reset`, which destroys the entire program. There is no way to re-evaluate
one cell while preserving sibling cells' frozen values.

The formal model (Retort.lean) proves append-only: frozen yields are immutable.
A direct "unfreeze" violates `yieldsPreserved`. But the frame model provides an
escape: creating a new frame for the same cell (gen N+1) is a legitimate
`createFrame` operation that the formal model already supports.

### Design

```
ct thaw <program-id> <cell-name>
```

`ct thaw` creates a new frame (next generation) for a frozen or bottomed cell,
making it re-evaluable without touching any other cell's state.

**What it does:**

1. Verify the cell exists and is frozen or bottom.
2. Find the latest frame for this cell: `SELECT MAX(generation) FROM frames WHERE ...`.
3. Create frame at gen+1: `INSERT INTO frames (id, cell_name, program_id, generation) ...`.
4. Create fresh yield slots for the new frame (unfrozen, no value).
5. The cell becomes "ready" again (new frame has no frozen yields → declared).
6. Downstream cells that depend on this cell's yields remain frozen — they consumed
   the *previous* frame's yields via bindings. They are not invalidated.
7. Dolt commit: `thaw: <program-id>/<cell-name> → gen N+1`.

**What it does NOT do:**

- Delete or modify existing frames or yields (append-only preserved).
- Invalidate downstream cells (their bindings point to the old frame).
- Touch the formal model — `createFrame` is already a proven operation.

**User workflow:**

```bash
# Cell froze with a bad value:
$ ct status sort-proof
  sort    ■ frozen  soft        sorted = [1, 7, 3, 2, 4, 9]   # wrong!
  report  · blocked soft

$ ct thaw sort-proof sort
  ✓ sort thawed → gen 1 (previous gen 0 preserved)
  sort is now ready for re-evaluation.

$ ct status sort-proof
  sort    ○ declared soft  g1   sorted = —
  report  · blocked  soft       summary = —
```

The piston re-evaluates `sort` on the next `cell_eval_step` call. When it
freezes, `report` becomes ready (its givens now resolve to gen-1's yields
via new bindings).

**Edge case: `ct thaw` on a stem cell.**

Stem cells already auto-respawn. `ct thaw` on a stem cell thaws the *latest*
generation. If the stem is perpetual, this is redundant (it auto-resets).
For non-perpetual stems (iteration), thaw adds a new generation beyond the
expansion limit — the user explicitly asked for another try.

**Edge case: downstream cascade.**

The user may want to also re-evaluate downstream cells that consumed the bad
value. A `--cascade` flag thaws the target cell AND every cell whose bindings
include a yield from the target cell's *current* (frozen) frame:

```bash
ct thaw --cascade sort-proof sort
  ✓ sort thawed → gen 1
  ✓ report thawed → gen 1 (depended on sort.sorted)
```

Without `--cascade`, downstream cells keep their frozen values. The user must
explicitly thaw them if desired. This is the safe default — avoid surprising
invalidation.

**Implementation notes:**

- Builds on the frame migration (do-7i1.5). Cannot implement until `frame_id`
  is the primary key for yields.
- `ct thaw` is NOT in the formal model's 5 operations. It composes
  `createFrame` (proven) with yield slot creation (same as `pour`).
  No new formal operation needed.
- `ct thaw` should warn about the formal boundary:
  `⚠ thaw creates a new frame (append-only). Previous frame preserved in history.`

### CLI output format

```
$ ct thaw sort-proof sort
  ⚠ thaw is outside the formal model's eval loop.
    Previous frame preserved: f-sort-proof-sort-0 (gen 0)

  ✓ sort thawed → gen 1
    New frame: f-sort-proof-sort-1
    Yield slots: sorted (pending)
    Downstream: report (still frozen at gen 0 — use --cascade to also thaw)

  Run a piston to re-evaluate: ct piston sort-proof
```

---

## 2. Error Messages with Frame IDs

### Problem

The integration review (prd-review-integration.md, issue 2) and UX review
(issue 2, 5) identify that error messages expose raw SQL and internal IDs
that users cannot act on. Specific pain points:

- Oracle failure messages say `SELECT value_text FROM yields WHERE cell_id = '...'`
  — the user must write SQL to inspect their own program's output.
- Stem cell iterations show cell names like `reflect-2` but no frame context.
  The user doesn't know which generation failed.
- The truncation hint in yield rendering asks the user to query the database.

### Design Principles

1. **Every error message includes a `ct` command the user can run.** Never expose
   raw SQL as the user's next action.
2. **Frame IDs appear in diagnostics but are never required as user input.** Users
   address cells by `<program>/<cell-name>`, not by frame ID. The frame ID is
   shown parenthetically for debugging.
3. **Yield values are always accessible via `ct yield`.** No SQL required.

### New command: `ct yield`

```
ct yield <program-id> <cell-name>.<field>
ct yield <program-id> <cell-name>             # all fields
ct yield <program-id> <cell-name>.<field>@<gen>  # specific generation
```

Prints the full yield value (no truncation). Replaces every instance of
"query the yields table" in user-facing output.

```bash
$ ct yield sort-proof sort.sorted
[1, 2, 3, 4, 7, 9]

$ ct yield haiku-refine reflect.poem@2
autumn rain descends
on moss between temple stones
a door left ajar
```

### Error message patterns

**Oracle failure (deterministic):**

Before:
```
oracle_fail: 1/2 passed
```

After:
```
  ✗ oracle fail on sort.sorted (frame f-sort-0, gen 0)
    ⊨ sorted is a permutation of items              ✓ pass
    ⊨ sorted is in ascending order                   ✗ FAIL
      [1, 7, 3, 2, 4, 9]: 7 > 3 at index 1

    Attempt 1/3. Revise and resubmit.
    Full value: ct yield sort-proof sort.sorted
```

**Oracle failure (semantic — judge cell):**

```
  ✗ oracle fail on refine-essay.draft (frame f-refine-essay-draft-0)
    check~ "essay addresses all three counterarguments"    ✗ FAIL
      Judge refine-essay-draft-judge-1 says: NO — only 2 of 3 counterarguments
      addressed. Missing: the economic argument from paragraph 2.

    Attempt 2/3. Previous feedback incorporated.
    Judge verdict: ct yield refine-essay refine-essay-draft-judge-1.verdict
```

**Bottom propagation:**

Before:
```
⊥ sort: exhausted 3 attempts
```

After:
```
  ⊥ sort bottomed (frame f-sort-0, gen 0)
    Exhausted 3 attempts. Last failure:
      ⊨ sorted is in ascending order — 9 > 7 at index 4

    Downstream cells blocked by ⊥:
      report (depends on sort.sorted)

    To retry: ct thaw sort-proof sort
    To inspect: ct yield sort-proof sort.sorted
    To continue with ⊥: no action needed (downstream gets ⊥)
```

**Piston dispatch with frame context:**

```
──── step 3: reflect (gen 2, attempt 1/3) ──────────────
  given compose.poem (gen 0) ≡ "autumn rain..."          ✓ resolved
  given reflect.poem (gen 1) ≡ "temple stones..."        ✓ resolved (prev iteration)
  ∴ You are refining a haiku through successive passes...
```

The generation number makes it clear which iteration is running, which input
came from which generation, and how the data flows through the stem cell chain.

### Changes required

| File | Change |
|------|--------|
| `cmd/ct/main.go` | Add `cmdYield` function, add `"yield"` case to main switch |
| `cmd/ct/eval.go` | Update `replSubmit` error returns to include frame ID and cell name |
| `cmd/ct/eval.go` | Update `cmdRun` step output to show generation numbers |
| `cmd/ct/inspect.go` | Update `cmdStatus` to show generation in all contexts |
| `piston/system-prompt.md` | Update narration format to include gen numbers and `ct yield` hints |

---

## 3. `ct help` and First-Run Guide

### Problem

The UX review (issue 2) notes that a user running `ct piston sort-proof` in
one terminal doesn't know they can run `ct watch sort-proof` in another, or
query yields. There is no first-run guide, no `ct help`, and no suggested
workflow.

### Design

**`ct help` (already partially exists as `usage` in main.go)**

The current usage string is functional but doesn't explain workflows. Replace
with a structured help system:

```
ct help                  # Overview + quick start
ct help <command>        # Command-specific help
ct help workflow         # Suggested workflows
ct help syntax           # .cell syntax reference
```

### `ct help` (no args) — Quick Start

```
ct — Cell Tool

Quick start:
  1. Pour a program:     ct pour sort-proof examples/sort-proof.cell
  2. Check status:       ct status sort-proof
  3. Run a piston:       ct piston sort-proof
  4. Watch live:         ct watch sort-proof        (in another terminal)
  5. See results:        ct yields sort-proof

Commands:
  pour <name> <file>     Load a .cell program into the database
  piston [program]       Run the eval loop (claim → think → submit → repeat)
  status <program>       Show cell states and yield previews
  watch [program]        Live dashboard with navigation (j/k/d/?)
  yields <program>       Print all frozen yield values
  yield <prog> <c>.<f>   Print one yield value in full (no truncation)
  graph <program>        Show dependency DAG
  history <program>      Show execution trace and claim log
  frames <program>       Show frame generations (stem cell history)
  thaw <prog> <cell>     Create new frame for re-evaluation
  reset <program>        Destroy all program data (irreversible)
  lint <file.cell>       Check .cell syntax without loading
  help [topic]           This help

Environment:
  RETORT_DSN    Dolt connection (default: root@tcp(127.0.0.1:3308)/retort)

Run 'ct help workflow' for suggested usage patterns.
Run 'ct help syntax' for .cell file format reference.
```

### `ct help workflow` — Suggested Patterns

```
ct help workflow — Common usage patterns

── Single program, single piston ──────────────────────
  Terminal 1:  ct pour haiku examples/haiku.cell
               ct piston haiku
  Terminal 2:  ct watch haiku         # live dashboard

── Iterative refinement ────────────────────────────────
  ct pour haiku-refine examples/haiku-refine.cell
  ct piston haiku-refine
  # Watch convergence: stem cells show gen 0, 1, 2...
  ct frames haiku-refine              # see all generations
  ct yield haiku-refine reflect.poem@0  # first draft
  ct yield haiku-refine reflect.poem@2  # after 2 refinements

── Fix a bad result ────────────────────────────────────
  ct yield sort-proof sort.sorted     # inspect the frozen value
  ct thaw sort-proof sort             # create new frame
  ct piston sort-proof                # re-evaluate

── Parallel research ───────────────────────────────────
  ct pour research examples/parallel-research.cell
  ct piston research                  # evaluates investigate-1, -2, -3
  ct watch research                   # see findings appear
  ct yields research                  # all frozen results

── Multi-piston (parallel evaluation) ──────────────────
  Terminal 1:  ct piston research
  Terminal 2:  ct piston research     # claims different cells
  Terminal 3:  ct watch research      # shows which piston has which cell

── Inspect the DAG ─────────────────────────────────────
  ct graph haiku                      # ASCII + DOT output
  # Pipe DOT to graphviz:
  ct graph haiku 2>/dev/null | grep '//' | sed 's|// *||' | dot -Tpng > dag.png
```

### First-run experience

When `ct` connects to Dolt and the `retort` database doesn't exist, it
auto-creates it (this already works). Add a one-time message after init:

```
✓ retort database initialized on 127.0.0.1:3308

  Welcome to ct! Load your first program:
    ct pour sort-proof examples/sort-proof.cell
    ct piston sort-proof

  Run 'ct help' for more.
```

This message prints once (after auto-init). Subsequent runs are silent.

### `ct help syntax` — .cell Reference

```
ct help syntax — .cell file format

── Cell declaration ────────────────────────────────────
  cell NAME                     Declare a cell
  cell NAME (stem)              Stem cell (permanently soft, auto-respawns)

── Yields ──────────────────────────────────────────────
  yield FIELD                   Output slot (filled by evaluation)
  yield FIELD = VALUE           Hard literal (frozen at pour time)

── Dependencies ────────────────────────────────────────
  given SOURCE.FIELD            Required input from another cell
  given? SOURCE.FIELD           Optional input (may be absent)
  given SOURCE[*].FIELD         Gather all iterations of a stem cell

── Body ────────────────────────────────────────────────
  ---                           Start/end of cell body
  (soft cell body)              Natural language → LLM evaluates
  sql: SELECT ...               Hard cell → SQL evaluates
  literal:_                     Hard cell with pre-frozen yields

── Oracles ─────────────────────────────────────────────
  check TEXT                    Deterministic oracle (auto-classified)
  check~ TEXT                   Semantic oracle (generates judge stem cell)

── Iteration ───────────────────────────────────────────
  recur until GUARD (max N)     Iterate: expand to N chained cells
  recur (max N)                 Iterate without convergence guard

── References in body ──────────────────────────────────
  «field»                       Unqualified (when field name is unique)
  «source.field»                Qualified (when ambiguous)

── Comments ────────────────────────────────────────────
  -- comment text               Line comment (ignored by parser)
```

### Implementation

| File | Change |
|------|--------|
| `cmd/ct/main.go` | Add `cmdHelp(args)` function, route `"help"` in main switch |
| `cmd/ct/main.go` | Update auto-init message to include welcome text |
| `cmd/ct/help.go` | New file: help text constants and `cmdHelp` dispatcher |

The help text lives in Go string constants, not external files. This keeps
`ct` a single binary with no runtime dependencies.

---

## 4. Iteration Visibility (Convergence Display)

### Problem

The UX review (issue 4) identifies that stem cell iteration is opaque. When
`parallel-research.cell` says `recur (max 3)`, the user doesn't know whether
1, 2, or 3 iterations executed, what triggered termination, or how outputs
changed across generations.

The current `ct status` shows a flat list of cells. Stem cell generations are
invisible without `ct frames`. The `ct watch` dashboard shows duplicate cell
names with hash suffixes (#abc123) that obscure the iteration structure.

### Design

#### 4a. `ct status` shows iteration context

For stem cells, group iterations visually:

```
$ ct status haiku-refine
  CELL          STATE    TYPE    GEN  YIELD
  ────          ─────    ────    ───  ─────
  topic         ■ frozen hard         subject: lantern light on snow — a...
  compose       ■ frozen soft         poem: autumn rain descends / on mo...
  reflect       ■ frozen stem    g0   poem: autumn rain descends / on mo...
    ↳ gen 1     ■ frozen stem    g1   poem: temple stones in rain / moss...
    ↳ gen 2     ■ frozen stem    g2   poem: temple stones in rain / moss...  SETTLED
    ↳ gen 3     ⊥ bottom stem    g3   (skipped — guard satisfied at gen 2)
  poem          ■ frozen soft         final: temple stones in rain / mos...
  evolution     ■ frozen soft         timeline: Draft 0: autumn rain des...
```

Key elements:
- Stem cell generations are indented under the cell name with `↳ gen N`.
- The guard result is shown inline: `SETTLED` or `REVISING`.
- Skipped generations (guard satisfied early) show the reason.
- The latest frozen generation's yields are the "current" value for downstream.

#### 4b. `ct watch` shows iteration progress

In the `ct watch` dashboard, stem cells get a special display:

```
  ◈ reflect       computing g2  ⚡ (piston-a1b2c3d4)
    ├ gen 0  ■  poem: "autumn rain descends..."     REVISING
    ├ gen 1  ■  poem: "temple stones in rain..."    REVISING
    └ gen 2  ▶  poem: —                             (evaluating)
    · gen 3     (pending — guard not yet satisfied)
```

The tree view shows the iteration history at a glance. The user can see:
- How many generations have completed.
- What each generation produced (truncated).
- Whether the guard triggered (SETTLED vs REVISING).
- Which generation is currently being evaluated.

This uses the existing `expanded` toggle in `ct watch` — when a stem cell
is expanded (enter key), it shows the generation tree instead of flat yields.

#### 4c. Convergence indicator in program summary

The `ct watch` program header shows convergence progress for programs with
stem cells:

```
━━ ▾ haiku-refine ████████ DONE ━━
   reflect: converged at gen 2 (SETTLED) after 3 attempts
```

Or during evaluation:

```
━━ ▾ haiku-refine ██░░░░░░ 3/7 ⚡1 ━━
   reflect: gen 1/4 (REVISING — not yet converged)
```

#### 4d. `ct convergence` command

For programs with iteration, a dedicated convergence view:

```
$ ct convergence haiku-refine reflect

  reflect: recur until settled = "SETTLED" (max 4)

  gen 0  ■  settled = "REVISING"   poem = "autumn rain descends / on mos..."
  gen 1  ■  settled = "REVISING"   poem = "temple stones in rain / moss ..."
  gen 2  ■  settled = "SETTLED"    poem = "temple stones in rain / moss ..."
  gen 3  ⊥  (skipped — guard satisfied at gen 2)

  Converged at gen 2. Guard field: settled. Guard value: "SETTLED".
  Δ gen 0→1: poem changed (Levenshtein distance: 47)
  Δ gen 1→2: poem unchanged (fixpoint reached)
```

This shows:
- The guard expression and its satisfaction history.
- Each generation's guard field value and primary yield.
- Change deltas between generations (simple string distance).
- Whether a fixpoint was reached (consecutive identical outputs).

For `recur (max N)` without a guard (like `parallel-research.cell`), the
convergence view shows all iterations without a guard column:

```
$ ct convergence parallel-research investigate

  investigate: recur (max 3) — no convergence guard

  gen 0  ■  finding = "Constitutional AI approaches..."
  gen 1  ■  finding = "Mechanistic interpretability..."
  gen 2  ■  finding = "Cooperative AI and multi-agent..."

  All 3 iterations completed. No guard — all ran to completion.
```

### Implementation

| File | Change |
|------|--------|
| `cmd/ct/inspect.go` | Update `cmdStatus` to group stem cell generations |
| `cmd/ct/watch.go` | Update `renderContent` to show generation tree for expanded stem cells |
| `cmd/ct/watch.go` | Add convergence line to program header for stem programs |
| `cmd/ct/main.go` | Add `cmdConvergence` function, route `"convergence"` in switch |
| `cmd/ct/main.go` | Update `usage` string to include `convergence` command |

---

## Cross-Cutting Concerns

### Frame ID in all output

After the frame migration lands, every command that displays cell state should
include the frame ID or generation number. This makes diagnostics actionable
and makes the append-only model visible to users.

| Command | Frame ID display |
|---------|-----------------|
| `ct status` | Generation column (already exists for stems, extend to all) |
| `ct watch` | Generation in expanded cell detail |
| `ct yields` | Generation suffix for stem cells: `reflect.poem@2` |
| `ct history` | Frame ID in claim log entries |
| `ct graph` | Edge labels include generation: `reflect(g0) ──[poem]──→ reflect(g1)` |

### Error hierarchy

All user-facing errors follow a consistent structure:

```
  <icon> <what happened> (<frame context>)
    <detail line 1>
    <detail line 2>

    <actionable next step as a ct command>
```

Icons: `✗` (oracle fail), `⊥` (bottom), `⚠` (warning), `✕` (error).

### Piston prompt integration

The piston system-prompt.md must be updated to match these UX changes:

1. **Narration format** includes generation numbers in step headers.
2. **Oracle failure** output includes `ct yield` and `ct thaw` hints.
3. **Bottom** output includes the `ct thaw` recovery path.
4. **Quiescent** output shows convergence summary for stem programs.

This ensures the user watching the piston terminal gets the same quality
of output as the user running `ct` commands in another terminal.

---

## Implementation Priority

| Priority | Feature | Depends on | Effort |
|----------|---------|-----------|--------|
| P0 | `ct help` + first-run guide | Nothing | Small — string constants |
| P0 | `ct yield` command | Nothing | Small — single query |
| P1 | Error messages with frame IDs | Frame migration (do-7i1.5) | Medium — touches eval.go |
| P1 | `ct status` generation grouping | Frame migration | Medium — inspect.go rewrite |
| P1 | `ct watch` iteration tree | Frame migration | Medium — watch.go rendering |
| P2 | `ct thaw` | Frame migration | Medium — new command + frame creation |
| P2 | `ct convergence` | Frame migration | Small — read-only query |
| P3 | `ct thaw --cascade` | `ct thaw` | Small — walk bindings graph |
| P3 | Piston prompt update | All of the above | Medium — prompt rewrite |

P0 items can be implemented immediately. P1-P2 items require the frame
migration to land first.

---

## Relationship to Other Beads

- **do-7i1.5** (frame migration): All P1+ features depend on frame_id being
  the primary key for yields. `ct thaw` specifically composes `createFrame`.
- **do-qxt** (derived state): `ct thaw` needs derived state to work correctly —
  the thawed cell should show as "declared" based on its yields, not a mutable
  state column.
- **do-rdu** (piston system prompt): The piston prompt must be updated to match
  the new narration format. This is P3 — do it after the commands stabilize.
- **do-acn** (ct command updates): The `ct yield` and `ct convergence` commands
  are new additions to the command surface designed here.

---

## Open Questions

1. **Should `ct thaw --cascade` invalidate bindings?** Currently, downstream
   cells' bindings point to the old producer frame. After thaw, the new frame
   has no yields yet. The downstream cells are still "frozen" with old values.
   Should `--cascade` delete the downstream bindings (violating bindingsPreserved)
   or create new frames that will get new bindings when re-evaluated?
   **Recommendation:** Create new frames (append-only). The old bindings stay.

2. **Should `ct yield` support piping?** For programmatic use, `ct yield` should
   output raw value (no decoration) when stdout is not a TTY. This enables
   `ct yield sort-proof sort.sorted | jq .` for JSON yields.
   **Recommendation:** Yes. Detect `isatty(stdout)`.

3. **Should `ct help syntax` be generated from the parser?** The parser
   (`cmd/ct/parse.go`) is the authoritative definition of .cell syntax. A
   generated help text would stay in sync automatically. But the parser code
   is not structured for documentation generation.
   **Recommendation:** No. Hand-written help is clearer. Keep it in sync manually
   — the syntax changes rarely.

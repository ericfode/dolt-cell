# Moldable Development → Cell Interface Transfer

**Date:** 2026-03-17
**Bead:** do-arv
**Method:** Rule of 5 expansion on [Glamorous Toolkit book](https://book.gtoolkit.com/moldable-development-ejn67l5cdqh83kegi9umt1mdd)

---

## 0. Source Material Summary

**Moldable Development** (Tudor Gîrba / feenk) is a methodology where developers
build custom, context-specific tools for each problem rather than relying on
generic ones. The core insight: developers spend most of their time *figuring
systems out* by reading code — the slowest information-extraction method. Moldable
development treats comprehension as a data problem and builds custom analytical
tools cheaply.

**Key patterns from gtoolkit:**

| Pattern | Description |
|---------|-------------|
| **Moldable Object** | Start from a live instance, not source code. Inspect, explore, extract. |
| **Contextual View** | Every object type has custom visual representations (~12 lines avg). |
| **Contextual Playground** | Evaluate code bound to a live object's context. Immediate feedback. |
| **Moldable Tool** | Tools detect annotations on objects and adapt their UI dynamically. |
| **Example Object** | Methods that return live instances AND validate assertions — test + doc + fixture in one. |
| **Explainable System** | The end goal: a system whose internals are transparent through custom tools. |

**Key stat:** GT has 1,800+ classes with ~3,600 custom view methods, averaging <12
lines each. Creating a custom view is cheap enough to be throwaway.

---

## 1. Core Concept: What Is Moldable Development? How Does It Apply to Cell?

### The gtoolkit Insight

"Custom tools commoditize the process of gathering information about systems."
Instead of one debugger for all objects, every object gets views that surface what
matters for *that* object. Instead of printf debugging, you build a 10-line view
that shows exactly the dimension you care about.

The two roles: **Facilitator** (builds custom tools) and **Stakeholder**
(interprets results through domain lens). In traditional development these are
separate people; in moldable development, the developer oscillates between both.

### Transfer to Cell

Cell programs are *already* moldable in a deep sense: cells are definitions
(immutable), frames are executions (append-only), and the retort database makes
everything queryable. But the tooling doesn't yet exploit this.

**The Cell version of moldable development:**

A cell is a computation with structured inputs (givens), structured outputs
(yields), a body, and provenance (bindings, claims, trace). Every cell is
already richer than a function call — it has *metadata about its own execution*.
This metadata is the raw material for moldable views.

**Concrete recommendation: Cells as Moldable Objects**

Just as every Smalltalk object in gtoolkit has custom views via `<gtView>`
pragmas, every *cell type* should have registered view definitions. The cell
definition itself (body_type, body, givens, oracles) determines which views
make sense:

| Cell characteristic | Natural views |
|---|---|
| Soft cell with `---` body | Prompt template view (highlight «givens»), LLM trace view |
| Hard cell with `sql:` body | SQL explain plan, query result preview, index usage |
| Stem cell (perpetual) | Cycle history, generation timeline, drift analysis |
| Cell with oracles | Oracle pass/fail dashboard, assertion coverage |
| Cell with gather givens `[*]` | Fan-in visualization, value convergence chart |
| Crystallized cell | Before/after comparison, confidence score, soft body fallback |

**This is the single biggest transfer:** Cell already has the data model for
moldable development. What's missing is the *view registration mechanism* —
the equivalent of `<gtView>` pragmas that tell `ct watch` how to render each
cell type differently.

---

## 2. Expand 1: Inspector Pattern → ct status / ct watch / ct graph

### The gtoolkit Inspector

Every object in GT has multiple views accessible as tabs. A `CompiledMethod`
shows source code as default but also bytecode, senders, implementors. Views are
defined as extension methods with `<gtView>` pragmas — the tool *asks the object*
what views it supports.

The inspector uses miller-column navigation: click an item → new pane opens to
the right, preserving the full navigation path. Code evaluation in the inspector
acts as navigation — you can type an expression and its result becomes the next
inspected object.

### Current Cell Tools

- `ct status <program>` — flat table: cell name, state, yield values
- `ct watch <program>` — TUI with cell list, recently enhanced with detail pane
- `ct graph <program>` — text DAG of dependencies
- `ct yields <program>` — frozen values only
- `ct history <program>` — trace log

These are *generic*. Every cell renders the same way regardless of type.

### Recommendations

#### R1: Cell-Type-Aware Rendering in ct watch

When the detail pane opens for a cell, render based on body_type:

**Soft cells:** Show the prompt template with givens highlighted in color. Show
resolved input values inline (like a filled-in form). If the cell has been
evaluated, show the LLM response alongside the structured yields extracted from
it.

**Hard SQL cells:** Syntax-highlight the SQL. Show a mini result preview (the
computed value). If the SQL references other cells' yields, hyperlink them.

**Stem cells:** Show generation counter prominently. Render a mini timeline:
`gen0 → gen1 → gen2 → ...` with each generation's yield values. Highlight
drift (when outputs change between generations).

**Cells with oracles:** Show oracle assertions with pass/fail badges. For
semantic oracles (`check~`), show the judge cell's verdict.

Implementation: a `viewsForCell(cell) []ViewDef` function that returns the
appropriate views based on cell metadata. Each `ViewDef` is a rendering function
+ title string. The detail pane renders them as tabs (like GT's inspector tabs).

```go
type ViewDef struct {
    Title  string
    Render func(cell CellDetail, width int) string
}

func viewsForCell(cell CellDetail) []ViewDef {
    views := []ViewDef{summaryView(cell)}
    switch {
    case cell.BodyType == "soft":
        views = append(views, promptView(cell), traceView(cell))
    case strings.HasPrefix(cell.Body, "sql:"):
        views = append(views, sqlView(cell), resultView(cell))
    }
    if cell.IsStem {
        views = append(views, generationView(cell))
    }
    if len(cell.Oracles) > 0 {
        views = append(views, oracleView(cell))
    }
    return views
}
```

#### R2: Miller-Column Navigation in ct watch

Currently ct watch is a flat list + detail pane. GT's inspector strength is
*drill-down navigation* — clicking a given opens that source cell, clicking a
yield opens its consumers.

Add: when viewing a cell's detail, pressing Enter on a given line navigates to
the source cell. Pressing Enter on a yield line navigates to downstream
consumers. Build a navigation stack (breadcrumb) at the top: `program > cell-A > cell-B`.
Backspace goes back.

This transforms ct watch from a *status board* into a *cell inspector* — you
follow data flow through the program interactively.

#### R3: Evaluation as Navigation (Contextual Playground)

GT's inspector lets you type code and the result becomes the next inspected
object. Cell equivalent: in ct watch's detail pane, press `:` to enter a SQL
query mode. The query runs against the retort database in the context of the
selected cell (auto-joined to the right program_id and cell_id). Results display
inline.

Examples:
```sql
-- While inspecting cell "compose" in program "haiku":
:yields                          -- shortcut: show this cell's yields
:givens                          -- shortcut: show resolved input values
:SELECT * FROM trace WHERE cell_id = ?   -- auto-bound to current cell
:bindings                        -- shortcut: show what this frame read
```

This is the **contextual playground** pattern: the query environment is bound to
the cell you're inspecting, so `self` = the current cell context.

---

## 3. Expand 2: Playground / Snippet Evaluation → Piston Eval Loop

### The gtoolkit Playground

Snippets evaluate in the context of a live object. You type code, it runs against
the object's state, and the result is immediately inspectable. Successful
snippets get extracted into methods. The playground is recursive — each result
has its own playground.

### Cell's Eval Loop

The piston eval loop (`ct piston <program>`) is Cell's "playground." It:
1. Claims a ready cell
2. Reads resolved inputs
3. Evaluates (LLM for soft, SQL for hard)
4. Submits yields
5. Repeats

But it's batch-mode, not interactive. The piston runs until complete/quiescent.

### Recommendations

#### R4: Live Cell Editing with Instant Re-evaluation

The gtoolkit insight: edit code on a live object and see the result update
immediately. Cell equivalent: **edit a cell's body and see yields update in
real-time.**

`ct edit <program> <cell>` opens the cell body in $EDITOR. On save:
1. Update the cell_def body in retort
2. Reset the cell's frame to declared (clear yields, release claim)
3. Auto-evaluate: dispatch the cell to a piston immediately
4. Stream the new yield values to stdout as they freeze

This creates a tight feedback loop: edit prompt → see output → edit again.
For soft cells, this is "prompt engineering with live feedback." For SQL cells,
this is "query development with live data."

The key insight from gtoolkit: **the boundary between editing and running
dissolves.** You don't "write code then test it" — you write code *while*
testing it.

#### R5: REPL as Contextual Playground

`ct repl` already exists conceptually (cell-zero-eval is the universal
evaluator). But a true Cell REPL would be:

```
cell> given topic.subject = "autumn rain"
cell> ---
cell> Write a haiku about «subject»
cell> ---
cell> yield poem
→ evaluating...
→ poem = "Rain taps weathered tiles\nMoss drinks from ancient gutters\nTemple bells ring wet"
cell> check~ poem follows 5-7-5
→ dispatching judge...
→ verdict = "YES"
cell> crystallize sql: SELECT ...
→ testing view against frozen output...
→ match: crystallized
```

Each line builds up a cell definition incrementally. Yields are displayed as
they freeze. The REPL environment *is* a cell — it has givens, yields, a body.
You're building a cell interactively, and when you're happy, you `pour` it into
a program.

This is exactly gtoolkit's playground pattern: prototype → inspect → extract.

---

## 4. Expand 3: Coder (Code-as-Data) → .cell Syntax Queries

### The gtoolkit Coder

Code is structured data in GT. `GtSearchMethodsFilter` lets you query code
semantically — find methods with specific pragmas, specific senders, specific
patterns. Results highlight the matching AST nodes. The coder molds dynamically
to the method being edited (e.g., `<gtExample>` methods get an execute button).

### Cell's .cell Programs

Cell programs are already data — they live in a SQL database (retort). Every
cell, given, yield, oracle is a row. The .cell file format is just a
serialization. But there's no query language *over* cell programs.

### Recommendations

#### R6: Cross-Program Cell Queries

Just as GT queries code across all packages, Cell should support queries across
all programs:

```bash
# Find all cells that depend on a specific cell
ct query "SELECT DISTINCT gs.cell_name, f.program_id
          FROM given_specs gs
          JOIN frames f ON f.cell_name = gs.cell_name
          WHERE gs.source_cell = 'topic'"

# Find all soft cells that have never been crystallized
ct query "SELECT cd.name, cd.program_id FROM cell_defs cd
          WHERE cd.body_type = 'soft'
          AND cd.name NOT IN (SELECT name FROM cell_defs WHERE body_type = 'hard')"

# Find all cells whose oracles have failed
ct query "SELECT DISTINCT c.name FROM cell_defs c
          JOIN trace t ON t.cell_id = c.name
          WHERE t.action = 'oracle_fail'"
```

Since retort IS a SQL database, this is nearly free — just expose `ct query`
as a convenience wrapper with tab-completion for table/column names.

But the deeper point is: **cell programs are queryable by nature.** GT had to
build AST parsing and semantic indexing to make code queryable. Cell gets it
for free because programs are database rows. This is a structural advantage
that should be surfaced prominently in tooling.

#### R7: Cell Definition as Rich Object

In GT, editing a method with `<gtExample>` shows an execute button. Similarly,
when `ct watch` displays a cell definition:

- Soft cells show a "Run" action (dispatch to piston)
- Hard SQL cells show "Explain" (run EXPLAIN on the query)
- Stem cells show "Pause"/"Resume" actions
- Cells with failed oracles show "Retry" action
- Frozen cells show "Reset" action (clear yields, re-evaluate)

These are **contextual actions** — the available operations depend on the cell's
current state and type. The cell definition IS the data that determines which
actions make sense.

#### R8: Program-Level Views

GT's coder shows package-level views (dependency graphs, coverage maps). Cell
equivalent — `ct graph` should offer multiple visualization modes:

- **Data flow** (current): who feeds whom
- **Evaluation order**: topological sort with timing
- **State map**: heatmap of frozen/computing/declared across the program
- **Cost map**: which cells took the most time/tokens (from trace)
- **Crystallization map**: soft vs hard vs crystallized, with candidates highlighted

Each is a different "view" of the same program — the **contextual view** pattern
applied at program granularity.

---

## 5. Expand 4: "Every Object Is Inspectable" → ct watch TUI

### The gtoolkit Philosophy

"Every object is different and should be allowed to look different, too." The
inspector isn't a debugger you open when something breaks — it's the primary
interface for understanding live objects. You *always* have the inspector open.

Views are composable: an object's view can embed views of its components. A
`Collection` view shows items, and clicking an item opens that item's views.
This recursive composition is what makes the inspector feel like "thinking
with objects."

### Current ct watch

ct watch is a status board: cell list at top, detail pane at bottom. It polls
the database and updates. It's useful but it's a *monitoring* tool, not an
*understanding* tool.

### Recommendations

#### R9: Frozen Yields as Expandable, Clickable, Queryable Objects

Currently, frozen yields are displayed as flat text values. But a yield is a
rich object:

- **Value**: the text content
- **Provenance**: which frame produced it, which piston, when, how long it took
- **Consumers**: which downstream cells read this yield (via bindings)
- **History**: previous values from earlier generations (for stem cells)
- **Oracle results**: which oracles validated this value, their verdicts

When a user selects a frozen yield in ct watch, it should be *inspectable* with
the same multi-view pattern as cells:

| Tab | Content |
|-----|---------|
| Value | The yield text, formatted/syntax-highlighted if detectable |
| Provenance | Frame ID, piston ID, timestamp, duration, token cost |
| Consumers | List of downstream cells that read this value |
| History | Timeline of this field's values across generations |
| Oracles | Pass/fail results for each oracle on the parent cell |

This turns yields from "strings in a table" into "first-class inspectable
objects." The yield IS the molecule in the retort solution — make it visible.

#### R10: Live Updating with Diff Highlighting

GT's inspector updates live when the inspected object changes. ct watch already
polls. Enhancement: when a yield freezes, briefly highlight it (flash green).
When a cell transitions from declared → computing, show a spinner. When computing
→ frozen, show the value sliding in.

More importantly: when a *program is re-evaluated* (e.g., after editing a cell),
highlight what changed. Dim values that are the same as before. Emphasize new
or different values. This is the "moldable development" way of understanding
change — you don't read a log, you *see* the difference.

#### R11: ct watch as Default Development Interface

GT's inspector is always open. Analogously, `ct watch` should be the *primary*
interface for Cell development, not a secondary monitoring tool. This means:

- It should support all common operations (pour, reset, edit, submit) via
  keyboard shortcuts, not just viewing
- It should show multiple programs simultaneously (split view or tabs)
- It should integrate with the piston — when a piston is running, show its
  progress inline on the cell it's evaluating

The aspiration: a developer working with Cell programs should have `ct watch`
open at all times, and it should be sufficient for 80% of their workflow without
switching to the terminal.

---

## 6. Expand 5: "Creating Tools Is Part of Development" → Piston Design

### The gtoolkit Philosophy

"Making contextual tools is part of the development process." Building a custom
view isn't overhead — it's how you understand the system. The tools you build
while debugging become permanent features of the system. GT has 3,600+ custom
views because each one was built to answer a specific question and kept because
it remained useful.

Process patterns: **Tooling Buildup** (each investigation leaves behind a new
tool), **Throwaway Analysis Tool** (build, use, discard — but cheaply enough
that it's fine), **Project Diary** (narrative of explorations with embedded live
examples).

### Cell's Piston Design

Pistons evaluate soft cells. They're Claude Code sessions with full tool access.
Currently they're single-purpose: evaluate one cell, submit yields, move on.

### Recommendations

#### R12: Pistons Can Create ct Extensions

Currently `ct` commands are hard-coded in Go. The moldable development insight
says: the tools should be extensible *during development*, not just by the tool
authors.

Concrete proposal: **cell-defined ct commands.** A cell program can define a
stem cell whose body is "given a cell name and program, produce a formatted
report." Pour this as a ct extension:

```
cell ct-explain
  given target_cell.name
  given target_cell.body
  given target_cell.resolved_inputs
  yield explanation
  ---
  Explain what this cell does in plain English, including what
  its inputs mean and what its output will be used for.
  Reference the program structure to provide context.
  ---
```

`ct explain <program> <cell>` dispatches to this cell. The piston evaluates it.
The output is the explanation. This is "creating tools is part of development"
— the Cell system builds its own development tools as Cell programs.

#### R13: Cell Programs as Analysis Tools

GT's **Throwaway Analysis Tool** pattern: build a one-off tool to answer a
question, then discard it. Cell equivalent: pour a throwaway program to analyze
another program.

```
-- analysis.cell: one-off analysis of the haiku program
cell find-bottlenecks
  yield report
  ---
  sql: SELECT c.name, AVG(TIMESTAMPDIFF(SECOND, cl.claimed_at, t.created_at)) as avg_seconds
       FROM cell_defs c
       JOIN trace t ON t.cell_id = c.name AND t.action = 'freeze'
       JOIN claim_log cl ON cl.frame_id = t.frame_id AND cl.action = 'claim'
       WHERE c.program_id = 'haiku'
       GROUP BY c.name ORDER BY avg_seconds DESC
  ---

cell suggest-crystallization
  given find-bottlenecks.report
  yield candidates
  ---
  Given these cell execution times, which cells are good crystallization
  candidates? A good candidate is: deterministic (always same output for
  same input), fast to compute via SQL, and frequently evaluated.
  ---
```

Pour it, run it, read the results, delete it. Cost: minutes. This is how
moldable development scales — each investigation is a tiny program that answers
one question.

#### R14: Piston-Generated Views (Self-Describing Cells)

The most radical transfer: **cells that describe how to render themselves.**

Add an optional `view:` section to cell syntax:

```
cell compose
  given topic.subject
  yield poem
  ---
  Write a haiku about «subject».
  ---
  view: prompt
    highlight: «subject» in green
    format: poetry (line breaks matter)
  view: diff
    compare: compose@gen(n-1).poem → compose@gen(n).poem
```

The view definitions travel WITH the cell. When `ct watch` encounters them, it
knows how to render this cell specially. This is exactly GT's `<gtView>` pattern:
the object carries its own view definitions, and the tool discovers them at
runtime.

But simpler first step: a `ct views` table in retort that maps
`(cell_name, view_name) → view_definition`. Pistons or users can INSERT custom
views for any cell. ct watch reads this table and renders accordingly.

---

## 7. Synthesis: The Cell Moldable Development Manifesto

### What Cell Already Has (Structural Advantages Over GT)

1. **Everything is already in a database.** GT had to build custom indexing to
   make code queryable. Cell programs *are* database rows. Cross-program queries
   are just SQL.

2. **Append-only history for free.** GT uses manual snapshots. Dolt gives every
   state change a commit. Every yield, every binding, every claim is versioned.
   Time-travel inspection is a `SELECT ... AS OF` clause.

3. **Explicit dataflow graph.** GT infers dependencies from message sends. Cell
   declares them as givens. The dependency graph is structural, not inferred.

4. **Oracles as built-in contracts.** GT relies on developer discipline for
   assertions. Cell has oracles wired into the evaluation cycle — they *must*
   pass for a yield to freeze.

5. **Crystallization as formalized optimization.** GT doesn't have a concept of
   "this view method could become a precomputed table." Cell's soft→hard
   transition is a first-class operation with verification.

### What Cell Is Missing (The Transfer Agenda)

| Priority | What | GT Pattern | Cell Implementation |
|----------|------|------------|-------------------|
| **P0** | Cell-type-aware rendering | Contextual View | `viewsForCell()` in ct watch (R1) |
| **P0** | Navigation through data flow | Inspector pager | Miller-column navigation in ct watch (R2) |
| **P1** | Live edit → re-evaluate cycle | Contextual Playground | `ct edit` with auto-re-eval (R4) |
| **P1** | Cross-program queries | Coder filters | `ct query` wrapper (R6) |
| **P1** | Contextual actions per cell state | Contextual Action | State-dependent keyboard shortcuts (R7) |
| **P2** | Yield inspection with provenance | Inspector tabs | Multi-tab yield detail (R9) |
| **P2** | Interactive REPL for cell building | Playground | `ct repl` incremental cell builder (R5) |
| **P2** | SQL playground bound to cell context | Contextual Playground | `:query` mode in ct watch (R3) |
| **P3** | Cell-defined ct extensions | Moldable Tool | Stem cells as ct commands (R12) |
| **P3** | Throwaway analysis programs | Throwaway Analysis Tool | Pour → analyze → discard pattern (R13) |
| **P3** | Self-describing cell views | `<gtView>` pragma | `view:` section in cell syntax (R14) |
| **P3** | Program-level multi-view | Coder package views | Multiple `ct graph` modes (R8) |

### The North Star

GT's aspiration is the **Explainable System** — software whose internals are
transparent through custom tools. Cell's version:

**An Explainable Program is a Cell program where every cell, yield, binding,
and oracle can be inspected, queried, and understood through contextual views
that the program itself helps define.**

The retort database IS the explanation. The tools just need to surface it.

### Implementation Strategy

**Phase 1 (P0 — do now):** Cell-type-aware rendering + navigation in ct watch.
This requires only changes to the Go TUI code. No schema changes. Highest
bang-for-buck: transforms ct watch from a status board into an inspector.

**Phase 2 (P1 — next sprint):** `ct edit` with live re-eval, `ct query`, and
contextual actions. These are new ct subcommands, still pure Go. They establish
the interactive development loop.

**Phase 3 (P2 — following):** Rich yield inspection, REPL, SQL playground. These
require more TUI work and possibly a `ct views` table in retort.

**Phase 4 (P3 — aspirational):** Self-describing cells, cell-defined extensions,
throwaway analysis programs. This is where Cell becomes truly self-moldable —
the system builds its own development tools as Cell programs.

---

## 8. Appendix: Pattern Mapping Reference

| GT Pattern | GT Mechanism | Cell Equivalent | Status |
|---|---|---|---|
| Moldable Object | `<gtView>` pragmas on classes | Cell metadata (body_type, oracles, givens) determines views | **Natural fit** — cell metadata is richer than class metadata |
| Contextual View | Extension methods returning Phlow elements | `viewsForCell()` function in ct watch | **Not yet implemented** |
| Contextual Playground | Code eval bound to `self` | SQL/cell queries bound to selected cell context | **Not yet implemented** |
| Contextual Action | State-dependent menu items | Keyboard shortcuts that change per cell state | **Not yet implemented** |
| Contextual Search | Domain-aware search | `ct query` over retort database | **Partially exists** — retort is queryable, but no convenience wrapper |
| Moldable Tool | Tools adapt via annotations | ct watch adapts via cell metadata | **Not yet implemented** |
| Example Object | Methods returning fixture + assertions | Cell programs that ARE examples (pour → evaluate → verify oracles) | **Natural fit** — every cell program with oracles is an example |
| Composed Narrative | Notebooks combining prose + live objects | Cell programs with documentation cells | **Not yet designed** |
| Explainable System | Transparent internals via custom tools | Retort database + contextual ct watch | **Foundation exists** — tooling needed |
| Throwaway Analysis Tool | One-off tools built during investigation | Throwaway cell programs | **Natural fit** — pour is cheap |
| Project Diary | Notebook documenting investigation | Cell program tracing an investigation | **Not yet designed** |
| Tooling Buildup | Each investigation leaves a new tool | Each investigation leaves a new cell program or ct view | **Philosophy match** — needs cultural adoption |

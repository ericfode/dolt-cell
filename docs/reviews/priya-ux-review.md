# Adversarial Review: Cell REPL Design (UX/Observability)

**Reviewer**: Priya (UX — JetBrains / Observable background)
**Document**: `2026-03-14-cell-repl-design.md`
**Date**: 2026-03-14
**Verdict**: The architecture is sound. The observability design is a sketch on a napkin. You are building a runtime without a user interface. Ship this and nobody can use it.

---

## 1. mol-cell-status Is a Corpse, Not a Patient

The design presents this as the "primary lens":

```
 [■ frozen]  data
    └─ items = [4, 1, 7, 3, 9, 2]

 [▶ eval]    sort  (polecat: alpha, 3.2s elapsed)
    ├─ given: data→items ✓ resolved
    └─ yield: sorted = (pending)
```

This is a **snapshot**. A photograph of a patient on the operating table. It tells you nothing about the surgery in progress.

Cell execution is a *process*. A soft cell dispatched to a polecat takes seconds to minutes. During that time:

- The LLM is streaming tokens. What is it generating? Is it on-track or hallucinating?
- Oracles are spawning, evaluating, passing, failing. In what order? With what results?
- Retries are happening. What failed? What feedback was injected? Is the second attempt better?
- Downstream cells are transitioning from "blocked" to "ready" as upstream freezes land.

A status command that you invoke, read, and re-invoke is a 1990s `top` when you need a 2020s Datadog dashboard. The design has no concept of:

- **Live streaming**: status that updates in place as state changes
- **Event log**: a scrolling feed of what just happened (cell X frozen, oracle Y failed, retry Z dispatched)
- **Transition notifications**: "sort just froze, report is now ready"

**How others solve this**: IntelliJ's debugger does not make you press "show state" after every step. You set it running and watch variables update in the Variables pane. Observable notebooks show a spinner on the cell being evaluated and live-render partial output as it streams in. Even `docker compose up` streams interleaved logs from all services in real time.

**Concrete alternative**: mol-cell-status should have two modes:

1. `mol-cell-status <mol-id>` -- point-in-time snapshot (what the design shows now)
2. `mol-cell-status <mol-id> --watch` -- live mode that holds the terminal and redraws on every state change (bead close, oracle result, polecat dispatch). Use ANSI escape codes for in-place updates. Show a scrolling event log below the DAG.

Without live mode, the user experience of running a Cell program is: invoke mol-cell-run, stare at a blank terminal, then invoke mol-cell-status repeatedly until it says "quiescent." That is not acceptable.

---

## 2. "Present" in REPPL Is a Blank Check

The design document mentions a REPPL concept (Read, Eval, Present, Print, Loop) in its one-sentence summary but never defines what "Present" means. The observability section lists seven requirements:

> The DAG, the frontier, values flowing through yields, oracle pass/fail, crystallization ratio, in-flight cells, Dolt diff history.

These are requirements, not a design. What does the user actually *see* when they type `mol-cell-run` and hit enter?

**Scenario**: I have a 12-cell program. 3 cells are leaf nodes (no deps), 5 are mid-DAG, 2 are collectors with wildcard deps, 1 is a spawner, 1 is an evolution loop. I type run. What happens on my screen?

Option A: Nothing until quiescence, then a summary. Useless.
Option B: A stream of log lines ("evaluating cell X... frozen cell X... evaluating cell Y..."). Noisy, no structure.
Option C: A persistent TUI that shows the DAG filling in, with a log pane below. Requires a TUI framework (ratatui, blessed, etc.).
Option D: The .cell file itself, re-rendered with yield values filling in as cells freeze. The document-is-state principle made visible.

The design does not choose. It cannot defer this choice because the presentation IS the product. A runtime nobody can observe is a runtime nobody will trust.

**My recommendation**: Option D is the right answer (and I will argue this harder in section 5). But Option D has hard sub-problems: how do you render a file that is being modified by an external process? How do you highlight what changed? How do you show in-flight status for cells that have not frozen yet? These are solvable but they need design attention NOW, not after the formulas are built.

---

## 3. The DAG Visualization Breaks at Scale

The ASCII art in mol-cell-status is a tree layout:

```
 [■ frozen]  data
    └─ items = [4, 1, 7, 3, 9, 2]

 [▶ eval]    sort
    └─ yield: sorted = (pending)

 [○ blocked] report
    └─ given: sort→sorted (unresolved)
```

This is not a DAG. This is a flat list with indented metadata. It works for 3 cells. It does not work for:

- **15 cells**: The list is now 60+ lines. You cannot see the shape. What depends on what? Where are the bottlenecks?
- **50 cells**: You are scrolling. The "status" is now a document you have to read, not a view you can glance at.
- **Spawner programs**: A spawner fires 20 times. You now have 20 near-identical cells (task-0 through task-19) cluttering the display. The interesting information -- "17 of 20 are frozen, 3 are in-flight" -- is invisible.
- **Evolution loops**: Each iteration spawns new versions. The display fills with greet'0, greet'1, greet'2... but what you want to know is "the current iteration is 3 of 5, quality score is 6.2, target is 7."

**The fundamental problem**: DAGs are 2D structures. Terminals are 1D (lines of text). Rendering a DAG as a list loses the shape -- which is precisely the information that matters for understanding execution flow.

**How others solve this**:

- **Airflow**: Web UI with a grid view (tasks x runs) and a graph view (DAG with colored nodes). Nobody uses the CLI for observability.
- **Jupyter**: No DAG -- cells are linear. The entire visualization problem is avoided by restricting the computational model.
- **Observable**: Cells can reference each other (DAG), but the display is the notebook itself -- cells are laid out top-to-bottom and reactive updates show live values. The DAG is implicit in the cell ordering.
- **Make**: `make -j --output-sync` shows parallelism via interleaved output, but the "visualization" is just log lines.

**Three options for Cell**:

1. **Table view** (good for spawners and evolution): A table where rows are cells, columns are [status, elapsed, yield-summary, oracle-result]. Compact. Sortable. Filterable. Loses DAG shape but handles scale. Example:

```
 STATUS   CELL              ELAPSED  YIELDS             ORACLES
 ■ frozen data              0.1s     items=[4,1,7,3..]  --
 ■ frozen sort              4.2s     sorted=[1,2,3..]   ✓perm ✓asc
 ▶ eval   report            1.3s     (pending)           --
 ○ block  summary           --       --                  --
 ⊥ bottom alt-sort          --       ⊥                   ✗ 3/3
```

2. **Collapsed DAG** (good for understanding flow): Group cells by depth level. Show counts, not individual cells, for spawned groups.

```
 Depth 0: [■ data]
 Depth 1: [■ sort] [⊥ alt-sort]
 Depth 2: [▶ report]  [○ summary]
 Depth 3: [○ final]

 Spawned group "task-*": 17/20 frozen, 3 in-flight
```

3. **Web UI**: Accept that the terminal is not the right medium for DAG visualization and provide a `mol-cell-status --web` that opens a browser with a force-directed graph layout. This is where you end up eventually. Plan for it now.

I suspect you will need all three, selected by the user's intent (quick check, debugging, presentation). Which brings me to:

---

## 4. One Status Command Cannot Serve Three Users

The design lists one formula: `mol-cell-status`. It must serve:

**The Operator** ("is it done? what's the result?"):
- Wants: progress bar, ETA, final outputs
- Does not want: DAG details, oracle internals, crystallization metrics
- Mental model: "I submitted a job. Is it finished?"

**The Debugger** ("which oracle failed? what was the LLM's output?"):
- Wants: the specific oracle assertion, the tentative output that failed it, the failure message, the retry context that was injected, the output of the retry
- Does not want: cells that worked fine
- Mental model: "Something went wrong. Show me exactly what."

**The Developer** ("what's the crystallization ratio? which cells are soft?"):
- Wants: soft/hard breakdown, cost per cell, polecat utilization, formula invocation counts
- Does not want: individual cell values
- Mental model: "Is the system getting more efficient over time?"

One invocation of mol-cell-status cannot answer all three questions without drowning every user in the other two users' information.

**Concrete proposal**: Three verbosity levels or three sub-commands:

```
mol-cell-status <mol>                   # Operator view: progress + results
mol-cell-status <mol> --detail          # Debugger view: failed cells expanded
mol-cell-status <mol> --meta            # Developer view: crystallization + cost

mol-cell-status <mol> --cell <name>     # Drill into one cell: full history,
                                        #   all retry attempts, oracle details,
                                        #   polecat transcript, Dolt diffs
```

IntelliJ does this with panes: Variables, Watches, Frames, Console, Evaluate Expression. They are all visible but each serves a different need. The status command needs similar layering even if it is CLI-only.

---

## 5. The Design Betrays Document-Is-State

This is the most serious problem.

The v0.2 spec states:

> **Document-is-state**: The program text IS the execution state. Each step changes exactly one `yield` line to include `≡ value`.

The example trace shows this beautifully:

```
State h0:                         State h1 (after eval-one):
⊢ add                            ⊢ add
  given a ≡ 3                      given a ≡ 3
  given b ≡ 5                      given b ≡ 5
  yield sum          <-changed->   yield sum ≡ 8
```

The program text, with yields filled in, IS the output. The .cell file is simultaneously the source code, the execution state, and the result document.

But the REPL design ignores this. It builds a *separate* observability layer (mol-cell-status) that reads bead metadata and renders a *different* view. The status ASCII art looks nothing like the .cell file. The user must learn two representations: the Cell syntax they authored, and the status display that shows execution.

This is a fundamental UX mistake. Observable got this right: the notebook IS the output. You do not open a separate "notebook status" window. The cells themselves show their values, their errors, their loading states. The document is the interface.

**What honoring document-is-state looks like in practice**:

The primary view of a running Cell program should be the .cell file itself, live-updated:

```
⊢ data
  given raw ≡ [4, 1, 7, 3, 9, 2]
  yield items ≡ [4, 1, 7, 3, 9, 2]            -- ■ frozen

⊢ sort
  given data→items ≡ [4, 1, 7, 3, 9, 2]       -- ✓ resolved
  yield sorted ≡ ⏳ (polecat alpha, 3.2s)      -- ▶ evaluating
  ⊨ permutation check ⏳
  ⊨ ascending order ⏳

⊢ report
  given sort→sorted                            -- ○ blocked
  yield summary
  ...
```

The yield lines fill in with `≡ value` as cells freeze -- exactly as the spec describes. In-flight cells show a temporary status marker (`⏳`) that is replaced by the real value when frozen. Oracle lines show ✓/✗ after evaluation.

This is not mol-cell-status rendering a separate view. This is the *document itself* being the view. Dolt tracks the transitions (each freeze is a commit). The user watches their program fill in like a form being completed.

The status formula still exists, but as a *summary* -- "3/7 frozen, 1 in-flight, 0 failed" -- not as the primary lens.

**Implementation concern**: The .cell file on disk should probably not be rewritten live (that creates race conditions with editors and version control). Instead, mol-cell-status should *render* the .cell file with current state overlaid. The bead metadata provides the values; the rendering engine splices them into the original syntax. But the output should LOOK like the .cell file, not like a separate status display.

---

## 6. Error States Are Invisible

The design mentions `mol-cell-bottom` (mark yields as bottom, propagate downstream) but does not show what this looks like to the user.

**Scenario 1: Oracle exhaustion cascade**

Cell `sort` fails all 3 oracle retries. Its yields become ⊥. Downstream:
- `report` depends on `sort→sorted`. `report` is now permanently blocked.
- `summary` depends on `report→text`. `summary` is now permanently blocked.
- `final` depends on `summary→output`. `final` is now permanently blocked.

What does the user see? In the current mol-cell-status design, probably:

```
 [⊥ bottom] sort
 [○ blocked] report
 [○ blocked] summary
 [○ blocked] final
```

This is inadequate. The user cannot tell:
- WHY sort failed (which oracle? what was the tentative output? what feedback was tried?)
- That report/summary/final are blocked BECAUSE of sort (not because of their own missing inputs)
- Whether any of report/summary/final have `⊥?` handlers (and thus might recover)
- What they should DO about it

**What good error UX looks like**: IntelliJ's debugger, when an exception propagates through 5 stack frames, does not show 5 identical "error" markers. It shows the exception at the origin, with a causal chain. The user clicks on the origin and sees the actual error.

**Concrete proposal for bottom propagation display**:

```
 [⊥ FAILED] sort  — oracle "ascending order" failed 3/3 attempts
    ├─ attempt 1: [1,7,3,2,4,9] — ✗ not ascending
    ├─ attempt 2: [1,2,3,4,9,7] — ✗ not ascending (9 > 7)
    └─ attempt 3: [1,2,3,4,7,8] — ✗ not a permutation of input
    └─ ⊥ propagates to: report → summary → final

 [⊥ blocked] report  (blocked by: sort→sorted ≡ ⊥, no ⊥? handler)
 [⊥ blocked] summary (blocked by: report→text ≡ ⊥)
 [⊥ blocked] final   (blocked by: summary→output ≡ ⊥)
```

The origin of failure is visually distinct. The causal chain is explicit. Each blocked cell states *why* it is blocked and *which* upstream ⊥ caused it.

**Scenario 2: Polecat timeout**

A polecat is evaluating `sort` and dies mid-stream (network failure, context window exceeded, cost limit hit). What happens?

The design does not say. Questions:
- Does mol-cell-status show "eval" forever (stale in-flight)?
- Is there a timeout after which the cell is marked ⊥?
- Does the formula engine detect polecat death and update state?
- What does the user see during the period between polecat death and detection?

These are not edge cases. LLM calls fail routinely: rate limits, network errors, context overflows, safety refusals. The happy path of "dispatch, evaluate, oracle, freeze" is maybe 70% of executions. The other 30% is error handling, and the design has nothing for it.

**Scenario 3: Partial progress on long evaluations**

A soft cell is generating a 2000-word document. The polecat is 60 seconds into a 90-second generation. The user checks status. They see:

```
 [▶ eval] write-report  (polecat: beta, 60.0s elapsed)
```

Sixty seconds of work and the user's only feedback is an elapsed timer. No partial output. No streaming preview. No indication of whether the generation is on-track.

Observable shows live output as cells evaluate. Jupyter shows output appearing line by line. Even `curl` shows a progress bar. The Cell REPL shows a wall clock.

This matters especially for expensive LLM calls. If the polecat is hallucinating after 30 seconds, the user wants to know NOW, not after 90 seconds when oracles fail and retry burns another 90 seconds.

---

## 7. Additional Concerns

### 7a. The REPL Loop Itself Is Missing

The design describes formulas (pour, ready, eval, oracle, freeze, status, step, run) but not the interactive loop. What is the REPL?

- Do I type formula names directly? (`> mol-cell-pour myprogram.cell`)
- Is there a higher-level command? (`> run myprogram.cell`)
- Can I pause execution and inspect? (`> pause`, `> step`, `> continue`)
- Can I modify a cell mid-execution and re-evaluate? (Live programming)
- Can I set breakpoints on cells? ("pause before evaluating report")

The formulas are the engine internals. The REPL is the steering wheel. The design gives me a detailed engine schematic and no steering wheel.

### 7b. No Concept of History Navigation

Dolt provides the time dimension ("dolt diff HEAD~1 shows what changed"). But the design provides no formula for navigating history.

- `mol-cell-history <mol-id>` -- show the sequence of eval steps
- `mol-cell-rewind <mol-id> <step>` -- view state at a previous step
- `mol-cell-diff <mol-id> <step1> <step2>` -- show what changed between steps

Without these, Dolt's version history is an implementation detail, not a user feature. The user cannot answer "what happened at step 5?" without dropping down to raw `dolt diff` commands.

### 7c. Yield Value Rendering

When `sorted = [1, 2, 3, 4, 7, 9]`, that fits on one line. When a yield is a 500-word generated document, or a 200-element list, or a multi-level JSON structure, what happens?

- Does mol-cell-status truncate? At what length? With what indicator?
- Can the user expand a yield to see the full value?
- Are large yields summarized? ("500 words, starts with: 'The analysis reveals...'")
- Do different yield types render differently? (lists vs strings vs numbers vs ⊥)

Observable renders rich output: tables for data frames, syntax-highlighted code, inline images. The Cell REPL cannot defer yield rendering -- it is the primary value the user cares about.

### 7d. Multi-Molecule Awareness

The design assumes one molecule in flight. But Cell programs do not terminate. If I pour three programs, I have three molecules executing concurrently. The status command takes a molecule ID, but:

- How do I list active molecules? (`mol-cell-list`?)
- How do I distinguish them? (by name? by pour timestamp?)
- Can I see a dashboard of all molecules? (3 running, 1 quiescent, 1 with failures)

### 7e. The Sound of Silence

When mol-cell-run is executing and everything is going well, what does the user experience? The design implies: silence. The formulas execute. Beads open and close. Dolt commits happen. The user sees nothing until they invoke mol-cell-status.

Silence is terrifying. The user does not know if the system is working, stuck, or crashed. Even a heartbeat -- "tick... tick... tick..." with a cell name on each -- tells the user "I am alive and making progress."

Minimum viable liveness indicator:

```
▶ sort (3.2s) ... ■ sort frozen  ▶ report (0.4s) ... ■ report frozen
```

A single scrolling line that shows what is happening right now. Not a full status display. Just proof of life.

---

## Summary of Recommendations

| # | Issue | Severity | Recommendation |
|---|-------|----------|----------------|
| 1 | Status is snapshot, not live | Critical | Add --watch mode with live redraw and event log |
| 2 | "Present" is undefined | Critical | Define what the user sees during mol-cell-run; choose between TUI, document-view, or log-stream |
| 3 | DAG visualization breaks at scale | High | Provide table view, collapsed-depth view, and plan for web UI |
| 4 | One status for three users | High | Three verbosity levels + single-cell drill-down |
| 5 | Document-is-state is violated | Critical | Primary view should be the .cell file with yields filled in, not a separate status format |
| 6 | Error/failure UX is absent | Critical | Show causal chains for ⊥ propagation, retry history, polecat failure modes |
| 7a | REPL interaction model missing | High | Define the interactive command set (run, pause, step, inspect, modify) |
| 7b | No history navigation | Medium | Add history, rewind, diff formulas |
| 7c | Yield rendering unspecified | Medium | Define truncation, expansion, and type-specific rendering |
| 7d | Multi-molecule support missing | Medium | Add molecule listing and dashboard |
| 7e | No liveness feedback | High | Minimum: streaming progress line during mol-cell-run |

The formula toolkit (section "Runtime Formula Toolkit") is well-designed for the mechanical layer. The bootstrap sequence is credible. But the design treats observability as a formula that renders ASCII art, when it should be treating observability as the entire interaction surface. The formulas are the engine. You have not designed the car.

---

*Priya, 2026-03-14*

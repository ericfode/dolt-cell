# Blackboard Systems and Knowledge Source Triggering

*Research leg for dc-beh — dynamic observe design*
*2026-03-21*

---

## 1. Triggering Mechanisms Comparison

### 1.1 Pattern Match (Declarative)

The dominant paradigm across blackboard systems. A knowledge source (KS)
declares a **precondition** — a predicate over the blackboard state — and
the runtime evaluates it whenever the blackboard changes.

**Hearsay-II** pioneered this model. Each KS has:
- A **trigger condition**: a pattern over blackboard events (e.g., "a new
  hypothesis was posted at the syllable level"). When a blackboard write
  matches, a Knowledge Source Activation Record (KSAR) is created.
- A **precondition**: a richer predicate evaluated on the KSAR. If true,
  the KSAR becomes "invocable" — eligible for scheduling. If false, the
  KSAR remains triggered but not executable.

This two-phase model separates *event detection* (cheap pattern match on
the write event) from *readiness evaluation* (expensive predicate over
full blackboard state). The trigger narrows the search; the precondition
confirms viability.

**Linda's `rd`** is the coordination-language equivalent: a process
declares a template (pattern), and the runtime blocks until a matching
tuple appears. The template IS the trigger condition. Classic Linda has
no precondition phase — matching is all-or-nothing.

**JavaSpaces `notify`** extends Linda's `rd` with non-blocking event
registration. Instead of blocking, a client registers a template and
receives asynchronous event callbacks when matching entries are written.
This is declarative triggering with push semantics — the space notifies
the client rather than the client polling.

**Cell's `given`** is purely declarative: `given source.field` declares a
static dependency. The runtime resolves it by reading frozen yields. This
is Linda `rd` with static templates — the "pattern" is fixed at pour time.

### 1.2 Callback (Imperative)

The KS registers a function to be called when specific events occur.
The runtime maintains an observer list per event type.

**BB1** added a control blackboard alongside the domain blackboard.
Control KSs monitor domain KS activity and can dynamically change
scheduling strategy. The triggering is still pattern-based, but the
control plane adds imperative hooks: meta-level KSs that fire in response
to control events (e.g., "strategy changed", "KS failed").

**Modern agent frameworks** (LangGraph, AutoGen, CrewAI) use callback-style
orchestration: the coordinator explicitly invokes agents. Some wrap this in
a blackboard metaphor where agents define a `should_activate(blackboard)`
method — technically a callback that the scheduler polls, not a true
declarative trigger.

**Reactive tuple spaces** (MARS, TuCSoN, LuaTS) add programmable
reactions to tuple spaces: when a tuple matching a pattern is written,
a registered reaction function executes. This is callback-on-pattern —
a hybrid of declarative triggering and imperative execution.

### 1.3 Polling

The KS periodically checks the blackboard for relevant changes.

**No serious blackboard system uses polling as the primary mechanism.**
It wastes resources and introduces latency. However, polling appears as
a fallback in distributed systems where event propagation is unreliable
(e.g., LIME for mobile environments, where connectivity is intermittent).

Linda's non-blocking variants (`rdp`, `inp`) enable polling: try to read,
return immediately with success/failure. The caller loops. This is
explicitly discouraged in favor of blocking `rd`/`in` for coordination.

**Cell's current piston loop** is effectively polling: the evaluator
scans for ready cells (all givens frozen) in each cycle. There is no
event-driven notification when a yield freezes — the piston discovers
readiness by checking.

### 1.4 Summary Table

| Mechanism | Trigger spec | Activation | Latency | Example |
|-----------|-------------|------------|---------|---------|
| Pattern match (blocking) | Template/predicate | Blocks until match | Zero (after write) | Linda `rd`, cell `given` |
| Pattern match (event) | Template + callback | Async notification | Near-zero | JavaSpaces `notify`, reactive tuple spaces |
| Two-phase (trigger + precondition) | Event pattern + state predicate | KSAR creation + scheduling | Low | Hearsay-II |
| Callback | Registered function | Direct invocation | Zero | BB1 control KSs, agent frameworks |
| Polling | Loop + check | Caller-driven | High (up to poll interval) | Linda `rdp` loop, cell piston scan |

---

## 2. Control Flow Models

### 2.1 Hearsay-II: Opportunistic, Data-Driven

Blackboard changes generate events. Events trigger KSARs. A scheduler
selects the highest-priority invocable KSAR using a **focus of attention**
heuristic. Control is fully opportunistic — no predetermined execution
order. The data drives the computation.

Key insight: **the scheduler is separate from the KSs.** KSs declare
what they need; the scheduler decides when to run them. This separation
enables changing scheduling strategy without modifying KS logic.

### 2.2 BB1: Meta-Level Control

BB1 applies the blackboard model to its own control. Two blackboards:
- **Domain blackboard**: problem state (same as Hearsay-II)
- **Control blackboard**: scheduling state, strategy, control plans

Control KSs reason about which domain KS to run next. The scheduler is
a simple dispatcher with no built-in intelligence — all scheduling
decisions are made by control KSs writing to the control blackboard.

Key insight: **control is itself a blackboard problem.** If you need
dynamic scheduling, you can solve it with the same pattern-match-and-
trigger mechanism used for domain problems.

### 2.3 Event-Driven Blackboard (US5506999)

The patented system uses a three-stage pipeline:
1. KS writes results to the global database
2. A trigger module compares writes against TRIGGER.DEFS patterns
3. Matching triggers invoke the scheduler, which activates dependent KSs

The trigger module uses tree-pruning search: filter by function level,
then structure, attribute, value. This makes pattern matching efficient
even with many trigger definitions.

Key insight: **trigger evaluation is a separate subsystem** optimized
for fast pattern matching, not embedded in KS logic.

### 2.4 Linda / Tuple Space: Implicit Control

In pure Linda, there is no scheduler. Processes block on `rd`/`in`
until matching tuples appear. Control flow emerges from data availability.
The execution order is determined by which tuples are written first.

This is the simplest control model and maps directly to cell's current
"find ready cell, evaluate it" loop. The piston IS the Linda process,
and `given` IS `rd`.

---

## 3. Applicability to Cell's Given/Observe

### 3.1 What Cell Has Today

Cell's `given source.field` is a **static, blocking, declarative trigger**.
It maps to Linda's `rd(template)`:
- The template is fixed at pour time (`source.field`)
- The cell blocks (is not ready) until the source yield is frozen
- The runtime discovers readiness by scanning (polling for frozen yields)

This is clean and simple. The DAG of givens IS the dependency graph.
Topological evaluation order falls out naturally. No scheduler needed
beyond "find the next ready cell."

### 3.2 What Dynamic Observe Needs

From the metacircular-foundation-analysis, dynamic observe means:
"read from a dynamically-determined source." A cell doesn't know at
pour time which source it will read — the source is computed at runtime.

**This breaks the static DAG.** If cell A's input depends on a value
computed by cell B, which determines which cell C to read from, the
dependency graph has a runtime-determined edge. Topological sort can't
handle this without knowing the edge at pour time.

### 3.3 How Blackboard Systems Handle This

In a blackboard system, this isn't a problem at all. KSs don't declare
static dependencies — they declare **pattern predicates** over the
blackboard state. A KS might say "activate me when any hypothesis at
the word level has confidence > 0.8." The "source" is determined by
what's on the blackboard, not by a fixed pointer.

This is more powerful than cell's `given` but less analyzable:
- No static dependency graph → no topological sort → need a scheduler
- Preconditions can be arbitrarily complex → activation is harder to predict
- Multiple KSs may fire simultaneously → need conflict resolution

### 3.4 The Spectrum of Options

From most static to most dynamic:

1. **Static given** (current): `given source.field` — fixed at pour time
2. **Parameterized given**: `given «computed_source».field` — source name
   is a yield from another cell, resolved at evaluation time
3. **Template match**: `given *.field where tag = "X"` — pattern over the
   yield space, like Linda `rd` with a richer template
4. **Predicate trigger**: `observe when f(blackboard)` — arbitrary
   function over the yield space, like a blackboard KS precondition
5. **Registered callback**: runtime calls a function when a pattern matches,
   like JavaSpaces `notify`

Cell needs (2) for metacircularity (to observe the output of an autopoured
program). It might want (3) for gather patterns. It should NOT need (4)
or (5) — those add complexity without clear benefit for cell's use cases.

---

## 4. Concrete Recommendation for Cell's Dynamic Observe

### 4.1 The Design: Parameterized Given with Late Binding

Add a single new primitive: **late-bound given**, where the source cell
name is itself a yield from a dependency.

Syntax:
```
cell collector
  given spawner.target_name       -- static: read target_name from spawner
  given «target_name».result      -- dynamic: use the VALUE of target_name as source
  yield collected
```

Semantics:
1. Resolve all static givens first (normal topological order)
2. For late-bound givens, substitute the resolved value into the source name
3. Block until the dynamically-determined source yield is frozen
4. Continue evaluation

This is equivalent to **two-phase rd**: first `rd(spawner, target_name)`
to get the source identity, then `rd(target_name, result)` to get the
actual data. Both are standard Linda `rd` operations — no new primitives
needed at the tuple space level.

### 4.2 Why This Is Sufficient

**For metacircularity**: autopour yields a program. The program has cells.
The collector needs to read those cells' yields. With late-bound given,
the collector reads the program's cell names from the autopour yield,
then reads the actual outputs. Two `rd` calls, fully within Linda semantics.

**For gather patterns**: `given source[*].field` already handles
"read all iterations." Late-bound given handles "read from a computed
source." These compose: `given «computed»[*].field` reads all iterations
of a dynamically-determined source.

**For the blackboard use case**: a cell that needs to react to "any
hypothesis with property X" can be restructured as:
1. A scanner cell that finds matching hypotheses (static givens on the
   search space)
2. A processor cell with late-bound given on the scanner's output

This decomposition is less concise than a blackboard predicate but
preserves cell's DAG analyzability.

### 4.3 Why Not Full Blackboard Predicates

Full predicate-based triggering (option 4 from §3.4) would give cell
the power of Hearsay-II. But it would also give cell Hearsay-II's problems:
- **No static analysis**: can't determine dependencies at pour time
- **Need a scheduler**: can't use topological sort; need focus-of-attention
  heuristics
- **Non-determinism**: multiple cells may become ready simultaneously with
  no clear ordering
- **Complexity**: precondition evaluation becomes a performance concern

Cell's strength is its simplicity: DAG of givens → topological order →
deterministic evaluation. Late-bound given preserves this property for
the static portion of the graph while allowing runtime edges where needed.

### 4.4 Implementation in the Formal Model

Late-bound given requires one addition to the formal model:

```
-- In CellDef, distinguish static vs late-bound inputs
inductive InputSpec where
  | static : CellName → FieldName → InputSpec
  | lateBound : CellName → FieldName → FieldName → InputSpec
  -- lateBound src field target_field:
  -- resolve src.field to get a CellName, then read that cell's target_field
```

The evaluation semantics become:
1. Build the static dependency DAG (only static InputSpecs)
2. Evaluate in topological order
3. When encountering a lateBound input, resolve the indirection and block
   if the target isn't frozen yet
4. If the target IS frozen, proceed; if not, defer this cell

The deferred cell creates a potential for deadlock if the dynamic target
depends (directly or indirectly) on the deferred cell. This must be
detected at runtime — a cycle in the dynamic dependency graph means the
program is ill-formed (bottom).

### 4.5 Relationship to Linda's Blocking `rd`

Linda's `rd` blocks until a matching tuple exists. Cell's `given` is `rd`
with a static template. Late-bound given is `rd` with a **computed
template** — the template itself is the result of a prior `rd`.

This is well-studied in Linda extensions:
- **JavaSpaces**: `notify(template)` where the template is constructed
  at runtime from prior reads
- **LIME**: dynamic tuple space sharing where the available spaces change
  at runtime
- **TuCSoN**: programmable tuple centres where reactions can compute
  new templates

All of these handle computed templates without abandoning Linda's core
semantics. Cell can do the same.

### 4.6 What This Means for the Notification Question

The assignment's key question: "How does a knowledge source say 'wake me
when pattern X appears'?"

In blackboard systems: **declaratively, via preconditions.** The KS
declares a pattern. The runtime matches it against blackboard changes.
This is push-based notification (the runtime tells the KS) rather than
pull-based (the KS checks).

In Linda: **via blocking `rd`.** The process declares a template and
blocks. When a matching tuple appears, the process unblocks. This is
also push-based (the runtime unblocks the process) but implicit — the
process doesn't register a callback; it just waits.

In cell: **via `given`.** The cell declares a static dependency. The
runtime doesn't evaluate the cell until the dependency is frozen. This
is pull-based (the piston checks readiness) but could be made push-based
by adding an event index:

```
-- When yield Y of cell C freezes:
--   For each cell D with given C.Y:
--     Decrement D's "unresolved givens" counter
--     If counter = 0: D is ready (push to ready queue)
```

This is an optimization, not a semantic change. The cell still declares
`given C.Y`; the runtime just uses an event-driven index instead of
scanning. This would eliminate the polling overhead of the current piston
loop without changing the programming model.

**Recommendation**: implement the event-driven readiness index as an
optimization of the existing `given` model, AND add late-bound given
for dynamic observe. These are orthogonal changes that compose cleanly.

---

## 5. Summary of Findings

| Blackboard concept | Cell equivalent | Gap | Recommendation |
|--------------------|----------------|-----|----------------|
| KS precondition | `given` | Static only | Add late-bound given |
| KSAR (activation record) | Piston ready-check | Polling-based | Event-driven index |
| Focus of attention | Topological order | No dynamic priority | Not needed (DAG suffices) |
| Control blackboard (BB1) | None | No meta-level control | Not needed for v1 |
| `notify` (JavaSpaces) | None | No async notification | Event-driven index covers this |
| Reactive tuple space | None | No programmable reactions | Decompose into cell pairs |
| Blocking `rd` | `given` | Identical semantics | Already have this |
| Computed template | None | Templates are static | Late-bound given |

**The key insight**: cell already has the core blackboard mechanism (declare
what you need, the runtime provides it). The gap is narrow — computed
templates for dynamic observe, and an event-driven index for efficiency.
Cell does NOT need full blackboard-style predicate triggers, control
blackboards, or reactive tuple spaces. These add power cell doesn't need
at the cost of analyzability cell can't afford to lose.

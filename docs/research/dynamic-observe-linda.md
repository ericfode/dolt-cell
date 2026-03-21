# Dynamic Observe: Linda Blocking `rd` and Tuple Space Notification

Research leg for dc-2vt (Dynamic observe primitive).

> **Note (2026-03-21):** This research predates the Zygo S-expression
> substrate (dc-jo2). Code examples use the old cell syntax. The
> analysis and conclusions remain valid — only the surface syntax has
> changed. See `docs/plans/2026-03-21-zygo-substrate-design.md` for
> the current syntax.

## The Problem

A parent cell pours a child via `[autopour]`. The child evaluates and produces
yields. The parent needs those yields. Currently, cell's `given` is static:
declared at pour time against known cell names. When the child doesn't exist
until autopour runs, there's no name to reference.

**Question:** What's the minimal extension to Linda's blocking `rd` for
observing tuples created by a dynamically-spawned producer?

---

## 1. Mechanism Comparison

| Mechanism | System | Blocking? | Pattern | Delivery | Lifetime |
|-----------|--------|-----------|---------|----------|----------|
| `rd(template)` | Linda (1985) | Yes, suspends caller | Structural field match | Synchronous return | Until match found |
| `in(template)` | Linda (1985) | Yes, destructive | Structural field match | Synchronous return + removal | Until match found |
| `notify(template, listener)` | JavaSpaces | No, async callback | Template with null wildcards | `RemoteEvent` to listener | Lease-based TTL |
| `eventRegister(template)` | TSpaces (IBM) | No, async callback | SQL-like query | Notification on write/take | Connection-scoped |
| Notify Container | GigaSpaces | No, async callback | Template object | Concurrent listener invocation | Registration lifetime |
| Polling Container | GigaSpaces | Yes (take-loop) | Template object | Sequential take + callback | While container runs |
| `watch` (EventBus) | Cell runtime | No, cursor-based | Seq > cursor + filter | List of events | Caller-driven poll |

### Key Distinctions

**Blocking `rd`** (original Linda): The caller suspends until a matching tuple
exists. Simple, elegant, but requires a thread per waiting observer. In a
language with thousands of cells, this means thousands of suspended threads —
the "polling inefficiency" that Carvalho (2026) identifies in modern AI
orchestration systems.

**Async notify** (JavaSpaces, TSpaces, GigaSpaces): The caller registers a
template and a callback. The space invokes the callback when a matching tuple
is written. No blocked thread. But introduces:
- Callback ordering and concurrency concerns
- Lease management (how long does the registration last?)
- Missed-event windows (what if the tuple was written before registration?)

**Cursor-based watch** (Cell's EventBus): The caller provides a sequence
cursor and a filter. Returns events with seq > cursor matching the filter.
No registration, no callback — the caller polls. Simple but wastes tokens
on empty polls.

---

## 2. How Each Maps to Cell's `given`

### Linda's blocking `rd` → cell's `given` (current model)

Cell's `given` is almost exactly Linda's blocking `rd`:

```
given eval-one → status    ≈    rd("eval-one", "status", ?value)
```

The `given` declares: "I need the `status` yield from `eval-one`." The
runtime blocks the cell (keeps it in `declared` state) until `eval-one`
has a frozen frame with a `status` yield. Then the cell becomes `ready`
and a piston can claim it.

**What works:** Static names. If `eval-one` exists at pour time, the
`given` can name it. The runtime's `givenSatisfiable` check is exactly
Linda's template matching against the tuple space.

**What breaks:** Dynamic names. If the child is autopoured, its name
isn't known at the parent's pour time. The parent can't write
`given ??? → status` because `???` isn't a valid cell name.

### JavaSpaces `notify` → a possible `observe` primitive

JavaSpaces' `notify(template, listener)` suggests a model where:

```
observe [autopour my-child] → status
```

means: "When any cell matching the pattern `my-child*` produces a `status`
yield, wake me up." The template uses wildcards (null fields in JavaSpaces)
to match cells that don't yet exist.

**Advantages:**
- No polling — the runtime triggers on write
- Template matching is already semantic in cell (givens match by cell name + field)
- Lease-based lifetime maps to frame generation (observe for this generation only)

**Disadvantages:**
- Requires runtime support for wildcard cell name patterns
- Callback model doesn't fit cell's declarative given semantics
- Missed-event window: if child freezes before parent registers observe

### TSpaces event notification → metadata-based matching

TSpaces extends Linda with SQL-like query matching. This suggests:

```
observe [program=my-child, field=status]
```

where the pattern matches on cell metadata (program, field) rather than
exact name. This is more expressive than JavaSpaces' structural matching.

**Maps well to:** Cell's existing metadata. Cells have `program`, `name`,
`fields`. A query-based observe could match on any combination.

**Doesn't map to:** Cell's static DAG model. Givens form a compile-time
dependency graph. Query-based observe would make the DAG dynamic, which
breaks `generationOrdered` and `noSelfLoops` invariants.

### GigaSpaces Notify vs Polling Container → the design tension

GigaSpaces offers both:
- **Notify Container**: push-based, low latency, but no backpressure
- **Polling Container**: pull-based, controllable concurrency, higher latency

Cell faces the same tension:
- Push (notify): runtime triggers parent when child freezes → low latency
- Pull (poll): parent periodically checks for child yields → wasteful

The GigaSpaces experience suggests: **use notify for the common case, with
polling as fallback for high-throughput scenarios.**

---

## 3. What Maps and What Doesn't

### Maps well

| Linda concept | Cell equivalent | Status |
|--------------|----------------|--------|
| `out(tuple)` | `pour` / `freeze` | Implemented |
| `in(template)` | `claim` (atomic, destructive) | Implemented |
| `rd(template)` | `given` (blocking, non-destructive) | Implemented (static) |
| Template matching | `givenSatisfiable` | Implemented |
| Tuple persistence | Yield immutability | Proved (`yieldUnique`) |
| `eval` (live tuples) | Piston evaluation | Implemented |

### Doesn't map

| Linda concept | Cell gap | Why |
|--------------|---------|-----|
| Wildcard `rd` | No pattern-based given | Givens require exact cell name |
| `notify` | No async observation | Cell is declarative, not callback-based |
| Dynamic tuple creation | Autopour creates cells, but parent can't reference them | Name not known at pour time |
| Lease-based registration | No TTL on givens | Givens are permanent |

### The core gap

Linda assumes all tuple names are known or matchable by structure. Cell
assumes all dependency names are known at pour time. **The autopour case
creates tuples whose names are determined at runtime**, violating both
assumptions.

---

## 4. Recommendation: Minimal Extension for Cell

### Option A: Name-convention `given` (simplest)

Autopour produces cells with predictable names derived from the parent:
```
autopour "my-child" → creates cells "my-child/eval", "my-child/judge", ...
```

The parent declares givens against the convention:
```
given my-child/eval → status
```

**Pro:** No language change. Just a naming convention.
**Con:** Tight coupling between parent and child program structure.
Parent must know child's internal cell names.

### Option B: `observe` with template matching (Linda-faithful)

Add a new primitive that's blocking `rd` with wildcards:
```
observe [autopour=my-child] → status
```

Runtime semantics:
1. At pour time, register an observation: "when any cell from program
   `my-child` freezes a `status` yield, satisfy this observe."
2. The cell stays `declared` until the match fires.
3. When matched, the observe resolves like a `given` — the specific
   cell name and frame are bound, creating a binding edge.

**Pro:** Faithful to Linda's `rd` semantics. Declarative. DAG edges
are created at resolution time, preserving `generationOrdered`.
**Con:** New primitive. Pattern language design needed. What patterns
are allowed? Just program name, or arbitrary predicates?

### Option C: `yield-ref` indirection (most minimal)

The autopour operation itself returns a reference:
```
cell parent {
  body: soft """
    [autopour my-child]
    The child's eval result is: «autopour:my-child/eval.status»
  """
}
```

The `autopour:` prefix tells the runtime: "this reference will be
resolved after autopour completes." It's syntactic sugar for a two-phase
given: first autopour, then resolve.

**Pro:** No new primitive. Extends existing given resolution.
**Con:** Couples autopour and given resolution in the eval loop.
Requires the piston to handle two-phase evaluation.

### Recommendation

**Option B (observe with template matching)** is the Linda-faithful
choice. It preserves cell's declarative semantics, keeps the DAG
well-formed (edges created at resolution time), and directly corresponds
to JavaSpaces' `notify(template, listener)` but with blocking semantics
matching Linda's `rd`.

The minimal template language: match on `program` (the autopoured program
name) and `field` (the yield field). No arbitrary predicates. This is
exactly TSpaces' SQL-like matching restricted to two columns.

```
observe program="my-child" field="status"
```

resolves to:
```
given <first-frozen-frame-of-my-child> → status
```

The runtime creates the binding edge when the match fires, preserving
all DAG invariants. The parent cell stays `declared` until resolved,
just like a normal `given`.

---

## Sources

- Gelernter, "Generative Communication in Linda" (1985)
- Carvalho, "Our AI Orchestration Frameworks Are Reinventing Linda" (2026)
- Carriero & Gelernter, "Linda in Context" (CACM 1989)
- JavaSpaces Service Specification (Jini/Apache River)
- IBM TSpaces documentation
- GigaSpaces Notify Container / Polling Container documentation
- Cell runtime: docs/research/tuple-space-protocol.md

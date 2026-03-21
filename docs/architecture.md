# Cell Architecture: A Gas City Native Runtime

Cell is a versioned tuple space where programs run deterministically until
they need judgment, and the runtime manages the boundary. It is built ON
Gas City's primitives, not alongside them.

---

## 1. Five Primitives

Gas City has five irreducible primitives. Cell maps to all five.
Removing any makes it impossible to build the system.

| # | Gas City Primitive | Cell Equivalent | Shared substrate |
|---|---|---|---|
| 1 | **Agent Protocol** — start/stop/observe agents | **Piston Protocol** — start/stop/claim/release pistons | Pistons ARE Gas City agents. Same lifecycle. |
| 2 | **Task Store (Beads)** — CRUD over work units | **Retort Store** — CRUD over cells/yields/frames | Cells are structured work units. Pour=Create, Submit=Update, Freeze=Close. |
| 3 | **Event Bus** — append-only pub/sub log | **Retort Events** — boundary events on yield freeze, program complete | Same `events.Provider` interface. One bus. |
| 4 | **Config** — TOML with progressive activation | **Cell Syntax + Annotations** — parser infers capabilities from syntax presence | Effect annotations, retries, fuel. Syntax IS config. |
| 5 | **Prompt Templates** — Go templates defining behavior | **Cell Body Text** — the `.cell` body IS the prompt | No separate template layer. The cell body is the behavioral specification. |

### Derived mechanisms (composed from primitives)

| Mechanism | Derivation | Gas City parallel |
|---|---|---|
| **Dynamic observe** | Event Bus watch + stem cell cycling | Order gate evaluation |
| **Autopour** | Retort Store pour + Event Bus `autopour_spawned` | Formula dispatch (sling) |
| **Cascade-thaw** | Retort Store thaw + Event Bus `thaw_cascaded` | Health patrol restart |
| **Oracle validation** | Piston dispatch + Retort Store submit | — (cell-specific) |
| **Formulas-as-cells** | Formula steps → cell DAG, step deps → givens | Formulas & molecules |
| **Convergence** | Stem cell + `recur until guard (max N)` | `gc converge` loops |

### The Primitive Test

Before adding anything to Cell, apply Gas City's three necessary conditions:

1. **Atomicity** — can it be decomposed into existing primitives? If yes,
   it's derived, not primitive.
2. **Bitter Lesson** — does it become MORE useful as models improve? If a
   smarter model would do it better from the prompt, it fails.
3. **ZFC** — is it transport or cognition? If implementing it requires a
   judgment call, the decision belongs in the cell body (prompt), not
   the runtime (Go).

---

## 2. The Effect Lattice

Effects are classified by **recoverability**, not by what they are.

```
Pure < Replayable < NonReplayable
```

| Level | What it means | On failure | Cost |
|---|---|---|---|
| **Pure** | Deterministic, no effects | Retry for free | Zero |
| **Replayable** | Produces a value, no mutations | Auto-retry (bounded N) | Cheap |
| **NonReplayable** | Mutates the space or the world | Cascade-thaw: rewind + redo | Expensive |

### Operations by effect level

**Pure**: Lookup (read given), YieldVal (freeze), SQLQuery (read-only), PureCheck

**Replayable**: LLMCall, LLMJudge (semantic oracle)

**NonReplayable**: SQLExec (DML), Spawn (autopour), CascadeThaw, ExtIO

### Composition

A cell's effect = max of its operations. A program's effect = max of
its cells. This follows from `join` being a semilattice homomorphism.

The canonical `EffLevel` type and its full join algebra are defined in
`formal/Core.lean`. See `formal/EffectAlgebra.md` for Wadler's algebraic
laws and handler interpretation.

---

## 3. The Tuple Space

Five operations over the retort:

| Operation | What | Linda | Effect |
|---|---|---|---|
| **pour** | Add cells to the space | `out` | Admin (not in lattice) |
| **claim** | Reserve a ready cell | `inp` (probe) | Replayable |
| **submit** | Provide yield values | — (consumes claim) | Pure |
| **observe** | Read frozen yields | `rd` | Pure |
| **thaw** | Rewind cell + dependents | — (no Linda equiv) | NonReplayable |

Invariants (proved in Lean):
1. Append-only (pour and submit only add data)
2. Claim mutex (at most one piston per frame)
3. Yield immutability (frozen yields never change)
4. DAG acyclicity (givens form a DAG)

See `formal/cell-tuple-space-spec.md` for the complete v4 specification.

---

## 4. Event Bus Integration

Cell emits **boundary events** to Gas City's EventBus — not internal
state machine transitions. Internal state lives in retort tables and
the trace table.

### Boundary events (emitted to EventBus)

| Event type | When | Who cares |
|---|---|---|
| `cell.program_poured` | `ct pour` completes | Agents waiting for work |
| `cell.program_complete` | All non-stem cells frozen | Autopour parent, bead system |
| `cell.program_bottomed` | Unrecoverable failure | Autopour parent, witness |
| `cell.autopour_spawned` | `[autopour]` creates child | Parent program's watcher |
| `cell.yield_frozen` | A watched yield freezes | Dynamic observe subscribers |

### Two-tier event model

- **Retort trace table** (internal, high-volume): every state change.
  For debugging, replay, audit. Excluded from Dolt versioning.
- **Gas City EventBus** (boundary, low-volume): cross-program and
  cross-system events only. Shared with all Gas City agents.

`yield_frozen` events are emitted **only for explicitly watched yields**.
No watchers = no events. Same principle as `inotify`.

### Dynamic observe via EventBus

Dynamic observe (watching autopoured program results) composes from
existing primitives:

```
watch = EventBus.Watch(filter={type:"cell.yield_frozen", subject:childProgID}, cursor)
      + stem cell cycling (advance generation on each new event)
```

No new observation primitive needed.

---

## 5. Progressive Activation

Capabilities activate from syntax presence. No feature flags.

| Level | What's present | What activates |
|---|---|---|
| 0 | `.cell` file with hard cells | Pour + inline evaluation |
| 1 | Soft cell bodies | Piston dispatch (LLM evaluation) |
| 2 | `(stem)` annotation | Perpetual evaluation, stem cycling |
| 3 | `check` / `check~` | Oracle validation |
| 4 | `recur until` | Guarded recursion |
| 5 | `[autopour]` | Metacircular evaluation |
| 6 | `watch` | Dynamic observation via EventBus |
| 7 | Effect annotations `(nonreplayable)` | Isolation, cascade-thaw |

The parser IS the config system. Syntax presence activates capability.

---

## 6. Layering Invariants

These hold across the entire system:

1. **No upward dependencies.** Retort Store never imports Piston Protocol.
   Event Bus never imports Retort Store. Primitives are independent.
2. **Retort Store is the persistence substrate** for all cell state.
3. **Event Bus is the observation substrate** for all cross-boundary events.
4. **Cell syntax is the activation mechanism.** Syntax presence = capability.
5. **Side effects (I/O, process spawning) are confined to NonReplayable cells.**
6. **The `ct` runtime handles transport only.** All judgment lives in cell
   bodies (prompts) and piston responses. ZFC is absolute.

---

## 7. Formulas as Cell Programs

A formula step IS a cell. The mapping is structural:

| Formula concept | Cell concept |
|---|---|
| Step `id` | Cell name |
| Step `needs` | Givens (data dependencies) |
| Step `description` | Cell body (prompt text) |
| Step completion | Frozen yield |
| Formula variables `{{var}}` | Hard literal cells (`yield x = "value"`) |
| `mol-review-leg` dispatch | NonReplayable cell (beads + sling) |

A convergence loop IS a stem cell with a guard:

```
gc converge --max-iterations 3 --gate condition
```
maps to:
```
cell refine (stem)
  recur until gate = "approved" (max 3)
```

This means Gas City's orchestration layer can eventually be expressed
as cell programs running in the retort.

---

## 8. The Retort and Gas City Share Everything

| Retort operation | Gas City operation | Shared how |
|---|---|---|
| Pour a program | Create a bead | Same store interface shape |
| Claim a cell | Hook a bead to an agent | Same atomic CAS |
| Submit a yield | Update + close a bead | Same lifecycle |
| Observe a yield | Read a bead | Same query |
| Emit retort event | Record Gas City event | Same `events.Provider` |
| Piston starts | Agent session starts | Same `runtime.Provider` |

The retort IS a specialized bead store. Pistons ARE Gas City agents.
Cell programs ARE structured work that Gas City agents execute.

**Cell is Gas City's cognitive layer.** Gas City can talk (beads, mail,
nudges). Cell lets Gas City think (structured multi-step reasoning with
formal guarantees).

---

## 9. Source of Truth

The authority chain:

> **Lean proofs** are the truth. **Docs/design** inform the proofs.
> **Go code** must align with both.

| Layer | Key files |
|---|---|
| Formal model | `formal/Core.lean`, `formal/Autopour.lean`, `formal/EventBus.lean`, `formal/AgentProtocol.lean` |
| Tuple space spec | `formal/cell-tuple-space-spec.md` (v4) |
| Effect algebra | `formal/EffectAlgebra.md` (Wadler) |
| Philosophy | `docs/cell-philosophy-cheatsheet.md` |
| Syntax | `docs/cell-v2-syntax.md`, `docs/cell-v2-parser-spec.md` |
| Architecture | This document |
| Implementation | `cmd/ct/*.go`, `schema/retort-init.sql` |
| Examples | `examples/*.cell` |

---

## See Also

- [Cell Philosophy Cheatsheet](cell-philosophy-cheatsheet.md) — "Evaluation reduces M"
- [Cell v2 Syntax](cell-v2-syntax.md) — the grammar
- [Reading List](reading-list.md) — Linda, actors, blackboard systems
- [Implementation Plan](plans/2026-03-20-implementation-plan-v2.md) — phased roadmap
- [Autopour Runtime Spec](plans/2026-03-21-autopour-runtime-spec.md) — reify + autopour for ct

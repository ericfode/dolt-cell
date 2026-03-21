# dolt-cell — Cell Language Runtime

Cell is a versioned tuple space where programs run deterministically
until they need judgment. It is built on Gas City's five primitives.

**Evaluation reduces M.** That's the whole language.

## Architecture

Cell maps to Gas City's five irreducible primitives:

1. **Piston Protocol** = Agent Protocol — pistons ARE Gas City agents
2. **Retort Store** = Task Store — cells are structured work units
3. **Retort Events** = Event Bus — boundary events, shared bus
4. **Cell Syntax** = Config — syntax presence activates capability
5. **Cell Body** = Prompt Template — the body IS the behavioral spec

Everything else derives from these five. See `docs/architecture.md`.

## Design Principles

### Zero Framework Cognition (ZFC)

The `ct` runtime handles **transport only**. If a line of Go contains
a judgment call, it's a bug. The cell body (prompt) decides. The piston
(agent) decides. Go moves data.

- Finding ready cells = transport (query a view)
- Dispatching to pistons = transport (send prompt)
- Freezing yields = transport (write to store)
- Deciding what to do on failure = **cognition** (belongs in cell body)

### The Primitive Test

Before adding anything to Cell, three conditions must all hold:

1. **Atomicity** — can it be decomposed into existing primitives?
   If yes, it's derived.
2. **Bitter Lesson** — does it become MORE useful as models improve?
   If not, it fails.
3. **ZFC** — is it transport or cognition? If cognition, it belongs
   in the prompt.

### Nondeterministic Idempotence (NDI)

Sessions come and go; the retort survives. Claims have TTLs. Ready
cells are re-discovered on poll. Multiple pistons can evaluate the
same program concurrently. Redundancy IS the reliability mechanism.

### Progressive Activation

No feature flags. Syntax presence activates capability:

| Present in `.cell` | Activates |
|---|---|
| Hard cells | Inline evaluation |
| Soft cell bodies | Piston dispatch |
| `(stem)` | Perpetual evaluation |
| `check` / `check~` | Oracle validation |
| `recur until` | Guarded recursion |
| `[autopour]` | Metacircular evaluation |
| Effect annotations | Isolation, cascade-thaw |

## Effect Lattice

```
Pure < Replayable < NonReplayable
 |         |              |
ground   falling       in orbit
```

- **Pure**: literals, deterministic SQL. Already a value.
- **Replayable**: LLM prompts, SQL reads. Safe to retry.
- **NonReplayable**: DML, beads ops, external APIs. Cascade-thaw on failure.

Effects are classified by **recoverability**, not by what they are.
Canonical definition: `formal/Core.lean` (`EffLevel`).

## Authority Chain

> **Lean proofs** are the truth. **Docs/design** inform the proofs.
> **Go code** must align with both.

When implementation can't match the proofs, the divergence is noted
in the proofs and filed as beads. The proofs don't bend.

## Event Bus Integration

Cell emits **boundary events only** to Gas City's EventBus:

- `cell.program_poured`, `cell.program_complete`, `cell.program_bottomed`
- `cell.autopour_spawned`, `cell.yield_frozen` (watched yields only)

Internal state transitions stay in the retort trace table.
No watchers = no `yield_frozen` events. Same principle as `inotify`.

## Change Notification Protocol

| You changed... | Notify | How |
|---|---|---|
| Design doc / research | scribe, glassblower, sussmind | `bd create --rig dolt-cell "Design: <what>" -t task` |
| Lean proof / formal model | glassblower, sussmind | `bd create --rig dolt-cell "Formal: <what>" -t task` |
| Go code (ct runtime) | scribe | `bd create --rig dolt-cell "Impl: <what>" -t task` |
| Cell syntax / language | alchemist, sussmind, scribe | `bd create --rig dolt-cell "Syntax: <what>" -t task` |

## Key Commands

```bash
ct pour <name> <file.cell>    # Pour a program into the retort
ct next --wait                # Claim next ready cell
ct submit <prog> <cell> <f> v # Submit a yield value
ct status <prog>              # Show program state
ct watch <prog>               # Live cell status view
ct yields <prog>              # Show frozen yields
```

## Cell Syntax (Lua Substrate)

Cell programs are Lua programs. Each cell is a table with effect level,
dependencies (givens), outputs (yields), and a body.

```lua
-- Hard literal (pure value, no computation)
hard({ subject = "autumn rain on a temple roof" })

-- Soft cell (LLM-evaluated prompt)
soft({"topic.subject"}, {"poem"}, function(env)
  return "Write a haiku about " .. env.subject .. "."
end)

-- Pure compute (replaces sql: — deterministic Lua function)
compute({"compose.poem"}, {"total"}, function(env)
  local n = 0
  for _ in env.poem:gmatch("%S+") do n = n + 1 end
  return { total = tostring(n) }
end)

-- Stem cell (perpetual, via coroutine)
stem_cell({"seed.world"}, {"world", "tick"}, function(env)
  -- coroutine.yield(result, "more") = request next cycle
  -- return result = final yield, cell freezes
end)

-- Autopour (eval = pour: cell yields a program)
autopour_cell({"request.program_text"}, {"evaluated"}, function(env)
  local fn = loadstring(env.program_text)  -- loadstring IS eval
  setfenv(fn, make_sandbox(PURE))          -- setfenv IS sandboxing
  return { evaluated = fn() }
end, "evaluated")
```

Effect tiers: `PURE` (math/string/table only) < `REPLAYABLE` (+LLM, +observe)
< `NON_REPLAYABLE` (+loadstring, +coroutine, +pour/claim/submit)

See `examples/cell-zero.lua` for the full metacircular evaluator.
Design doc: `docs/plans/2026-03-21-lua-substrate-design.md`

## Project Structure

- `cmd/ct/` — Go source for the ct tool
- `examples/` — Cell program examples
- `formal/` — Lean 4 formal proofs and specifications
- `schema/` — Retort database schema (SQL)
- `piston/` — Piston system prompt and runtime protocol
- `docs/` — Design docs, research, and plans ([index](docs/README.md))

## Documentation

Start with `docs/architecture.md` (how Cell is built) and
`docs/cell-philosophy-cheatsheet.md` (why Cell works the way it does).
Full index at `docs/README.md`.

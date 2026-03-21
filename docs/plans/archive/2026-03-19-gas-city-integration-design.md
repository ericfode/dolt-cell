# Gas City Integration: Shared Distributed Tuple Space for Agent Cognition

## Core vision

dolt-cell provides a shared, distributed tuple space (backed by Dolt) where agents across Gas City think by pouring cell programs, evaluating them, and observing crystallized yields. Cells are ephemeral thoughts; yields are persistent knowledge. The retort (Dolt database) is the communication and cognition medium.

## Key principles

- Cells don't live forever — they're thoughts that crystallize and can be reaped
- The retort is a shared workspace, not per-agent — many cell programs coexist, one thought's yields become another's givens
- The retort is DISTRIBUTED across Gas City via Dolt replication — agents in different towns share the same cognitive space
- Beads integration happens through NonReplayable cells — filing issues, updating status are just side effects like DML
- Cell programs can be loaded from a template library or authored fresh by agents
- The Linda tuple space operations (pour/claim/observe/gather) are the primitives

## Effect classification for integrations

| Cell body | Effect | Why |
|-----------|--------|-----|
| `sql: SELECT ...` | Replayable | reads mutable state, safe to retry |
| LLM prompt | Replayable | non-deterministic but no side effects |
| `bd create "..."` / script with side effects | NonReplayable | mutates external state |
| LLM prompt that calls tools | NonReplayable | LLM + side effects |

## Distribution topology

- Each town runs a local Dolt server with a retort replica
- DoltHub syncs retorts across towns
- Pour is local, then pushes
- Observe reads the local replica
- Claim goes through Dolt merge — first-claim-wins on unique constraint
- Yields are append-only, so merge is trivial — no conflicts on frozen values

## What it is NOT

- Not a replacement for beads, mail, or nudge — those remain for simple coordination
- Not infrastructure that agents depend on to function — it's a capability they USE when structured collaborative thinking beats message-passing
- Not permanent storage — cells are working memory, not database of record

## Relationship to existing concepts

- The cell language is the lingua franca of Gas City
- Pour = load thinking patterns into the space
- Claim = grab ready work (like bd update --claim, but for thoughts)
- Observe = see what's been figured out (non-destructive)
- Gather [*] = collect results across iterations/programs
- Crystallization = thought becomes value

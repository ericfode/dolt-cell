# Cell Runtime: Next Phase PRD

## Problem Statement

The Cell runtime is technically complete: formal model at A+ (5285 lines Lean, 175 theorems), Go implementation validated end-to-end (93 commits, 78 tests, frame migration done), piston pattern proven. But it's a tool nobody reaches for yet. The gap is between "works when you drive it manually" and "tool people use for real work."

Five specific questions need answers:
1. How do Cell programs get triggered by real events (incidents, PRs, schedules)?
2. How does Cell integrate with Gas Town agents — can a cell program BE an agent's workflow?
3. How do we make the piston experience great — what does a piston session look like when it's working well?
4. Can Cell programs compose — one program's output feeding another?
5. What's the path from "demo that works" to "tool people reach for"?

## Current State

### What exists
- **ct tool**: 15 commands (pour, run, piston, next, submit, status, yields, graph, lint, watch, frames, eval, reset, release, history)
- **v2 parser**: 23 .cell programs, all parse via Phase B
- **Frame model**: yields keyed on frame_id, bindings, claim_log, append-only semantics
- **Formal model**: A+ (11 invariants, 55 preservation proofs, behavioral refinement, total correctness)
- **Piston pattern**: Claude Code session uses ct commands (piston/next/submit)
- **Completion beads**: emitted to Gas Town when program finishes
- **Real workloads**: code-audit.cell, design-doc.cell, incident-response.cell

### What's missing
- **No event triggers**: programs must be manually poured and driven
- **No piston automation**: the piston formula (mol-cell-piston) exists but hasn't been exercised
- **No composition**: one program's output can't feed into another program
- **No scheduling**: no way to run a program on a schedule or in response to events
- **No discovery**: other agents can't find or use Cell programs

## Target Users

1. **Gas Town agents** — crew members who could use Cell for complex multi-step workflows instead of ad-hoc scripts
2. **The overseer** — who wants structured, auditable, repeatable processes
3. **The mayor** — who wants to dispatch work via Cell programs instead of direct agent management

## Success Criteria

1. At least one Cell program runs weekly on a schedule and produces useful output
2. A Gas Town agent can trigger a Cell program in response to an event (e.g., escalation → incident-response.cell)
3. The piston experience is smooth enough that an agent follows the system-prompt without getting stuck
4. Cell program results are discoverable via Gas Town beads

## Non-Goals (this phase)

- Multi-piston parallelism (single-piston is fine)
- Performance optimization (< 100 cells is fine)
- Public API or external users
- Replacing beads (Cell complements beads, doesn't replace them)

## Open Questions

1. Should `gt cell run <program.cell>` be the entry point, or should Cell programs be triggered via mail/hooks?
2. Should the piston formula (mol-cell-piston) be the standard way to run Cell, or should there be a simpler path?
3. How much of the system-prompt does the piston actually need? The current 290-line prompt may be overkill for most programs.
4. Should Cell programs live in the rig directory or in a shared Cell registry?
5. What's the minimum viable piston — the simplest Claude Code session config that can evaluate soft cells?

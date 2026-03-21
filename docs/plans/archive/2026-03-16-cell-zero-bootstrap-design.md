# Cell-Zero Bootstrap: User-Space Evaluator

**Date:** 2026-03-16
**Status:** Approved — implementing

## Problem

The Cell runtime's eval loop lives in Go code (`ct run`, `ct piston`, `ct repl`).
The piston is smart — it knows how to claim cells, resolve inputs, dispatch hard
vs soft, submit results. This knowledge should live in cell-space, not Go code.

## Design

cell-zero is a persistent Cell program that IS the evaluator. The piston runs
against cell-zero and just evaluates whatever soft cell it's given. cell-zero's
cells handle orchestration: scanning for ready cells across all programs,
evaluating them, submitting results.

### New Primitives

**1. Perpetual cells** — a cell that auto-resets to `declared` after freezing.

- Syntax: body_type `perpetual` (or a flag on stem cells)
- Runtime: after `cell_submit` freezes all yields → reset state to `declared`,
  clear yield values, delete claim. Cell becomes ready again immediately.
- This gives cell-zero its heartbeat. eval-one keeps cycling.
- Schema: `is_perpetual BOOLEAN DEFAULT FALSE` on cells table, or new body_type.

**2. `dml:` hard cell type** — SQL that modifies data.

- Body: `dml:INSERT INTO ... VALUES (...)` or `dml:UPDATE ... SET ...`
- Yield: affected row count (as string)
- Implementation: same PREPARE/EXECUTE pattern as sql:, but no scalar subquery
  wrapper. Just execute and capture ROW_COUNT().

### cell-zero Program

```
⊢ context
  yield schema ≡ [retort schema]
  yield syntax ≡ [cell syntax]

⊢ eval-one                          ← perpetual stem cell
  yield cell_name
  yield program_id
  yield status                       ← "evaluated" | "quiescent"
  ∴∴ Scan all programs for ready cells. Claim one. If hard, execute
     inline. If soft, read body + resolved inputs, think, submit
     each yield. If nothing ready, yield status="quiescent".
```

### Eval Flow

1. Pour cell-zero once (persistent)
2. Piston runs: `ct piston cell-zero`
3. eval-one is perpetual — always becomes ready after freezing
4. Each cycle: eval-one scans programs, claims a ready cell, evaluates it
5. Pour a new program (e.g., `ct pour haiku haiku.cell`)
6. eval-one picks up haiku's ready cells automatically
7. When haiku completes, eval-one yields "quiescent" → resets → polls again

### Piston Integration

The crew piston (do-w9u) runs against cell-zero instead of target programs.
It becomes a thin loop: cell_eval_step → think → submit → repeat.

### Bootstrapping Ladder

- Level 0 (today): Go code orchestrates
- Level 1 (this): cell-zero orchestrates, piston just thinks
- Level 2: pour is a perpetual cell in cell-zero
- Level 3: cell-zero evaluates modified versions of itself

### Customization

cell-zero is persistent, but you can pour modified versions scoped to specific
programs. Swap eval-one's body for different eval strategies. Stem cells are
the extension points.

## Implementation Steps

1. Add `is_perpetual` column to cells table
2. Implement perpetual reset in cell_submit (Go + stored procedure)
3. Add `dml:` hard cell type to cell_eval_step
4. Write cell-zero.cell (the operational version)
5. Pour cell-zero, test with haiku example
6. Switch crew piston to run against cell-zero

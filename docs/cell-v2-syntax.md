# Cell v2 Syntax — LLM-Native Notation

## Migration Guide: v1 → v2

| v1 (Unicode) | v2 (ASCII) | Notes |
|---|---|---|
| `⊢ NAME` | `cell NAME` | |
| `⊢= sql: QUERY` | `cell NAME` + `sql: QUERY` in body | Unified under `cell` |
| `⊢∘ NAME × N` | `cell NAME` + `recur until GUARD (max N)` | Guarded recursion |
| `⊢∘ NAME × N` (no guard) | `iterate NAME N` | Bounded iteration (sugar) |
| `yield NAME ≡ VALUE` | `yield NAME = VALUE` | |
| `yield NAME` | `yield NAME` | Unchanged |
| `given SOURCE→FIELD` | `given SOURCE.FIELD` | Dot notation |
| `given? SOURCE→FIELD` | `given? SOURCE.FIELD` | |
| `given SOURCE-*→FIELD` | `given SOURCE[*].FIELD` | Bracket gather |
| `∴ TEXT` | `---` fenced block | Explicit boundaries |
| `∴∴ TEXT` | `cell NAME (stem)` + `---` block | Keyword annotation |
| `⊨ CONDITION` | `check CONDITION` | |
| `⊨~ ASSERTION` | `check~ ASSERTION` | |
| `«field»` | `«field»` | Kept — visually distinct, no collisions |
| `-- comment` | `-- comment` | Unchanged |

## Full Syntax

```
-- Comments use double-dash (unchanged)

cell NAME [(stem)]
  yield FIELD [= LITERAL_VALUE]
  yield FIELD [: TYPE]
  given SOURCE.FIELD
  given? SOURCE.FIELD              -- optional dependency
  given SOURCE[*].FIELD            -- gather all iterations
  given SOURCE[N].FIELD            -- specific iteration
  recur until GUARD_EXPR (max N)   -- guarded recursion
  recur (max N)                    -- unguarded recursion (always runs N times)

-- OR at column 0 (sugar for recur without guard):
iterate NAME N
  ---
  Body text here. Freeform natural language for soft cells.
  SQL for hard computed cells: sql: SELECT ...
  References use «field» guillemets.
  ---
  check DETERMINISTIC_CONDITION
  check~ SEMANTIC_ASSERTION
```

## Cell Kinds (derived, not declared)

- **Hard literal**: has `yield NAME = VALUE`, no body
- **Hard computed**: body starts with `sql:` or `dml:`
- **Soft**: has a `---` body with natural language
- **Stem**: declared with `(stem)` — permanently soft, never crystallizes

## Recursion

Replaces `⊢∘ NAME × N`. The fundamental form is `recur` — a cell chains
copies of itself, each receiving the previous step's yields as givens.

### Guarded recursion

The cell recurses until a guard on one of its yields is satisfied:

```
cell reflect (stem)
  given compose.poem
  yield poem
  yield settled
  recur until settled = "SETTLED" (max 8)
  ---
  Refine this haiku: «poem»
  ---
```

Semantics:
- First instance reads from seed givens (compose.poem)
- After each eval, runtime checks guard on `settled` yield
- If guard satisfied → freeze, done
- If not → spawn successor, previous yields chain forward
- `(max N)` is safety bound; at max, freeze anyway or bottom

Guard expressions (SQL-checkable):
- `FIELD = "VALUE"` — exact match
- `FIELD in ["A", "B", "C"]` — set membership
- `FIELD > N` — numeric comparison
- `FIELD is not empty` — non-empty check

### Bounded iteration (sugar)

`iterate NAME N` is shorthand for `cell NAME` + `recur (max N)` with no guard.
Use it for state-transition simulations where you want exactly N applications:

```
iterate day 5
  given assemble.initial_state
  yield world_state
  yield narrative
  ---
  Execute one tick of the simulation...
  ---
```

is equivalent to:

```
cell day
  given assemble.initial_state
  yield world_state
  yield narrative
  recur (max 5)
  ---
  Execute one tick of the simulation...
  ---
```

**Use `iterate`** when you want exactly N steps (simulation ticks, pipeline stages).
**Use `recur until`** when you're seeking convergence (refinement loops, search).
Both expand to the same chain: `NAME-1 → NAME-2 → ... → NAME-N`.

## Yield Output Format (for piston responses)

When a piston evaluates a soft cell, it returns yields in delimited sections:

```
--- fieldname
value here (can be multiline)
--- fieldname2
another value
```

This replaces freeform extraction from unstructured LLM output.

## Examples

### Hard literal
```
cell topic
  yield subject = "autumn rain on a temple roof"
```

### Soft cell
```
cell compose
  given topic.subject
  yield poem
  ---
  Write a haiku about «subject». Follow 5-7-5 syllable structure.
  Return only the three lines.
  ---
```

### Hard computed (SQL)
```
cell count-words
  given compose.poem
  yield total
  ---
  sql: SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(TRIM(p.value_text), ' ', '')) + 1
       FROM yields p JOIN cells c ON p.cell_id = c.id
       WHERE c.program_id = 'haiku' AND c.name = 'compose'
       AND p.field_name = 'poem' AND p.is_frozen = 1
  ---
```

### Guarded recursion
```
cell reflect (stem)
  given compose.poem
  given compose.notes
  yield poem
  yield notes
  yield settled
  recur until settled = "SETTLED" (max 8)
  ---
  You are refining a haiku. Current version:
  «poem»
  Previous notes: «notes»
  Critique and improve. Return SETTLED or REVISING.
  ---
  check~ poem follows 5-7-5 syllable pattern
```

### Bounded iteration (sugar)
```
iterate day 5
  given assemble.initial_state
  yield world_state
  ---
  Simulate one day. Evolve «world_state» according to the rules.
  ---
  check world_state is not empty
```

### Gather all iterations
```
cell evolution
  given compose.poem
  given reflect[*].poem
  given reflect[*].settled
  yield timeline
  ---
  Compile all versions into a numbered timeline.
  ---
  check timeline is not empty
```

### Stem cell (perpetual)
```
cell eval-one (stem)
  yield cell_name
  yield program_id
  yield status
  ---
  Find one ready cell, evaluate it, submit results.
  ---
```

# Cell v2 Syntax — LLM-Native Notation

## Migration Guide: v1 → v2

| v1 (Unicode) | v2 (ASCII) | Notes |
|---|---|---|
| `⊢ NAME` | `cell NAME` | |
| `⊢= sql: QUERY` | `cell NAME` + `sql: QUERY` in body | Unified under `cell` |
| `⊢∘ NAME × N` | `cell NAME` + `recur until GUARD (max N)` | Guarded recursion |
| `⊢∘ NAME × N` (no guard) | `iterate NAME N` | Sugar for `cell NAME` + `recur (max N)` |
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
  -- OR use shorthand:
  -- iterate NAME N                -- sugar for cell NAME + recur (max N)
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

Replaces `⊢∘ NAME × N`. Cell supports two forms of recursion:

### Guarded Recursion

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

### Bounded Iteration (`iterate`)

When you need fixed-count recursion without a guard, use `iterate`:

```
iterate refine 3
  given compose.poem
  yield poem
  ---
  Polish this draft: «poem»
  ---
```

This is syntactic sugar. The parser desugars it to:

```
cell refine
  given compose.poem
  yield poem
  recur (max 3)
  ---
  Polish this draft: «poem»
  ---
```

`iterate` is recursion, not classical iteration — each step is a
nondeterministic transformation whose output feeds the next step.
There is no loop variable, no mutation, no break. See
`docs/research/iterate-is-sugar.md` for the full rationale.

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

### Bounded iteration
```
iterate polish 5
  given compose.poem
  yield poem
  ---
  Improve clarity and rhythm of this haiku: «poem»
  Keep 5-7-5 syllable structure.
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

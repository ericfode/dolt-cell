# Crystallization Design: Soft Cell → SQL View

**Date**: 2026-03-14
**Status**: Design
**Parent**: do-27k

## What Crystallization Is

A soft cell evaluates via LLM. A crystallized cell evaluates via SQL (a view).
Crystallization replaces the LLM call with a deterministic query that produces
the same output, verified by the same oracles.

```
BEFORE (soft):
⊢ word-count
  given text
  yield count
  ∴ Count the words in «text».
  ⊨ count = number of whitespace-separated tokens

AFTER (crystallized):
⊢ word-count
  given text
  yield count
  ⊢= view: cell_prog_word_count
  ⊨ count = number of whitespace-separated tokens
```

The cell row in Retort changes:
- `body_type`: 'soft' → 'hard'
- `body`: '∴ Count the words...' → 'view:cell_prog_word_count'

A new view is created:
```sql
CREATE VIEW cell_prog_word_count AS
SELECT 'word-count' as cell_name, 'count' as field_name,
  LENGTH(y.value_text) - LENGTH(REPLACE(y.value_text, ' ', '')) + 1 as value
FROM yields y
JOIN cells c ON y.cell_id = c.id
WHERE c.program_id = 'prog-id' AND c.name = 'text-source'
  AND y.field_name = 'text' AND y.is_frozen = 1;
```

---

## The Crystallization Procedure

```
CALL cell_crystallize(cell_id, proposed_sql)
```

### Steps

1. **Validate**: Cell must be frozen (has been successfully evaluated at least
   once). Must have at least one oracle.

2. **Create view**: `CREATE VIEW cell_{program}_{name} AS {proposed_sql}`

3. **Differential test**: Re-run the view on the current frozen inputs.
   Compare view output to the existing frozen yield values.
   - Match → view is correct for this input set
   - Mismatch → reject crystallization

4. **Cross-validate**: If historical execution data exists (previous runs with
   different inputs), test the view against those too. The more input/output
   pairs that match, the higher confidence.

5. **Update cell**: If tests pass:
   - `UPDATE cells SET body_type = 'hard', body = 'view:cell_{program}_{name}'`
   - `CALL DOLT_COMMIT('crystallize: {cell_name}')`

6. **Keep the soft version**: The original `∴` body is preserved in metadata
   or a `cell_history` table. If the crystallized view ever fails an oracle
   that the soft version passed, automatic fallback.

### The Soft Version Is Never Discarded

Per the spec: "May replace is PERMISSION, not equality. The soft cell is the
specification. The hard cell is a proven optimization. Both coexist."

Store the soft body in a `cell_soft_bodies` table:
```sql
CREATE TABLE cell_soft_bodies (
  cell_id VARCHAR(64) PRIMARY KEY,
  soft_body TEXT NOT NULL,
  crystallized_at TIMESTAMP,
  CONSTRAINT fk_soft_cell FOREIGN KEY (cell_id) REFERENCES cells(id)
);
```

---

## Who Proposes Crystallization?

### Option 1: The Piston (Inline)

After evaluating a soft cell multiple times, the piston notices the pattern:
"This cell always produces the same output for similar inputs. I can write
SQL for this."

The piston writes the SQL and calls `cell_crystallize()`.

### Option 2: A Crystallization Sweep

A separate process (could be a piston, a cron job, or a formula) scans for
crystallization candidates:

```sql
-- Find soft cells that have been frozen successfully N+ times
-- with consistent oracle results
SELECT c.id, c.name, c.body
FROM cells c
WHERE c.body_type = 'soft'
  AND c.state = 'frozen'
  AND (SELECT COUNT(*) FROM trace t
       WHERE t.cell_id = c.id AND t.action = 'freeze') >= 3
  -- All executions passed oracles
  AND NOT EXISTS (
    SELECT 1 FROM trace t
    WHERE t.cell_id = c.id AND t.action = 'bottom'
  );
```

For each candidate, dispatch a piston to write the SQL.

### Option 3: Oracle Promotion (Automatic)

When a deterministic oracle literally states the implementation:
```
⊨ count = len(split(«text», " "))
```

The oracle IS the SQL. Auto-crystallize:
```sql
CREATE VIEW cell_prog_word_count AS
SELECT LENGTH(y.value_text) - LENGTH(REPLACE(y.value_text, ' ', '')) + 1 as value
FROM ...;
```

This is the "the oracle that literally states the implementation is the
transition point" from the spec.

---

## What Cannot Crystallize

Per the spec, permanently soft cells:
- `crystallize` itself (the cell that writes SQL from natural language)
- `eval-one` / cell-zero (interprets arbitrary ∴ blocks)
- Any cell that operates on `§` values (cell definitions as data)

These are the "stem cells" — expensive, pluripotent, essential for growth.

In the Retort schema, mark these:
```sql
UPDATE cells SET metadata = JSON_SET(metadata, '$.crystallizable', false)
WHERE name IN ('crystallize', 'eval-one', 'cell-zero');
```

---

## Crystallization and Dolt Branching

Crystallization is a schema change (`CREATE VIEW`). This has implications
for Dolt branching:

- Creating a view on one branch doesn't affect other branches
- Merging a branch with a new view into main adds the view to main
- Two branches that crystallize the same cell differently → merge conflict
  (view name collision)

Strategy: crystallize on a dedicated branch, test, merge to main. This
is analogous to how code changes work in Git.

```sql
CALL DOLT_BRANCH('crystallize/word-count');
CALL DOLT_CHECKOUT('crystallize/word-count');
-- create view, test, validate
CALL DOLT_CHECKOUT('main');
CALL DOLT_MERGE('crystallize/word-count');
```

---

## The Crystallization Spectrum (Concrete)

```
Level 0: Pure soft (∴ body, LLM evaluates every time)
Level 1: Cached (LLM evaluated, result memoized for same inputs)
Level 2: Crystallized (SQL view, deterministic, no LLM)
Level 3: Optimized (SQL view with indices, materialized)
```

Level 1 (caching) is a useful intermediate step. If the same cell with the
same inputs has been evaluated before, return the cached result:

```sql
-- In cell_eval_step, before dispatching a soft cell:
SELECT y.value_text FROM yields y
WHERE y.cell_id = ? AND y.field_name = ?
  AND y.value_hash = SHA2(resolved_inputs, 256)
  AND y.is_frozen = 1;
-- If found: skip LLM call, return cached value
```

This gives you crystallization-like cost savings without writing SQL.
True crystallization (Level 2) comes when someone writes the view.

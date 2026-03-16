# Frame Model Migration Plan

## Current Schema (v1)

```
cells (id, program_id, name, body_type, body, state, ...)  -- MUTABLE state
yields (cell_id, field_name, value_text, is_frozen, ...)     -- MUTABLE is_frozen
givens (cell_id, source_cell, source_field, is_optional)     -- immutable
oracles (cell_id, oracle_type, assertion, condition_expr)     -- immutable
cell_claims (cell_id, piston_id, claimed_at)                 -- mutable
```

Problems with v1:
- `cells.state` is mutable — breaks append-only invariant
- `yields.is_frozen` is mutable — same issue
- Stem cell respawn requires DELETE+INSERT (unique constraint workaround)
- No generation tracking — stem cell history lost on respawn
- No binding records — can't audit what a cell read

## Target Schema (v2 Frame Model)

From formal/Retort.lean:

```sql
-- IMMUTABLE (set at pour time, never modified)
cell_defs (name, program_id, body_type, body)
given_specs (cell_name, source_cell, source_field, is_optional)
oracles (cell_name, oracle_type, assertion, condition_expr)

-- APPEND-ONLY (rows only added, never modified or deleted)
frames (id, cell_name, program_id, generation)
yields (frame_id, field_name, value_text)      -- existence = frozen
bindings (consumer_frame, producer_frame, field) -- DAG edges

-- MUTABLE (the only mutable table)
claims (frame_id, piston_id)

-- APPEND-ONLY AUDIT
claim_log (frame_id, piston_id, action, created_at)
```

## Derived State (computed, never stored)

```sql
-- Frame status: derived from yields + claims
CREATE VIEW frame_status AS
SELECT f.id, f.cell_name,
  CASE
    WHEN (SELECT COUNT(*) FROM yields y WHERE y.frame_id = f.id)
       = (SELECT COUNT(*) FROM cell_defs cd
          JOIN yields_expected ye ON ye.cell_name = cd.name
          WHERE cd.name = f.cell_name)
    THEN 'frozen'
    WHEN EXISTS (SELECT 1 FROM claims c WHERE c.frame_id = f.id)
    THEN 'computing'
    ELSE 'declared'
  END AS status
FROM frames f;

-- Ready frames: declared + all givens satisfied
CREATE VIEW ready_frames AS
SELECT f.*
FROM frames f
WHERE [status = declared]
  AND f.id NOT IN (
    SELECT f2.id FROM frames f2
    JOIN given_specs gs ON gs.cell_name = f2.cell_name
    WHERE gs.is_optional = FALSE
      AND NOT EXISTS (
        SELECT 1 FROM frames pf
        JOIN yields y ON y.frame_id = pf.id AND y.field_name = gs.source_field
        WHERE pf.cell_name = gs.source_cell AND pf.program_id = f2.program_id
      )
  );
```

## Migration Steps

### Step 1: Add tables alongside existing (backward compatible)
- CREATE frames, bindings, claim_log tables
- ct pour creates frames (gen 0) alongside existing cells rows
- Existing procedures continue to work on old tables
- New code can read from frames table

### Step 2: ct run/submit writes to both schemas
- On freeze: write yield to both old and new tables
- On claim: write to both cell_claims and claims
- Record bindings when resolving inputs

### Step 3: Switch reads to frame-based
- Update ready_cells view to use frames
- Update cell_eval_step to use frames
- Update cell_submit to use frames + bindings

### Step 4: Remove old mutable columns
- Drop cells.state column
- Drop yields.is_frozen column
- Rename cells → cell_defs

### Stem Cell Benefits
With frames, stem cell lifecycle becomes:
1. Pour: create cell_def, NO frame (demand-driven)
2. Demand detected: INSERT frame (gen 0)
3. Claim + evaluate + freeze: yields written for frame
4. More demand: INSERT frame (gen 1) — no DELETE needed
5. Each generation's yields are permanent history

No more DELETE+INSERT respawn hack.

## Key Invariants (from Retort.lean)

1. cell_defs never change after pour
2. frames, yields, bindings are append-only
3. Only claims table is mutable
4. Each (frame_id, field) has at most one yield
5. Each (cell_name, generation) has at most one frame
6. Bindings only point to frozen frames
7. Same-cell bindings go backward in generation (acyclic)

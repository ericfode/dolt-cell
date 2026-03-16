-- Pour SQL for cell-zero-eval: operational self-spawning evaluator
USE retort;

-- The eval-one stem cell — self-spawning universal evaluator
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('cz-eval-one', 'cell-zero-eval', 'eval-one', 'stem',
'You are the Cell runtime evaluator. Your job: find one ready cell across all programs in this retort database, evaluate it, submit the result, then spawn a fresh copy of yourself so evaluation continues.

## Step 1: Find work

Run this SQL to find a ready cell in any program (excluding your own program):

```sql
SELECT rc.id, rc.program_id, rc.name, rc.body_type, LEFT(rc.body, 4096) AS body, rc.model_hint
FROM ready_cells rc
WHERE rc.program_id != ''cell-zero-eval''
  AND rc.id NOT IN (SELECT cell_id FROM cell_claims)
LIMIT 1;
```

If no rows returned: yield status="quiescent", cell_name="none", program_id="none".
Then skip to Step 4 (still spawn your successor).

## Step 2: Claim and evaluate

Claim the cell:
```sql
INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at)
VALUES (''<CELL_ID>'', ''cell-zero-piston'', NOW());
```

If ROW_COUNT()=0, another piston claimed it. Go back to Step 1.

Mark it computing:
```sql
UPDATE cells SET state = ''computing'', computing_since = NOW(),
  assigned_piston = ''cell-zero-piston'' WHERE id = ''<CELL_ID>'';
CALL DOLT_COMMIT(''-Am'', ''cell-zero: claim <CELL_NAME>'');
```

Now evaluate based on body_type:

**Hard cell (literal:)** — Extract the value after "literal:", freeze yields:
```sql
UPDATE yields SET value_text = ''<LITERAL_VALUE>'', is_frozen = TRUE, frozen_at = NOW()
WHERE cell_id = ''<CELL_ID>'' AND is_frozen = FALSE;
UPDATE cells SET state = ''frozen'', computing_since = NULL, assigned_piston = NULL
WHERE id = ''<CELL_ID>'';
DELETE FROM cell_claims WHERE cell_id = ''<CELL_ID>'';
CALL DOLT_COMMIT(''-Am'', ''cell: freeze hard cell <CELL_NAME>'');
```

**Hard cell (sql:)** — Execute the SQL after "sql:" prefix, freeze with result:
Run the query, take the scalar result, freeze yields same as literal.

**Soft/stem cell** — Read the body as a prompt. Look up resolved inputs:
```sql
SELECT CONCAT(g.source_cell, ''.'', g.source_field) AS input_key,
       LEFT(COALESCE(y.value_text, CAST(y.value_json AS CHAR)), 4096) AS input_val
FROM givens g
JOIN cells src ON src.name = g.source_cell AND src.program_id = ''<PROGRAM_ID>''
JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
WHERE g.cell_id = ''<CELL_ID>'';
```

Replace any «guillemet» references in the body with the resolved input values.
Think carefully about the prompt. Produce output for each yield field:
```sql
SELECT field_name FROM yields WHERE cell_id = ''<CELL_ID>'';
```

## Step 3: Submit results

For each yield field, submit via:
```sql
CALL cell_submit(''<PROGRAM_ID>'', ''<CELL_NAME>'', ''<FIELD>'', ''<YOUR_OUTPUT>'');
```

Check the result. If oracle_fail, revise your output and resubmit (max 3 tries).

Yield your own fields: cell_name=<name of cell you evaluated>,
program_id=<program you evaluated>, status="evaluated".

## Step 4: Spawn successor

CRITICAL: You MUST do this step even if Step 1 found no work. Create a fresh copy of yourself so the eval loop continues. Generate a unique ID:
```sql
SELECT CONCAT(''cz-eval-'', SUBSTR(MD5(RAND()), 1, 8)) AS new_id;
```

Then clone yourself — copy the cell row, create fresh yields:
```sql
INSERT INTO cells (id, program_id, name, body_type, body, state)
SELECT ''<NEW_ID>'', program_id, name, body_type, body, ''declared''
FROM cells WHERE id = ''<YOUR_CELL_ID>'';

INSERT INTO yields (id, cell_id, field_name)
VALUES (CONCAT(''y-'', SUBSTR(MD5(RAND()), 1, 8)), ''<NEW_ID>'', ''cell_name''),
       (CONCAT(''y-'', SUBSTR(MD5(RAND()), 1, 8)), ''<NEW_ID>'', ''program_id''),
       (CONCAT(''y-'', SUBSTR(MD5(RAND()), 1, 8)), ''<NEW_ID>'', ''status'');

CALL DOLT_COMMIT(''-Am'', ''cell-zero: spawn eval-one successor'');
```

This ensures there is always an eval-one cell ready for the next cycle.',
'declared');

-- Yields for eval-one
INSERT INTO yields (id, cell_id, field_name)
VALUES ('y-cz-eval-cell', 'cz-eval-one', 'cell_name'),
       ('y-cz-eval-prog', 'cz-eval-one', 'program_id'),
       ('y-cz-eval-stat', 'cz-eval-one', 'status');

CALL DOLT_COMMIT('-Am', 'pour: cell-zero-eval');

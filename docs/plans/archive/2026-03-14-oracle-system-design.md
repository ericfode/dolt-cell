# Oracle System Design: cell_submit and Verification

**Date**: 2026-03-14
**Status**: Design
**Parent**: do-27k

## How Oracle Checking Works

When a piston evaluates a soft cell and calls `cell_submit(cell_id, yields)`,
the procedure must verify the output before freezing.

```
Piston evaluates soft cell → tentative output
    ↓
CALL cell_submit('sp-sort', '{"sorted": "[1,2,3,4,7,9]"}')
    ↓
Procedure writes tentative_value to yields table
    ↓
For each oracle on this cell:
    ├─ deterministic? → evaluate in SQL → pass/fail
    ├─ structural?    → evaluate in SQL → pass/fail
    └─ semantic?      → return to piston for LLM judgment
    ↓
All pass? → freeze (is_frozen=1, value_text=tentative, commit)
Any fail? → increment retry_count, return failure context
Retries exhausted? → bottom (is_bottom=1, commit)
```

---

## Oracle Types and Evaluation

### Deterministic Oracles (Checked in SQL)

```
⊨ count = 42
⊨ len(sorted) = len(items)
⊨ result > 0
```

These are exact value checks or arithmetic comparisons. `cell_submit` evaluates
them as SQL expressions:

```sql
-- ⊨ count = 42
SELECT CASE
  WHEN tentative_value = '42' THEN 'pass'
  ELSE 'fail'
END as result,
'expected 42, got ' || tentative_value as detail
FROM yields WHERE cell_id = ? AND field_name = 'count';
```

The oracle's `assertion` column stores the check. For v0, we support:
- Exact equality: `field = value`
- Numeric comparison: `field > value`, `field < value`, `field >= value`
- Length check: `len(field) = value`

### Structural Oracles (Checked in SQL)

```
⊨ sorted is a permutation of «data→items»
⊨ sorted is in ascending order
```

These check structural properties. They're more complex but still deterministic.
Implemented as SQL functions or stored procedures:

```sql
-- Permutation check: same elements, same counts
-- Compare JSON arrays after sorting
SELECT CASE
  WHEN JSON_SORT(tentative_value) = JSON_SORT(upstream_value)
  THEN 'pass'
  ELSE 'fail'
END as result;

-- Ascending order check
-- Verify each element <= next element
SELECT CASE
  WHEN is_ascending(tentative_value) THEN 'pass'
  ELSE 'fail'
END as result;
```

Structural oracles may need helper functions. These can be:
- SQL stored functions (pure SQL)
- Views that perform the check
- For complex checks: `exec:` to an external validator

### Semantic Oracles (Returned to LLM)

```
⊨ summary captures the main points
⊨ code is idiomatic and readable
```

These require judgment. `cell_submit` cannot evaluate them in SQL. Instead:

1. Procedure writes tentative value to yields (tentative_value column)
2. Procedure returns the semantic oracle(s) to the piston:

```
status: 'oracle_check'
cell_id: 'sp-summary'
tentative_value: '...'
oracles: [
  { id: 'o1', assertion: 'summary captures the main points', type: 'semantic' }
]
```

3. The piston reads the tentative value and oracle assertion
4. The piston makes a judgment (this IS soft cell evaluation — LLM thinks)
5. The piston calls `cell_oracle_result(oracle_id, 'pass'|'fail', detail)`
6. When all oracles are resolved, the procedure freezes or retries

### Oracle Classification

Who decides if an oracle is deterministic, structural, or semantic?

**Phase A (LLM-based cell_pour)**: The LLM classifies during parsing:
- Contains `=`, `>`, `<`, `len(`, `count(` → deterministic
- Contains "permutation", "sorted", "ascending", "subset" → structural
- Everything else → semantic

**Phase B/C (deterministic parser)**: Pattern matching on the assertion text.
A conservative classifier: if uncertain, mark semantic (safe default — LLM
checks it, which is always valid; the worst case is wasted LLM cost, not
missed verification).

---

## The cell_submit Procedure

```sql
DELIMITER //
CREATE PROCEDURE cell_submit(
  IN p_cell_id VARCHAR(64),
  IN p_yields_json JSON
)
BEGIN
  DECLARE v_program_id VARCHAR(64);
  DECLARE v_all_pass TINYINT DEFAULT 1;
  DECLARE v_has_semantic TINYINT DEFAULT 0;
  DECLARE v_retry_count INT;
  DECLARE v_max_retries INT;

  -- Get cell info
  SELECT program_id, retry_count, max_retries
  INTO v_program_id, v_retry_count, v_max_retries
  FROM cells WHERE id = p_cell_id;

  -- Write tentative values
  -- For each key in p_yields_json, update the yields row
  -- (implementation depends on Dolt's JSON function support)

  -- Check deterministic oracles
  -- For each oracle WHERE cell_id = p_cell_id AND oracle_type = 'deterministic':
  --   Evaluate assertion against tentative values
  --   If fail: set v_all_pass = 0

  -- Check structural oracles
  -- Similar to deterministic but using helper functions

  -- Check for semantic oracles
  SELECT COUNT(*) INTO v_has_semantic
  FROM oracles WHERE cell_id = p_cell_id AND oracle_type = 'semantic';

  IF v_has_semantic > 0 THEN
    -- Return semantic oracles to piston for LLM judgment
    UPDATE cells SET state = 'tentative' WHERE id = p_cell_id;
    SELECT 'oracle_check' as status, p_cell_id as cell_id,
           -- return semantic oracle details
           ;
  ELSEIF v_all_pass = 1 THEN
    -- All deterministic/structural oracles pass, no semantic oracles
    -- FREEZE
    UPDATE yields SET
      value_text = tentative_value,
      is_frozen = 1,
      frozen_at = NOW()
    WHERE cell_id = p_cell_id;
    UPDATE cells SET state = 'frozen' WHERE id = p_cell_id;
    CALL DOLT_COMMIT('-am', CONCAT('freeze: ', p_cell_id));
    SELECT 'frozen' as status, p_cell_id as cell_id;
  ELSE
    -- Oracle failed
    IF v_retry_count < v_max_retries THEN
      UPDATE cells SET
        retry_count = retry_count + 1,
        state = 'declared'
      WHERE id = p_cell_id;
      -- Return failure context for retry
      SELECT 'retry' as status, p_cell_id as cell_id,
             -- failure details for retry prompt
             ;
    ELSE
      -- Exhausted: bottom
      UPDATE yields SET is_bottom = 1, is_frozen = 1 WHERE cell_id = p_cell_id;
      UPDATE cells SET state = 'bottom' WHERE id = p_cell_id;
      CALL DOLT_COMMIT('-am', CONCAT('bottom: ', p_cell_id));
      SELECT 'bottom' as status, p_cell_id as cell_id;
    END IF;
  END IF;
END //
```

---

## Retry with Feedback

When an oracle fails and retries remain, the piston gets:

```
status: 'retry'
cell_id: 'sp-sort'
attempt: 2
failures: [
  { oracle: 'sorted is ascending', detail: 'got [1,7,3,2,4,9] — 7 > 3' }
]
original_prompt: 'Sort [4, 1, 7, 3, 9, 2] in ascending order.'
```

The piston re-evaluates with the failure context appended:

```
Sort [4, 1, 7, 3, 9, 2] in ascending order.

PREVIOUS ATTEMPT FAILED:
- Oracle "sorted is ascending" failed: got [1,7,3,2,4,9] — 7 > 3
Please try again, ensuring the output is in ascending order.
```

This is the `⊨? retry with «oracle.failures»` pattern from the spec,
implemented as a piston instruction rather than a language feature.

---

## Oracle Cost Optimization

| Oracle type | Cost | Strategy |
|------------|------|----------|
| Deterministic | Zero (SQL) | Always check in SQL |
| Structural | Zero (SQL) | Check in SQL with helper functions |
| Semantic | 1 LLM call | Use cheaper model (Haiku) for verification |

**Batching for semantic oracles**: When a cell has multiple semantic oracles,
send them all in one LLM call:

```
Check these assertions about the output:
1. summary captures the main points
2. summary is 2-3 sentences
3. summary does not introduce new information

Output: For each assertion, PASS or FAIL with one-line reason.
```

One LLM call instead of three.

**Self-checking optimization**: For non-critical cells, include oracle
assertions in the original evaluation prompt. The LLM checks its own work
inline. ~10-15% less accurate but halves the call count.

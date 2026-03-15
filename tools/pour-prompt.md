# cell_pour Phase A: Parsing Prompt

Parse the following Cell program into SQL INSERT statements for the Retort schema.

## Schema

```sql
-- cells: one row per cell declaration
cells(id VARCHAR(64), program_id VARCHAR(64), name VARCHAR(128),
      body_type VARCHAR(8), body VARCHAR(4096), state VARCHAR(16))

-- givens: one row per input dependency
givens(id VARCHAR(64), cell_id VARCHAR(64), source_cell VARCHAR(64),
       source_field VARCHAR(64), is_optional BOOLEAN DEFAULT FALSE)

-- yields: one row per output declaration
yields(id VARCHAR(64), cell_id VARCHAR(64), field_name VARCHAR(64))

-- oracles: one row per assertion
oracles(id VARCHAR(64), cell_id VARCHAR(64), oracle_type VARCHAR(16),
        assertion VARCHAR(1024), condition_expr VARCHAR(1024))
```

## Turnstyle Operator Rules

| Syntax | Meaning | Mapping |
|--------|---------|---------|
| `⊢ NAME` | Cell declaration | INSERT into cells |
| `given X→Y` | Input dependency | INSERT into givens: source_cell=X, source_field=Y |
| `given? X→Y` | Optional input | INSERT into givens: source_cell=X, source_field=Y, is_optional=TRUE |
| `yield NAME` | Output declaration | INSERT into yields: field_name=NAME |
| `yield NAME ≡ VALUE` | Pre-bound output | INSERT into yields + cell is hard/literal |
| `∴ TEXT` | Soft cell body | body_type='soft', body=TEXT (with «» refs kept) |
| `⊢= TEXT` | Hard cell body | body_type='hard', body=TEXT |
| `⊨ TEXT` | Oracle assertion | INSERT into oracles |

## ID Convention

- Cell IDs: `{program}-{cellname}` (e.g., `sort-proof-data`, `sp-data`)
- Given IDs: `g-{cellname}-{source_field}` (e.g., `g-sort-items`)
- Yield IDs: `y-{cellname}-{field}` (e.g., `y-data-items`)
- Oracle IDs: `o-{cellname}-{ordinal}` (e.g., `o-sort-1`)

## IMPORTANT: source_cell in givens

The `source_cell` column in givens is the **cell NAME** (e.g., `data`, `sort`),
NOT the full cell ID (e.g., NOT `sort-proof-data`). This matches the turnstyle
syntax: `given data→items` means source_cell='data', source_field='items'.

## Cell Type Classification

1. **Hard cell (literal pre-bound)**: Has `yield NAME ≡ VALUE` and NO `∴` body.
   - body_type = 'hard'
   - body = 'literal:VALUE'
   - state = 'declared'
   - The yield row gets field_name=NAME (no value_text — runtime fills it)

2. **Soft cell**: Has a `∴` body.
   - body_type = 'soft'
   - body = the text after `∴`
   - state = 'declared'
   - CRITICAL: Preserve `«»` guillemet references EXACTLY as written.
     `∴ Sort «items» in ascending order.` → body='Sort «items» in ascending order.'
     Do NOT strip, replace, or expand guillemets. They are runtime interpolation markers.

3. **Hard cell (computed)**: Has a `⊢=` body.
   - body_type = 'hard'
   - body = the text after `⊢=`
   - state = 'declared'

## Oracle Type Classification

Use `deterministic` ONLY for assertions that can be checked with a simple SQL
expression (exact value comparison, length/count check, NOT NULL check). Examples:
- "count = 42" → deterministic, condition_expr='exact:42'
- "X is a permutation of Y" → deterministic, condition_expr='length_matches:Y_source_cell'
  (length match is the best SQL approximation of permutation)

Use `semantic` for ALL other assertions — anything requiring judgment, ordering,
format validation, or meaning. Examples:
- "sorted is in ascending order" → semantic (requires inspecting values)
- "poem follows 5-7-5 syllable pattern" → semantic
- "summary captures main points" → semantic
- "X is a valid JSON array" → semantic
- "X is one of positive, negative, or neutral" → semantic

When in doubt, use 'semantic' with condition_expr=NULL.

## Example

Input:
```
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» in ascending order.
  ⊨ sorted is a permutation of items
  ⊨ sorted is in ascending order
```

Output:
```
USE retort;
INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('sp-data', 'sort-proof', 'data', 'hard', 'literal:[4, 1, 7, 3, 9, 2]', 'declared');
INSERT INTO yields (id, cell_id, field_name) VALUES ('y-data-items', 'sp-data', 'items');
INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('sp-sort', 'sort-proof', 'sort', 'soft', 'Sort «items» in ascending order.', 'declared');
INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES ('g-sort-items', 'sp-sort', 'data', 'items');
INSERT INTO yields (id, cell_id, field_name) VALUES ('y-sort-sorted', 'sp-sort', 'sorted');
INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('o-sort-1', 'sp-sort', 'deterministic', 'sorted is a permutation of items', 'length_matches:data');
INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('o-sort-2', 'sp-sort', 'semantic', 'sorted is in ascending order', NULL);
CALL DOLT_COMMIT('-Am', 'pour: sort-proof');
```

Note: source_cell='data' (cell name), NOT 'sp-data' (cell ID).
Note: "ascending order" is semantic, "permutation" is deterministic (length_matches).
Note: body='Sort «items» in ascending order.' — guillemets «» are preserved verbatim.

## Output Format

Output ONLY valid SQL INSERT statements. Each statement on its own line.
Use `USE retort;` as the first line.
End with `CALL DOLT_COMMIT('-Am', 'pour: {program_name}');`
No commentary, no markdown fences, no explanations.

## Program to Parse

```
{program_text}
```

# cell_pour Design: From Turnstyle Syntax to Retort Rows

**Date**: 2026-03-14
**Status**: Design
**Parent**: do-27k

## The Problem

A Cell program in turnstyle syntax:

```
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» in ascending order.
  ⊨ sorted is a permutation of «data→items»
  ⊨ sorted is in ascending order
```

Must become rows in the Retort schema: programs, cells, givens, yields, oracles.

`cell_pour` is the compiler. It has three phases of bootstrap:
- **Phase A**: LLM parses (soft)
- **Phase B**: SQL string parsing (deterministic but fragile)
- **Phase C**: Proper parser (crystallized)

---

## Phase A: LLM Parses (Works Today)

The LLM receives the turnstyle text and produces INSERT statements. This is
a structured extraction task on well-defined syntax — the turnstyle operators
are unambiguous delimiters.

### The Prompt

```
Parse this Cell program into SQL INSERT statements for the Retort schema.

SCHEMA:
- programs(id, name, source_file, source_hash, status)
- cells(id, program_id, name, qualified_name, body_type, body, state)
- givens(id, cell_id, param_name, source_cell, source_field, is_optional)
- yields(cell_id, field_name, default_value)
- oracles(id, cell_id, oracle_type, assertion, ordinal)

RULES:
- ⊢ starts a cell declaration. The word after ⊢ is the cell name.
- Indented lines belong to the current cell.
- "given X→Y" = source_cell=X, source_field=Y
- "given? X→Y" = source_cell=X, source_field=Y, is_optional=1
- "yield NAME" = yield declaration
- "yield NAME ≡ VALUE" = yield with default value (cell is hard, pre-bound)
- "∴ text" = soft body (body_type='soft', body=text)
- "⊢= text" = hard body (body_type='hard', body=text)
- "⊨ text" = oracle assertion (oracle_type='semantic' unless it's a pure comparison)
- IDs: use program_name + '-' + cell_name as id prefix

PROGRAM TEXT:
{program_text}

OUTPUT: SQL INSERT statements only. No commentary.
```

### Accuracy Estimate

Ravi estimated ~85-90% end-to-end accuracy for structured turnstyle syntax
(vs ~50-60% for prose). The well-defined delimiters (⊢, ∴, ⊨, →, ≡) make
this a delimiter-splitting task, not an NLP task.

### Verification

After parsing, render the extracted structure back and confirm:

```
Extracted from 'sort-proof':
  cell: data (hard, pre-bound)
    yield: items = [4, 1, 7, 3, 9, 2]
  cell: sort (soft)
    given: data→items
    yield: sorted
    body: Sort «items» in ascending order.
    oracle[0]: sorted is a permutation of «data→items»
    oracle[1]: sorted is in ascending order

Proceed? [y/n]
```

This confirmation step costs zero LLM calls — it's just a SELECT rendering
the parsed rows. Catches parse errors before execution begins.

---

## Phase B: SQL String Parsing

The turnstyle syntax is line-oriented. Each line starts with a known keyword
or is a continuation. A SQL stored procedure can parse it with string functions.

### Line Classification

```
⊢ name          → START_CELL
  given X→Y     → GIVEN
  given? X→Y    → GIVEN_OPTIONAL
  yield NAME    → YIELD
  yield N ≡ V   → YIELD_DEFAULT
  ∴ text        → SOFT_BODY
  ⊢= text       → HARD_BODY
  ⊨ text        → ORACLE
  ⊨? text       → RECOVERY
  (blank)       → CELL_BOUNDARY
  -- text       → COMMENT
```

### Parsing Strategy

```sql
-- Pseudocode for cell_pour stored procedure
-- Split input on newlines
-- For each line:
--   TRIM and classify by first character/token
--   ⊢ → create new cell, insert into cells
--   given → parse X→Y, insert into givens
--   yield → parse NAME ≡ VALUE, insert into yields
--   ∴ → accumulate body text until next keyword
--   ⊨ → insert into oracles
--   blank → close current cell
```

Dolt/MySQL string functions needed:
- `SUBSTRING_INDEX(line, ' ', 1)` — first token
- `LOCATE('→', line)` — find arrow for given parsing
- `LOCATE('≡', line)` — find binding for yield defaults
- `TRIM()`, `SUBSTRING()` — whitespace handling

### Limitations

- Multi-line `∴` bodies need accumulation across lines
- `⊢=` bodies may contain SQL with special characters
- `«»` guillemets are multi-byte UTF-8 — need careful string handling
- Guard clauses (`where`) require sub-line parsing
- Spawners (`⊢⊢`) and evolution (`⊢∘`) have complex syntax

Phase B handles the kernel (12 features). Deferred features need Phase C.

---

## Phase C: Proper Parser

A real parser — either:
- A Go binary called via `exec:` from a stored procedure
- A Dolt UDF (user-defined function) in Go
- An external tool that emits SQL

The parser handles the full v0.2 spec: spawners, evolution loops, co-evolution,
wildcard dependencies, guard clauses, conditional oracles, recovery policies.

### The Crystallization Oracle

The Phase A (LLM) parser serves as the test oracle for Phase C:

```
For each of the 55 example .cell programs:
  Phase A: LLM parses → rows_a
  Phase C: Deterministic parser → rows_c
  Assert: rows_a == rows_c
```

Zero differences across all 55 programs = crystallization complete.

---

## Hard Cell Compilation: ⊢= to SQL View

When `cell_pour` encounters a `⊢=` body, it needs to compile it to a
CREATE VIEW statement. This is a separate compilation step.

### Simple Cases (Direct SQL)

If the `⊢=` body is already SQL:
```
⊢= sql: SELECT LENGTH(?) - LENGTH(REPLACE(?, ' ', '')) + 1
```
→ Wrap in CREATE VIEW with input resolution from yields table.

### Expression Cases (Compile to SQL)

If the `⊢=` body uses the Cell expression syntax:
```
⊢= count ← len(split(«text», " "))
```
→ Compile to SQL:
```sql
CREATE VIEW cell_word_count AS
SELECT LENGTH(y.value_text) - LENGTH(REPLACE(y.value_text, ' ', '')) + 1 as count
FROM yields y JOIN cells c ON y.cell_id = c.id
WHERE c.name = 'data' AND y.field_name = 'text' AND y.is_frozen = 1;
```

### Compilation Mapping

| Cell expression | SQL equivalent |
|----------------|---------------|
| `len(s)` | `LENGTH(s)` |
| `split(s, d)` | JSON_TABLE or SUBSTRING_INDEX patterns |
| `contains(s, sub)` | `LOCATE(sub, s) > 0` |
| `join(list, d)` | `GROUP_CONCAT(... SEPARATOR d)` |
| `sort(list)` | `ORDER BY` in subquery |
| `a + b` | `a + b` |
| `if c then a else b` | `CASE WHEN c THEN a ELSE b END` |
| `x→field` | JOIN on yields table |
| `name ← expr` | Column alias or CTE |

### The Phase A Shortcut

In Phase A, the LLM does this compilation too. Give it:
```
Compile this ⊢= expression to a CREATE VIEW statement that reads
from the yields table. The view should resolve inputs from upstream
frozen yields and produce the output as a column.
```

The LLM writes SQL fluently. This works for bootstrap.

---

## cell_pour Input/Output Contract

### Input
- `program_name`: VARCHAR — name for the program
- `source_text`: TEXT — the turnstyle syntax program

### Output (Side Effects)
- 1 row in `programs`
- N rows in `cells` (one per cell declaration)
- M rows in `givens` (one per given clause)
- K rows in `yields` (one per yield declaration)
- J rows in `oracles` (one per oracle assertion)
- Optional: CREATE VIEW statements for hard cells
- 1 `DOLT_COMMIT` with message "pour: {program_name}"

### Return Value
- `program_id`: the ID of the created program
- `cell_count`: number of cells created
- `error`: NULL on success, error message on failure

---

## Pre-Bound Cells (yield ≡ value)

When a cell has yields with default values and no body:
```
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]
```

This cell is already frozen at pour time:
1. Insert cell with `state = 'frozen'`
2. Insert yield with `value_text = '[4, 1, 7, 3, 9, 2]'`, `is_frozen = 1`

No evaluation needed. The cell is data, not computation.

---

## Dolt MCP Integration

If the Dolt MCP server is available, `cell_pour` could be an MCP tool:

```json
{
  "tool": "cell_pour",
  "params": {
    "program_name": "sort-proof",
    "source": "⊢ data\n  yield items ≡ [4, 1, 7, 3, 9, 2]\n..."
  }
}
```

The MCP server handles parameterization (no SQL injection), structured
responses (program_id, cell_count, errors), and tool discovery.

This eliminates the "LLM composing SQL strings" problem entirely. The piston
calls typed MCP tools instead of constructing `dolt sql -q "..."` commands.

# Hard Cells After the Tuple Store Rewrite

**Bead**: dc-88t
**Date**: 2026-03-20
**Author**: Alchemist (dolt-cell)

## The Problem

Hard cells with `sql:` bodies currently execute raw SQL against Dolt:

```go
sqlQuery := strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
db.QueryRow(sqlQuery).Scan(&result)
```

With a log-structured tuple store, there's no SQL engine. What should
hard cells do?

## What Hard Cells Actually Compute

After reading all 13 `.cell` files that use `sql:`, I found three
categories:

### Category 1: Pure Arithmetic / String Ops

```sql
SELECT CAST(10 + 25 AS CHAR)
SELECT CAST(1+2+3+4+5+6+7+8 AS CHAR)
SELECT CAST(3.14159 + 2.71828 AS CHAR)
SELECT CASE WHEN 35 > 250 THEN 'sum' ELSE 'product' END
```

These don't query any tables. They're deterministic expressions that
happen to be written in SQL because SQL was the available evaluator.

### Category 2: Yield Validation (the majority)

```sql
-- Count words in a frozen yield
SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(TRIM(p.value_text), ' ', '')) + 1
  FROM yields p JOIN cells c ON p.cell_id = c.id
  WHERE c.name = 'compose' AND p.field_name = 'poem' AND p.is_frozen = 1

-- Verify factors multiply to target
SELECT CASE WHEN CAST(JSON_EXTRACT(..., '$[0]') AS SIGNED)
              * CAST(JSON_EXTRACT(..., '$[1]') AS SIGNED)
              = CAST(TRIM(n.value_text) AS SIGNED)
       THEN 'VERIFIED' ELSE 'FAILED' END
  FROM yields ...

-- Validate classification label
SELECT CASE WHEN LOWER(TRIM(l.value_text)) IN ('clean','borderline','toxic')
       THEN 'valid' ELSE 'invalid' END
  FROM yields l JOIN cells c ON ...
```

These query the `yields` table to read frozen values from other cells.
But here's the key: **these cells already declare `given` dependencies
on those same cells.** The data is already available via resolved givens.

The SQL is a *workaround* for the fact that the `sql:` body executes in
a database context where yields are rows, rather than in a context where
resolved givens are variables.

### Category 3: Meta-Circular (cell-zero-eval)

```sql
-- Direct manipulation of retort schema
SELECT ... FROM cells WHERE program_id = ...
INSERT INTO cells ...
```

This is explicitly NonReplayable — it reaches below the abstraction to
manipulate retort state. This is the `dml:` case from the formal model,
not a `sql:` case.

## The Insight

**Hard cells don't need SQL. They need a deterministic expression
evaluator that operates on resolved givens.**

The `given` system already resolves yield values before a cell is
dispatched. For soft cells, resolved givens are interpolated via
guillemets (`«field»`). Hard cells bypass this and go straight to the
database. But they shouldn't have to.

Consider the word-count cell. Currently:

```
cell count-words
  given compose.poem
  yield count
  ---
  sql: SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(TRIM(p.value_text), ' ', '')) + 1
       FROM yields p JOIN cells c ON p.cell_id = c.id
       WHERE c.name = 'compose' AND p.field_name = 'poem' AND p.is_frozen = 1
  ---
```

Proposed:

```
cell count-words
  given compose.poem
  yield count
  ---
  expr: string(size(poem.split(" ")))
  ---
```

The `given compose.poem` already brings the value in. The expression
evaluates on that value directly. No database query needed.

## Proposal: Replace `sql:` with `expr:`

### The Expression Language

Use **CEL (Common Expression Language)** — Google's expression language
for policy evaluation. It's:

- **Deterministic** — no side effects, no IO, no mutation
- **Type-safe** — catches errors before evaluation
- **Fast** — compiles to bytecode, sub-millisecond evaluation
- **Go-native** — `cel-go` library, actively maintained
- **Designed for this** — built for evaluating conditions and
  computing values from structured inputs

### How It Works

When a hard cell with `expr:` body is claimed:

1. Resolve all `given` dependencies (same as soft cells)
2. Build a CEL environment with resolved givens as typed variables
3. Compile and evaluate the expression
4. Freeze the result as the yield value

```go
func evalHardExpr(givens map[string]Value, body string) (string, error) {
    env, _ := cel.NewEnv(
        cel.Variable("poem", cel.StringType),
        cel.Variable("factors", cel.StringType),
        // ... one variable per resolved given
    )
    ast, _ := env.Compile(body)
    prg, _ := env.Program(ast)
    out, _, _ := prg.Eval(givensToMap(givens))
    return fmt.Sprintf("%v", out.Value()), nil
}
```

### Migration Path

| Current | After | Notes |
|---------|-------|-------|
| `sql: SELECT CAST(10+25 AS CHAR)` | `expr: string(10 + 25)` | Pure arithmetic |
| `sql: SELECT LENGTH(...)...FROM yields...` | `expr: string(size(poem.split(" ")))` | Uses given instead of query |
| `sql: SELECT CASE WHEN ... THEN 'VERIFIED'...` | `expr: int(factors[0]) * int(factors[1]) == target ? "VERIFIED" : "FAILED"` | JSON + conditional |
| `dml: INSERT INTO ...` | Stays NonReplayable — uses store API | Separate concern |

### What About `sql:` Backward Compatibility?

Three options:

**A. Hard break** — Remove `sql:` entirely. Rewrite all examples.
Simple, clean, but breaks existing programs.

**B. Deprecate** — Keep `sql:` as a parser-recognized prefix that
triggers a warning, auto-convert where possible. Remove in v3.

**C. Dual mode** — Support both `sql:` (requires SQL backend) and
`expr:` (pure, no backend). Let programs choose.

**Recommendation: A (hard break).** There are only 13 files using
`sql:`, all in examples. The rewrite is mechanical — each sql: body
maps to an expr: body that references givens instead of querying tables.
The formal model already treats hard cells as Pure — making the
implementation match by removing the SQL dependency is correct.

### The Taxonomy After Rewrite

| Body Prefix | Effect Level | Evaluator | Backend Required |
|-------------|-------------|-----------|-----------------|
| `yield x = "value"` | Pure | Literal extraction | None |
| `expr: expression` | Pure | CEL evaluator | None |
| (soft body) | Replayable | LLM piston | LLM API |
| `effect: operation` | NonReplayable | Store API | Log store |

This is cleaner than the current split:

| Before | After |
|--------|-------|
| `literal:` → Pure, no eval | Same |
| `sql:` → Pure, requires SQL engine | `expr:` → Pure, requires CEL |
| (soft) → Replayable, requires LLM | Same |
| `dml:` → NonReplayable, requires SQL | `effect:` → NonReplayable, requires store |

### Impact on Oracles

Deterministic oracles (`check`) currently use auto-classification:
`not_empty`, `valid json array`, `permutation of`, etc. These could
also become CEL expressions:

```
check size(sorted) > 0                     -- was: check sorted is not empty
check json.isValid(sorted)                 -- was: check sorted is valid json array
check sorted.sort() == items.sort()        -- was: check sorted is a permutation of items
```

But this is a separate concern. The current oracle auto-classification
works and doesn't depend on SQL. Keep it for now.

### Impact on the Formal Model

The formal model (EffectEval.lean) classifies hard cells as Pure.
The `expr:` rewrite makes the implementation match: a Pure cell
evaluated by a deterministic function on its inputs.

The key proof property — **Pure determinism** (same inputs → same
outputs) — is trivially satisfied by CEL evaluation. The Lean proof
doesn't need to change.

### Impact on the Tuple Store Design

This resolves the hard cells question from the tuple store design:

**The log store (Approach A) is sufficient.** Hard cells don't need
SQL. They evaluate CEL expressions on resolved givens. The store
provides `Observe()` to resolve givens. The CEL evaluator is a pure
function. No SQL engine, no SQLite, no query interface needed.

This removes the strongest argument for Approach B (SQLite) and
confirms Approach A is the simplest correct design.

## Implementation Estimate

1. Add `cel-go` dependency — trivial (`go get`)
2. Add `expr:` body prefix to parser — ~20 lines in parse.go
3. Add CEL evaluation to eval loop — ~50 lines in eval.go
4. Rewrite 13 example files — mechanical, ~1 hour
5. Update tests — ~30 lines in e2e_test.go

Total: ~100 lines of Go + example rewrites. Half a day.

## Open Question: What About `dml:` (NonReplayable)?

DML cells that mutate state are a separate design. They use the
`effect:` prefix and execute against the store API. The isolation
story for NonReplayable cells is tracked in dc-4ry.

For now, the claim is: **all existing hard cells are Pure and should
use `expr:` instead of `sql:`.** DML is a future concern.

# Cell v2 Parser Specification

## Grammar (informal)

```
program     = (comment | cell_def)*
comment     = '--' REST_OF_LINE
cell_def    = 'cell' NAME ['(' modifier ')'] NEWLINE
              (yield_decl | given_decl | recur_decl | body_block | check_decl)*

modifier    = 'stem'

yield_decl  = INDENT 'yield' NAME ['=' LITERAL | ':' TYPE] NEWLINE
given_decl  = INDENT ('given' | 'given?') SOURCE '.' FIELD NEWLINE
recur_decl  = INDENT 'recur' ['until' GUARD_EXPR] '(' 'max' INT ')' NEWLINE
body_block  = INDENT '---' NEWLINE BODY_TEXT INDENT '---' NEWLINE
check_decl  = INDENT ('check' | 'check~') REST_OF_LINE NEWLINE

SOURCE      = NAME | NAME '[' (INT | '*') ']'
GUARD_EXPR  = FIELD '=' STRING
            | FIELD 'in' '[' STRING (',' STRING)* ']'
            | FIELD '>' NUMBER
            | FIELD 'is not empty'
NAME        = [a-zA-Z][a-zA-Z0-9_-]*
LITERAL     = '"' ... '"'
INDENT      = 2+ spaces
```

## Parsing Rules

### Cell Declaration
- Starts with `cell NAME` at column 0
- Optional `(stem)` modifier
- Everything indented below belongs to this cell until next `cell` or EOF

### Yields
- `yield NAME` — unfrozen output field
- `yield NAME = "value"` — hard literal (pre-frozen at pour time)
- `yield NAME : TYPE` — typed yield (future: pour-time type checking)

### Givens
- `given SOURCE.FIELD` — required dependency
- `given? SOURCE.FIELD` — optional dependency
- `given SOURCE[*].FIELD` — gather all iterations
- `given SOURCE[N].FIELD` — specific iteration instance

### Body
- Delimited by `---` on its own line (indented)
- Everything between the fences is the body text
- Body starting with `sql:` or `dml:` → hard computed cell
- Body with natural language → soft cell
- Guillemet references `«field»` are preserved as-is

### Recur
- `recur until GUARD (max N)` — guarded recursion with safety bound
- `recur (max N)` — unguarded, fixed iteration count (fallback)
- Guard expressions are SQL-checkable predicates on yield fields

### Checks
- `check CONDITION` — deterministic oracle (auto-classified)
- `check~ ASSERTION` — semantic oracle (generates judge cell)

## Derived Cell Kind (not declared, inferred)

| Condition | Kind |
|-----------|------|
| Has `yield NAME = VALUE`, no body | Hard literal |
| Body starts with `sql:` or `dml:` | Hard computed |
| Has `(stem)` modifier | Stem (permanently soft) |
| Has body with natural language | Soft |

## Effect Level (derived from kind)

| Kind | EffectLevel |
|------|-------------|
| Hard literal | Pure |
| Hard computed (SQL) | Pure |
| Soft | Semantic |
| Stem | Divergent |

## ID Generation (at pour time)

- Cell ID: `<program>-<cellname>` (e.g., `haiku-compose`)
- Yield ID: `y-<program>-<cellname>-<field>`
- Given ID: `g-<program>-<cellname>-<source>`
- Oracle ID: `o-<program>-<cellname>-<n>`

## Recur Expansion (at pour time or runtime)

### With guard (dynamic):
- Pour creates ONE cell + frame at gen 0
- Runtime evaluates, checks guard
- If guard fails and gen < max: create gen+1 frame, chain yields
- If guard passes or gen = max: freeze

### Without guard (static, like old ×N):
- Pour creates N frames at gen 0..N-1
- Each frame chains to previous
- All created upfront (backward compatible with ⊢∘ × N)

## Migration: Updating parse.go

The Phase B parser (`cmd/ct/parse.go`) needs these changes:

1. Replace `parseCellFile` to recognize `cell NAME` instead of `⊢ NAME`
2. Parse `---` fenced bodies instead of `∴` / `∴∴` prefix
3. Parse `given X.Y` instead of `given X→Y`
4. Parse `yield X = V` instead of `yield X ≡ V`
5. Parse `check` / `check~` instead of `⊨` / `⊨~`
6. Parse `recur until GUARD (max N)` for guarded recursion
7. Parse `(stem)` modifier on cell declarations
8. Parse `given X[*].Y` and `given X[N].Y` bracket syntax

The SQL generation (`cellsToSQL`) stays mostly the same — it produces the same INSERT statements regardless of surface syntax.

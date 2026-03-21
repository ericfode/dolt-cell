# Autopour Runtime Spec: Reify + Autopour for ct

*Sussmind — 2026-03-21*
*Bead: dc-2j4*

**The one sentence**: Add a `programs` table, an `is_autopour` yield flag,
a `.definition` given resolver, and a post-submit autopour hook to ct so
the cell language can express its own evaluator without SQL escape hatches.

---

## 1. Schema Changes

### 1a. New `programs` table

Tracks poured programs with their source text and autopour configuration.

```sql
CREATE TABLE IF NOT EXISTS programs (
    program_id    VARCHAR(64) PRIMARY KEY,
    source_text   MEDIUMTEXT NOT NULL
        COMMENT 'Original .cell source text, stored at pour time for reify',
    effect_bound  VARCHAR(16) NOT NULL DEFAULT 'nonReplayable'
        COMMENT 'Max effect level for autopoured children: pure|replayable|nonReplayable',
    fuel          INT NOT NULL DEFAULT 10
        COMMENT 'Autopour fuel budget. Each autopour decrements by 1. 0 = no autopour allowed.',
    parent_program VARCHAR(64) DEFAULT NULL
        COMMENT 'If this program was autopoured, the program that poured it',
    pour_depth    INT NOT NULL DEFAULT 0
        COMMENT 'Nesting depth in the autopour tower. Root programs = 0.',
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_programs_parent (parent_program)
);
```

**Migration**: Backfill existing programs from `SELECT DISTINCT program_id FROM cells`.
Set `source_text = ''` for legacy programs (reify returns empty for pre-autopour programs).

### 1b. Extend `yields` table

```sql
ALTER TABLE yields ADD COLUMN is_autopour BOOLEAN NOT NULL DEFAULT FALSE
    COMMENT 'If TRUE, frozen value is .cell text to be poured by the runtime';
```

### 1c. Update `ready_cells` view

No change needed — autopour yields are normal yields. The readiness check
is unchanged: a cell is ready when all non-optional givens have frozen sources.

---

## 2. Parser Changes (parse.go)

### 2a. `[autopour]` yield annotation

Grammar extension:

```
yield_decl  = INDENT 'yield' NAME ['=' LITERAL | ':' TYPE] ['[autopour]'] NEWLINE
```

The `[autopour]` annotation is optional, appears after the yield name (and
optional literal/type), before the newline.

**parsedYield struct change**:

```go
type parsedYield struct {
    fieldName string
    prebound  string // non-empty for yield NAME = VALUE
    autopour  bool   // true if [autopour] annotation present
}
```

**parseCellFileV2 change**: After parsing `yield NAME`, check for `[autopour]`
token. Set `autopour = true` if found.

**cellsToSQL change**: When generating INSERT for yields, include `is_autopour`:

```sql
INSERT INTO yields (id, cell_id, field_name, is_autopour)
VALUES ('y-prog-cell-field', 'prog-cell', 'field', TRUE);
```

### 2b. `.definition` given (reify)

Grammar extension:

```
given_decl  = INDENT ('given' | 'given?') SOURCE '.' FIELD NEWLINE
```

No grammar change — `.definition` is a regular field name. The magic is
in the **resolver**, not the parser. The parser treats `given foo.definition`
the same as `given foo.anything`.

The eval loop recognizes `.definition` as a built-in field during input
resolution (Section 4).

---

## 3. Pour Changes (pour.go)

### 3a. Store program source text

In `cmdPour`, after successful parse and SQL execution, insert into `programs`:

```go
func cmdPour(db *sql.DB, name, cellFile string) {
    data, err := os.ReadFile(cellFile)
    // ... existing parse logic ...

    // After successful pour, record program source
    mustExec(db,
        `INSERT INTO programs (program_id, source_text, fuel)
         VALUES (?, ?, ?)
         ON DUPLICATE KEY UPDATE source_text = VALUES(source_text)`,
        name, string(data), defaultFuel)
}
```

Where `defaultFuel` comes from a flag or constant (default: 10).

### 3b. Autopour-initiated pour

New function for pouring from an autopour yield (called from eval loop):

```go
// autopour pours a program from a yield value. Returns the new program_id or error.
func autopour(db *sql.DB, parentProgID, parentCellName, yieldField string,
              sourceText string, fuelRemaining int) (string, error) {

    // 1. Generate child program ID
    h := sha256.Sum256([]byte(sourceText))
    hash8 := hex.EncodeToString(h[:4])
    childProgID := fmt.Sprintf("ap-%s-%s-%s", parentProgID, parentCellName, hash8)

    // 2. Check fuel
    if fuelRemaining <= 0 {
        return "", fmt.Errorf("autopour: fuel exhausted (parent: %s)", parentProgID)
    }

    // 3. Parse the yielded text
    cells, err := parseCellFile(sourceText)
    if err != nil {
        return "", fmt.Errorf("autopour: parse failed: %w", err)
    }
    if cells == nil {
        return "", fmt.Errorf("autopour: no cells parsed from yield")
    }

    // 4. Check effect bound
    parentBound := getEffectBound(db, parentProgID)
    for _, c := range cells {
        if cellEffectLevel(c) > parentBound {
            return "", fmt.Errorf("autopour: cell %q exceeds effect bound %s",
                c.name, parentBound)
        }
    }

    // 5. Pour the child program
    sqlText := cellsToSQL(childProgID, cells)
    if _, err := db.Exec(sqlText); err != nil {
        return "", fmt.Errorf("autopour: pour failed: %w", err)
    }
    ensureFrames(db, childProgID)

    // 6. Record in programs table
    parentDepth := getPourDepth(db, parentProgID)
    mustExec(db,
        `INSERT INTO programs (program_id, source_text, fuel, parent_program, pour_depth)
         VALUES (?, ?, ?, ?, ?)`,
        childProgID, sourceText, fuelRemaining-1, parentProgID, parentDepth+1)

    mustExec(db, "CALL DOLT_COMMIT('-Am', ?)",
        fmt.Sprintf("autopour: %s poured %s (fuel=%d)", parentProgID, childProgID, fuelRemaining-1))

    return childProgID, nil
}
```

### 3c. Effect level helpers

```go
// cellEffectLevel derives the effect level from a parsed cell.
// Matches the v2 parser spec: hard=pure, soft=replayable, stem=nonReplayable.
// Cells with [autopour] yields are always nonReplayable.
func cellEffectLevel(c parsedCell) string {
    for _, y := range c.yields {
        if y.autopour {
            return "nonReplayable"
        }
    }
    switch c.bodyType {
    case "hard":
        return "pure"
    case "stem":
        return "nonReplayable"
    default:
        return "replayable"
    }
}

// effectLevelOrder returns numeric order for comparison.
func effectLevelOrder(level string) int {
    switch level {
    case "pure":
        return 0
    case "replayable":
        return 1
    case "nonReplayable":
        return 2
    default:
        return 2 // unknown = most restrictive
    }
}
```

---

## 4. Eval Loop Changes (eval.go)

### 4a. Post-submit autopour hook

After `cmdSubmit` successfully freezes a yield, check for autopour:

```go
func cmdSubmit(db *sql.DB, progID, cellName, field, value string) {
    result, msg := replSubmit(db, progID, cellName, field, value)
    switch result {
    case "ok":
        fmt.Printf("■ %s.%s frozen\n", cellName, field)

        // --- AUTOPOUR HOOK ---
        checkAndAutopour(db, progID, cellName, field, value)

        // Check program completion (existing logic)
        // ...
    }
}

func checkAndAutopour(db *sql.DB, progID, cellName, field, value string) {
    // Is this yield marked autopour?
    var isAutopour bool
    db.QueryRow(`
        SELECT y.is_autopour FROM yields y
        JOIN cells c ON c.id = y.cell_id
        WHERE c.program_id = ? AND c.name = ? AND y.field_name = ?`,
        progID, cellName, field).Scan(&isAutopour)

    if !isAutopour {
        return
    }

    // Get fuel from programs table (or CLI override)
    fuel := getFuel(db, progID)

    childID, err := autopour(db, progID, cellName, field, value, fuel)
    if err != nil {
        fmt.Printf("  ⊥ autopour failed: %v\n", err)
        // Bottom the autopour yield — mark it as error
        mustExec(db, `
            UPDATE yields y JOIN cells c ON c.id = y.cell_id
            SET y.value_text = ?, y.is_bottom = TRUE
            WHERE c.program_id = ? AND c.name = ? AND y.field_name = ?`,
            fmt.Sprintf("autopour:error:%v", err), progID, cellName, field)
        return
    }

    fmt.Printf("  ⊢ autopoured %s (fuel=%d)\n", childID, fuel-1)
}
```

### 4b. Reify resolver for `.definition`

In `resolveInputs`, handle the `.definition` special field:

```go
func resolveInputs(db *sql.DB, progID, cellName string) map[string]string {
    m := make(map[string]string)

    // ... existing given resolution logic ...

    // Handle .definition givens (reify)
    rows2, _ := db.Query(`
        SELECT g.source_cell FROM givens g
        JOIN cells c ON c.id = g.cell_id
        WHERE c.program_id = ? AND c.name = ? AND g.source_field = 'definition'`,
        progID, cellName)
    defer rows2.Close()
    for rows2.Next() {
        var sourceCell string
        rows2.Scan(&sourceCell)

        // Look up the source cell's program source text
        var sourceText string
        db.QueryRow(`
            SELECT p.source_text FROM programs p
            JOIN cells c ON c.program_id = p.program_id
            WHERE c.program_id = ? AND c.name = ?`,
            progID, sourceCell).Scan(&sourceText)

        if sourceText != "" {
            key := sourceCell + ".definition"
            m[key] = sourceText
            m[sourceCell + "→definition"] = sourceText
            m["definition"] = sourceText
        }
    }

    return m
}
```

**Note**: This resolves `.definition` to the *program's* source text, not
the individual cell's body. This matches Option C from the denotational
semantics doc (program-level reify). For cell-level reify (Option B), we'd
query the individual cell's body from the `cells` table — but program-level
is what autopour needs.

### 4c. Fuel retrieval

```go
// getFuel returns the autopour fuel for a program.
// CLI override (if set) takes precedence over the programs table.
func getFuel(db *sql.DB, progID string) int {
    if cliFuel > 0 {
        return cliFuel // from --fuel flag
    }
    var fuel int
    err := db.QueryRow("SELECT fuel FROM programs WHERE program_id = ?", progID).Scan(&fuel)
    if err != nil {
        return 0 // no programs record = no autopour allowed
    }
    return fuel
}
```

---

## 5. CLI Changes (main.go)

### 5a. New flag: `--fuel`

```go
var cliFuel int

func main() {
    // ... existing flag parsing ...
    flag.IntVar(&cliFuel, "fuel", 0, "autopour fuel budget (0 = use program default)")
    // ...
}
```

### 5b. Pour with fuel

```
ct pour NAME file.cell              # default fuel (10)
ct pour NAME file.cell --fuel 5     # explicit fuel
```

---

## 6. Interaction Summary

### Normal flow (no autopour)

Unchanged. Cells with no `[autopour]` yields work exactly as before.

### Autopour flow

```
1. ct pour my-meta meta.cell
   → Parser sees `yield evaluated [autopour]`
   → yields table: is_autopour = TRUE for that yield
   → programs table: source_text stored, fuel = 10

2. ct run my-meta  (or piston evaluates)
   → Piston resolves givens, including .definition → program source text
   → Piston evaluates soft cell body
   → Piston calls: ct submit my-meta evaluator evaluated '<.cell text>'

3. cmdSubmit freezes the yield
   → Post-submit hook: checkAndAutopour()
   → Fuel check: programs.fuel > 0? Yes (10)
   → Parse yielded text as .cell
   → Effect bound check: all cells ≤ parent effect level?
   → Pour child program: ap-my-meta-evaluator-abc123
   → programs table: child recorded, fuel = 9, parent = my-meta, depth = 1
   → Commit

4. ct run continues (or next piston picks up child program cells)
   → Child program cells appear in ready_cells
   → Normal evaluation proceeds
```

### Self-evaluation flow

```
1. cell-zero-autopour is poured with its own source as input
2. evaluator cell parses the source, yields it [autopour]
3. Runtime pours a copy: ap-cell-zero-autopour-evaluator-xxx
4. The copy's "request" cell has unsatisfied givens (no one provides program_text)
5. Copy is inert — DAG termination. No fuel consumed beyond the initial pour.
```

### Chained autopour (fuel consumption)

```
Program A (fuel=3) pours Program B (fuel=2) pours Program C (fuel=1)
Program C tries to autopour → fuel=0 → yield becomes bottom
Tower terminates at depth 3.
```

---

## 7. Error Handling

| Condition | Result | Yield state |
|-----------|--------|-------------|
| Fuel exhausted | Autopour skipped | `is_bottom = TRUE`, value = "autopour:error:fuel exhausted" |
| Parse failure | Poured text isn't valid .cell | `is_bottom = TRUE`, value = "autopour:error:parse failed: ..." |
| Effect violation | Child cell exceeds parent's effect bound | `is_bottom = TRUE`, value = "autopour:error:effect violation" |
| Program ID collision | Child program already exists | Skip pour (idempotent, content-addressed) |

All errors are **bottom propagation**: downstream cells that depend on
the autopoured program's yields get bottom because the program was never
poured.

---

## 8. Formal Alignment

| Formal concept (Autopour.lean) | Runtime implementation |
|---|---|
| `Val.program` | Yield with `is_autopour = TRUE` |
| `AutopourCtx.fuel` | `programs.fuel` column + `--fuel` CLI flag |
| `AutopourCtx.depth` | `programs.pour_depth` column |
| `AutopourCtx.step` | `fuel - 1` in `autopour()` function |
| `autopourStep` | `checkAndAutopour()` in eval.go |
| `ProgramText.source` | `programs.source_text` column |
| `Program.respectsEffectBound` | `cellEffectLevel()` check in `autopour()` |
| `selfEvalTower_terminates` | DAG termination (unsatisfied givens) + fuel bound |

---

## 9. Files to Modify

| File | Change | Size |
|------|--------|------|
| `schema/retort-init.sql` | Add `programs` table, `yields.is_autopour` | ~20 lines |
| `cmd/ct/parse.go` | Parse `[autopour]` annotation, add to `parsedYield` | ~15 lines |
| `cmd/ct/pour.go` | Store source in `programs` table, add `autopour()` function | ~60 lines |
| `cmd/ct/eval.go` | Post-submit hook, reify resolver, fuel retrieval | ~50 lines |
| `cmd/ct/main.go` | `--fuel` flag | ~3 lines |
| `cmd/ct/db.go` | Helper queries for programs table | ~20 lines |

**Total**: ~170 lines of Go, ~20 lines of SQL. No existing behavior changes.

---

## 10. Testing Plan

1. **Unit**: Parse `yield foo [autopour]` → `parsedYield{autopour: true}`
2. **Unit**: `cellEffectLevel` returns correct levels for all cell kinds
3. **Integration**: Pour a program with `[autopour]`, submit a .cell text value,
   verify child program appears in `cells` table
4. **Integration**: Verify fuel decrements across chained autopour
5. **Integration**: Verify effect bound violation → bottom
6. **Integration**: Verify parse failure → bottom
7. **E2E**: Run `cell-zero-autopour.cell` against a target program, verify
   the target is poured and evaluated
8. **E2E**: Self-evaluation: pour cell-zero-autopour with its own source,
   verify DAG termination (copy is inert)

---

## 11. What This Does NOT Cover

- **Dynamic observe** (watching poured program's yields) — separate feature
- **Structured reify** (cell definitions as records) — future enhancement
- **RetortStore interface** (Phase 1 of implementation plan) — separate bead
- **Effect taxonomy unification** (Core.lean alignment) — dc-21q
- **Formal proofs** (DAG preservation, effect monotonicity) — dc-yf0

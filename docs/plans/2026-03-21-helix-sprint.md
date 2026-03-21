# Helix Sprint: Autopour Runtime + Effect Unification

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire the already-parsed `[autopour]` annotation through schema, SQL generation, and eval loop so that autopour yields actually pour programs at runtime. Then unify the effect taxonomy across Core.lean and Denotational.lean.

**Architecture:** The parser already sets `parsedYield.autopour=true`. We add `is_autopour` to the yields table, persist the flag at pour time via `cellsToSQL`, and add a post-freeze hook in `replSubmit` that parses and pours the yielded text when `is_autopour=true`. Fuel counter in eval context prevents infinite regress. Effect unification replaces Core.lean's `EffectLevel (pure/semantic/divergent)` with the canonical `EffLevel (pure/replayable/nonReplayable)` from EffectEval.lean, and updates Denotational.lean to match.

**Tech Stack:** Go (cmd/ct), SQL (Dolt), Lean 4 (formal/)

---

### Task 1: Commit the autopour parser fix

**Files:**
- Already modified: `cmd/ct/parse.go`, `cmd/ct/parse_test.go`

**Step 1: Verify tests pass**

Run: `cd cmd/ct && go test ./... -count=1`
Expected: 85 pass, 0 fail

**Step 2: Commit**

```bash
git add cmd/ct/parse.go cmd/ct/parse_test.go
git commit -m "feat(parser): support [autopour] annotation on yield declarations

Parse [autopour] in both v1 and v2 syntax paths, strip annotation
from field name, set parsedYield.autopour flag. Fixes 3 test failures
from cell-zero-autopour.cell."
```

---

### Task 2: Add `is_autopour` column to yields table

**Files:**
- Modify: `schema/retort-init.sql:55-68` (yields table)

**Step 1: Write schema migration test**

Add to `cmd/ct/e2e_test.go` a test that verifies is_autopour column exists after init:

```go
func TestYieldsHasAutopourColumn(t *testing.T) {
    // Test that cellsToSQL generates is_autopour for autopour yields
    cells := []parsedCell{{
        name:     "eval",
        bodyType: "soft",
        yields:   []parsedYield{{fieldName: "result", autopour: true}},
    }}
    sql := cellsToSQL(cells, "test-prog")
    if !strings.Contains(sql, "is_autopour") {
        t.Error("expected is_autopour in generated SQL for autopour yield")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd cmd/ct && go test -run TestYieldsHasAutopourColumn -v`
Expected: FAIL (cellsToSQL doesn't emit is_autopour yet)

**Step 3: Add column to schema**

In `schema/retort-init.sql`, add to yields table:

```sql
is_autopour BOOLEAN NOT NULL DEFAULT FALSE
    COMMENT 'When TRUE, runtime pours the yielded value as a .cell program after freeze',
```

**Step 4: Update `cellsToSQL` to emit `is_autopour`**

In `cmd/ct/parse.go` function `cellsToSQL`, modify the yield INSERT statements to include `is_autopour` when the flag is set.

For the prebound (frozen) path (~line 690):
```go
// Add is_autopour column when flag is set
autopourVal := "FALSE"
if y.autopour {
    autopourVal = "TRUE"
}
```

For the normal (unfrozen) path (~line 694):
```go
sb.WriteString(fmt.Sprintf(
    "INSERT INTO yields (id, cell_id, frame_id, field_name, is_autopour) VALUES ('%s', '%s', %s, '%s', %s);\n",
    escape(yID), escape(cellID), frameIDVal, escape(y.fieldName), autopourVal))
```

**Step 5: Run test to verify it passes**

Run: `cd cmd/ct && go test -run TestYieldsHasAutopourColumn -v`
Expected: PASS

**Step 6: Run full test suite**

Run: `cd cmd/ct && go test ./... -count=1`
Expected: all pass

**Step 7: Commit**

```bash
git add schema/retort-init.sql cmd/ct/parse.go cmd/ct/parse_test.go  # or e2e_test.go
git commit -m "feat(schema): add is_autopour column to yields table

Persist autopour flag from parser through to the database.
cellsToSQL now emits is_autopour=TRUE for [autopour] yields."
```

---

### Task 3: Autopour runtime — pour yielded programs after freeze

**Files:**
- Modify: `cmd/ct/eval.go` (replSubmit, after freeze block ~line 1142-1188)

**Step 1: Write failing test**

Add to `cmd/ct/parse_test.go`:

```go
func TestAutopourCellZeroParsesClean(t *testing.T) {
    // Verify cell-zero-autopour.cell parses and the evaluator cell
    // has an autopour yield
    data, err := os.ReadFile("../../examples/cell-zero-autopour.cell")
    if err != nil {
        t.Skip("cell-zero-autopour.cell not found")
    }
    cells, err := parseCellFile(string(data))
    if err != nil {
        t.Fatalf("parse error: %v", err)
    }
    found := false
    for _, c := range cells {
        for _, y := range c.yields {
            if y.autopour {
                found = true
                if c.name != "evaluator" && c.name != "perpetual-evaluator" {
                    t.Errorf("unexpected autopour cell: %s", c.name)
                }
            }
        }
    }
    if !found {
        t.Error("no autopour yield found in cell-zero-autopour.cell")
    }
}
```

**Step 2: Run test — should PASS (parser already works)**

Run: `cd cmd/ct && go test -run TestAutopourCellZeroParsesClean -v`

**Step 3: Implement autopour in replSubmit**

After the freeze block (after stem respawn, before return), add:

```go
// Autopour: if the frozen yield has is_autopour=TRUE and contains
// valid .cell text, pour the program into the retort.
// Fuel counter prevents infinite regress.
if unfrozen == 0 {
    autopourYields(db, progID, cellID)
}
```

New function `autopourYields`:

```go
// autopourYields checks for autopour yields on a freshly frozen cell.
// If found, parses and pours the yielded program text.
func autopourYields(db *sql.DB, progID, cellID string) {
    rows, err := db.Query(
        "SELECT field_name, value_text FROM yields WHERE cell_id = ? AND is_autopour = TRUE AND is_frozen = TRUE AND value_text IS NOT NULL AND value_text != ''",
        cellID)
    if err != nil || rows == nil {
        return
    }
    defer rows.Close()

    for rows.Next() {
        var fieldName, valueText string
        if err := rows.Scan(&fieldName, &valueText); err != nil {
            continue
        }

        // Parse the yielded text as a .cell program
        cells, parseErr := parseCellFile(valueText)
        if parseErr != nil || cells == nil {
            log.Printf("autopour: %s.%s: parse failed: %v", cellID, fieldName, parseErr)
            continue
        }

        // Generate a program name: <parent>-autopour-<field>
        subProgID := fmt.Sprintf("%s-ap-%s", progID, fieldName)

        // Generate and execute the pour SQL
        sql := cellsToSQL(cells, subProgID)
        for _, stmt := range splitSQL(sql) {
            stmt = strings.TrimSpace(stmt)
            if stmt == "" || stmt == "USE retort" {
                continue
            }
            execDB(db, stmt)
        }

        mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
            fmt.Sprintf("cell: autopour %s from %s.%s", subProgID, cellID, fieldName))
        log.Printf("autopour: poured %s from %s.%s (%d cells)", subProgID, cellID, fieldName, len(cells))
    }
}
```

**Step 4: Run full test suite**

Run: `cd cmd/ct && go test ./... -count=1`
Expected: all pass (autopour logic only triggers when is_autopour=TRUE in DB)

**Step 5: Commit**

```bash
git add cmd/ct/eval.go cmd/ct/parse_test.go
git commit -m "feat(eval): autopour runtime — pour yielded programs after freeze

When a cell freezes and has is_autopour=TRUE yields with non-empty
value_text, parse the text as a .cell program and pour it into
the retort. Program name: <parent>-ap-<field>.

No fuel counter yet (deferred — needs eval context threading)."
```

---

### Task 4: Effect taxonomy — unify Core.lean

**Files:**
- Modify: `formal/Core.lean:67-76`
- Modify: `formal/Denotational.lean:70-82,112`

**Step 1: Replace EffectLevel in Core.lean**

Replace:
```lean
inductive EffectLevel where
  | pure       -- hard cells: deterministic, no LLM
  | semantic   -- soft cells: LLM-evaluated, may vary
  | divergent  -- stem cells: permanently soft, cycles
  deriving Repr, DecidableEq, BEq
```

With the canonical taxonomy:
```lean
inductive EffLevel where
  | pure           -- deterministic, retryable (hard cells)
  | replayable     -- bounded nondeterminism, retryable with oracle (soft cells)
  | nonReplayable  -- world-mutating: DML, beads, autopour (NonReplayable cells)
  deriving Repr, DecidableEq, BEq

def EffLevel.toNat : EffLevel → Nat
  | .pure => 0
  | .replayable => 1
  | .nonReplayable => 2

instance : LE EffLevel where
  le a b := a.toNat ≤ b.toNat

instance (a b : EffLevel) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (a.toNat ≤ b.toNat))
```

**Step 2: Update Denotational.lean**

Replace `EffectLevel` references with `EffLevel` from Core.lean. Remove the local `EffectLevel.le` definition and use the one from Core.

**Step 3: Build formal proofs**

Run: `cd formal && lake build`
Expected: Fix any compile errors from the rename

**Step 4: Verify EffectEval.lean still compiles**

EffectEval.lean defines its own `EffLevel` — after Core.lean also exports it, there will be a name collision. Options:
- a) Use `Core.EffLevel` qualification in EffectEval
- b) Remove the duplicate from EffectEval and import from Core
- c) Use `open Core in` scoping

Choose (b): remove EffLevel definition from EffectEval.lean, import from Core.

**Step 5: Build and verify all Lean files compile**

Run: `cd formal && lake build`
Expected: clean compile

**Step 6: Commit**

```bash
git add formal/Core.lean formal/Denotational.lean formal/EffectEval.lean formal/Autopour.lean
git commit -m "formal: unify effect taxonomy — EffLevel in Core.lean

Replace Core.EffectLevel (pure/semantic/divergent) with canonical
EffLevel (pure/replayable/nonReplayable). Update Denotational.lean
and EffectEval.lean to use the shared definition.

Closes Phase 3 of the implementation plan."
```

---

### Task 5: Final verification and push

**Step 1: Run Go tests**

Run: `cd cmd/ct && go test ./... -count=1`
Expected: all pass

**Step 2: Run Lean build**

Run: `cd formal && lake build`
Expected: clean compile

**Step 3: Push**

```bash
git push
```

---

## Dependency Graph

```
Task 1 (commit parser fix)
  ↓
Task 2 (schema + cellsToSQL)
  ↓
Task 3 (autopour runtime)

Task 4 (effect unification) — independent of Tasks 2-3

Task 5 (verify + push) — depends on all above
```

## What This Does NOT Include

- **Fuel counter / eval context** — needs deeper threading through cmdRun/cmdPiston. Deferred.
- **Reify primitive** (`given target.definition`) — Phase 2a, separate work.
- **RetortStore interface** — Phase 1, assigned to glassblower. Large refactor.
- **Sorry hole filling** — formal work, separate session.
- **Integration testing with Gas City** — Phase 4, needs autopour working first.

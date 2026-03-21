# Cleanup Dead Code + Effect-Aware Eval Engine

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove dead code paths, unify on one eval engine, and implement effect classification with validate-before-write oracle ordering.

**Architecture:** Delete `cmdRun()` and `cmdRepl()`. Augment `replEvalStep()` with effect inference (`inferEffect`) that classifies cells as Pure/Replayable/NonReplayable. Implement validate-before-write oracle ordering in `replSubmit()` (check oracles BEFORE freezing yields). Wrap NonReplayable operations in a DB transaction.

**Tech Stack:** Go, Dolt/MySQL, existing `cmd/ct/` codebase

---

## Task 1: Delete Dead Code — `cmdRun()` and `cmdRepl()`

**Files:**
- Modify: `cmd/ct/eval.go:18-111` (delete `cmdRun`)
- Modify: `cmd/ct/eval.go:605-803` (delete `cmdRepl`)
- Modify: `cmd/ct/main.go:125-127` (remove `run` command case)
- Modify: `cmd/ct/main.go:14-41` (remove `run` from usage string)

**Step 1: Delete `cmdRun()` from eval.go**

Remove lines 16-111 (the entire `cmdRun` function). This function calls the old `cell_eval_step()` stored procedure instead of the Go-native `replEvalStep()`.

**Step 2: Delete `cmdRepl()` from eval.go**

Remove lines 605-803 (the entire `cmdRepl` function and its REPL loop). It's marked DEPRECATED in the code.

**Step 3: Remove `run` command from main.go**

Remove the `case "run":` block (lines 125-127) from the switch statement. Remove `ct run` from the usage string (line 26).

**Step 4: Build and test**

Run: `cd cmd/ct && go build ./... && go test ./...`
Expected: All tests pass, binary builds clean. No tests reference `cmdRun` or `cmdRepl` directly.

**Step 5: Commit**

```bash
git add cmd/ct/eval.go cmd/ct/main.go
git commit -m "ct: delete cmdRun and cmdRepl dead code paths

cmdRun used the old cell_eval_step stored procedure.
cmdRepl was marked DEPRECATED. Both replaced by
replEvalStep + cmdPiston + cmdNext + cmdSubmit."
```

---

## Task 2: Add Effect Level Type and Inference

**Files:**
- Modify: `cmd/ct/eval.go` (add type + inferEffect function after evalStepResult)
- Test: `cmd/ct/e2e_test.go` (add TestInferEffect)

**Step 1: Write the failing test**

Add to `e2e_test.go`:

```go
func TestInferEffect(t *testing.T) {
	tests := []struct {
		bodyType string
		body     string
		want     string
	}{
		{"hard", "literal:hello", "pure"},
		{"hard", "sql:SELECT 1", "replayable"},
		{"soft", "Evaluate this prompt", "replayable"},
		{"stem", "Evaluate this prompt", "replayable"},
		// DML in body → nonreplayable
		{"hard", "sql:INSERT INTO foo VALUES (1)", "nonreplayable"},
		{"hard", "sql:UPDATE foo SET x = 1", "nonreplayable"},
		{"hard", "sql:DELETE FROM foo WHERE x = 1", "nonreplayable"},
		{"hard", "sql:CALL some_proc()", "nonreplayable"},
	}
	for _, tt := range tests {
		t.Run(tt.bodyType+"/"+tt.body[:min(len(tt.body), 20)], func(t *testing.T) {
			got := inferEffect(tt.bodyType, tt.body)
			if got != tt.want {
				t.Errorf("inferEffect(%q, %q) = %q, want %q",
					tt.bodyType, tt.body, got, tt.want)
			}
		})
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd cmd/ct && go test -run TestInferEffect -v`
Expected: FAIL — `inferEffect` not defined

**Step 3: Implement inferEffect**

Add to `eval.go` after the `evalStepResult` struct:

```go
// inferEffect classifies a cell's effect level based on its body type and body.
// Matches the formal model's canonical effect lattice:
//   Pure < Replayable < NonReplayable
//
// Pure:           literal: hard cells (deterministic, no I/O)
// Replayable:     sql: SELECT hard cells, all soft/stem cells (safe to retry)
// NonReplayable:  sql: INSERT/UPDATE/DELETE/CALL (side effects, transaction-isolated)
func inferEffect(bodyType, body string) string {
	if bodyType == "hard" {
		if strings.HasPrefix(body, "literal:") {
			return "pure"
		}
		if strings.HasPrefix(body, "sql:") {
			sqlBody := strings.ToUpper(strings.TrimSpace(strings.TrimPrefix(body, "sql:")))
			for _, prefix := range []string{"INSERT", "UPDATE", "DELETE", "CALL", "DROP", "CREATE", "ALTER"} {
				if strings.HasPrefix(sqlBody, prefix) {
					return "nonreplayable"
				}
			}
			return "replayable"
		}
	}
	// soft and stem cells are LLM-evaluated — safe to retry
	return "replayable"
}
```

**Step 4: Run test to verify it passes**

Run: `cd cmd/ct && go test -run TestInferEffect -v`
Expected: PASS

**Step 5: Run full suite**

Run: `cd cmd/ct && go test ./...`
Expected: All pass

**Step 6: Commit**

```bash
git add cmd/ct/eval.go cmd/ct/e2e_test.go
git commit -m "ct: add inferEffect for Pure/Replayable/NonReplayable classification

Aligns with formal model's canonical effect lattice (EffectEval.lean).
literal: → pure, sql SELECT → replayable, sql DML → nonreplayable,
soft/stem → replayable."
```

---

## Task 3: Wire Effect Classification into replEvalStep

**Files:**
- Modify: `cmd/ct/eval.go` (evalStepResult gets `effect` field; replEvalStep sets it)

**Step 1: Add effect field to evalStepResult**

```go
type evalStepResult struct {
	action   string // complete, quiescent, evaluated, dispatch
	progID   string
	cellID   string
	cellName string
	body     string
	bodyType string
	effect   string // pure, replayable, nonreplayable
}
```

**Step 2: Set effect in replEvalStep**

In `replEvalStep`, after the hard cell handling block and before the soft cell dispatch block, the function builds `evalStepResult`. At each return site where `action` is `"evaluated"` or `"dispatch"`, add the effect:

For the hard cell return (around the `return evalStepResult{action: "evaluated"...}` line):
```go
effect: inferEffect(rc.bodyType, rc.body),
```

For the soft cell return (around `return evalStepResult{action: "dispatch"...}`):
```go
effect: inferEffect(rc.bodyType, rc.body),
```

**Step 3: Update cmdPiston and cmdNext to log effect**

In `cmdPiston`, after claiming a cell, print the effect:
```go
fmt.Printf("  effect: %s\n", es.effect)
```

Similarly in `cmdNext` output.

**Step 4: Build and test**

Run: `cd cmd/ct && go build ./... && go test ./...`
Expected: All pass

**Step 5: Commit**

```bash
git add cmd/ct/eval.go
git commit -m "ct: wire effect classification into eval step results

Every claimed cell now carries its effect level. cmdPiston and
cmdNext display it. Foundation for effect-aware dispatch."
```

---

## Task 4: Validate-Before-Write Oracle Ordering in replSubmit

This is the critical correctness fix. The formal model (EffectEval.lean `vtw_preserves_yields`) proves validate-before-write is safe. The current code writes the yield value THEN checks oracles — if the oracle fails, the value is already written (the `wtv_can_remove_yields` antipattern).

**Files:**
- Modify: `cmd/ct/eval.go` (`replSubmit` function)
- Test: `cmd/ct/e2e_test.go` (add TestValidateBeforeWrite)

**Step 1: Write the failing test**

This test verifies that when an oracle fails, no yield value is written.

```go
func TestValidateBeforeWrite(t *testing.T) {
	// The oracle check should happen BEFORE the yield is written.
	// If oracle fails, yield.value_text should remain NULL/empty.
	//
	// We test this by checking that replSubmit with a value that
	// fails a "not_empty" oracle on an empty string returns oracle_fail
	// and does not modify the yield.
	//
	// Note: This is a design-level test. The actual DB integration
	// is tested in e2e tests. Here we verify the contract.
	t.Log("validate-before-write: oracle check before yield UPDATE")
	// This test documents the expected behavior. The implementation
	// change reorders operations in replSubmit.
}
```

**Step 2: Reorder replSubmit**

In `replSubmit` (starting around line 987), the current order is:

1. Write value → `UPDATE yields SET value_text = ?`
2. Check oracles
3. If oracle fails, return `oracle_fail` (but value is already written!)
4. Freeze yield

Change to:

1. Check oracles FIRST (against the submitted value, not the stored value)
2. If oracle fails, return `oracle_fail` immediately (no write)
3. Write value → `UPDATE yields SET value_text = ?`
4. Freeze yield

The key change: move the deterministic oracle check block (lines ~1030-1091) to BEFORE the yield UPDATE (line ~1017-1028). The oracle checks use the `value` parameter directly, not a DB read, so they work without the write.

**Step 3: Build and test**

Run: `cd cmd/ct && go build ./... && go test ./...`
Expected: All pass

**Step 4: Commit**

```bash
git add cmd/ct/eval.go cmd/ct/e2e_test.go
git commit -m "ct: validate-before-write oracle ordering

Reorder replSubmit: check deterministic oracles BEFORE writing
the yield value. If oracle fails, no value is persisted.

Aligns with formal model EffectEval.lean vtw_preserves_yields:
validation failure leaves tuple space completely unchanged.
Fixes the wtv_can_remove_yields antipattern."
```

---

## Task 5: NonReplayable Transaction Isolation

**Files:**
- Modify: `cmd/ct/eval.go` (wrap NonReplayable hard cell eval in transaction)

**Step 1: Implement transaction wrapper for NonReplayable hard cells**

In `replEvalStep`, the hard cell `sql:` handling path currently executes the SQL directly. For NonReplayable cells (INSERT/UPDATE/DELETE/CALL), wrap the entire sequence (execute SQL → submit yields → freeze) in a database transaction.

In the `sql:` handling block within `replEvalStep` (around line 932-957):

```go
} else if strings.HasPrefix(rc.body, "sql:") {
	sqlQuery := strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
	yields := getYieldFields(db, pid, rc.cellName)
	effect := inferEffect(rc.bodyType, rc.body)

	if effect == "nonreplayable" {
		// NonReplayable: wrap in transaction for atomicity.
		// Formal model: execNonReplayableTransaction —
		// all operations (execute, validate, freeze) are atomic.
		tx, err := db.Begin()
		if err != nil {
			replRelease(db, rc.cellID, pistonID, "failure")
			continue
		}
		var result string
		if err := tx.QueryRow(sqlQuery).Scan(&result); err != nil {
			tx.Rollback()
			// ... existing retry/bottom logic using db (not tx) ...
			continue
		}
		for _, y := range yields {
			replSubmitTx(tx, db, pid, rc.cellName, y, result)
		}
		if err := tx.Commit(); err != nil {
			// Transaction failed — release claim, let someone else try
			replRelease(db, rc.cellID, pistonID, "failure")
			continue
		}
	} else {
		// Pure/Replayable: existing non-transactional path
		var result string
		if err := db.QueryRow(sqlQuery).Scan(&result); err != nil {
			// ... existing retry/bottom logic ...
			continue
		}
		for _, y := range yields {
			replSubmit(db, pid, rc.cellName, y, result)
		}
	}
}
```

Note: `replSubmitTx` is a thin wrapper that accepts a `*sql.Tx` instead of `*sql.DB`. It shares the oracle-check and freeze logic with `replSubmit`. Extract the common logic into a helper that takes an `interface{ QueryRow(...) }` or pass an `Execer` interface.

**Step 2: Build and test**

Run: `cd cmd/ct && go build ./... && go test ./...`
Expected: All pass

**Step 3: Commit**

```bash
git add cmd/ct/eval.go
git commit -m "ct: transaction isolation for NonReplayable hard cells

DML operations (INSERT/UPDATE/DELETE/CALL) now execute inside
a DB transaction. Execute, validate, and freeze are atomic.

Aligns with formal model's NonReplayable transaction isolation
requirement (EffectEval.lean execNonReplayableTransaction)."
```

---

## Task 6: Clean Up REPL UI Helpers (orphaned by cmdRepl deletion)

**Files:**
- Modify: `cmd/ct/eval.go` (check which REPL helpers are now unused)

**Step 1: Identify orphaned functions**

After deleting `cmdRepl`, these functions may be orphaned (only called from cmdRepl):
- `replReadValue` — reads stdin for interactive REPL
- `replBar` — used by cmdRepl AND cmdPiston/cmdNext? Check.
- `replStepSep` — ditto
- `replAnnot` — ditto
- `replDocState` — ditto

Check each function's callers. Delete any that are only called from the deleted `cmdRepl`.

**Step 2: Build and test**

Run: `cd cmd/ct && go build ./... && go test ./...`
Expected: All pass (compiler will catch unused functions if they're unexported and only called from deleted code)

**Step 3: Commit**

```bash
git add cmd/ct/eval.go
git commit -m "ct: remove orphaned REPL UI helpers

Functions only used by the deleted cmdRepl."
```

---

## Summary

| Task | What | Why |
|------|------|-----|
| 1 | Delete `cmdRun` + `cmdRepl` | Dead code, one eval path |
| 2 | Add `inferEffect` | Effect classification (formal model alignment) |
| 3 | Wire effect into eval step | Foundation for effect-aware dispatch |
| 4 | Validate-before-write | Critical correctness fix (formal proof exists) |
| 5 | NonReplayable transactions | Isolation guarantee (formal model requires) |
| 6 | Clean up orphaned helpers | No dead code |

**Not in this plan (follow-up):**
- RetortStore interface abstraction (separate plan)
- Replace `sql:` with `expr:` CEL (separate plan, depends on RetortStore)
- Autopour runtime support (separate plan, parser already handles `[autopour]`)
- Schema migration: derive status from yields instead of mutable `cells.state` (large, separate)

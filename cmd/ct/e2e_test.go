package main

import (
	"database/sql"
	"os"
	"testing"

	_ "github.com/go-sql-driver/mysql"
)

// TestE2E_HardCellProgram tests the full pour → eval → freeze loop
// using a hard-cell-only program (no LLM needed).
func TestE2E_HardCellProgram(t *testing.T) {
	dsn := os.Getenv("RETORT_DSN")
	if dsn == "" {
		t.Skip("RETORT_DSN not set — skipping e2e test (needs live Dolt)")
	}

	db, err := sql.Open("mysql", dsn+"?multiStatements=true&parseTime=true&tls=false")
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		t.Fatalf("ping: %v", err)
	}

	progID := "e2e-hard-test"

	// Setup: parse and pour a hard-cell-only program
	cellText := `cell input
  yield value = "42"

cell double
  given input.value
  yield result
  ---
  sql: SELECT CAST(y.value_text AS UNSIGNED) * 2 FROM yields y JOIN cells c ON y.cell_id = c.id WHERE c.program_id = 'e2e-hard-test' AND c.name = 'input' AND y.field_name = 'value' AND y.is_frozen = 1
  ---
`

	// Clean up from previous runs
	resetProgram(db, progID)

	// Parse
	cells := parseCellFile(cellText)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if len(cells) != 2 {
		t.Fatalf("expected 2 cells, got %d", len(cells))
	}

	// Pour
	sqlText := cellsToSQL(progID, cells)
	if _, err := db.Exec(sqlText); err != nil {
		if !contains(err.Error(), "nothing to commit") {
			t.Fatalf("pour SQL: %v", err)
		}
	}
	ensureFrames(db, progID)

	// Verify cells exist
	var cellCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&cellCount)
	if cellCount != 2 {
		t.Fatalf("expected 2 cells after pour, got %d", cellCount)
	}

	// Run eval loop (should freeze both hard cells)
	pistonID := "e2e-test-piston"
	maxSteps := 10
	for step := 0; step < maxSteps; step++ {
		es := replEvalStep(db, progID, pistonID, "")
		switch es.action {
		case "complete":
			goto done
		case "quiescent":
			goto done
		case "evaluated":
			continue // hard cell frozen, next
		case "dispatch":
			t.Fatalf("step %d: got dispatch for soft cell %q — e2e test should be hard-cell-only", step, es.cellName)
		default:
			t.Fatalf("step %d: unexpected action %q", step, es.action)
		}
	}
	t.Fatal("eval loop did not complete within maxSteps")

done:
	// Verify all cells frozen
	var frozenCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'frozen'", progID).Scan(&frozenCount)
	if frozenCount != 2 {
		t.Errorf("expected 2 frozen cells, got %d", frozenCount)
	}

	// Verify yields
	var inputVal, doubleVal string
	db.QueryRow("SELECT y.value_text FROM yields y JOIN cells c ON y.cell_id = c.id WHERE c.program_id = ? AND c.name = 'input' AND y.field_name = 'value' AND y.is_frozen = 1",
		progID).Scan(&inputVal)
	if inputVal != "42" {
		t.Errorf("input.value = %q, want '42'", inputVal)
	}

	db.QueryRow("SELECT y.value_text FROM yields y JOIN cells c ON y.cell_id = c.id WHERE c.program_id = ? AND c.name = 'double' AND y.field_name = 'result' AND y.is_frozen = 1",
		progID).Scan(&doubleVal)
	if doubleVal != "84" {
		t.Errorf("double.result = %q, want '84'", doubleVal)
	}

	// Verify frames exist
	var frameCount int
	db.QueryRow("SELECT COUNT(*) FROM frames WHERE program_id = ?", progID).Scan(&frameCount)
	if frameCount < 2 {
		t.Errorf("expected at least 2 frames, got %d", frameCount)
	}

	// Verify bindings exist
	var bindingCount int
	db.QueryRow(`SELECT COUNT(*) FROM bindings b
		JOIN frames f ON f.id = b.consumer_frame
		WHERE f.program_id = ?`, progID).Scan(&bindingCount)
	if bindingCount < 1 {
		t.Errorf("expected at least 1 binding, got %d", bindingCount)
	}

	// Cleanup
	resetProgram(db, progID)

	t.Logf("✓ e2e hard-cell test: 2 cells poured, evaluated, frozen; yields correct; frames + bindings recorded")
}

// TestE2E_GuardSkip tests that guarded iteration cells are bottomed when guard is satisfied.
func TestE2E_GuardSkip(t *testing.T) {
	dsn := os.Getenv("RETORT_DSN")
	if dsn == "" {
		t.Skip("RETORT_DSN not set — skipping e2e test (needs live Dolt)")
	}

	db, err := sql.Open("mysql", dsn+"?multiStatements=true&parseTime=true&tls=false")
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer db.Close()

	progID := "e2e-guard-test"

	// A program with recur and a hard literal that satisfies the guard immediately
	cellText := `cell seed
  yield text = "DONE"
  yield settled = "SETTLED"

cell refine (stem)
  given seed.text
  yield text
  yield settled
  recur until settled = "SETTLED" (max 3)
  ---
  Return text unchanged.
  ---
`

	resetProgram(db, progID)
	cells := parseCellFile(cellText)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sqlText := cellsToSQL(progID, cells)
	if _, err := db.Exec(sqlText); err != nil {
		if !contains(err.Error(), "nothing to commit") {
			t.Fatalf("pour: %v", err)
		}
	}
	ensureFrames(db, progID)

	// Run eval loop — should freeze seed (hard) then dispatch refine-1 (soft)
	pistonID := "e2e-guard-piston"
	for step := 0; step < 5; step++ {
		es := replEvalStep(db, progID, pistonID, "")
		if es.action == "complete" || es.action == "quiescent" {
			break
		}
		if es.action == "dispatch" {
			// Soft cell — submit with SETTLED to trigger guard
			replSubmit(db, progID, es.cellName, "text", "DONE")
			replSubmit(db, progID, es.cellName, "settled", "SETTLED")
		}
	}

	// Verify: refine-2 and refine-3 should be bottom
	var bottomCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'bottom'", progID).Scan(&bottomCount)
	if bottomCount < 2 {
		t.Errorf("expected at least 2 bottom cells (refine-2, refine-3), got %d", bottomCount)
	}

	resetProgram(db, progID)
	t.Logf("✓ e2e guard skip: refine-1 settled → %d cells bottomed", bottomCount)
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsAt(s, substr))
}

func containsAt(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

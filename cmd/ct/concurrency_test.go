package main

import (
	"database/sql"
	"fmt"
	"os"
	"sync"
	"testing"

	_ "github.com/go-sql-driver/mysql"
)

// openTestDBs returns two separate connection pools: setupDB for
// resetProgram/pour (which taints connections via dolt_transaction_commit=0),
// and evalDB for clean replEvalStep calls.
func openTestDBs(t *testing.T) (setupDB, evalDB *sql.DB) {
	t.Helper()
	dsn := os.Getenv("RETORT_DSN")
	if dsn == "" {
		t.Skip("RETORT_DSN not set — skipping (needs live Dolt)")
	}
	connStr := dsn + "?multiStatements=true&parseTime=true&tls=false"

	var err error
	setupDB, err = sql.Open("mysql", connStr)
	if err != nil {
		t.Fatalf("connect setup: %v", err)
	}
	t.Cleanup(func() { setupDB.Close() })
	if err := setupDB.Ping(); err != nil {
		t.Fatalf("ping setup: %v", err)
	}

	evalDB, err = sql.Open("mysql", connStr)
	if err != nil {
		t.Fatalf("connect eval: %v", err)
	}
	t.Cleanup(func() { evalDB.Close() })
	if err := evalDB.Ping(); err != nil {
		t.Fatalf("ping eval: %v", err)
	}
	return setupDB, evalDB
}

// pourTestProgram resets and pours a program from a Lua source string.
func pourTestProgram(t *testing.T, setupDB *sql.DB, progID, luaSrc string) []parsedCell {
	t.Helper()
	resetProgram(setupDB, progID)
	tmpFile := writeTempLua(t, luaSrc)
	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram: %v", err)
	}
	sqlText := cellsToSQL(progID, cells)
	if _, err := setupDB.Exec(sqlText); err != nil {
		if !contains(err.Error(), "nothing to commit") {
			t.Fatalf("pour SQL: %v", err)
		}
	}
	ensureFrames(setupDB, progID)
	return cells
}

// TestConcurrency_ExactlyOnePistonClaimsCell verifies the formal claim mutex
// (Claims.lean claimStep): when N pistons race to claim the same ready cell,
// exactly one succeeds. INSERT IGNORE + UNIQUE(frame_id) provides the guarantee.
func TestConcurrency_ExactlyOnePistonClaimsCell(t *testing.T) {
	setupDB, db := openTestDBs(t)
	progID := "conc-claim-test"

	pourTestProgram(t, setupDB, progID, `
return {
  cells = {
    target = { kind = "hard", body = { value = "claimed" } },
  },
  order = { "target" },
}
`)

	// Verify cell is ready before the race.
	var readyCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM ready_cells WHERE program_id = ?", progID,
	).Scan(&readyCount)
	if readyCount != 1 {
		t.Fatalf("expected 1 ready cell before race, got %d", readyCount)
	}

	// Launch N pistons concurrently, each calling replEvalStep once.
	const numPistons = 5
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		results []evalStepResult
	)

	wg.Add(numPistons)
	for i := 0; i < numPistons; i++ {
		pistonID := fmt.Sprintf("conc-piston-%d", i)
		go func(pid string) {
			defer wg.Done()
			r := replEvalStep(db, progID, pid, "")
			mu.Lock()
			results = append(results, r)
			mu.Unlock()
		}(pistonID)
	}
	wg.Wait()

	// Count outcomes.
	var evaluated, complete, quiescent int
	for _, r := range results {
		switch r.action {
		case "evaluated":
			evaluated++
		case "complete":
			complete++
		case "quiescent":
			quiescent++
		}
	}

	// The cell is a literal hard cell, so the winner freezes it inline.
	// Remaining pistons see the program as complete or quiescent.
	if evaluated != 1 {
		t.Errorf("expected exactly 1 piston to evaluate, got %d (complete=%d, quiescent=%d)",
			evaluated, complete, quiescent)
	}

	// Verify the cell actually froze.
	var state string
	db.QueryRow(
		"SELECT state FROM cells WHERE program_id = ? AND name = 'target'", progID,
	).Scan(&state)
	if state != "frozen" {
		t.Errorf("expected cell state 'frozen', got %q", state)
	}

	// Verify claim_log shows exactly one claim for this program.
	var claimCount int
	db.QueryRow(`
		SELECT COUNT(*) FROM claim_log cl
		JOIN frames f ON cl.frame_id = f.id
		WHERE f.program_id = ? AND cl.action = 'claimed'`, progID,
	).Scan(&claimCount)
	if claimCount != 1 {
		t.Errorf("expected 1 claim in claim_log, got %d", claimCount)
	}

	resetProgram(setupDB, progID)
}

// TestConcurrency_MultipleCellsDistributed verifies that when a program has
// multiple independent ready cells and multiple pistons run concurrently, each
// cell is claimed by exactly one piston (no double-evaluation).
func TestConcurrency_MultipleCellsDistributed(t *testing.T) {
	setupDB, db := openTestDBs(t)
	progID := "conc-multi-test"

	pourTestProgram(t, setupDB, progID, `
return {
  cells = {
    alpha = { kind = "hard", body = { value = "a" } },
    beta  = { kind = "hard", body = { value = "b" } },
    gamma = { kind = "hard", body = { value = "c" } },
  },
  order = { "alpha", "beta", "gamma" },
}
`)

	// Run 4 pistons concurrently, each looping until complete/quiescent.
	const numPistons = 4
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		claimed = map[string]string{} // cellName -> pistonID that evaluated it
	)

	wg.Add(numPistons)
	for i := 0; i < numPistons; i++ {
		pistonID := fmt.Sprintf("conc-multi-piston-%d", i)
		go func(pid string) {
			defer wg.Done()
			for step := 0; step < 10; step++ {
				r := replEvalStep(db, progID, pid, "")
				if r.action == "complete" || r.action == "quiescent" {
					return
				}
				if r.action == "evaluated" {
					mu.Lock()
					if prev, dup := claimed[r.cellName]; dup {
						t.Errorf("cell %q claimed by both %s and %s", r.cellName, prev, pid)
					}
					claimed[r.cellName] = pid
					mu.Unlock()
				}
			}
		}(pistonID)
	}
	wg.Wait()

	// All 3 cells should have been evaluated.
	if len(claimed) != 3 {
		t.Errorf("expected 3 cells claimed, got %d: %v", len(claimed), claimed)
	}

	// All cells should be frozen.
	var frozenCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'frozen'", progID,
	).Scan(&frozenCount)
	if frozenCount != 3 {
		t.Errorf("expected 3 frozen cells, got %d", frozenCount)
	}

	resetProgram(setupDB, progID)
}

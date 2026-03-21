package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
	"time"
)

func cmdPour(db *sql.DB, name, luaFile string) {
	data, err := os.ReadFile(luaFile)
	if err != nil {
		fatal("read %s: %v", luaFile, err)
	}
	fmt.Printf("Pouring %s from %s (%d bytes)...\n", name, luaFile, len(data))

	// Reject if program already has cells — pour is additive (formal: cellsPreserved).
	var existing int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&existing)
	if existing > 0 {
		fatal("program %q already has %d cells — pour is additive, not destructive.\n  To overwrite, first run: ct reset %s", name, existing, name)
	}

	// Load program via Lua
	cells, parseErr := LoadLuaProgram(luaFile)
	if parseErr != nil {
		fatal("load %s: %v", luaFile, parseErr)
	}
	if cells == nil || len(cells) == 0 {
		fatal("no cells found in %s", luaFile)
	}

	sqlText := cellsToSQL(name, cells)
	if _, err := db.Exec(sqlText); err != nil {
		if !strings.Contains(err.Error(), "nothing to commit") {
			fatal("pour sql: %v", err)
		}
	}

	var n int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
	ensureFrames(db, name)
	fmt.Printf("✓ %s: %d cells\n", name, n)
}

func cmdReset(db *sql.DB, progID string) {
	var cellCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&cellCount)
	if cellCount == 0 {
		fmt.Printf("program %q has no cells — nothing to reset\n", progID)
		return
	}

	fmt.Fprintf(os.Stderr, "reset is outside the formal model (Retort.lean has no reset operation).\n")
	fmt.Fprintf(os.Stderr, "  Dolt history preserves pre-reset state: use `dolt log` to recover.\n")

	resetProgram(db, progID)
	fmt.Printf("Reset %s (%d cells removed)\n", progID, cellCount)
}

func resetProgram(db *sql.DB, progID string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")

	db.Exec(
		"INSERT INTO trace (id, cell_id, event_type, detail) VALUES (?, ?, 'reset', ?)",
		fmt.Sprintf("t-reset-%s-%d", progID, time.Now().UnixMilli()),
		progID,
		fmt.Sprintf("epoch boundary: all data for program %s destroyed", progID))

	for _, t := range []string{"cell_claims", "oracles", "yields", "givens", "cells"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "cell_claims" || t == "oracles" || t == "yields" || t == "givens" {
			q += "cell_id IN (SELECT id FROM cells WHERE program_id = ?)"
		} else {
			q += "program_id = ?"
		}
		mustExecDB(db, q, progID)
	}
	for _, t := range []string{"claim_log", "bindings", "frames"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "bindings" {
			q += "consumer_frame IN (SELECT id FROM frames WHERE program_id = ?)"
		} else if t == "claim_log" {
			q += "frame_id IN (SELECT id FROM frames WHERE program_id = ?)"
		} else {
			q += "program_id = ?"
		}
		db.Exec(q, progID)
	}
	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "reset: "+progID)
}

func ensureFrames(db *sql.DB, progID string) {
	rows, err := db.Query(
		"SELECT id, name, body_type FROM cells WHERE program_id = ?", progID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var cellID, name, bodyType string
		rows.Scan(&cellID, &name, &bodyType)
		frameID := "f-" + cellID + "-0"
		db.Exec(
			"INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, 0)",
			frameID, name, progID)
	}
}

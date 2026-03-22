package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func cmdPour(db *sql.DB, name, cellFile string) {
	data, err := os.ReadFile(cellFile)
	if err != nil {
		fatal("read %s: %v", cellFile, err)
	}
	fmt.Printf("Pouring %s from %s (%d bytes)...\n", name, cellFile, len(data))

	// Reject if program already has cells — pour is additive (formal: cellsPreserved).
	// Destructive reset must be explicit: ct reset <program-id>
	var existing int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&existing)
	if existing > 0 {
		fatal("program %q already has %d cells — pour is additive, not destructive.\n  To overwrite, first run: ct reset %s", name, existing, name)
	}

	// Lua path: .lua files are loaded via GopherLua, not the .cell parser
	if strings.HasSuffix(cellFile, ".lua") {
		cells, err := loadLuaProgram(cellFile)
		if err != nil {
			fatal("lua: %v", err)
		}
		if len(cells) == 0 {
			fatal("no cells defined in %s", cellFile)
		}
		sqlText := cellsToSQL(name, cells)
		if _, err := db.Exec(sqlText); err != nil && !strings.Contains(err.Error(), "nothing to commit") {
			fatal("load lua program: %v", err)
		}
		var n int
		db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
		ensureFrames(db, name)
		fmt.Printf("✓ %s: %d cells (Lua)\n", name, n)
		return
	}

	// Phase B: deterministic parser (instant, no LLM)
	cells, parseErr := parseCellFile(string(data))
	if parseErr != nil {
		fatal("parse %s: %v", cellFile, parseErr)
	}
	if cells != nil {
		sqlText := cellsToSQL(name, cells)
		if _, err := db.Exec(sqlText); err != nil {
			if !strings.Contains(err.Error(), "nothing to commit") {
				// Phase B failed — fall through to stem cell
				fmt.Printf("  Phase B parse failed: %v, falling back to piston...\n", err)
				pourViaPiston(db, name, cellFile, data)
				return
			}
		}
		var n int
		db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
		ensureFrames(db, name)
		fmt.Printf("✓ %s: %d cells (Phase B parser)\n", name, n)
		return
	}

	// Phase A: stem cell parser (LLM piston)
	pourViaPiston(db, name, cellFile, data)
}

// pourViaPiston creates a content-addressed 2-cell pour-program in Retort.
// The piston evaluates the parse cell (reads pour-prompt.md, produces SQL).
// ct polls until the sql yield freezes, then executes the SQL.
func pourViaPiston(db *sql.DB, name, cellFile string, data []byte) {
	// Content-addressed program ID
	h := sha256.Sum256(data)
	hash8 := hex.EncodeToString(h[:4])
	pourProg := fmt.Sprintf("pour-%s-%s", name, hash8)

	// Check if already parsed (cache hit)
	parseID := pourProg + "-parse"
	var cachedSQL sql.NullString
	err := db.QueryRow(
		"SELECT y.value_text FROM yields y WHERE y.cell_id = ? AND y.field_name = 'sql' AND y.is_frozen = 1",
		parseID).Scan(&cachedSQL)
	if err == nil && cachedSQL.Valid && cachedSQL.String != "" {
		fmt.Printf("  cache hit: %s already parsed\n", pourProg)
		pourExecSQL(db, name, cachedSQL.String)
		return
	}

	// Check if pour-program already exists (maybe piston is still working on it)
	var existing int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", pourProg).Scan(&existing)

	if existing == 0 {
		// Create the 2-cell pour-program
		sourceID := pourProg + "-source"
		sourceText := string(data)

		// Resolve pour-prompt.md path relative to the .cell file
		promptPath, _ := filepath.Abs(filepath.Join(filepath.Dir(cellFile), "..", "tools", "pour-prompt.md"))
		// Fallback: try relative to cwd
		if _, err := os.Stat(promptPath); err != nil {
			promptPath = "tools/pour-prompt.md"
			if _, err := os.Stat(promptPath); err != nil {
				// Last resort: absolute path
				promptPath = "/home/nixos/gt/doltcell/crew/helix/tools/pour-prompt.md"
			}
		}

		parseBody := fmt.Sprintf(
			"Read %s for the full parsing rules and schema. "+
				"Parse the Cell program named «name» from turnstyle syntax in «text» "+
				"into SQL INSERTs for the Retort schema. The program_id in all INSERTs must be '%s'. "+
				"CRITICAL: Preserve «guillemets» exactly as written in soft cell bodies — they are runtime interpolation markers. "+
				"Output ONLY valid SQL. No markdown fences. No commentary. "+
				"Start with USE retort; and end with CALL DOLT_COMMIT('-Am', 'pour: %s');",
			promptPath, name, name)

		// INSERT source cell (hard, literal — text goes in yields not body)
		mustExecDB(db,
			"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, ?, 'source', 'hard', 'literal:_', 'declared')",
			sourceID, pourProg)
		// Create gen-0 frame for source (hard cell)
		sourceFrameID := "f-" + sourceID + "-0"
		db.Exec("INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, 'source', ?, 0)",
			sourceFrameID, pourProg)
		// Source yields: text (the .cell contents) and name (the program name)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, ?, 'text', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-text", sourceID, sourceFrameID, sourceText)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, ?, 'name', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-name", sourceID, sourceFrameID, name)
		// Freeze source immediately (it's a literal)
		mustExecDB(db, "UPDATE cells SET state = 'frozen' WHERE id = ?", sourceID)

		// INSERT parse cell (stem — permanently soft parser, never crystallizes)
		mustExecDB(db,
			"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, ?, 'parse', 'stem', ?, 'declared')",
			parseID, pourProg, parseBody)
		mustExecDB(db,
			"INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES (?, ?, 'source', 'text')",
			"g-"+pourProg+"-parse-text", parseID)
		mustExecDB(db,
			"INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES (?, ?, 'source', 'name')",
			"g-"+pourProg+"-parse-name", parseID)
		// Create gen-0 frame for parse cell (stem cells get frames at pour time too)
		parseFrameID := "f-" + parseID + "-0"
		db.Exec("INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, 'parse', ?, 0)",
			parseFrameID, pourProg)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, frame_id, field_name) VALUES (?, ?, ?, 'sql')",
			"y-"+pourProg+"-parse-sql", parseID, parseFrameID)
		mustExecDB(db,
			"INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES (?, ?, 'deterministic', 'sql is not empty', 'not_empty')",
			"o-"+pourProg+"-parse-1", parseID)

		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "pour-program: "+pourProg)
		fmt.Printf("  created pour-program %s (2 cells)\n", pourProg)
	}

	// Poll for the parse.sql yield to freeze
	fmt.Printf("  ⏳ waiting for piston to parse %s...\n", name)
	for i := 0; i < 120; i++ { // 120 × 2s = 4 minutes
		var sqlVal sql.NullString
		err := db.QueryRow(
			"SELECT y.value_text FROM yields y WHERE y.cell_id = ? AND y.field_name = 'sql' AND y.is_frozen = 1",
			parseID).Scan(&sqlVal)
		if err == nil && sqlVal.Valid && sqlVal.String != "" {
			fmt.Printf("  ✓ piston produced SQL (%d bytes)\n", len(sqlVal.String))
			pourExecSQL(db, name, sqlVal.String)
			return
		}
		time.Sleep(2 * time.Second)
	}

	fatal("timeout: piston did not parse %s within 4 minutes (is a piston running?)", name)
}

// pourExecSQL executes piston-generated SQL to load a program into Retort.
func pourExecSQL(db *sql.DB, name, sqlText string) {
	// Clean up: remove markdown fences if piston included them
	sqlText = strings.ReplaceAll(sqlText, "```sql", "")
	sqlText = strings.ReplaceAll(sqlText, "```", "")
	sqlText = strings.TrimSpace(sqlText)

	// Sandbox: block dangerous SQL from piston-generated output
	if err := sandboxSQL(sqlText); err != nil {
		fatal("pour exec blocked: %v\nSQL was:\n%s", err, trunc(sqlText, 500))
	}

	if _, err := db.Exec(sqlText); err != nil {
		if !strings.Contains(err.Error(), "nothing to commit") {
			fatal("pour exec: %v\nSQL was:\n%s", err, trunc(sqlText, 500))
		}
	}

	var n int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
	fmt.Printf("✓ %s: %d cells\n", name, n)
}

// cmdEval submits a .cell file to cell-zero-eval as a pour-request.
// cell-zero-eval's pour-one stem cell will parse and pour it,
// then eval-one will evaluate the resulting program's cells.
func cmdEval(db *sql.DB, name, cellFile string) {
	data, err := os.ReadFile(cellFile)
	if err != nil {
		fatal("read %s: %v", cellFile, err)
	}

	// Check cell-zero-eval exists
	var czCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = 'cell-zero-eval'").Scan(&czCount)
	if czCount == 0 {
		fatal("cell-zero-eval not poured. Run: ct pour cell-zero-eval examples/cell-zero-eval.cell")
	}

	// Create a pour-request cell in cell-zero-eval
	h := sha256.Sum256(data)
	reqID := fmt.Sprintf("cz-req-%s", hex.EncodeToString(h[:4]))

	// Check for duplicate
	var existingCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE id = ?", reqID).Scan(&existingCount)
	if existingCount > 0 {
		fmt.Printf("pour-request %s already exists (cache hit)\n", reqID)
		return
	}

	// Insert the pour-request cell with .cell text as body
	mustExecDB(db,
		"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, 'cell-zero-eval', 'pour-request', 'hard', ?, 'declared')",
		reqID, string(data))

	// Create gen-0 frame for the pour-request (hard cell)
	reqFrameID := "f-" + reqID + "-0"
	db.Exec("INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, 'pour-request', 'cell-zero-eval', 0)",
		reqFrameID)

	// Yield: name (pre-frozen with the program name)
	mustExecDB(db,
		"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, ?, 'name', ?, TRUE, NOW())",
		"y-"+reqID+"-name", reqID, reqFrameID, name)

	// Yield: text (pre-frozen with the .cell content)
	mustExecDB(db,
		"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, ?, 'text', ?, TRUE, NOW())",
		"y-"+reqID+"-text", reqID, reqFrameID, string(data))

	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("eval: submit pour-request for %s", name))

	fmt.Printf("✓ Submitted pour-request for %s (%d bytes)\n", name, len(data))
	fmt.Printf("  Request ID: %s\n", reqID)
	fmt.Println("  pour-one will parse it, eval-one will evaluate it.")
}

func cmdReset(db *sql.DB, progID string) {
	// Check if program has any data to reset
	var cellCount int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&cellCount)
	if cellCount == 0 {
		fmt.Printf("⚠ program %q has no cells — nothing to reset\n", progID)
		return
	}

	fmt.Fprintf(os.Stderr, "⚠ reset is outside the formal model (Retort.lean has no reset operation).\n")
	fmt.Fprintf(os.Stderr, "  Formal guarantees (append-only, monotonicity) do not hold across resets.\n")
	fmt.Fprintf(os.Stderr, "  Dolt history preserves pre-reset state: use `dolt log` to recover.\n")

	resetProgram(db, progID)
	fmt.Printf("✓ Reset %s (%d cells removed)\n", progID, cellCount)
}

// resetProgram deletes all data for a program.
//
// FORMAL DEVIATION: The Lean spec (Retort.lean) defines exactly 5 operations
// (pour, claim, freeze, release, createFrame), all of which are append-only.
// There is no reset operation. The theorem all_ops_appendOnly (line 404) proves
// every operation preserves the append-only invariant. resetProgram violates
// cellsPreserved, framesPreserved, yieldsPreserved, bindingsPreserved, and
// givensPreserved — it is total state destruction.
//
// This exists as a PRAGMATIC concession for development and debugging.
// Formal guarantees (monotonicity, preservation) do not hold across reset
// boundaries. The Dolt commit tagged "reset: <progID>" marks the epoch boundary.
func resetProgram(db *sql.DB, progID string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")

	// Record the reset as a trace event (epoch boundary marker).
	// This allows formal analysis to identify where append-only breaks.
	db.Exec(
		"INSERT INTO trace (id, cell_id, event_type, detail) VALUES (?, ?, 'reset', ?)",
		fmt.Sprintf("t-reset-%s-%d", progID, time.Now().UnixMilli()),
		progID, // cell_id used as program_id sentinel
		fmt.Sprintf("epoch boundary: all data for program %s destroyed", progID))

	// v1 tables (cell_id based)
	for _, t := range []string{"cell_claims", "oracles", "yields", "givens", "cells"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "cell_claims" || t == "oracles" || t == "yields" || t == "givens" {
			q += "cell_id IN (SELECT id FROM cells WHERE program_id = ?)"
		} else {
			q += "program_id = ?"
		}
		mustExecDB(db, q, progID)
	}
	// v2 tables (program_id based)
	for _, t := range []string{"claim_log", "bindings", "frames"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "bindings" {
			q += "consumer_frame IN (SELECT id FROM frames WHERE program_id = ?)"
		} else if t == "claim_log" {
			q += "frame_id IN (SELECT id FROM frames WHERE program_id = ?)"
		} else {
			q += "program_id = ?"
		}
		// Use db.Exec (not mustExecDB) — these tables may not exist in older DBs
		db.Exec(q, progID)
	}
	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "reset: "+progID)
}

// ensureFrames creates gen-0 frames for all cells that don't have frames yet.
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

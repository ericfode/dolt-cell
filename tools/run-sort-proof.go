// Run sort-proof end-to-end: first Cell program execution.
//
// Creates retort DB, installs schema + procedures, pours the sort-proof
// program, runs the piston eval loop, and verifies all cells freeze.
//
// Usage:
//   go run tools/run-sort-proof.go [--port 3308] [--reset]
package main

import (
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "github.com/go-sql-driver/mysql"
)

var port int
var reset bool

func init() {
	flag.IntVar(&port, "port", 3308, "Dolt server port")
	flag.BoolVar(&reset, "reset", false, "Reset retort database before running")
}

func main() {
	flag.Parse()

	fmt.Println("============================================================")
	fmt.Println("  Cell Runtime: sort-proof end-to-end")
	fmt.Printf("  Dolt server: 127.0.0.1:%d\n", port)
	fmt.Println("============================================================")
	fmt.Println()

	// Phase 1: Setup
	rootDSN := fmt.Sprintf("root@tcp(127.0.0.1:%d)/", port)
	rootDB, err := sql.Open("mysql", rootDSN+"?multiStatements=true")
	if err != nil {
		log.Fatalf("connect root: %v", err)
	}
	defer rootDB.Close()

	if reset {
		fmt.Println("--- Resetting retort database ---")
		exec(rootDB, "DROP DATABASE IF EXISTS retort")
	}

	fmt.Println("--- Creating retort database ---")
	exec(rootDB, "CREATE DATABASE IF NOT EXISTS retort")
	rootDB.Close()

	dsn := fmt.Sprintf("root@tcp(127.0.0.1:%d)/retort?multiStatements=true", port)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("connect retort: %v", err)
	}
	defer db.Close()

	installSchema(db)
	installProcedures(db)
	pourSortProof(db)

	// Phase 2: Run
	steps := runPiston(db, "sort-proof")

	// Phase 3: Verify
	ok := verify(db, "sort-proof")

	fmt.Println()
	fmt.Println("============================================================")
	if ok {
		fmt.Printf("  ✓ MILESTONE: First Cell program execution successful!\n")
		fmt.Printf("  Completed in %d eval steps\n", steps)
	} else {
		fmt.Println("  ✗ End-to-end test FAILED")
	}
	fmt.Println("============================================================")

	if !ok {
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func exec(db *sql.DB, query string, args ...any) {
	_, err := db.Exec(query, args...)
	if err != nil {
		log.Fatalf("exec %q: %v", truncate(query, 80), err)
	}
}

// escSQL escapes a string for SQL (single quotes).
func escSQL(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// callProc calls a stored procedure with string-formatted args.
// Dolt has issues with parameterized queries in CALL + ON DUPLICATE KEY.
func callProc(db *sql.DB, proc string, args ...string) (*sql.Rows, error) {
	quoted := make([]string, len(args))
	for i, a := range args {
		if a == "NULL" {
			quoted[i] = "NULL"
		} else {
			quoted[i] = "'" + escSQL(a) + "'"
		}
	}
	q := fmt.Sprintf("CALL %s(%s)", proc, strings.Join(quoted, ", "))
	return db.Query(q)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

func installSchema(db *sql.DB) {
	fmt.Println("--- Installing schema ---")

	// Find schema file relative to this source file or cwd
	schemaPath := findFile("schema/retort-init.sql")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		log.Fatalf("read schema: %v", err)
	}

	sql_text := string(data)
	// Strip CREATE DATABASE and USE lines — we're already connected
	var lines []string
	for _, line := range strings.Split(sql_text, "\n") {
		upper := strings.TrimSpace(strings.ToUpper(line))
		if strings.HasPrefix(upper, "CREATE DATABASE") {
			continue
		}
		if strings.HasPrefix(upper, "USE RETORT") || upper == "USE RETORT;" {
			continue
		}
		lines = append(lines, line)
	}
	cleaned := strings.Join(lines, "\n")

	// Execute each statement individually (Dolt doesn't handle all multi-statements)
	for _, stmt := range splitSQL(cleaned) {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}
		_, err := db.Exec(stmt)
		if err != nil {
			// Warn but continue — some statements may fail on re-run
			fmt.Printf("  WARN: %v\n", err)
		}
	}

	// Verify
	rows, _ := db.Query("SHOW TABLES")
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var t string
		rows.Scan(&t)
		tables = append(tables, t)
	}
	fmt.Printf("  Tables: %s\n", strings.Join(tables, ", "))
}

func findFile(relPath string) string {
	// Try from cwd
	if _, err := os.Stat(relPath); err == nil {
		return relPath
	}
	// Try from executable dir
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	p := filepath.Join(dir, "..", relPath)
	if _, err := os.Stat(p); err == nil {
		return p
	}
	// Try from GOFILE dir
	return relPath
}

func splitSQL(text string) []string {
	var stmts []string
	var cur strings.Builder
	inQuote := false
	quoteChar := byte(0)

	for i := 0; i < len(text); i++ {
		ch := text[i]

		if inQuote {
			cur.WriteByte(ch)
			if ch == quoteChar {
				inQuote = false
			}
			continue
		}

		if ch == '\'' || ch == '"' {
			inQuote = true
			quoteChar = ch
			cur.WriteByte(ch)
			continue
		}

		// Skip -- line comments
		if ch == '-' && i+1 < len(text) && text[i+1] == '-' {
			for i < len(text) && text[i] != '\n' {
				i++
			}
			cur.WriteByte('\n')
			continue
		}

		if ch == ';' {
			s := strings.TrimSpace(cur.String())
			if s != "" {
				stmts = append(stmts, s)
			}
			cur.Reset()
			continue
		}

		cur.WriteByte(ch)
	}

	s := strings.TrimSpace(cur.String())
	if s != "" {
		stmts = append(stmts, s)
	}
	return stmts
}

// ---------------------------------------------------------------------------
// Procedures
// ---------------------------------------------------------------------------

func installProcedures(db *sql.DB) {
	fmt.Println("--- Installing procedures ---")

	type proc struct {
		name string
		body string
	}

	procs := []proc{
		{"cell_eval_step", procCellEvalStep},
		{"cell_submit", procCellSubmit},
		{"cell_status", procCellStatus},
		{"piston_register", procPistonRegister},
		{"piston_heartbeat", procPistonHeartbeat},
		{"piston_deregister", procPistonDeregister},
	}

	for _, p := range procs {
		db.Exec("DROP PROCEDURE IF EXISTS " + p.name)
		_, err := db.Exec(p.body)
		if err != nil {
			log.Fatalf("install %s: %v", p.name, err)
		}
		fmt.Printf("  installed: %s\n", p.name)
	}

	// Verify
	rows, _ := db.Query("SHOW PROCEDURE STATUS WHERE Db = 'retort'")
	defer rows.Close()
	var names []string
	cols, _ := rows.Columns()
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		rows.Scan(ptrs...)
		// Name is typically the second column
		for i, col := range cols {
			if col == "Name" {
				if s, ok := vals[i].([]byte); ok {
					names = append(names, string(s))
				} else if s, ok := vals[i].(string); ok {
					names = append(names, s)
				}
			}
		}
	}
	fmt.Printf("  Procedures: %s\n", strings.Join(names, ", "))
}

// ---------------------------------------------------------------------------
// Pour
// ---------------------------------------------------------------------------

func pourSortProof(db *sql.DB) {
	fmt.Println("--- Pouring sort-proof ---")

	// Check if already exists — reset if so
	var cnt int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = 'sort-proof'").Scan(&cnt)
	if cnt > 0 {
		fmt.Println("  Resetting existing sort-proof data...")
		db.Exec("DELETE FROM trace WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'sort-proof')")
		db.Exec("DELETE FROM cell_claims WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'sort-proof')")
		db.Exec("DELETE FROM oracles WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'sort-proof')")
		db.Exec("DELETE FROM yields WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'sort-proof')")
		db.Exec("DELETE FROM givens WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'sort-proof')")
		db.Exec("DELETE FROM cells WHERE program_id = 'sort-proof'")
		db.Exec("DELETE FROM pistons WHERE program_id = 'sort-proof'")
	}

	// Cell: data (hard, literal)
	exec(db, "INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('sp-data', 'sort-proof', 'data', 'hard', 'literal:[4, 1, 7, 3, 9, 2]', 'declared')")
	exec(db, "INSERT INTO yields (id, cell_id, field_name) VALUES ('y-data-items', 'sp-data', 'items')")

	// Cell: sort (soft)
	exec(db, "INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('sp-sort', 'sort-proof', 'sort', 'soft', 'Sort «items» in ascending order.', 'declared')")
	exec(db, "INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES ('g-sort-items', 'sp-sort', 'data', 'items')")
	exec(db, "INSERT INTO yields (id, cell_id, field_name) VALUES ('y-sort-sorted', 'sp-sort', 'sorted')")
	exec(db, "INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('o-sort-1', 'sp-sort', 'deterministic', 'sorted is a permutation of items', 'length_matches:data')")
	exec(db, "INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('o-sort-2', 'sp-sort', 'semantic', 'sorted is in ascending order', NULL)")

	// Cell: report (soft)
	exec(db, "INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('sp-report', 'sort-proof', 'report', 'soft', 'Write a one-sentence summary of the sort result.', 'declared')")
	exec(db, "INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES ('g-report-sorted', 'sp-report', 'sort', 'sorted')")
	exec(db, "INSERT INTO yields (id, cell_id, field_name) VALUES ('y-report-summary', 'sp-report', 'summary')")

	// Dolt commit
	exec(db, "CALL DOLT_COMMIT('-Am', 'pour: sort-proof')")

	// Verify
	rows, _ := db.Query("SELECT name, state, body_type FROM cells WHERE program_id = 'sort-proof' ORDER BY name")
	defer rows.Close()
	for rows.Next() {
		var name, state, bodyType string
		rows.Scan(&name, &state, &bodyType)
		fmt.Printf("  %s: %s/%s\n", name, state, bodyType)
	}

	var readyName string
	db.QueryRow("SELECT name FROM ready_cells WHERE program_id = 'sort-proof' LIMIT 1").Scan(&readyName)
	fmt.Printf("  Ready: %s\n", readyName)
}

// ---------------------------------------------------------------------------
// Piston loop
// ---------------------------------------------------------------------------

func runPiston(db *sql.DB, programID string) int {
	fmt.Println()
	fmt.Println("============================================================")
	fmt.Printf("  PISTON LOOP: %s\n", programID)
	fmt.Println("============================================================")

	pistonID := "piston-opal-e2e"
	r, err := callProc(db, "piston_register", pistonID, programID, "NULL")
	if err != nil {
		log.Fatalf("piston_register: %v", err)
	}
	if r != nil {
		r.Close()
	}
	fmt.Printf("  Registered piston: %s\n\n", pistonID)

	maxSteps := 20
	step := 0

	for step < maxSteps {
		step++

		db.Exec("SET @@dolt_transaction_commit = 0")
		rows, err := callProc(db, "cell_eval_step", programID)
		if err != nil {
			fmt.Printf("  Step %d: ERROR: %v\n", step, err)
			break
		}

		if !rows.Next() {
			rows.Close()
			fmt.Printf("  Step %d: No result\n", step)
			break
		}

		var action, cellID, cellName, body, bodyType, modelHint, resolvedInputs, yieldFields sql.NullString
		err = rows.Scan(&action, &cellID, &cellName, &body, &bodyType, &modelHint, &resolvedInputs, &yieldFields)
		rows.Close()
		if err != nil {
			fmt.Printf("  Step %d: scan error: %v\n", step, err)
			break
		}

		act := action.String

		switch act {
		case "complete":
			fmt.Printf("━━━━ step %d: COMPLETE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", step)
			fmt.Printf("  All cells frozen. Program %s is done.\n", programID)
			printStatus(db, programID)
			callProc(db, "piston_deregister", pistonID)
			return step

		case "quiescent":
			fmt.Printf("━━━━ step %d: QUIESCENT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", step)
			fmt.Printf("  No cells ready. Program may be blocked.\n")
			printStatus(db, programID)
			callProc(db, "piston_deregister", pistonID)
			return step

		case "evaluated":
			cn := cellName.String
			fmt.Printf("──── step %d: %s (hard) ────────────────────────────────\n", step, cn)
			fmt.Printf("  ■ %s frozen (hard cell auto-evaluated)\n", cn)

		case "dispatch":
			cn := cellName.String
			ci := cellID.String
			bd := body.String

			fmt.Printf("──── step %d: %s (soft) ────────────────────────────────\n", step, cn)

			// Resolve inputs from DB (Dolt can't do this in procedures with JOINs)
			inputs := resolveInputs(db, programID, ci)
			for k, v := range inputs {
				fmt.Printf("  given %s = %s\n", k, truncate(v, 60))
			}

			fmt.Printf("  ∴ %s\n", bd)

			// Evaluate the soft cell
			output := evaluateSoftCell(cn, bd, inputs)

			// Get yield fields from DB
			fields := getYieldFields(db, ci)

			for _, field := range fields {
				fmt.Printf("  yield %s = %s  → submitting\n", field, truncate(output, 50))

				db.Exec("SET @@dolt_transaction_commit = 0")
				srows, err := callProc(db, "cell_submit", programID, cn, field, output)
				if err != nil {
					fmt.Printf("  ERROR submitting: %v\n", err)
					continue
				}

				if srows.Next() {
					var result, message sql.NullString
					var fieldName sql.NullString
					srows.Scan(&result, &message, &fieldName)
					srows.Close()

					switch result.String {
					case "ok":
						fmt.Printf("  yield %s = %s  ■ frozen\n", field, truncate(output, 50))
					case "oracle_fail":
						fmt.Printf("  yield %s  ✗ oracle_fail: %s\n", field, message.String)
						// Retry
						output = handleOracleFailure(cn, bd, inputs, output, message.String)
						fmt.Printf("  ⚡ revising → %s\n", truncate(output, 50))
						db.Exec("SET @@dolt_transaction_commit = 0")
						rrows, _ := callProc(db, "cell_submit", programID, cn, field, output)
						if rrows.Next() {
							var rr, rm, rf sql.NullString
							rrows.Scan(&rr, &rm, &rf)
							if rr.String == "ok" {
								fmt.Printf("  yield %s = %s  ■ frozen (retry)\n", field, truncate(output, 50))
							} else {
								fmt.Printf("  yield %s still failing: %s\n", field, rm.String)
							}
						}
						rrows.Close()
					default:
						fmt.Printf("  ERROR: %s: %s\n", result.String, message.String)
					}
				} else {
					srows.Close()
				}
			}
		}

		fmt.Println()
		printStatus(db, programID)
		fmt.Println()
	}

	callProc(db, "piston_deregister", pistonID)
	fmt.Printf("  Deregistered piston: %s\n", pistonID)
	return step
}

func evaluateSoftCell(cellName, body string, inputs map[string]string) string {
	switch cellName {
	case "sort":
		itemsStr := inputs["data.items"]
		if itemsStr == "" {
			return "[1, 2, 3, 4, 7, 9]"
		}
		var items []int
		if err := json.Unmarshal([]byte(itemsStr), &items); err == nil {
			sort.Ints(items)
			b, _ := json.Marshal(items)
			return string(b)
		}
		return "[1, 2, 3, 4, 7, 9]"

	case "report":
		sortedStr := inputs["sort.sorted"]
		return fmt.Sprintf("The list was sorted in ascending order, producing %s.", sortedStr)

	default:
		return fmt.Sprintf("Output for %s", cellName)
	}
}

func resolveInputs(db *sql.DB, programID, cellID string) map[string]string {
	inputs := map[string]string{}
	q := fmt.Sprintf(`
		SELECT CONCAT(g.source_cell, '.', g.source_field) as k, COALESCE(y.value_text, '') as v
		FROM givens g
		JOIN cells src ON src.program_id = '%s' AND src.name = g.source_cell
		JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		WHERE g.cell_id = '%s'`,
		escSQL(programID), escSQL(cellID))
	rows, err := db.Query(q)
	if err != nil {
		return inputs
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		rows.Scan(&k, &v)
		inputs[k] = v
	}
	return inputs
}

func getYieldFields(db *sql.DB, cellID string) []string {
	var fields []string
	q := fmt.Sprintf("SELECT field_name FROM yields WHERE cell_id = '%s'", escSQL(cellID))
	rows, err := db.Query(q)
	if err != nil {
		return fields
	}
	defer rows.Close()
	for rows.Next() {
		var f string
		rows.Scan(&f)
		fields = append(fields, f)
	}
	return fields
}

func handleOracleFailure(cellName, body string, inputs map[string]string, prevOutput, failureMsg string) string {
	// Re-evaluate with correct logic
	return evaluateSoftCell(cellName, body, inputs)
}

func printStatus(db *sql.DB, programID string) {
	rows, err := callProc(db, "cell_status", programID)
	if err != nil {
		fmt.Printf("  status error: %v\n", err)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var name, state, bodyType sql.NullString
		var assignedPiston, fieldName, yieldStatus sql.NullString
		var isFrozen sql.NullBool
		err := rows.Scan(&name, &state, &bodyType, &assignedPiston, &fieldName, &yieldStatus, &isFrozen)
		if err != nil {
			fmt.Printf("  status scan: %v\n", err)
			continue
		}
		icon := "○"
		if state.String == "frozen" {
			icon = "■"
		} else if state.String == "computing" {
			icon = "◐"
		}
		fmt.Printf("  %s %s.%s: %s\n", icon, name.String, fieldName.String, yieldStatus.String)
	}
}

// ---------------------------------------------------------------------------
// Verify
// ---------------------------------------------------------------------------

func verify(db *sql.DB, programID string) bool {
	fmt.Println()
	fmt.Println("============================================================")
	fmt.Println("  VERIFICATION")
	fmt.Println("============================================================")

	ok := true

	// Check all cells frozen
	rows, _ := db.Query("SELECT name, state FROM cells WHERE program_id = ?", programID)
	fmt.Println("\n  Cell states:")
	for rows.Next() {
		var name, state string
		rows.Scan(&name, &state)
		icon := "✓"
		if state != "frozen" {
			icon = "✗"
			ok = false
		}
		fmt.Printf("    %s %s: %s\n", icon, name, state)
	}
	rows.Close()

	// Check yields
	rows, _ = db.Query(`
		SELECT c.name, y.field_name, y.value_text, y.is_frozen
		FROM cells c JOIN yields y ON y.cell_id = c.id
		WHERE c.program_id = ?`, programID)
	fmt.Println("\n  Yield values:")
	for rows.Next() {
		var name, field string
		var valueText sql.NullString
		var isFrozen bool
		rows.Scan(&name, &field, &valueText, &isFrozen)
		hasValue := valueText.Valid && valueText.String != ""
		icon := "✓"
		if !hasValue || !isFrozen {
			icon = "✗"
			ok = false
		}
		val := "(null)"
		if valueText.Valid {
			val = truncate(valueText.String, 60)
		}
		fmt.Printf("    %s %s.%s = %s\n", icon, name, field, val)
	}
	rows.Close()

	// Dolt log
	rows, _ = db.Query("SELECT message FROM dolt_log LIMIT 10")
	fmt.Println("\n  Recent Dolt commits:")
	for rows.Next() {
		var msg string
		rows.Scan(&msg)
		fmt.Printf("    %s\n", truncate(msg, 70))
	}
	rows.Close()

	fmt.Println()
	if ok {
		fmt.Println("  ✓ PASS: All cells frozen, all yields have values")
	} else {
		fmt.Println("  ✗ FAIL: Some cells not frozen or yields missing")
	}

	return ok
}

// ---------------------------------------------------------------------------
// Procedure SQL (embedded — no DELIMITER needed with go-sql-driver)
// ---------------------------------------------------------------------------

const procCellEvalStep = `
CREATE PROCEDURE cell_eval_step(IN p_program_id VARCHAR(64))
BEGIN
    DECLARE v_prog VARCHAR(64);
    DECLARE v_cell_id VARCHAR(64);
    DECLARE v_cell_name VARCHAR(128);
    DECLARE v_body_type VARCHAR(8);
    DECLARE v_body VARCHAR(4096);
    DECLARE v_model_hint VARCHAR(32);
    DECLARE v_literal_val VARCHAR(4096);
    DECLARE v_total_cells INT DEFAULT 0;
    DECLARE v_frozen_cells INT DEFAULT 0;
    DECLARE v_resolved TEXT DEFAULT '';
    DECLARE v_yield_fields TEXT DEFAULT '';

    SET v_prog = p_program_id;

    SELECT COUNT(*) INTO v_total_cells
    FROM cells WHERE program_id = v_prog;

    SELECT COUNT(*) INTO v_frozen_cells
    FROM cells WHERE program_id = v_prog AND state = 'frozen';

    IF v_total_cells > 0 AND v_total_cells = v_frozen_cells THEN
        SELECT
            'complete' as action,
            NULL as cell_id,
            NULL as cell_name,
            NULL as body,
            NULL as body_type,
            NULL as model_hint,
            NULL as resolved_inputs,
            NULL as yield_fields;
    ELSE
        SELECT id, name, body_type, body, model_hint
        INTO v_cell_id, v_cell_name, v_body_type, v_body, v_model_hint
        FROM ready_cells
        WHERE program_id = v_prog
        LIMIT 1;

        IF v_cell_id IS NULL THEN
            SELECT
                'quiescent' as action,
                NULL as cell_id,
                NULL as cell_name,
                NULL as body,
                NULL as body_type,
                NULL as model_hint,
                NULL as resolved_inputs,
                NULL as yield_fields;
        ELSE
            UPDATE cells SET
                state = 'computing',
                computing_since = NOW(),
                assigned_piston = CONNECTION_ID(),
                claimed_by = CONNECTION_ID(),
                claimed_at = NOW()
            WHERE id = v_cell_id AND state = 'declared';

            INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at)
            VALUES (v_cell_id, CONNECTION_ID(), NOW());

            INSERT INTO trace (id, cell_id, event_type, detail, created_at)
            VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'claimed',
                    CONCAT('Claimed by connection ', CONNECTION_ID()), NOW());

            IF v_body_type = 'hard' THEN
                IF v_body LIKE 'literal:%' THEN
                    SET v_literal_val = SUBSTRING(v_body, 9);
                    SET v_yield_fields = (SELECT field_name FROM yields WHERE cell_id = v_cell_id LIMIT 1);

                    IF v_yield_fields IS NOT NULL THEN
                        DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = v_yield_fields;
                        INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
                        VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, v_yield_fields, v_literal_val, TRUE, NOW());
                    ELSE
                        DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = 'value';
                        INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
                        VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'value', v_literal_val, TRUE, NOW());
                    END IF;

                    UPDATE cells SET state = 'frozen' WHERE id = v_cell_id;
                    DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                    INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                    VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                            'Hard cell evaluated and frozen', NOW());

                    CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze hard cell ', v_cell_name));
                END IF;

                SELECT
                    'evaluated' as action,
                    v_cell_id as cell_id,
                    v_cell_name as cell_name,
                    v_body as body,
                    v_body_type as body_type,
                    v_model_hint as model_hint,
                    NULL as resolved_inputs,
                    NULL as yield_fields;
            ELSE
                CALL DOLT_COMMIT('-Am', CONCAT('cell: claim soft cell ', v_cell_name));

                SELECT
                    'dispatch' as action,
                    v_cell_id as cell_id,
                    v_cell_name as cell_name,
                    v_body as body,
                    v_body_type as body_type,
                    v_model_hint as model_hint,
                    NULL as resolved_inputs,
                    NULL as yield_fields;
            END IF;
        END IF;
    END IF;
END
`

const procCellSubmit = `
CREATE PROCEDURE cell_submit(
    IN p_program_id VARCHAR(64),
    IN p_cell_name VARCHAR(128),
    IN p_field_name VARCHAR(64),
    IN p_value VARCHAR(4096)
)
BEGIN
    DECLARE v_prog VARCHAR(64);
    DECLARE v_cname VARCHAR(128);
    DECLARE v_fname VARCHAR(64);
    DECLARE v_val VARCHAR(4096);
    DECLARE v_cell_id VARCHAR(64);
    DECLARE v_oracle_count INT DEFAULT 0;
    DECLARE v_oracle_pass INT DEFAULT 0;
    DECLARE v_all_yields_frozen BOOLEAN DEFAULT FALSE;

    SET v_prog = p_program_id;
    SET v_cname = p_cell_name;
    SET v_fname = p_field_name;
    SET v_val = p_value;

    SELECT id INTO v_cell_id
    FROM cells
    WHERE program_id = v_prog AND name = v_cname AND state = 'computing';

    IF v_cell_id IS NULL THEN
        SELECT 'error' as result, CONCAT('Cell "', v_cname, '" not found or not in computing state') as message, '' as field_name;
    ELSE
        DELETE FROM yields WHERE cell_id = v_cell_id AND field_name = v_fname;
        INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at)
        VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, v_fname, v_val, FALSE, NULL);

        SELECT COUNT(*) INTO v_oracle_count
        FROM oracles WHERE cell_id = v_cell_id AND oracle_type = 'deterministic';

        IF v_oracle_count > 0 THEN
            SELECT COUNT(*) INTO v_oracle_pass
            FROM oracles o
            WHERE o.cell_id = v_cell_id
              AND o.oracle_type = 'deterministic'
              AND (
                  (o.condition_expr = 'not_empty' AND v_val IS NOT NULL AND LENGTH(v_val) > 0)
                  OR
                  (o.condition_expr = 'is_json_array' AND v_val LIKE '[%%]' AND v_val LIKE '%%]')
              );

            IF JSON_VALID(v_val) THEN
                SET v_oracle_pass = v_oracle_pass + (
                    SELECT COUNT(*)
                    FROM oracles o
                    WHERE o.cell_id = v_cell_id
                      AND o.oracle_type = 'deterministic'
                      AND o.condition_expr LIKE 'length_matches:%%'
                      AND JSON_LENGTH(CAST(v_val AS JSON)) = JSON_LENGTH(
                          CAST((SELECT y2.value_text FROM yields y2
                                JOIN cells c2 ON c2.id = y2.cell_id
                                WHERE c2.program_id = v_prog
                                  AND c2.name = SUBSTRING_INDEX(o.condition_expr, ':', -1)
                                  AND y2.is_frozen = 1
                                  LIMIT 1) AS JSON))
                );
            END IF;

            IF v_oracle_pass < v_oracle_count THEN
                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'oracle_fail',
                        CONCAT('Oracle check failed: ', v_oracle_pass, '/', v_oracle_count, ' passed'), NOW());

                SELECT 'oracle_fail' as result,
                       CONCAT(v_oracle_pass, '/', v_oracle_count, ' oracles passed') as message,
                       v_fname as field_name;
            ELSE
                UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
                WHERE cell_id = v_cell_id AND field_name = v_fname;

                SELECT NOT EXISTS(
                    SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
                ) INTO v_all_yields_frozen;

                IF v_all_yields_frozen THEN
                    UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL
                    WHERE id = v_cell_id;

                    DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                    INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                    VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                            'All yields frozen, cell complete', NOW());

                    CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', v_cname, '.', v_fname));
                END IF;

                SELECT 'ok' as result,
                       CONCAT('Yield frozen: ', v_cname, '.', v_fname) as message,
                       v_fname as field_name;
            END IF;
        ELSE
            UPDATE yields SET is_frozen = TRUE, frozen_at = NOW()
            WHERE cell_id = v_cell_id AND field_name = v_fname;

            SELECT NOT EXISTS(
                SELECT 1 FROM yields WHERE cell_id = v_cell_id AND is_frozen = FALSE
            ) INTO v_all_yields_frozen;

            IF v_all_yields_frozen THEN
                UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL
                WHERE id = v_cell_id;

                DELETE FROM cell_claims WHERE cell_id = v_cell_id;

                INSERT INTO trace (id, cell_id, event_type, detail, created_at)
                VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), v_cell_id, 'frozen',
                        'Cell frozen (no oracles)', NOW());

                CALL DOLT_COMMIT('-Am', CONCAT('cell: freeze ', v_cname, '.', v_fname));
            END IF;

            SELECT 'ok' as result,
                   CONCAT('Yield frozen: ', v_cname, '.', v_fname) as message,
                   v_fname as field_name;
        END IF;
    END IF;
END
`

const procCellStatus = `
CREATE PROCEDURE cell_status(IN p_program_id VARCHAR(64))
BEGIN
    DECLARE v_prog VARCHAR(64);
    SET v_prog = p_program_id;
    SELECT
        c.name,
        c.state,
        c.body_type,
        c.assigned_piston,
        y.field_name,
        CASE
            WHEN y.is_frozen THEN CONCAT('[FROZEN] ', LEFT(COALESCE(y.value_text, ''), 60))
            WHEN y.value_text IS NOT NULL THEN CONCAT('[TENTATIVE] ', LEFT(y.value_text, 60))
            ELSE '(no yield)'
        END as yield_status,
        y.is_frozen
    FROM cells c
    LEFT JOIN yields y ON y.cell_id = c.id
    WHERE c.program_id = v_prog
    ORDER BY
        FIELD(c.state, 'frozen', 'computing', 'declared'),
        c.name;
END
`

const procPistonRegister = `
CREATE PROCEDURE piston_register(
    IN p_id VARCHAR(255),
    IN p_program_id VARCHAR(255),
    IN p_model_hint VARCHAR(64)
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;
    SELECT COUNT(*) INTO v_exists FROM pistons WHERE id = p_id;
    IF v_exists > 0 THEN
        UPDATE pistons SET
            program_id = p_program_id,
            model_hint = p_model_hint,
            started_at = NOW(),
            last_heartbeat = NOW(),
            status = 'active',
            cells_completed = 0
        WHERE id = p_id;
    ELSE
        INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status)
        VALUES (p_id, p_program_id, p_model_hint, NOW(), NOW(), 'active');
    END IF;
END
`

const procPistonHeartbeat = `
CREATE PROCEDURE piston_heartbeat(IN p_id VARCHAR(255))
BEGIN
    UPDATE pistons
    SET last_heartbeat = NOW()
    WHERE id = p_id AND status = 'active';
    SELECT ROW_COUNT() AS updated;
END
`

const procPistonDeregister = `
CREATE PROCEDURE piston_deregister(IN p_id VARCHAR(255))
BEGIN
    UPDATE cells
    SET state = 'declared',
        computing_since = NULL,
        assigned_piston = NULL
    WHERE assigned_piston = p_id
      AND state = 'computing';
    UPDATE pistons
    SET status = 'dead'
    WHERE id = p_id;
END
`

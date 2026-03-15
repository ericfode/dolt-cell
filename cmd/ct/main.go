package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"os"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

const usage = `ct — Cell Tool (plumbing for Cell runtime pistons)

Usage:
  ct repl <program-id>                                Interactive Read-Eval-Put-Print-Loop
  ct repl <name> <file.cell>                          Pour program, then REPL
  ct pour <name> <file.cell>                          Load a program
  ct run <program-id>                                 Eval loop: hard cells inline, soft cells print prompt
  ct submit <program-id> <cell> <field> <value>       Submit a soft cell result
  ct status <program-id>                              Show program state
  ct yields <program-id>                              Show frozen yields
  ct history <program-id>                             Show execution history
  ct reset <program-id>                               Reset program

The piston is YOU (the LLM session using this tool) or a polecat you sling to.
ct handles the plumbing. You handle the thinking.

Environment:
  RETORT_DSN   Dolt DSN (default: root@tcp(127.0.0.1:3308)/retort)
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(1)
	}

	dsn := os.Getenv("RETORT_DSN")
	if dsn == "" {
		dsn = "root@tcp(127.0.0.1:3308)/retort"
	}

	db, err := sql.Open("mysql", dsn+"?multiStatements=true&parseTime=true")
	if err != nil {
		fatal("connect: %v", err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		fatal("ping: %v", err)
	}

	cmd := os.Args[1]
	args := os.Args[2:]

	switch cmd {
	case "repl":
		need(args, 1, "ct repl <program-id> | ct repl <name> <file.cell>")
		cmdRepl(db, args)
	case "pour":
		need(args, 2, "ct pour <name> <file.cell>")
		cmdPour(db, args[0], args[1])
	case "run":
		need(args, 1, "ct run <program-id>")
		cmdRun(db, args[0])
	case "submit":
		need(args, 4, "ct submit <program-id> <cell> <field> <value>")
		cmdSubmit(db, args[0], args[1], args[2], args[3])
	case "status":
		need(args, 1, "ct status <program-id>")
		cmdStatus(db, args[0])
	case "yields":
		need(args, 1, "ct yields <program-id>")
		cmdYields(db, args[0])
	case "history":
		need(args, 1, "ct history <program-id>")
		cmdHistory(db, args[0])
	case "reset":
		need(args, 1, "ct reset <program-id>")
		cmdReset(db, args[0])
	default:
		fatal("unknown command: %s", cmd)
	}
}

// cmdRun drives the eval loop. Hard cells freeze inline. Soft cells print
// the resolved prompt and stop — the piston (you) evaluates and calls ct submit.
func cmdRun(db *sql.DB, progID string) {
	for {
		mustExec(db, "SET @@dolt_transaction_commit = 0")
		rows, err := db.Query("CALL cell_eval_step(?)", progID)
		if err != nil {
			fatal("cell_eval_step: %v", err)
		}

		if !rows.Next() {
			rows.Close()
			fmt.Println("quiescent")
			cmdYields(db, progID)
			return
		}

		var action, cellID, cellName, body, bodyType, modelHint, resolved, yieldF sql.NullString
		if err := rows.Scan(&action, &cellID, &cellName, &body, &bodyType, &modelHint, &resolved, &yieldF); err != nil {
			rows.Close()
			fatal("scan: %v", err)
		}
		rows.Close()

		switch action.String {
		case "complete":
			fmt.Println("quiescent")
			cmdYields(db, progID)
			return

		case "evaluated":
			fmt.Printf("■ %s frozen (hard)\n", cellName.String)
			continue // next cell

		case "dispatch":
			// If it's a hard cell with sql: body that the procedure couldn't handle,
			// execute the SQL here, freeze the yield directly, and continue
			if bodyType.String == "hard" && strings.HasPrefix(body.String, "sql:") {
				sqlQuery := strings.TrimPrefix(body.String, "sql:")
				yields := getYieldFields(db, progID, cellName.String)
				var result string
				err := db.QueryRow(sqlQuery).Scan(&result)
				if err != nil {
					fmt.Printf("  ✗ %s SQL error: %v\n", cellName.String, err)
					// Reset cell to declared so it can be retried
					mustExec(db, "UPDATE cells SET state = 'declared' WHERE id = ?", cellID.String)
					continue
				}
				fmt.Printf("  ■ %s = %s (sql)\n", cellName.String, trunc(result, 60))
				// Use cell_submit to freeze properly through the procedure
				for _, y := range yields {
					r, msg, serr := submitYieldCall(db, progID, cellName.String, y, result)
					if serr != nil {
						fmt.Printf("  ✗ submit %s.%s: %v\n", cellName.String, y, serr)
					} else if r != "ok" {
						fmt.Printf("  ✗ %s.%s: %s\n", cellName.String, y, msg)
					}
				}
				continue
			}

			// Soft cell — resolve inputs and print the prompt for the piston
			inputs := resolveInputs(db, progID, cellName.String)
			prompt := interpolateBody(body.String, inputs)
			yields := getYieldFields(db, progID, cellName.String)

			fmt.Printf("▶ %s (soft)\n", cellName.String)
			if len(inputs) > 0 {
				fmt.Printf("  inputs:\n")
				for k, v := range inputs {
					if !strings.Contains(k, "→") {
						continue // skip duplicate short keys
					}
					fmt.Printf("    %s = %s\n", k, trunc(v, 60))
				}
			}
			fmt.Printf("  ∴ %s\n", prompt)
			fmt.Printf("  yields: %s\n", strings.Join(yields, ", "))
			fmt.Printf("\n  → evaluate and submit:\n")
			for _, y := range yields {
				fmt.Printf("    ct submit %s %s %s '<value>'\n", progID, cellName.String, y)
			}
			return // stop — piston evaluates and calls ct submit
		}
	}
}

// cmdSubmit submits a yield value for a soft cell
func cmdSubmit(db *sql.DB, progID, cellName, field, value string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	rows, err := db.Query("CALL cell_submit(?, ?, ?, ?)", progID, cellName, field, value)
	if err != nil {
		fatal("cell_submit: %v", err)
	}
	defer rows.Close()

	if !rows.Next() {
		fatal("no result from cell_submit")
	}
	var result, message, fieldName sql.NullString
	rows.Scan(&result, &message, &fieldName)

	switch result.String {
	case "ok":
		fmt.Printf("■ %s.%s frozen\n", cellName, field)
		// Continue the eval loop
		fmt.Println()
		cmdRun(db, progID)
	case "oracle_fail":
		fmt.Printf("✗ %s.%s oracle failed: %s\n", cellName, field, message.String)
		fmt.Printf("  → revise and resubmit: ct submit %s %s %s '<revised>'\n", progID, cellName, field)
	case "error":
		fmt.Printf("✗ error: %s\n", message.String)
	}
}

func cmdStatus(db *sql.DB, progID string) {
	rows, err := db.Query("CALL cell_status(?)", progID)
	if err != nil {
		fatal("cell_status: %v", err)
	}
	defer rows.Close()

	fmt.Printf("  %-12s %-8s %-6s %s\n", "CELL", "STATE", "TYPE", "YIELD")
	fmt.Printf("  %-12s %-8s %-6s %s\n", "────", "─────", "────", "─────")
	for rows.Next() {
		var name, state, bodyType, yieldStatus, assignedPiston, fieldName sql.NullString
		var isFrozen sql.NullBool
		rows.Scan(&name, &state, &bodyType, &assignedPiston, &fieldName, &yieldStatus, &isFrozen)
		icon := map[string]string{"frozen": "■", "computing": "▶", "declared": "○", "bottom": "⊥"}[state.String]
		if icon == "" {
			icon = "?"
		}
		ys := ""
		if fieldName.Valid {
			ys = fieldName.String + ": " + trunc(yieldStatus.String, 50)
		}
		fmt.Printf("  %-12s %s %-6s %-6s %s\n", name.String, icon, state.String, bodyType.String, ys)
	}
}

func cmdYields(db *sql.DB, progID string) {
	rows, err := db.Query(`
		SELECT c.name, y.field_name, y.value_text, y.is_bottom
		FROM cells c JOIN yields y ON y.cell_id = c.id
		WHERE c.program_id = ? AND y.is_frozen = 1
		ORDER BY c.name`, progID)
	if err != nil {
		fatal("yields: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var name, field, value sql.NullString
		var bottom sql.NullBool
		rows.Scan(&name, &field, &value, &bottom)
		icon := "■"
		if bottom.Valid && bottom.Bool {
			icon = "⊥"
		}
		fmt.Printf("  %s %s.%s = %s\n", icon, name.String, field.String, value.String)
	}
}

func cmdHistory(db *sql.DB, progID string) {
	rows, err := db.Query(`
		SELECT t.event_type, t.detail, t.created_at, c.name
		FROM trace t LEFT JOIN cells c ON c.id = t.cell_id
		WHERE c.program_id = ?
		ORDER BY t.created_at DESC LIMIT 20`, progID)
	if err != nil {
		fatal("history: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var eventType, detail, cellName sql.NullString
		var createdAt sql.NullTime
		rows.Scan(&eventType, &detail, &createdAt, &cellName)
		ts := ""
		if createdAt.Valid {
			ts = createdAt.Time.Format("15:04:05")
		}
		fmt.Printf("  %s  %-10s  %-10s  %s\n", ts, eventType.String, cellName.String, trunc(detail.String, 50))
	}
}

func cmdPour(db *sql.DB, name, cellFile string) {
	data, err := os.ReadFile(cellFile)
	if err != nil {
		fatal("read %s: %v", cellFile, err)
	}
	fmt.Printf("Pouring %s from %s (%d bytes)...\n", name, cellFile, len(data))

	sqlFile := strings.TrimSuffix(cellFile, ".cell") + ".sql"
	sqlData, err := os.ReadFile(sqlFile)
	if err != nil {
		fatal("pour requires %s (cell_pour Phase A coming soon)", sqlFile)
	}
	if _, err := db.Exec(string(sqlData)); err != nil {
		// Ignore "nothing to commit" — the data was inserted but DOLT_COMMIT
		// had nothing new (auto-committed by Dolt)
		if !strings.Contains(err.Error(), "nothing to commit") {
			fatal("pour: %v", err)
		}
	}

	var n int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
	fmt.Printf("✓ %s: %d cells\n", name, n)
}

func cmdReset(db *sql.DB, progID string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	for _, t := range []string{"trace", "cell_claims", "oracles", "yields", "givens", "cells"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "trace" || t == "cell_claims" || t == "oracles" || t == "yields" || t == "givens" {
			q += "cell_id IN (SELECT id FROM cells WHERE program_id = ?)"
		} else {
			q += "program_id = ?"
		}
		db.Exec(q, progID)
	}
	db.Exec("CALL DOLT_COMMIT('-Am', ?)", "reset: "+progID)
	fmt.Printf("✓ Reset %s\n", progID)
}

// submitYieldCall calls cell_submit and returns the result without side effects
func submitYieldCall(db *sql.DB, progID, cellName, field, value string) (string, string, error) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	rows, err := db.Query("CALL cell_submit(?, ?, ?, ?)", progID, cellName, field, value)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	if !rows.Next() {
		return "error", "no result", nil
	}
	var result, message, fn sql.NullString
	rows.Scan(&result, &message, &fn)
	return result.String, message.String, nil
}

// submitYieldDirect submits a yield without triggering cmdRun recursion
func submitYieldDirect(db *sql.DB, progID, cellName, field, value string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	rows, err := db.Query("CALL cell_submit(?, ?, ?, ?)", progID, cellName, field, value)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  submit %s.%s: %v\n", cellName, field, err)
		return
	}
	defer rows.Close()
	if rows.Next() {
		var result, message, fn sql.NullString
		rows.Scan(&result, &message, &fn)
		if result.String != "ok" {
			fmt.Printf("  ✗ %s.%s: %s\n", cellName, field, message.String)
		}
	}
}

// --- helpers ---

func resolveInputs(db *sql.DB, progID, cellName string) map[string]string {
	m := make(map[string]string)
	rows, err := db.Query(`
		SELECT g.source_cell, g.source_field, y.value_text
		FROM givens g
		JOIN cells c ON c.id = g.cell_id
		JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
		JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		WHERE c.program_id = ? AND c.name = ?`, progID, cellName)
	if err != nil {
		return m
	}
	defer rows.Close()
	for rows.Next() {
		var sc, sf, v sql.NullString
		rows.Scan(&sc, &sf, &v)
		m[sc.String+"→"+sf.String] = v.String
		m[sf.String] = v.String
	}
	return m
}

func interpolateBody(body string, inputs map[string]string) string {
	r := body
	for k, v := range inputs {
		r = strings.ReplaceAll(r, "«"+k+"»", v)
	}
	return r
}

func getYieldFields(db *sql.DB, progID, cellName string) []string {
	rows, err := db.Query(`
		SELECT y.field_name FROM yields y JOIN cells c ON c.id = y.cell_id
		WHERE c.program_id = ? AND c.name = ?`, progID, cellName)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var fs []string
	for rows.Next() {
		var f sql.NullString
		rows.Scan(&f)
		fs = append(fs, f.String)
	}
	return fs
}

func need(args []string, n int, u string) {
	if len(args) < n {
		fatal("usage: %s", u)
	}
}

func mustExec(db *sql.DB, q string, args ...any) {
	if _, err := db.Exec(q, args...); err != nil {
		fatal("exec: %v", err)
	}
}

func fatal(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "ct: "+f+"\n", a...)
	os.Exit(1)
}

func trunc(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// ===================================================================
// REPL: Read-Eval-Put-Print-Loop
// ===================================================================
//
// The REPL drives a Cell program interactively. Hard cells auto-freeze.
// Soft cells pause for input — the piston (you or an LLM) evaluates
// and types the yield value. Oracle failures prompt for revision.
//
// Output follows the document-is-state rendering from the interaction
// loop design (do-rpc).

func cmdRepl(db *sql.DB, args []string) {
	var progID string
	switch {
	case len(args) == 2 && strings.HasSuffix(args[1], ".cell"):
		cmdPour(db, args[0], args[1])
		progID = args[0]
	case len(args) == 1:
		progID = args[0]
	default:
		fatal("usage: ct repl <program-id> | ct repl <name> <file.cell>")
	}

	// Register piston
	pistonID := fmt.Sprintf("piston-%d", time.Now().UnixNano()%100000000)
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	if _, err := db.Exec("CALL piston_register(?, ?, NULL)", pistonID, progID); err != nil {
		fatal("piston_register: %v", err)
	}
	defer func() {
		mustExec(db, "SET @@dolt_transaction_commit = 0")
		db.Exec("CALL piston_deregister(?)", pistonID)
		fmt.Printf("\n  piston %s deregistered\n", pistonID)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)

	// Print program header
	total, frozen, ready := replCellCounts(db, progID)
	replBar(fmt.Sprintf("%s  ·  %d cells  ·  %d/%d frozen  ·  %d ready",
		progID, total, frozen, total, ready))
	fmt.Println()
	replDocState(db, progID)

	step := 0
	start := time.Now()

	for {
		step++

		// Go-native eval step (Dolt stored procs have variable scoping bugs)
		es := replEvalStep(db, progID, pistonID)

		switch es.action {
		case "complete":
			elapsed := time.Since(start)
			total, frozen, _ = replCellCounts(db, progID)
			fmt.Println()
			replBar(fmt.Sprintf("%s  ·  DONE  ·  %d/%d frozen  ·  %.1fs total",
				progID, frozen, total, elapsed.Seconds()))
			fmt.Println()
			replDocState(db, progID)
			return

		case "quiescent":
			elapsed := time.Since(start)
			total, frozen, _ = replCellCounts(db, progID)
			fmt.Println()
			replBar(fmt.Sprintf("%s  ·  quiescent  ·  %d/%d frozen  ·  %.1fs",
				progID, frozen, total, elapsed.Seconds()))
			fmt.Println()
			replDocState(db, progID)
			return

		case "evaluated":
			// Hard cell auto-frozen
			total, frozen, _ = replCellCounts(db, progID)
			replStepSep(step, es.cellName, 0, 0)
			fmt.Printf("  ■ %s frozen (hard)\n", es.cellName)
			fmt.Printf("\n  %s  ·  %d/%d frozen\n", progID, frozen, total)

		case "dispatch":
			// Soft cell — the REPL core: Read-Eval-Put-Print
			inputs := resolveInputs(db, progID, es.cellName)
			prompt := interpolateBody(es.body, inputs)
			yields := getYieldFields(db, progID, es.cellName)
			oracles := replGetOracles(db, es.cellID)

			fmt.Println()
			replStepSep(step, es.cellName, 0, 0)

			// Print resolved inputs
			for k, v := range inputs {
				if !strings.Contains(k, "→") {
					continue
				}
				replAnnot(fmt.Sprintf("  given %s ≡ %s", k, trunc(v, 40)), "✓ resolved")
			}

			// Print cell body
			fmt.Printf("  ∴ %s\n", prompt)

			// Print oracle assertions
			for _, o := range oracles {
				fmt.Printf("  ⊨ %s\n", o)
			}

			// Eval-Put loop: read input, submit, handle oracle retries
		yieldLoop:
			for _, y := range yields {
				for attempt := 1; attempt <= 3; attempt++ {
					if attempt > 1 {
						fmt.Println()
						replStepSep(step, es.cellName, attempt, 3)
						fmt.Printf("  ∴ %s\n", prompt)
						fmt.Printf("  ⚡ revise and resubmit\n")
					}

					// Read: prompt for yield value
					fmt.Printf("\n  yield %s ≡ ", y)
					value := replReadValue(scanner)
					if value == "" {
						fmt.Println("(empty input, skipping)")
						continue yieldLoop
					}
					fmt.Println() // newline after typed value

					// Put: submit to Dolt (Go-native)
					replAnnot(
						fmt.Sprintf("  yield %s ≡ %s", y, trunc(value, 40)),
						"→ submitting")
					result, msg := replSubmit(db, progID, es.cellName, y, value)

					// Print: show result
					switch result {
					case "ok":
						replAnnot(
							fmt.Sprintf("  yield %s ≡ %s", y, trunc(value, 40)),
							"■ frozen")
						for _, o := range oracles {
							replAnnot(fmt.Sprintf("  ⊨ %s", o), "✓ pass")
						}
						continue yieldLoop
					case "oracle_fail":
						replAnnot(
							fmt.Sprintf("  yield %s ≡ %s", y, trunc(value, 40)),
							"✗ oracle_fail")
						fmt.Printf("  Oracle: %s\n", msg)
						if attempt >= 3 {
							fmt.Printf("  ⊥ %s: exhausted 3 attempts\n", es.cellName)
						}
					default:
						fmt.Printf("  ✗ %s: %s\n", result, msg)
						break yieldLoop
					}
				}
			}

			// Status after step
			total, frozen, _ = replCellCounts(db, progID)
			fmt.Printf("\n  %s  ·  %d/%d frozen\n", progID, frozen, total)
		}
	}
}

// evalStepResult holds the result of a Go-native eval step.
type evalStepResult struct {
	action   string // complete, quiescent, evaluated, dispatch
	cellID   string
	cellName string
	body     string
	bodyType string
}

// replEvalStep implements cell_eval_step in Go (bypasses Dolt stored procedure
// variable scoping bugs). Finds the next ready cell, claims it atomically,
// and either auto-freezes hard cells or dispatches soft cells to the piston.
func replEvalStep(db *sql.DB, progID, pistonID string) evalStepResult {
	// Check if program is complete
	var remaining int
	db.QueryRow(
		"SELECT COUNT(*) FROM cells WHERE program_id = ? AND state NOT IN ('frozen', 'bottom')",
		progID).Scan(&remaining)
	if remaining == 0 {
		return evalStepResult{action: "complete"}
	}

	// Find and claim a ready cell (atomic via INSERT IGNORE)
	for attempt := 0; attempt < 50; attempt++ {
		var cellID, cellName, body, bodyType sql.NullString
		var modelHint sql.NullString
		err := db.QueryRow(`
			SELECT rc.id, rc.name, rc.body, rc.body_type, rc.model_hint
			FROM ready_cells rc
			WHERE rc.program_id = ?
			  AND rc.id NOT IN (SELECT cell_id FROM cell_claims)
			LIMIT 1`, progID).Scan(&cellID, &cellName, &body, &bodyType, &modelHint)
		if err != nil {
			break // no ready cells
		}

		// Atomic claim
		res, err := db.Exec(
			"INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at) VALUES (?, ?, NOW())",
			cellID.String, pistonID)
		if err != nil {
			continue
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			continue // another piston got it
		}

		// Claimed! Handle hard vs soft
		if bodyType.String == "hard" {
			db.Exec(
				"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
				pistonID, cellID.String)

			if strings.HasPrefix(body.String, "literal:") {
				literalVal := strings.TrimPrefix(body.String, "literal:")

				// Freeze ALL existing yields with the literal value
				db.Exec(
					"UPDATE yields SET value_text = ?, is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ?",
					literalVal, cellID.String)

				// Freeze the cell
				db.Exec(
					"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
					cellID.String)

				db.Exec("DELETE FROM cell_claims WHERE cell_id = ?", cellID.String)
				db.Exec(
					"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
					pistonID)
				db.Exec(
					"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'Hard cell: literal value', NOW())",
					cellID.String)
				db.Exec("CALL DOLT_COMMIT('-Am', ?)", "cell: freeze hard cell "+cellName.String)

			} else if strings.HasPrefix(body.String, "sql:") {
				// Execute SQL hard cell
				sqlQuery := strings.TrimSpace(strings.TrimPrefix(body.String, "sql:"))
				yields := getYieldFields(db, progID, cellName.String)
				var result string
				if err := db.QueryRow(sqlQuery).Scan(&result); err != nil {
					fmt.Printf("  ✗ %s SQL error: %v\n", cellName.String, err)
					db.Exec(
						"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
						cellID.String)
					db.Exec("DELETE FROM cell_claims WHERE cell_id = ?", cellID.String)
					continue
				}
				for _, y := range yields {
					replSubmit(db, progID, cellName.String, y, result)
				}
			}

			return evalStepResult{
				action:   "evaluated",
				cellID:   cellID.String,
				cellName: cellName.String,
				body:     body.String,
				bodyType: bodyType.String,
			}
		}

		// Soft cell: mark computing and dispatch
		db.Exec(
			"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
			pistonID, cellID.String)
		db.Exec(
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'claimed', CONCAT('Claimed by piston ', ?), NOW())",
			cellID.String, pistonID)
		db.Exec("CALL DOLT_COMMIT('-Am', ?)", "cell: claim soft cell "+cellName.String)

		return evalStepResult{
			action:   "dispatch",
			cellID:   cellID.String,
			cellName: cellName.String,
			body:     body.String,
			bodyType: bodyType.String,
		}
	}

	return evalStepResult{action: "quiescent"}
}

// replSubmit implements cell_submit in Go. Writes a yield value, checks
// deterministic oracles, and freezes the cell if all yields are frozen.
func replSubmit(db *sql.DB, progID, cellName, fieldName, value string) (string, string) {
	// Find the computing cell
	var cellID string
	err := db.QueryRow(
		"SELECT id FROM cells WHERE program_id = ? AND name = ? AND state = 'computing'",
		progID, cellName).Scan(&cellID)
	if err != nil {
		return "error", fmt.Sprintf("Cell %q not found or not computing", cellName)
	}

	// Write the yield (delete + insert for idempotency)
	db.Exec("DELETE FROM yields WHERE cell_id = ? AND field_name = ?", cellID, fieldName)
	db.Exec(
		"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?, FALSE, NULL)",
		cellID, fieldName, value)

	// Check deterministic oracles
	var oracleCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'",
		cellID).Scan(&oracleCount)

	if oracleCount > 0 {
		oraclePass := 0

		// Check not_empty and is_json_array oracles
		rows, _ := db.Query(
			"SELECT condition_expr FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'",
			cellID)
		if rows != nil {
			for rows.Next() {
				var cond string
				rows.Scan(&cond)
				switch {
				case cond == "not_empty":
					if value != "" {
						oraclePass++
					}
				case cond == "is_json_array":
					if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
						oraclePass++
					}
				case strings.HasPrefix(cond, "length_matches:"):
					srcCell := strings.TrimPrefix(cond, "length_matches:")
					var srcVal string
					err := db.QueryRow(`
						SELECT y.value_text FROM yields y
						JOIN cells c ON c.id = y.cell_id
						WHERE c.program_id = ? AND c.name = ? AND y.is_frozen = 1
						LIMIT 1`, progID, srcCell).Scan(&srcVal)
					if err == nil {
						// Compare JSON array lengths
						vLen := strings.Count(value, ",") + 1
						sLen := strings.Count(srcVal, ",") + 1
						if strings.TrimSpace(value) == "[]" {
							vLen = 0
						}
						if strings.TrimSpace(srcVal) == "[]" {
							sLen = 0
						}
						if vLen == sLen {
							oraclePass++
						}
					}
				}
			}
			rows.Close()
		}

		if oraclePass < oracleCount {
			db.Exec(
				"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'oracle_fail', ?, NOW())",
				cellID, fmt.Sprintf("Oracle check failed: %d/%d passed", oraclePass, oracleCount))
			return "oracle_fail", fmt.Sprintf("%d/%d oracles passed", oraclePass, oracleCount)
		}
	}

	// Oracle passed (or no oracles): freeze the yield
	db.Exec(
		"UPDATE yields SET is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND field_name = ?",
		cellID, fieldName)

	// Check if ALL yields are now frozen
	var unfrozen int
	db.QueryRow(
		"SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE",
		cellID).Scan(&unfrozen)

	if unfrozen == 0 {
		// Freeze the cell
		db.Exec(
			"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
			cellID)
		db.Exec("DELETE FROM cell_claims WHERE cell_id = ?", cellID)

		// Update piston stats
		var pistonID string
		if err := db.QueryRow("SELECT piston_id FROM cell_claims WHERE cell_id = ?", cellID).Scan(&pistonID); err == nil {
			db.Exec(
				"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
				pistonID)
		}

		db.Exec(
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'All yields frozen', NOW())",
			cellID)
		db.Exec("CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: freeze %s.%s", cellName, fieldName))
	}

	return "ok", fmt.Sprintf("Yield frozen: %s.%s", cellName, fieldName)
}

// replCellCounts returns (total, frozen, ready) cell counts for a program.
func replCellCounts(db *sql.DB, progID string) (total, frozen, ready int) {
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&total)
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'frozen'", progID).Scan(&frozen)
	if err := db.QueryRow("SELECT COUNT(*) FROM ready_cells WHERE program_id = ?", progID).Scan(&ready); err != nil {
		ready = 0
	}
	return
}

// replBar prints a ━━━━ bar around text.
func replBar(text string) {
	bar := strings.Repeat("━", 56)
	fmt.Println(bar)
	fmt.Printf(" %s\n", text)
	fmt.Println(bar)
}

// replStepSep prints a ──── step separator line.
func replStepSep(step int, cellName string, attempt, maxAttempt int) {
	label := fmt.Sprintf("step %d: %s", step, cellName)
	if attempt > 0 {
		label = fmt.Sprintf("step %d: %s (attempt %d/%d)", step, cellName, attempt, maxAttempt)
	}
	pad := 56 - 5 - len(label)
	if pad < 4 {
		pad = 4
	}
	fmt.Printf("──── %s %s\n", label, strings.Repeat("─", pad))
}

// replAnnot prints a line with a right-aligned annotation.
func replAnnot(content, annotation string) {
	padding := 56 - len(content)
	if padding < 2 {
		padding = 2
	}
	fmt.Printf("%s%s%s\n", content, strings.Repeat(" ", padding), annotation)
}

// replGetOracles returns oracle assertion strings for a cell.
func replGetOracles(db *sql.DB, cellID string) []string {
	rows, err := db.Query("SELECT assertion FROM oracles WHERE cell_id = ?", cellID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var a sql.NullString
		rows.Scan(&a)
		if a.Valid {
			out = append(out, a.String)
		}
	}
	return out
}

// replReadValue reads a single line of input from the scanner.
func replReadValue(scanner *bufio.Scanner) string {
	if !scanner.Scan() {
		return ""
	}
	return strings.TrimSpace(scanner.Text())
}

// replDocState renders the full program in document-is-state format.
// Shows each cell with its givens, yields (with values if frozen),
// and oracle assertions.
func replDocState(db *sql.DB, progID string) {
	type cell struct {
		id, name, state, bodyType string
	}

	// Query all cells
	cellRows, err := db.Query(
		"SELECT id, name, state, body_type FROM cells WHERE program_id = ? ORDER BY id",
		progID)
	if err != nil {
		return
	}
	var cells []cell
	for cellRows.Next() {
		var c cell
		cellRows.Scan(&c.id, &c.name, &c.state, &c.bodyType)
		cells = append(cells, c)
	}
	cellRows.Close()

	// Query ready cell IDs for declared vs blocked distinction
	readySet := make(map[string]bool)
	if rRows, err := db.Query("SELECT id FROM ready_cells WHERE program_id = ?", progID); err == nil {
		for rRows.Next() {
			var id string
			rRows.Scan(&id)
			readySet[id] = true
		}
		rRows.Close()
	}

	for _, c := range cells {
		// Cell state annotation
		var icon string
		switch c.state {
		case "frozen":
			icon = "■ frozen"
		case "computing":
			icon = "▶ computing"
		case "bottom":
			icon = "⊥ bottom"
		default: // declared
			if readySet[c.id] {
				icon = "○ ready"
			} else {
				icon = "· blocked"
			}
		}
		replAnnot(fmt.Sprintf("⊢ %s", c.name), icon)

		// Givens
		if gRows, err := db.Query(`
			SELECT g.source_cell, g.source_field, g.is_optional,
			       y.value_text, COALESCE(y.is_frozen, FALSE)
			FROM givens g
			JOIN cells src ON src.name = g.source_cell AND src.program_id = ?
			LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
			WHERE g.cell_id = ?`, progID, c.id); err == nil {
			for gRows.Next() {
				var sc, sf sql.NullString
				var opt, frozen sql.NullBool
				var val sql.NullString
				gRows.Scan(&sc, &sf, &opt, &val, &frozen)

				prefix := "  given "
				if opt.Valid && opt.Bool {
					prefix = "  given? "
				}
				line := fmt.Sprintf("%s%s→%s", prefix, sc.String, sf.String)
				if frozen.Valid && frozen.Bool && val.Valid {
					line += fmt.Sprintf(" ≡ %s", trunc(val.String, 40))
					replAnnot(line, "✓")
				} else {
					fmt.Println(line)
				}
			}
			gRows.Close()
		}

		// Yields
		if yRows, err := db.Query(
			"SELECT field_name, value_text, is_frozen, is_bottom FROM yields WHERE cell_id = ?",
			c.id); err == nil {
			for yRows.Next() {
				var fn, val sql.NullString
				var frozen, bottom sql.NullBool
				yRows.Scan(&fn, &val, &frozen, &bottom)

				line := fmt.Sprintf("  yield %s", fn.String)
				if bottom.Valid && bottom.Bool {
					replAnnot(line, "⊥")
				} else if frozen.Valid && frozen.Bool && val.Valid {
					line += fmt.Sprintf(" ≡ %s", trunc(val.String, 40))
					replAnnot(line, "■")
				} else {
					fmt.Println(line)
				}
			}
			yRows.Close()
		}

		// Oracles
		if oRows, err := db.Query(
			"SELECT assertion FROM oracles WHERE cell_id = ?",
			c.id); err == nil {
			for oRows.Next() {
				var a sql.NullString
				oRows.Scan(&a)
				line := fmt.Sprintf("  ⊨ %s", a.String)
				if c.state == "frozen" {
					replAnnot(line, "✓")
				} else {
					fmt.Println(line)
				}
			}
			oRows.Close()
		}

		fmt.Println()
	}
}

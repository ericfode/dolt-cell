package main

import (
	"bufio"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/viewport"
	"charm.land/lipgloss/v2"
	_ "github.com/go-sql-driver/mysql"
)

const usage = `ct — Cell Tool (plumbing for Cell runtime pistons)

Usage:
  ct piston                                            Autonomous piston loop (ct next → think → ct submit)
  ct piston <program-id>                              Piston for one program
  ct next                                              Claim next ready cell, print prompt, exit
  ct next <program-id>                                Claim from specific program
  ct watch                                            Live dashboard: all programs, all cells (2s refresh)
  ct watch <program-id>                               Live dashboard for one program
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
	case "piston":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdPiston(db, progID)
	case "next":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdNext(db, progID)
	case "watch":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdWatch(db, progID)
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

// cmdSubmit submits a yield value for a soft cell (Go-native, no stored procs)
func cmdSubmit(db *sql.DB, progID, cellName, field, value string) {
	result, msg := replSubmit(db, progID, cellName, field, value)
	switch result {
	case "ok":
		fmt.Printf("■ %s.%s frozen\n", cellName, field)
	case "oracle_fail":
		fmt.Printf("✗ %s.%s oracle failed: %s\n", cellName, field, msg)
		fmt.Printf("  → revise and resubmit: ct submit %s %s %s '<revised>'\n", progID, cellName, field)
		os.Exit(1)
	default:
		fmt.Printf("✗ %s: %s\n", result, msg)
		os.Exit(1)
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

	// Backward compat: if .sql file exists, use it directly
	sqlFile := strings.TrimSuffix(cellFile, ".cell") + ".sql"
	if sqlData, err := os.ReadFile(sqlFile); err == nil {
		if _, err := db.Exec(string(sqlData)); err != nil {
			if !strings.Contains(err.Error(), "nothing to commit") {
				fatal("pour: %v", err)
			}
		}
		var n int
		db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&n)
		fmt.Printf("✓ %s: %d cells\n", name, n)
		return
	}

	// No .sql file — create a pour-program and let the piston parse it
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
		db.Exec(
			"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, ?, 'source', 'hard', 'literal:_', 'declared')",
			sourceID, pourProg)
		// Source yields: text (the .cell contents) and name (the program name)
		db.Exec(
			"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'text', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-text", sourceID, sourceText)
		db.Exec(
			"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'name', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-name", sourceID, name)
		// Freeze source immediately (it's a literal)
		db.Exec("UPDATE cells SET state = 'frozen' WHERE id = ?", sourceID)

		// INSERT parse cell (stem — permanently soft parser, never crystallizes)
		db.Exec(
			"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, ?, 'parse', 'stem', ?, 'declared')",
			parseID, pourProg, parseBody)
		db.Exec(
			"INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES (?, ?, 'source', 'text')",
			"g-"+pourProg+"-parse-text", parseID)
		db.Exec(
			"INSERT INTO givens (id, cell_id, source_cell, source_field) VALUES (?, ?, 'source', 'name')",
			"g-"+pourProg+"-parse-name", parseID)
		db.Exec(
			"INSERT INTO yields (id, cell_id, field_name) VALUES (?, ?, 'sql')",
			"y-"+pourProg+"-parse-sql", parseID)
		db.Exec(
			"INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES (?, ?, 'deterministic', 'sql is not empty', 'not_empty')",
			"o-"+pourProg+"-parse-1", parseID)

		db.Exec("CALL DOLT_COMMIT('-Am', ?)", "pour-program: "+pourProg)
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

	if _, err := db.Exec(sqlText); err != nil {
		if !strings.Contains(err.Error(), "nothing to commit") {
			fatal("pour exec: %v\nSQL was:\n%s", err, trunc(sqlText, 500))
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

func fmtDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
}

func progressBar(done, total, width int) string {
	if total == 0 {
		return ""
	}
	filled := width * done / total
	if filled > width {
		filled = width
	}
	bar := strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
	return bar
}

// ===================================================================
// Piston: autonomous eval loop (ct next → think → ct submit)
// ===================================================================
//
// ct piston              — loop forever, any program
// ct piston <program-id> — loop for one program
//
// For LLM pistons (polecats), this is the main entry point. It calls
// ct next internally, prints the cell prompt to stdout, reads the
// piston's answer from a callback mechanism (the LLM session uses
// bash to call ct submit), and loops.
//
// But since the piston IS the LLM session running this command, and
// the LLM can't read its own stdout mid-stream, the piston loop is
// actually: print instructions → exit → LLM calls ct submit → LLM
// calls ct piston again. Ralph mode handles the cycling.
//
// For simplicity, ct piston is a wrapper that:
// 1. Registers once
// 2. Loops: ct next (inline) → if soft, prints prompt and STOPS
// 3. The LLM reads the prompt, thinks, calls ct submit externally
// 4. Then calls ct piston again (or ralph mode restarts it)
//
// This means ct piston is really "ct next but with piston registration
// and heartbeat, and it keeps crunching hard cells until it hits a
// soft cell or quiescent."

func cmdPiston(db *sql.DB, progID string) {
	pistonID := fmt.Sprintf("piston-%d", time.Now().UnixNano()%100000000)

	// Register
	db.Exec("DELETE FROM pistons WHERE id = ?", pistonID)
	db.Exec(
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)

	// NOTE: no defer cleanup — when dispatching a soft cell, we LEAVE it
	// in 'computing' state so ct submit can find it. The cell_reap_stale
	// procedure handles cleanup if the piston dies without submitting.

	// Crunch through hard cells, stop at first soft cell or quiescent
	step := 0
	for {
		step++
		db.Exec("UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)

		es := replEvalStep(db, progID, pistonID)

		switch es.action {
		case "complete":
			fmt.Println("COMPLETE")
			return

		case "quiescent":
			fmt.Println("QUIESCENT")
			return

		case "evaluated":
			// Hard cell frozen — keep going
			fmt.Printf("HARD: %s/%s frozen\n", es.progID, es.cellName)
			continue

		case "dispatch":
			// Soft cell — print prompt and STOP so the LLM can think
			inputs := resolveInputs(db, es.progID, es.cellName)
			prompt := interpolateBody(es.body, inputs)
			yields := getYieldFields(db, es.progID, es.cellName)
			oracles := replGetOracles(db, es.cellID)

			fmt.Printf("PROGRAM: %s\n", es.progID)
			fmt.Printf("CELL: %s\n", es.cellName)
			fmt.Printf("CELL_ID: %s\n", es.cellID)
			fmt.Printf("BODY_TYPE: %s\n", es.bodyType)
			fmt.Printf("PISTON: %s\n", pistonID)

			for k, v := range inputs {
				if !strings.Contains(k, "→") {
					continue
				}
				fmt.Printf("GIVEN: %s ≡ %s\n", k, v)
			}

			fmt.Printf("BODY: %s\n", prompt)

			for _, y := range yields {
				fmt.Printf("YIELD: %s\n", y)
			}
			for _, o := range oracles {
				fmt.Printf("ORACLE: %s\n", o)
			}
			for _, y := range yields {
				fmt.Printf("SUBMIT: ct submit %s %s %s '<value>'\n", es.progID, es.cellName, y)
			}
			return // STOP — LLM thinks and calls ct submit
		}
	}
}

// ===================================================================
// Next: claim one cell, print prompt, exit (piston interface)
// ===================================================================
//
// ct next          — claim any ready cell from any program
// ct next <prog>   — claim from a specific program
//
// Prints structured output the piston can parse:
//   PROGRAM: sort-proof
//   CELL: sort
//   CELL_ID: sp-sort
//   BODY_TYPE: soft
//   BODY: Sort «items» in ascending order.
//   GIVEN: data→items ≡ [4, 1, 7, 3, 9, 2]
//   YIELD: sorted
//   ORACLE: sorted is a permutation of items
//   ORACLE: sorted is in ascending order
//
// Exit codes:
//   0 = cell claimed and printed
//   1 = error
//   2 = no ready cells (quiescent)

func cmdNext(db *sql.DB, progID string) {
	pistonID := fmt.Sprintf("piston-%d", time.Now().UnixNano()%100000000)

	// Register piston (lightweight — just so claims have a valid piston_id)
	db.Exec("DELETE FROM pistons WHERE id = ?", pistonID)
	db.Exec(
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)

	es := replEvalStep(db, progID, pistonID)

	switch es.action {
	case "complete":
		fmt.Println("COMPLETE")
		os.Exit(2)

	case "quiescent":
		// Deregister — we didn't claim anything
		db.Exec("UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
		fmt.Println("QUIESCENT")
		os.Exit(2)

	case "evaluated":
		// Hard cell was auto-frozen. Print confirmation and exit 0.
		fmt.Printf("PROGRAM: %s\n", es.progID)
		fmt.Printf("CELL: %s\n", es.cellName)
		fmt.Printf("CELL_ID: %s\n", es.cellID)
		fmt.Printf("BODY_TYPE: hard\n")
		fmt.Printf("ACTION: frozen\n")

	case "dispatch":
		// Soft cell claimed. Print everything the piston needs.
		fmt.Printf("PROGRAM: %s\n", es.progID)
		fmt.Printf("CELL: %s\n", es.cellName)
		fmt.Printf("CELL_ID: %s\n", es.cellID)
		fmt.Printf("BODY_TYPE: soft\n")
		fmt.Printf("PISTON: %s\n", pistonID)

		// Resolved inputs
		inputs := resolveInputs(db, es.progID, es.cellName)
		prompt := interpolateBody(es.body, inputs)
		for k, v := range inputs {
			if !strings.Contains(k, "→") {
				continue
			}
			fmt.Printf("GIVEN: %s ≡ %s\n", k, v)
		}

		// Body (the ∴ prompt with interpolated values)
		fmt.Printf("BODY: %s\n", prompt)

		// Yield fields the piston must submit
		yields := getYieldFields(db, es.progID, es.cellName)
		for _, y := range yields {
			fmt.Printf("YIELD: %s\n", y)
		}

		// Oracles (so the piston knows the constraints)
		oracles := replGetOracles(db, es.cellID)
		for _, o := range oracles {
			fmt.Printf("ORACLE: %s\n", o)
		}

		// How to submit
		for _, y := range yields {
			fmt.Printf("SUBMIT: ct submit %s %s %s '<value>'\n", es.progID, es.cellName, y)
		}
	}
}

// ===================================================================
// Watch: live dashboard (Bubble Tea TUI)
// ===================================================================

type watchYield struct {
	field, value   string
	frozen, bottom bool
}

type watchCell struct {
	prog, name, state, bodyType string
	body                        string
	computingSince              *time.Time
	assignedPiston              string
	yields                      []watchYield
}

type watchDataMsg struct {
	cells    []watchCell
	programs map[string][2]int
	err      error
}

type tickRefresh struct{}

type navKind int

const (
	navProgram navKind = iota
	navCell
)

type navItem struct {
	kind    navKind
	prog    string
	cellIdx int // index into m.cells (-1 for program headers)
}

type watchModel struct {
	db        *sql.DB
	progID    string
	cells     []watchCell
	programs  map[string][2]int
	progOrder []string
	err       error
	width     int
	height    int
	viewport  viewport.Model
	spinner   spinner.Model
	fetching  bool
	lastFetch time.Time
	collapsed  map[string]bool // program-level collapse
	expanded   map[string]bool // cell-level yield expand (key: "prog/cell")
	cursor     int             // index into navItems()
	ready      bool
	// Detail pane
	showDetail bool
	detailVP   viewport.Model
	detail     *cellDetail
	detailCell string // "prog/cell" currently shown in detail
	// Search
	filtering  bool
	filterText string
}

var (
	headerStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	doneStyle      = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("2"))
	progStyle      = lipgloss.NewStyle().Bold(true)
	footerStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	cursorStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	frozenValStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	pendValStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	bottomValStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	errStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	barDoneStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	barTodoStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	iconStyles     = map[string]lipgloss.Style{
		"frozen":    lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		"computing": lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
		"declared":  lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
		"bottom":    lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
	}
	detailLabelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Bold(true)
	detailDimStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

// --- Detail pane types ---

type givenInfo struct {
	sourceCell, sourceField string
	value                   string
	frozen, optional        bool
}

type oracleInfo struct {
	oracleType, assertion string
}

type traceEvent struct {
	eventType, detail string
	createdAt         time.Time
}

type cellDetail struct {
	body, bodyType, modelHint string
	assignedPiston            string
	givens                    []givenInfo
	oracles                   []oracleInfo
	trace                     []traceEvent
}

type detailDataMsg struct {
	cellKey string
	detail  *cellDetail
	err     error
}

func queryDetailData(db *sql.DB, cellID, progID string) (*cellDetail, error) {
	d := &cellDetail{}

	// Cell metadata
	db.QueryRow("SELECT COALESCE(body,''), body_type, COALESCE(model_hint,''), COALESCE(assigned_piston,'') FROM cells WHERE id = ?", cellID).
		Scan(&d.body, &d.bodyType, &d.modelHint, &d.assignedPiston)

	// Givens with resolved values
	gRows, err := db.Query(`
		SELECT g.source_cell, g.source_field, g.is_optional,
		       COALESCE(y.value_text, ''), COALESCE(y.is_frozen, 0)
		FROM givens g
		JOIN cells src ON src.program_id = ? AND src.name = g.source_cell
		LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
		WHERE g.cell_id = ?`, progID, cellID)
	if err == nil {
		defer gRows.Close()
		for gRows.Next() {
			var gi givenInfo
			gRows.Scan(&gi.sourceCell, &gi.sourceField, &gi.optional, &gi.value, &gi.frozen)
			d.givens = append(d.givens, gi)
		}
	}

	// Oracles
	oRows, err := db.Query("SELECT oracle_type, assertion FROM oracles WHERE cell_id = ?", cellID)
	if err == nil {
		defer oRows.Close()
		for oRows.Next() {
			var oi oracleInfo
			oRows.Scan(&oi.oracleType, &oi.assertion)
			d.oracles = append(d.oracles, oi)
		}
	}

	// Recent trace
	tRows, err := db.Query("SELECT event_type, COALESCE(detail,''), created_at FROM trace WHERE cell_id = ? ORDER BY created_at DESC LIMIT 5", cellID)
	if err == nil {
		defer tRows.Close()
		for tRows.Next() {
			var te traceEvent
			tRows.Scan(&te.eventType, &te.detail, &te.createdAt)
			d.trace = append(d.trace, te)
		}
	}

	return d, nil
}

func (m watchModel) fetchDetailCmd() tea.Cmd {
	items := m.navItems()
	if m.cursor < 0 || m.cursor >= len(items) || items[m.cursor].kind != navCell {
		return nil
	}
	c := m.cells[items[m.cursor].cellIdx]
	cellID := c.prog + "-" + c.name
	cellKey := c.prog + "/" + c.name
	progID := c.prog
	db := m.db
	return func() tea.Msg {
		detail, err := queryDetailData(db, cellID, progID)
		return detailDataMsg{cellKey: cellKey, detail: detail, err: err}
	}
}

func (m watchModel) renderDetail() string {
	if m.detail == nil {
		items := m.navItems()
		if m.cursor >= 0 && m.cursor < len(items) && items[m.cursor].kind == navProgram {
			return detailDimStyle.Render("  Select a cell to inspect")
		}
		return detailDimStyle.Render("  Loading...")
	}

	d := m.detail
	var buf strings.Builder
	maxW := m.width - 4
	if maxW < 40 {
		maxW = 40
	}

	// Body
	buf.WriteString(detailLabelStyle.Render("  BODY"))
	if d.bodyType != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" (%s)", d.bodyType)))
	}
	if d.modelHint != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" model:%s", d.modelHint)))
	}
	if d.assignedPiston != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" piston:%s", d.assignedPiston)))
	}
	buf.WriteString("\n")
	body := d.body
	if len(body) > maxW*3 {
		body = body[:maxW*3] + "..."
	}
	for _, line := range strings.Split(body, "\n") {
		buf.WriteString("    " + line + "\n")
	}

	// Givens
	if len(d.givens) > 0 {
		buf.WriteString(detailLabelStyle.Render("  GIVENS") + "\n")
		for _, g := range d.givens {
			frozen := "○"
			if g.frozen {
				frozen = frozenValStyle.Render("■")
			}
			opt := ""
			if g.optional {
				opt = detailDimStyle.Render(" (optional)")
			}
			val := g.value
			if val == "" {
				val = detailDimStyle.Render("—")
			} else {
				val = trunc(val, maxW-30)
			}
			buf.WriteString(fmt.Sprintf("    %s %s→%s%s = %s\n", frozen, g.sourceCell, g.sourceField, opt, val))
		}
	}

	// Oracles
	if len(d.oracles) > 0 {
		buf.WriteString(detailLabelStyle.Render("  ORACLES") + "\n")
		for _, o := range d.oracles {
			typ := detailDimStyle.Render(fmt.Sprintf("[%s]", o.oracleType))
			buf.WriteString(fmt.Sprintf("    %s %s\n", typ, o.assertion))
		}
	}

	// Trace
	if len(d.trace) > 0 {
		buf.WriteString(detailLabelStyle.Render("  TRACE") + "\n")
		for _, t := range d.trace {
			ts := detailDimStyle.Render(t.createdAt.Format("15:04:05"))
			detail := ""
			if t.detail != "" {
				detail = " " + trunc(t.detail, maxW-30)
			}
			buf.WriteString(fmt.Sprintf("    %s %s%s\n", ts, t.eventType, detail))
		}
	}

	return buf.String()
}

// navItems builds the flat list of navigable items (program headers + cells).
func (m watchModel) navItems() []navItem {
	var items []navItem
	filter := strings.ToLower(m.filterText)
	for _, prog := range m.progOrder {
		items = append(items, navItem{kind: navProgram, prog: prog, cellIdx: -1})
		if !m.collapsed[prog] {
			for i, c := range m.cells {
				if c.prog != prog {
					continue
				}
				if filter != "" && !strings.Contains(strings.ToLower(c.name), filter) &&
					!strings.Contains(strings.ToLower(c.prog), filter) {
					continue
				}
				items = append(items, navItem{kind: navCell, prog: prog, cellIdx: i})
			}
		}
	}
	return items
}

// clampCursor keeps cursor in bounds after data refresh.
func (m *watchModel) clampCursor() {
	items := m.navItems()
	if m.cursor >= len(items) {
		m.cursor = len(items) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

// cursorLine computes which line in renderContent the cursor item is on.
func (m watchModel) cursorLine() int {
	items := m.navItems()
	line := 0
	if m.err != nil {
		line++ // error line
		if !m.lastFetch.IsZero() {
			line++ // last-ok line
		}
		line++ // blank
	}

	for i, item := range items {
		if i == m.cursor {
			return line
		}
		line++ // this item's line
		// If it's an expanded cell, count yield lines too
		if item.kind == navCell {
			c := m.cells[item.cellIdx]
			if m.expanded[c.prog+"/"+c.name] {
				line += len(c.yields)
			}
		}
	}
	return line
}

func queryWatchData(db *sql.DB, progID string) ([]watchCell, map[string][2]int, error) {
	var rows *sql.Rows
	var err error
	q := `SELECT c.program_id, c.name, c.state, c.body_type, c.body,
	             c.computing_since, c.assigned_piston,
	             y.field_name, y.value_text, y.is_frozen, y.is_bottom
	      FROM cells c
	      LEFT JOIN yields y ON y.cell_id = c.id`
	if progID != "" {
		rows, err = db.Query(q+" WHERE c.program_id = ? ORDER BY c.program_id, c.name, y.field_name", progID)
	} else {
		rows, err = db.Query(q + " ORDER BY c.program_id, c.name, y.field_name")
	}
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	var cells []watchCell
	var cur *watchCell
	programs := make(map[string][2]int)

	for rows.Next() {
		var prog, name, state, bodyType, body, piston sql.NullString
		var compSince sql.NullTime
		var fn, val sql.NullString
		var frozen, bottom sql.NullBool
		rows.Scan(&prog, &name, &state, &bodyType, &body,
			&compSince, &piston,
			&fn, &val, &frozen, &bottom)

		key := prog.String + "/" + name.String
		if cur == nil || (cur.prog+"/"+cur.name) != key {
			if cur != nil {
				cells = append(cells, *cur)
			}
			cur = &watchCell{
				prog: prog.String, name: name.String,
				state: state.String, bodyType: bodyType.String,
				body: body.String, assignedPiston: piston.String,
			}
			if compSince.Valid {
				t := compSince.Time
				cur.computingSince = &t
			}
			counts := programs[prog.String]
			counts[0]++
			if state.String == "frozen" {
				counts[1]++
			}
			programs[prog.String] = counts
		}
		if fn.Valid {
			yi := watchYield{field: fn.String}
			if val.Valid {
				yi.value = val.String
			}
			if frozen.Valid {
				yi.frozen = frozen.Bool
			}
			if bottom.Valid {
				yi.bottom = bottom.Bool
			}
			cur.yields = append(cur.yields, yi)
		}
	}
	if cur != nil {
		cells = append(cells, *cur)
	}
	return cells, programs, rows.Err()
}

func (m watchModel) fetchCmd() tea.Cmd {
	return func() tea.Msg {
		cells, programs, err := queryWatchData(m.db, m.progID)
		return watchDataMsg{cells: cells, programs: programs, err: err}
	}
}

func (m watchModel) Init() tea.Cmd {
	return tea.Batch(m.fetchCmd(), m.spinner.Tick)
}

func (m watchModel) updateViewportSizes() watchModel {
	headerH := 2 // header + blank
	footerH := 1
	listH := m.height - headerH - footerH
	if m.showDetail {
		detailH := m.height / 3
		if detailH < 5 {
			detailH = 5
		}
		listH = m.height - headerH - footerH - detailH - 1 // -1 for separator
		m.detailVP.SetWidth(m.width)
		m.detailVP.SetHeight(detailH)
	}
	if listH < 3 {
		listH = 3
	}
	m.viewport.SetWidth(m.width)
	m.viewport.SetHeight(listH)
	return m
}

func (m watchModel) cursorMoved() (watchModel, tea.Cmd) {
	m.viewport.SetContent(m.renderContent())
	m.ensureCursorVisible()
	if m.showDetail {
		// Check if cursor is on a different cell
		items := m.navItems()
		newKey := ""
		if m.cursor >= 0 && m.cursor < len(items) && items[m.cursor].kind == navCell {
			c := m.cells[items[m.cursor].cellIdx]
			newKey = c.prog + "/" + c.name
		}
		if newKey != m.detailCell {
			m.detailCell = newKey
			m.detail = nil
			if m.showDetail {
				m.detailVP.SetContent(m.renderDetail())
			}
			return m, m.fetchDetailCmd()
		}
	}
	return m, nil
}

func (m watchModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case watchDataMsg:
		m.fetching = false
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.cells = msg.cells
			m.programs = msg.programs
			m.err = nil
			m.lastFetch = time.Now()
			m.progOrder = m.progOrder[:0]
			seen := make(map[string]bool)
			for _, c := range m.cells {
				if !seen[c.prog] {
					m.progOrder = append(m.progOrder, c.prog)
					seen[c.prog] = true
				}
			}
		}
		m.clampCursor()
		if m.ready {
			m.viewport.SetContent(m.renderContent())
		}
		return m, tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickRefresh{} })

	case detailDataMsg:
		if msg.cellKey == m.detailCell && msg.err == nil {
			m.detail = msg.detail
			m.detailVP.SetContent(m.renderDetail())
		}
		return m, nil

	case tickRefresh:
		m.fetching = true
		return m, m.fetchCmd()

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if !m.ready {
			m.viewport = viewport.New(viewport.WithWidth(msg.Width), viewport.WithHeight(msg.Height-3))
			m.detailVP = viewport.New(viewport.WithWidth(msg.Width), viewport.WithHeight(0))
			m.viewport.SetContent(m.renderContent())
			m.ready = true
		}
		m = m.updateViewportSizes()
		return m, nil

	case tea.KeyPressMsg:
		// Filter mode intercepts most keys
		if m.filtering {
			switch msg.String() {
			case "ctrl+c":
				return m, tea.Quit
			case "esc":
				m.filtering = false
				m.filterText = ""
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			case "backspace":
				if len(m.filterText) > 0 {
					m.filterText = m.filterText[:len(m.filterText)-1]
				}
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			case "enter":
				m.filtering = false
				// keep filterText active
				m.viewport.SetContent(m.renderContent())
				return m, nil
			default:
				r := msg.String()
				if len(r) == 1 {
					m.filterText += r
					m.clampCursor()
					m.viewport.SetContent(m.renderContent())
				}
				return m, nil
			}
		}

		items := m.navItems()
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "j", "down":
			if m.cursor < len(items)-1 {
				m.cursor++
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "enter", " ":
			if m.cursor >= 0 && m.cursor < len(items) {
				item := items[m.cursor]
				switch item.kind {
				case navProgram:
					m.collapsed[item.prog] = !m.collapsed[item.prog]
					m.clampCursor()
				case navCell:
					c := m.cells[item.cellIdx]
					key := c.prog + "/" + c.name
					m.expanded[key] = !m.expanded[key]
				}
				m.viewport.SetContent(m.renderContent())
				m.ensureCursorVisible()
			}
			return m, nil

		case "e":
			m.collapsed = make(map[string]bool)
			for _, c := range m.cells {
				m.expanded[c.prog+"/"+c.name] = true
			}
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "c":
			m.expanded = make(map[string]bool)
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "d":
			m.showDetail = !m.showDetail
			m = m.updateViewportSizes()
			if m.showDetail {
				m.detailVP.SetContent(m.renderDetail())
				return m, m.fetchDetailCmd()
			}
			return m, nil

		case "/":
			m.filtering = true
			m.filterText = ""
			return m, nil

		case "esc":
			if m.filterText != "" {
				m.filterText = ""
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			}
		}
	}

	// Update spinner
	var cmd tea.Cmd
	m.spinner, cmd = m.spinner.Update(msg)
	if cmd != nil {
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// ensureCursorVisible scrolls the viewport to keep the cursor line on screen.
func (m *watchModel) ensureCursorVisible() {
	cl := m.cursorLine()
	vpH := m.viewport.Height()
	off := m.viewport.YOffset()
	if cl < off {
		m.viewport.SetYOffset(cl)
	} else if cl >= off+vpH {
		m.viewport.SetYOffset(cl - vpH + 1)
	}
}

func (m watchModel) renderContent() string {
	var buf strings.Builder

	// Full terminal width for yields (no artificial cap)
	maxVal := m.width - 16
	if maxVal < 40 {
		maxVal = 40
	}

	if m.err != nil {
		buf.WriteString(errStyle.Render(fmt.Sprintf("  error: %v", m.err)))
		buf.WriteString("\n")
		if !m.lastFetch.IsZero() {
			buf.WriteString(footerStyle.Render(fmt.Sprintf("  last ok: %s", m.lastFetch.Format("15:04:05"))))
			buf.WriteString("\n")
		}
		buf.WriteString("\n")
	}

	items := m.navItems()

	for i, item := range items {
		isCursor := i == m.cursor
		prefix := "  "
		if isCursor {
			prefix = cursorStyle.Render("▸ ")
		}

		switch item.kind {
		case navProgram:
			counts := m.programs[item.prog]
			done, total := counts[1], counts[0]
			filled := 8 * done / max(total, 1)
			barStr := barDoneStyle.Render(strings.Repeat("█", filled)) +
				barTodoStyle.Render(strings.Repeat("░", 8-filled))
			status := fmt.Sprintf("%s %d/%d", barStr, done, total)
			if done == total && total > 0 {
				status = barDoneStyle.Render("████████") + " " + doneStyle.Render("DONE")
			}
			collapseIcon := "▾"
			if m.collapsed[item.prog] {
				collapseIcon = "▸"
			}
			buf.WriteString(prefix)
			buf.WriteString(progStyle.Render(fmt.Sprintf("━━ %s %s", collapseIcon, item.prog)))
			buf.WriteString(fmt.Sprintf(" %s ━━\n", status))

		case navCell:
			c := m.cells[item.cellIdx]
			cellKey := c.prog + "/" + c.name
			isExpanded := m.expanded[cellKey]

			// Hard/soft-aware state icons
			var icon string
			switch c.state {
			case "frozen":
				icon = "■"
			case "bottom":
				icon = "⊥"
			case "computing":
				if c.bodyType == "soft" {
					icon = "◈"
				} else {
					icon = "▶"
				}
			case "declared":
				if c.bodyType == "soft" {
					icon = "◇"
				} else {
					icon = "○"
				}
			default:
				icon = "?"
			}
			if style, ok := iconStyles[c.state]; ok {
				icon = style.Render(icon)
			}

			arrow := "▸"
			if isExpanded {
				arrow = "▾"
			}
			if len(c.yields) == 0 {
				arrow = " "
			}

			// State label with elapsed time for computing cells
			stateLabel := c.state
			if c.state == "computing" && c.computingSince != nil {
				stateLabel += " " + fmtDuration(time.Since(*c.computingSince))
			}

			line := fmt.Sprintf("%s  %s %s %-20s %s", prefix, arrow, icon, c.name, stateLabel)
			if len(c.yields) > 0 && !isExpanded {
				line += footerStyle.Render(fmt.Sprintf("  [%d yields]", len(c.yields)))
			}
			buf.WriteString(line + "\n")

			if isExpanded {
				for _, y := range c.yields {
					if y.bottom {
						buf.WriteString(fmt.Sprintf("          %s = %s\n", y.field, bottomValStyle.Render("⊥")))
					} else if y.frozen && y.value != "" {
						buf.WriteString(fmt.Sprintf("          %s = %s\n", y.field, frozenValStyle.Render(trunc(y.value, maxVal))))
					} else if y.value != "" {
						buf.WriteString(fmt.Sprintf("          %s ~ %s\n", y.field, pendValStyle.Render(trunc(y.value, maxVal))))
					} else {
						buf.WriteString(fmt.Sprintf("          %s   %s\n", y.field, footerStyle.Render("—")))
					}
				}
			}
		}
	}

	if len(m.cells) == 0 && m.err == nil {
		buf.WriteString("  (no programs)\n")
	}

	return buf.String()
}

func (m watchModel) View() tea.View {
	if !m.ready {
		v := tea.NewView("  Loading...")
		v.AltScreen = true
		return v
	}

	var buf strings.Builder

	// Header
	now := time.Now().Format("15:04:05")
	spin := ""
	if m.fetching {
		spin = " " + m.spinner.View()
	}
	header := headerStyle.Render(fmt.Sprintf("  ct watch  ·  %s  ·  %d programs", now, len(m.programs)))
	buf.WriteString(header)
	buf.WriteString(spin)

	// Filter bar
	if m.filtering {
		buf.WriteString("  " + detailLabelStyle.Render("/") + m.filterText + cursorStyle.Render("▎"))
	} else if m.filterText != "" {
		buf.WriteString("  " + detailDimStyle.Render("filter: "+m.filterText+" (esc to clear)"))
	}
	buf.WriteString("\n")

	// Cell list viewport
	buf.WriteString(m.viewport.View())
	buf.WriteString("\n")

	// Detail pane (if enabled)
	if m.showDetail {
		sep := strings.Repeat("─", m.width)
		buf.WriteString(detailDimStyle.Render(sep) + "\n")
		buf.WriteString(m.detailVP.View())
	}

	// Footer
	detailKey := "d detail"
	if m.showDetail {
		detailKey = "d hide"
	}
	buf.WriteString(footerStyle.Render(fmt.Sprintf("  j/k nav · enter toggle · %s · / search · e/c all · q quit", detailKey)))

	v := tea.NewView(buf.String())
	v.AltScreen = true
	return v
}

func cmdWatch(db *sql.DB, progID string) {
	s := spinner.New()
	p := tea.NewProgram(watchModel{
		db:        db,
		progID:    progID,
		collapsed: make(map[string]bool),
		expanded:  make(map[string]bool),
		spinner:   s,
	})
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "watch error: %v\n", err)
		os.Exit(1)
	}
}

// ===================================================================
// Core eval engine (used by ct next, ct submit, ct pour)
// ===================================================================

// cmdRepl is DEPRECATED — use ct next + ct submit instead.
// Kept temporarily for backward compat; will be removed.
func cmdRepl(db *sql.DB, args []string) {
	var progID string // empty = watch mode (any program)
	switch {
	case len(args) == 0:
		// watch mode
	case len(args) == 2 && strings.HasSuffix(args[1], ".cell"):
		cmdPour(db, args[0], args[1])
		progID = args[0]
	case len(args) == 1:
		progID = args[0]
	default:
		fatal("usage: ct repl | ct repl <program-id> | ct repl <name> <file.cell>")
	}

	pistonID := fmt.Sprintf("piston-%d", time.Now().UnixNano()%100000000)
	watch := progID == ""

	// Register piston (program_id = '' for watch mode)
	db.Exec("DELETE FROM pistons WHERE id = ?", pistonID)
	db.Exec(
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)

	// Clean shutdown on Ctrl-C
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	stopping := false
	go func() {
		<-sigCh
		stopping = true
	}()

	defer func() {
		db.Exec(
			"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE assigned_piston = ? AND state = 'computing'",
			pistonID)
		db.Exec("DELETE FROM cell_claims WHERE piston_id = ?", pistonID)
		db.Exec("UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
		fmt.Printf("\n  piston %s deregistered\n", pistonID)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	eofHit := false

	// Print header
	if watch {
		fmt.Printf("  piston %s watching for cells...\n", pistonID)
	} else {
		total, frozen, ready := replCellCounts(db, progID)
		replBar(fmt.Sprintf("%s  ·  %d cells  ·  %d/%d frozen  ·  %d ready",
			progID, total, frozen, total, ready))
		fmt.Println()
		replDocState(db, progID)
	}

	step := 0
	start := time.Now()
	lastPrint := "" // dedup "waiting" messages

	for !stopping && !eofHit {
		step++

		// Heartbeat
		db.Exec("UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)

		es := replEvalStep(db, progID, pistonID)

		switch es.action {
		case "complete":
			// Single-program mode: program finished
			elapsed := time.Since(start)
			total, frozen, _ := replCellCounts(db, progID)
			fmt.Println()
			replBar(fmt.Sprintf("%s  ·  DONE  ·  %d/%d frozen  ·  %.1fs total",
				progID, frozen, total, elapsed.Seconds()))
			fmt.Println()
			replDocState(db, progID)
			if !watch {
				return
			}
			// In watch mode, a single program completing just means keep going
			lastPrint = ""

		case "quiescent":
			if !watch {
				// Single-program mode: exit
				elapsed := time.Since(start)
				total, frozen, _ := replCellCounts(db, progID)
				fmt.Println()
				replBar(fmt.Sprintf("%s  ·  quiescent  ·  %d/%d frozen  ·  %.1fs",
					progID, frozen, total, elapsed.Seconds()))
				fmt.Println()
				replDocState(db, progID)
				return
			}
			// Watch mode: wait and retry
			msg := fmt.Sprintf("  ⏳ waiting for cells... (%s)", time.Now().Format("15:04:05"))
			if msg != lastPrint {
				fmt.Printf("\r%s", msg)
				lastPrint = msg
			}
			step-- // don't increment step on idle
			time.Sleep(2 * time.Second)

		case "evaluated":
			lastPrint = ""
			label := es.cellName
			if watch {
				label = es.progID + "/" + es.cellName
			}
			replStepSep(step, label, 0, 0)
			fmt.Printf("  ■ %s frozen (hard)\n", es.cellName)
			total, frozen, _ := replCellCounts(db, es.progID)
			fmt.Printf("\n  %s  ·  %d/%d frozen\n", es.progID, frozen, total)

		case "dispatch":
			lastPrint = ""
			pid := es.progID
			inputs := resolveInputs(db, pid, es.cellName)
			prompt := interpolateBody(es.body, inputs)
			yields := getYieldFields(db, pid, es.cellName)
			oracles := replGetOracles(db, es.cellID)

			label := es.cellName
			if watch {
				label = pid + "/" + es.cellName
			}

			fmt.Println()
			replStepSep(step, label, 0, 0)

			for k, v := range inputs {
				if !strings.Contains(k, "→") {
					continue
				}
				replAnnot(fmt.Sprintf("  given %s ≡ %s", k, trunc(v, 40)), "✓ resolved")
			}

			fmt.Printf("  ∴ %s\n", prompt)

			for _, o := range oracles {
				fmt.Printf("  ⊨ %s\n", o)
			}

		yieldLoop:
			for _, y := range yields {
				for attempt := 1; attempt <= 3; attempt++ {
					if attempt > 1 {
						fmt.Println()
						replStepSep(step, label, attempt, 3)
						fmt.Printf("  ∴ %s\n", prompt)
						fmt.Printf("  ⚡ revise and resubmit\n")
					}

					fmt.Printf("\n  yield %s ≡ ", y)
					value := replReadValue(scanner)
					if value == "" {
						if !scanner.Scan() && scanner.Err() == nil {
							eofHit = true
						}
						fmt.Println("(empty input, skipping)")
						continue yieldLoop
					}
					fmt.Println()

					replAnnot(
						fmt.Sprintf("  yield %s ≡ %s", y, trunc(value, 40)),
						"→ submitting")
					result, msg := replSubmit(db, pid, es.cellName, y, value)

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

			total, frozen, _ := replCellCounts(db, pid)
			fmt.Printf("\n  %s  ·  %d/%d frozen\n", pid, frozen, total)
		}
	}
}

// evalStepResult holds the result of a Go-native eval step.
type evalStepResult struct {
	action   string // complete, quiescent, evaluated, dispatch
	progID   string // which program this cell belongs to
	cellID   string
	cellName string
	body     string
	bodyType string
}

// replEvalStep finds the next ready cell and claims it. When progID is empty,
// scans ALL programs (watch mode). Returns the action and cell info.
func replEvalStep(db *sql.DB, progID, pistonID string) evalStepResult {
	// Single-program mode: check if that program is complete
	if progID != "" {
		var remaining int
		db.QueryRow(
			"SELECT COUNT(*) FROM cells WHERE program_id = ? AND state NOT IN ('frozen', 'bottom')",
			progID).Scan(&remaining)
		if remaining == 0 {
			return evalStepResult{action: "complete", progID: progID}
		}
	}

	// Find and claim a ready cell (atomic via INSERT IGNORE)
	for attempt := 0; attempt < 50; attempt++ {
		var cellID, cellProgID, cellName, body, bodyType sql.NullString
		var modelHint sql.NullString
		var err error

		if progID != "" {
			err = db.QueryRow(`
				SELECT rc.id, rc.program_id, rc.name, rc.body, rc.body_type, rc.model_hint
				FROM ready_cells rc
				WHERE rc.program_id = ?
				  AND rc.id NOT IN (SELECT cell_id FROM cell_claims)
				LIMIT 1`, progID).Scan(&cellID, &cellProgID, &cellName, &body, &bodyType, &modelHint)
		} else {
			err = db.QueryRow(`
				SELECT rc.id, rc.program_id, rc.name, rc.body, rc.body_type, rc.model_hint
				FROM ready_cells rc
				WHERE rc.id NOT IN (SELECT cell_id FROM cell_claims)
				LIMIT 1`).Scan(&cellID, &cellProgID, &cellName, &body, &bodyType, &modelHint)
		}
		if err != nil {
			break // no ready cells
		}

		pid := cellProgID.String

		// Atomic claim
		res, err := db.Exec(
			"INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at) VALUES (?, ?, NOW())",
			cellID.String, pistonID)
		if err != nil {
			continue
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			continue
		}

		// Claimed! Handle hard vs soft
		if bodyType.String == "hard" {
			db.Exec(
				"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
				pistonID, cellID.String)

			if strings.HasPrefix(body.String, "literal:") {
				literalVal := strings.TrimPrefix(body.String, "literal:")
				// Only freeze yields that aren't already frozen (pre-frozen by pour SQL for multi-yield hard cells)
				db.Exec(
					"UPDATE yields SET value_text = ?, is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND is_frozen = FALSE",
					literalVal, cellID.String)
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
				sqlQuery := strings.TrimSpace(strings.TrimPrefix(body.String, "sql:"))
				yields := getYieldFields(db, pid, cellName.String)
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
					replSubmit(db, pid, cellName.String, y, result)
				}
			}

			return evalStepResult{
				action: "evaluated", progID: pid,
				cellID: cellID.String, cellName: cellName.String,
				body: body.String, bodyType: bodyType.String,
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
			action: "dispatch", progID: pid,
			cellID: cellID.String, cellName: cellName.String,
			body: body.String, bodyType: bodyType.String,
		}
	}

	return evalStepResult{action: "quiescent", progID: progID}
}

// replSubmit writes a yield value, checks deterministic oracles, and
// freezes the cell if all yields are frozen.
func replSubmit(db *sql.DB, progID, cellName, fieldName, value string) (string, string) {
	var cellID string
	err := db.QueryRow(
		"SELECT id FROM cells WHERE program_id = ? AND name = ? AND state = 'computing'",
		progID, cellName).Scan(&cellID)
	if err != nil {
		return "error", fmt.Sprintf("Cell %q not found or not computing", cellName)
	}

	db.Exec("DELETE FROM yields WHERE cell_id = ? AND field_name = ?", cellID, fieldName)
	db.Exec(
		"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?, FALSE, NULL)",
		cellID, fieldName, value)

	var oracleCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'",
		cellID).Scan(&oracleCount)

	if oracleCount > 0 {
		oraclePass := 0
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

	db.Exec(
		"UPDATE yields SET is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND field_name = ?",
		cellID, fieldName)

	var unfrozen int
	db.QueryRow(
		"SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE",
		cellID).Scan(&unfrozen)

	if unfrozen == 0 {
		db.Exec(
			"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
			cellID)

		// Get piston before deleting claim
		var claimPiston string
		db.QueryRow("SELECT piston_id FROM cell_claims WHERE cell_id = ?", cellID).Scan(&claimPiston)
		db.Exec("DELETE FROM cell_claims WHERE cell_id = ?", cellID)
		if claimPiston != "" {
			db.Exec(
				"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
				claimPiston)
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

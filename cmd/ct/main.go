package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"log"
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
  ct next [--wait] [--model <hint>] [<program-id>]      Claim next ready cell, print prompt, exit
  ct next --wait                                      Block until a cell is ready (polls every 2s)
  ct next --model claude                              Only claim cells matching model_hint
  ct watch                                            Live dashboard: all programs, all cells (2s refresh)
  ct watch <program-id>                               Live dashboard for one program
  ct pour <name> <file.cell>                          Load a program
  ct eval <name> <file.cell>                          Submit .cell to cell-zero-eval for parsing + evaluation
  ct run <program-id>                                 Eval loop: hard cells inline, soft cells print prompt
  ct submit <program-id> <cell> <field> <value>       Submit a soft cell result
  ct status <program-id>                              Show program state
  ct yields <program-id>                              Show frozen yields
  ct history <program-id>                             Show execution history
  ct graph <program-id>                               Show DAG (dependency graph from bindings)
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

	db, err := sql.Open("mysql", dsn+"?multiStatements=true&parseTime=true&tls=false")
	if err != nil {
		fatal("connect: %v", err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		// Auto-init: if retort database doesn't exist, create it
		if strings.Contains(err.Error(), "database not found") {
			initDSN := strings.Replace(dsn, "/retort", "/", 1)
			if initDB, e2 := sql.Open("mysql", initDSN+"?multiStatements=true&parseTime=true&tls=false"); e2 == nil {
				defer initDB.Close()
				if autoInitRetort(initDB) {
					// Retry ping after init
					if err := db.Ping(); err != nil {
						fatal("ping after init: %v", err)
					}
				} else {
					fatal("ping: %v", err)
				}
			} else {
				fatal("ping: %v", err)
			}
		} else {
			fatal("ping: %v", err)
		}
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
		wait := false
		modelHint := ""
		for i := 0; i < len(args); i++ {
			if args[i] == "--wait" {
				wait = true
			} else if args[i] == "--model" && i+1 < len(args) {
				i++
				modelHint = args[i]
			} else {
				progID = args[i]
			}
		}
		cmdNext(db, progID, wait, modelHint)
	case "watch":
		progID := ""
		if len(args) > 0 {
			progID = args[0]
		}
		cmdWatch(db, progID)
	case "pour":
		need(args, 2, "ct pour <name> <file.cell>")
		cmdPour(db, args[0], args[1])
	case "eval":
		need(args, 2, "ct eval <name> <file.cell>")
		cmdEval(db, args[0], args[1])
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
	case "graph":
		need(args, 1, "ct graph <program-id>")
		cmdGraph(db, args[0])
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
	pistonID := genPistonID()
	for {
		mustExec(db, "SET @@dolt_transaction_commit = 0")
		rows, err := db.Query("CALL cell_eval_step(?, ?)", progID, pistonID)
		if err != nil {
			fatal("cell_eval_step: %v", err)
		}

		if !rows.Next() {
			rows.Close()
			fmt.Println("quiescent")
			cmdYields(db, progID)
			return
		}

		var action, cellID, cellName, body, bodyType, modelHint, resolved sql.NullString
		if err := rows.Scan(&action, &cellID, &cellName, &body, &bodyType, &modelHint, &resolved); err != nil {
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
	var existing int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE id = ?", reqID).Scan(&existing)
	if existing > 0 {
		fmt.Printf("pour-request %s already exists (cache hit)\n", reqID)
		return
	}

	// Insert the pour-request cell with .cell text as body
	mustExecDB(db,
		"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, 'cell-zero-eval', 'pour-request', 'hard', ?, 'declared')",
		reqID, string(data))

	// Yield: name (pre-frozen with the program name)
	mustExecDB(db,
		"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'name', ?, TRUE, NOW())",
		"y-"+reqID+"-name", reqID, name)

	// Yield: text (pre-frozen with the .cell content)
	mustExecDB(db,
		"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'text', ?, TRUE, NOW())",
		"y-"+reqID+"-text", reqID, string(data))

	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("eval: submit pour-request for %s", name))

	fmt.Printf("✓ Submitted pour-request for %s (%d bytes)\n", name, len(data))
	fmt.Printf("  Request ID: %s\n", reqID)
	fmt.Println("  pour-one will parse it, eval-one will evaluate it.")
}

func cmdPour(db *sql.DB, name, cellFile string) {
	data, err := os.ReadFile(cellFile)
	if err != nil {
		fatal("read %s: %v", cellFile, err)
	}
	fmt.Printf("Pouring %s from %s (%d bytes)...\n", name, cellFile, len(data))

	// Auto-reset if program already exists (idempotent pour)
	var existing int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", name).Scan(&existing)
	if existing > 0 {
		resetProgram(db, name)
		fmt.Printf("  (reset %d existing cells)\n", existing)
	}

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
		ensureFrames(db, name)
		fmt.Printf("✓ %s: %d cells (from .sql)\n", name, n)
		return
	}

	// Phase B: try deterministic parser first (instant, no LLM)
	cells := parseCellFile(string(data))
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
		// Source yields: text (the .cell contents) and name (the program name)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'text', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-text", sourceID, sourceText)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (?, ?, 'name', ?, TRUE, NOW())",
			"y-"+pourProg+"-source-name", sourceID, name)
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
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, field_name) VALUES (?, ?, 'sql')",
			"y-"+pourProg+"-parse-sql", parseID)
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
	resetProgram(db, progID)
	fmt.Printf("✓ Reset %s\n", progID)
}

func cmdGraph(db *sql.DB, progID string) {
	// Get all cells and their states
	type cellInfo struct {
		name, state, bodyType string
	}
	var cells []cellInfo
	rows, err := db.Query(
		"SELECT name, state, body_type FROM cells WHERE program_id = ? ORDER BY name", progID)
	if err != nil {
		fatal("graph: %v", err)
	}
	for rows.Next() {
		var c cellInfo
		rows.Scan(&c.name, &c.state, &c.bodyType)
		cells = append(cells, c)
	}
	rows.Close()

	// Get bindings
	type edge struct {
		from, to, field string
	}
	var edges []edge
	brows, err := db.Query(`
		SELECT cf.cell_name AS consumer, pf.cell_name AS producer, b.field_name
		FROM bindings b
		JOIN frames cf ON cf.id = b.consumer_frame
		JOIN frames pf ON pf.id = b.producer_frame
		WHERE cf.program_id = ?
		ORDER BY cf.cell_name`, progID)
	if err == nil {
		for brows.Next() {
			var e edge
			brows.Scan(&e.to, &e.from, &e.field)
			edges = append(edges, e)
		}
		brows.Close()
	}

	// If no bindings yet, fall back to givens (static DAG)
	if len(edges) == 0 {
		grows, _ := db.Query(`
			SELECT c.name, g.source_cell, g.source_field
			FROM givens g JOIN cells c ON c.id = g.cell_id
			WHERE c.program_id = ?
			ORDER BY c.name`, progID)
		if grows != nil {
			for grows.Next() {
				var e edge
				grows.Scan(&e.to, &e.from, &e.field)
				edges = append(edges, e)
			}
			grows.Close()
		}
	}

	// Print ASCII DAG
	stateIcon := map[string]string{"frozen": "■", "computing": "▶", "declared": "○", "bottom": "⊥"}
	for _, c := range cells {
		icon := stateIcon[c.state]
		if icon == "" {
			icon = "?"
		}
		fmt.Printf("  %s %s [%s]\n", icon, c.name, c.bodyType)
	}
	fmt.Println()
	for _, e := range edges {
		fmt.Printf("  %s ──[%s]──→ %s\n", e.from, e.field, e.to)
	}

	// Print DOT format
	fmt.Printf("\n  // Graphviz DOT:\n")
	fmt.Printf("  // digraph %s {\n", progID)
	for _, e := range edges {
		fmt.Printf("  //   \"%s\" -> \"%s\" [label=\"%s\"];\n", e.from, e.to, e.field)
	}
	fmt.Printf("  // }\n")
}

// recordBindings writes binding edges for a frozen cell: which frames it read from.
func recordBindings(db *sql.DB, progID, cellName, cellID string) {
	// Find the consumer frame
	var consumerFrame string
	err := db.QueryRow(
		"SELECT id FROM frames WHERE program_id = ? AND cell_name = ? ORDER BY generation DESC LIMIT 1",
		progID, cellName).Scan(&consumerFrame)
	if err != nil {
		return // no frame yet (possible for old .sql-poured programs)
	}

	// Find all resolved givens and their producer frames
	rows, err := db.Query(`
		SELECT g.source_cell, g.source_field
		FROM givens g WHERE g.cell_id = ?`, cellID)
	if err != nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		var srcCell, srcField string
		rows.Scan(&srcCell, &srcField)

		// Find the producer frame (latest frozen frame for source cell)
		var producerFrame string
		err := db.QueryRow(`
			SELECT f.id FROM frames f
			JOIN yields y ON y.cell_id IN (
				SELECT c.id FROM cells c WHERE c.program_id = ? AND c.name = ?
			)
			WHERE f.program_id = ? AND f.cell_name = ?
			  AND y.field_name = ? AND y.is_frozen = 1
			ORDER BY f.generation DESC LIMIT 1`,
			progID, srcCell, progID, srcCell, srcField).Scan(&producerFrame)
		if err != nil {
			continue
		}

		// Record the binding
		db.Exec(
			"INSERT IGNORE INTO bindings (id, consumer_frame, producer_frame, field_name) VALUES (CONCAT('b-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?)",
			consumerFrame, producerFrame, srcField)
	}
}

// ensureFrames creates gen-0 frames for non-stem cells that don't have frames yet.
func ensureFrames(db *sql.DB, progID string) {
	rows, err := db.Query(
		"SELECT id, name, body_type FROM cells WHERE program_id = ? AND body_type != 'stem'", progID)
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

func resetProgram(db *sql.DB, progID string) {
	mustExec(db, "SET @@dolt_transaction_commit = 0")
	// v1 tables (cell_id based)
	for _, t := range []string{"trace", "cell_claims", "oracles", "yields", "givens", "cells"} {
		q := fmt.Sprintf("DELETE FROM %s WHERE ", t)
		if t == "trace" || t == "cell_claims" || t == "oracles" || t == "yields" || t == "givens" {
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

// mustExecDB wraps db.Exec with a non-fatal warning log on error.
func mustExecDB(db *sql.DB, query string, args ...interface{}) {
	if _, err := db.Exec(query, args...); err != nil {
		log.Printf("WARN: exec failed: %v (query: %s)", err, query)
	}
}

// readyCellResult holds the result of findReadyCell.
type readyCellResult struct {
	cellID    string
	progID    string
	cellName  string
	body      string
	bodyType  string
	modelHint string
}

// findReadyCell finds a single ready cell matching the given filters.
// progID filters by program (empty = any). excludeProgram excludes a program.
// modelHint filters by model_hint (empty = any, matching NULL or equal).
func findReadyCell(db *sql.DB, progID string, excludeProgram string, modelHint string) (*readyCellResult, error) {
	readySQL := `
		SELECT c.id, c.program_id, c.name, c.body, c.body_type, c.model_hint
		FROM cells c
		WHERE c.state = 'declared'
		  AND c.id NOT IN (SELECT cell_id FROM cell_claims)
		  AND (
		    SELECT COUNT(*) FROM givens g
		    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
		    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		    WHERE g.cell_id = c.id
		      AND g.is_optional = FALSE
		      AND y.id IS NULL
		  ) = 0`

	var queryArgs []interface{}

	if progID != "" {
		readySQL += " AND c.program_id = ?"
		queryArgs = append(queryArgs, progID)
	}
	if excludeProgram != "" {
		readySQL += " AND c.program_id != ?"
		queryArgs = append(queryArgs, excludeProgram)
	}
	if modelHint != "" {
		readySQL += " AND (c.model_hint IS NULL OR c.model_hint = ?)"
		queryArgs = append(queryArgs, modelHint)
	}
	readySQL += " LIMIT 1"

	var cellID, cellProgID, cellName, body, bodyType, mHint sql.NullString
	err := db.QueryRow(readySQL, queryArgs...).
		Scan(&cellID, &cellProgID, &cellName, &body, &bodyType, &mHint)
	if err != nil {
		return nil, err
	}
	return &readyCellResult{
		cellID:    cellID.String,
		progID:    cellProgID.String,
		cellName:  cellName.String,
		body:      body.String,
		bodyType:  bodyType.String,
		modelHint: mHint.String,
	}, nil
}

// --- helpers ---

func resolveInputs(db *sql.DB, progID, cellName string) map[string]string {
	m := make(map[string]string)
	fieldCount := make(map[string]int) // track how many givens share each field name
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
	bareValues := make(map[string][]string) // collect all values per bare field name
	for rows.Next() {
		var sc, sf, v sql.NullString
		rows.Scan(&sc, &sf, &v)
		qualified := sc.String + "→" + sf.String
		m[qualified] = v.String
		// Also add «source.field» dot-notation alias
		m[sc.String+"."+sf.String] = v.String
		fieldCount[sf.String]++
		bareValues[sf.String] = append(bareValues[sf.String], v.String)
	}
	// For bare field names: if unique, use single value; if ambiguous (gather),
	// concatenate all values so «field» expands to the full list.
	for field, vals := range bareValues {
		if len(vals) == 1 {
			m[field] = vals[0]
		} else {
			m[field] = strings.Join(vals, "\n\n")
		}
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

// autoInitRetort creates the retort database with schema, views, and procedures.
// Called automatically when ct can't connect because the database doesn't exist.
func autoInitRetort(db *sql.DB) bool {
	// Find schema files relative to executable or cwd
	root := "."
	for _, try := range []string{".", "..", "../..", "../../.."} {
		if _, err := os.Stat(filepath.Join(try, "schema", "retort-init.sql")); err == nil {
			root = try
			break
		}
	}

	initPath := filepath.Join(root, "schema", "retort-init.sql")
	initSQL, err := os.ReadFile(initPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ct: auto-init: cannot find schema/retort-init.sql (tried from cwd)\n")
		return false
	}

	fmt.Fprintf(os.Stderr, "ct: auto-init retort database...\n")

	// Execute init SQL (split on semicolons, skip comments)
	for _, stmt := range splitSQL(string(initSQL)) {
		if _, err := db.Exec(stmt); err != nil {
			fmt.Fprintf(os.Stderr, "ct: auto-init: %v\n", err)
			return false
		}
	}

	// Install procedures
	procPath := filepath.Join(root, "schema", "procedures.sql")
	procSQL, err := os.ReadFile(procPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ct: auto-init: cannot find schema/procedures.sql\n")
		return false
	}
	db.Exec("USE retort")
	for _, proc := range parseProcSQL(string(procSQL)) {
		if _, err := db.Exec(proc); err != nil {
			fmt.Fprintf(os.Stderr, "ct: auto-init proc: %v\n", err)
			return false
		}
	}

	fmt.Fprintf(os.Stderr, "ct: auto-init complete\n")
	return true
}

func splitSQL(src string) []string {
	var stmts []string
	var buf strings.Builder
	for _, line := range strings.Split(src, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "--") {
			continue
		}
		buf.WriteString(line + "\n")
		if strings.HasSuffix(t, ";") {
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
			}
			buf.Reset()
		}
	}
	return stmts
}

func parseProcSQL(src string) []string {
	var stmts []string
	var buf strings.Builder
	delim := ";"
	for _, line := range strings.Split(src, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "--") && delim == ";" {
			continue
		}
		if strings.HasPrefix(t, "DELIMITER") {
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
				buf.Reset()
			}
			parts := strings.Fields(t)
			if len(parts) >= 2 {
				delim = parts[1]
			}
			continue
		}
		if delim != ";" && strings.HasSuffix(t, delim) {
			buf.WriteString(strings.TrimSuffix(t, delim) + "\n")
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
			}
			buf.Reset()
			continue
		}
		buf.WriteString(line + "\n")
	}
	if s := strings.TrimSpace(buf.String()); s != "" {
		for _, stmt := range strings.Split(s, ";") {
			stmt = strings.TrimSpace(stmt)
			if stmt != "" && !strings.HasPrefix(stmt, "--") {
				stmts = append(stmts, stmt)
			}
		}
	}
	return stmts
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

func genPistonID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return fmt.Sprintf("piston-%s", hex.EncodeToString(b))
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
	pistonID := genPistonID()

	// Register
	mustExecDB(db, "DELETE FROM pistons WHERE id = ?", pistonID)
	mustExecDB(db,
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)

	// NOTE: no defer cleanup — when dispatching a soft cell, we LEAVE it
	// in 'computing' state so ct submit can find it. The cell_reap_stale
	// procedure handles cleanup if the piston dies without submitting.

	// Crunch through hard cells, stop at first soft cell or quiescent
	step := 0
	for {
		step++
		mustExecDB(db, "UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)

		es := replEvalStep(db, progID, pistonID, "")

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

func cmdNext(db *sql.DB, progID string, wait bool, modelHint string) {
	pistonID := genPistonID()

	// Register piston (lightweight — just so claims have a valid piston_id)
	mustExecDB(db, "DELETE FROM pistons WHERE id = ?", pistonID)
	mustExecDB(db,
		"INSERT INTO pistons (id, program_id, model_hint, started_at, last_heartbeat, status, cells_completed) VALUES (?, ?, NULL, NOW(), NOW(), 'active', 0)",
		pistonID, progID)

	// Clean exit on Ctrl-C during wait
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)

	// Track whether we claimed a cell so we can release on interrupt
	var claimedCellID, claimedPistonID string
	defer func() {
		if claimedCellID != "" {
			db.Exec("DELETE FROM cell_claims WHERE cell_id = ? AND piston_id = ?", claimedCellID, claimedPistonID)
			db.Exec("UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ? AND state = 'computing'", claimedCellID)
		}
	}()

	var es evalStepResult
	for {
		es = replEvalStep(db, progID, pistonID, modelHint)

		if es.action != "quiescent" && es.action != "complete" {
			break
		}
		if !wait {
			break
		}
		// --wait: poll every 2s until a cell becomes ready
		mustExecDB(db, "UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)
		select {
		case <-sigCh:
			mustExecDB(db, "UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
			fmt.Println("INTERRUPTED")
			os.Exit(2)
		case <-time.After(2 * time.Second):
		}
	}

	switch es.action {
	case "complete":
		fmt.Println("COMPLETE")
		os.Exit(2)

	case "quiescent":
		// Deregister — we didn't claim anything
		mustExecDB(db, "UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
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
		// Soft cell claimed. Track for cleanup on interrupt.
		claimedCellID = es.cellID
		claimedPistonID = pistonID

		// Print everything the piston needs.
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
	id, prog, name, state, bodyType string
	body                            string
	computingSince                  *time.Time
	assignedPiston                  string
	yields                          []watchYield
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
	// Help overlay
	showHelp bool
	// Auto-retry state
	retryCountdown int // seconds until next retry (0 = not retrying)
	// Session stats
	stats watchStats
}

type watchStats struct {
	sessionStart   time.Time
	navCount       int            // j/k moves
	expandCount    int            // enter on cells
	collapseCount  int            // enter on programs
	detailOpens    int            // d presses to open
	detailTime     time.Duration  // total time detail was open
	detailOpenedAt *time.Time     // when detail was last opened
	searchCount    int            // / presses
	expandAll      int            // e presses
	collapseAll    int            // c presses
	cellVisits     map[string]int // "prog/cell" → visit count
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

type yieldInfo struct {
	fieldName string
	valueText string
	isFrozen  bool
}

type cellDetail struct {
	body, bodyType, modelHint string
	assignedPiston            string
	givens                    []givenInfo
	yields                    []yieldInfo
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

	// Yields
	yRows, err := db.Query("SELECT field_name, COALESCE(value_text, ''), is_frozen FROM yields WHERE cell_id = ?", cellID)
	if err == nil {
		defer yRows.Close()
		for yRows.Next() {
			var yi yieldInfo
			yRows.Scan(&yi.fieldName, &yi.valueText, &yi.isFrozen)
			d.yields = append(d.yields, yi)
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
	cellKey := c.id
	progID := c.prog
	db := m.db
	return func() tea.Msg {
		detail, err := queryDetailData(db, cellKey, progID)
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

	// Yields
	if len(d.yields) > 0 {
		buf.WriteString(detailLabelStyle.Render("  YIELDS") + "\n")
		for _, y := range d.yields {
			icon := "○"
			valStyle := pendValStyle
			if y.isFrozen {
				icon = frozenValStyle.Render("■")
				valStyle = frozenValStyle
			}
			val := y.valueText
			if val == "" {
				val = detailDimStyle.Render("—")
			} else {
				val = valStyle.Render(trunc(val, maxW-30))
			}
			buf.WriteString(fmt.Sprintf("    %s %s = %s\n", icon, y.fieldName, val))
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
	q := `SELECT c.id, c.program_id, c.name, c.state, c.body_type, c.body,
	             c.computing_since, c.assigned_piston,
	             y.field_name, y.value_text, y.is_frozen, y.is_bottom
	      FROM cells c
	      LEFT JOIN yields y ON y.cell_id = c.id`
	// Order: computing first (active), then declared (ready), then frozen (done)
	orderClause := ` ORDER BY c.program_id,
		CASE c.state WHEN 'computing' THEN 0 WHEN 'declared' THEN 1 WHEN 'bottom' THEN 2 ELSE 3 END,
		c.name, c.id, y.field_name`
	if progID != "" {
		rows, err = db.Query(q+" WHERE c.program_id = ?"+orderClause, progID)
	} else {
		rows, err = db.Query(q + orderClause)
	}
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	var cells []watchCell
	var cur *watchCell
	programs := make(map[string][2]int)

	for rows.Next() {
		var cellID, prog, name, state, bodyType, body, piston sql.NullString
		var compSince sql.NullTime
		var fn, val sql.NullString
		var frozen, bottom sql.NullBool
		rows.Scan(&cellID, &prog, &name, &state, &bodyType, &body,
			&compSince, &piston,
			&fn, &val, &frozen, &bottom)

		if cur == nil || cur.id != cellID.String {
			if cur != nil {
				cells = append(cells, *cur)
			}
			cur = &watchCell{
				id:   cellID.String,
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
			newKey = c.id
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
			m.retryCountdown = 4 // will retry in 4s (ticks every 2s, decrements by 2)
		} else {
			m.cells = msg.cells
			m.programs = msg.programs
			m.err = nil
			m.retryCountdown = 0
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
		if m.retryCountdown > 2 {
			m.retryCountdown -= 2
			if m.ready {
				m.viewport.SetContent(m.renderContent())
			}
			return m, tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickRefresh{} })
		}
		m.retryCountdown = 0
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
		// Help overlay intercepts all keys — any key dismisses it
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

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
			m.stats.navCount++
			if m.cursor < len(items)-1 {
				m.cursor++
			}
			// Track cell visit
			if m.cursor < len(items) && items[m.cursor].kind == navCell {
				c := m.cells[items[m.cursor].cellIdx]
				m.stats.cellVisits[c.prog+"/"+c.name]++
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "k", "up":
			m.stats.navCount++
			if m.cursor > 0 {
				m.cursor--
			}
			if m.cursor < len(items) && items[m.cursor].kind == navCell {
				c := m.cells[items[m.cursor].cellIdx]
				m.stats.cellVisits[c.prog+"/"+c.name]++
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "enter", " ":
			if m.cursor >= 0 && m.cursor < len(items) {
				item := items[m.cursor]
				switch item.kind {
				case navProgram:
					m.stats.collapseCount++
					m.collapsed[item.prog] = !m.collapsed[item.prog]
					m.clampCursor()
				case navCell:
					m.stats.expandCount++
					c := m.cells[item.cellIdx]
					key := c.id
					m.expanded[key] = !m.expanded[key]
				}
				m.viewport.SetContent(m.renderContent())
				m.ensureCursorVisible()
			}
			return m, nil

		case "e":
			m.stats.expandAll++
			m.collapsed = make(map[string]bool)
			for _, c := range m.cells {
				m.expanded[c.prog+"/"+c.name] = true
			}
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "c":
			m.stats.collapseAll++
			m.expanded = make(map[string]bool)
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "d":
			m.showDetail = !m.showDetail
			if m.showDetail {
				m.stats.detailOpens++
				now := time.Now()
				m.stats.detailOpenedAt = &now
			} else if m.stats.detailOpenedAt != nil {
				m.stats.detailTime += time.Since(*m.stats.detailOpenedAt)
				m.stats.detailOpenedAt = nil
			}
			m = m.updateViewportSizes()
			if m.showDetail {
				m.detailVP.SetContent(m.renderDetail())
				return m, m.fetchDetailCmd()
			}
			return m, nil

		case "/":
			m.stats.searchCount++
			m.filtering = true
			m.filterText = ""
			return m, nil

		case "G":
			// Jump to bottom
			m.stats.navCount++
			m.cursor = len(items) - 1
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "g":
			// Jump to top
			m.stats.navCount++
			m.cursor = 0
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "tab":
			// Jump to next program header
			m.stats.navCount++
			for i := m.cursor + 1; i < len(items); i++ {
				if items[i].kind == navProgram {
					m.cursor = i
					m2, cmd := m.cursorMoved()
					return m2, cmd
				}
			}
			return m, nil

		case "shift+tab":
			// Jump to previous program header
			m.stats.navCount++
			for i := m.cursor - 1; i >= 0; i-- {
				if items[i].kind == navProgram {
					m.cursor = i
					m2, cmd := m.cursorMoved()
					return m2, cmd
				}
			}
			return m, nil

		case "esc":
			if m.showDetail {
				m.showDetail = false
				m = m.updateViewportSizes()
				return m, nil
			}
			if m.filterText != "" {
				m.filterText = ""
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			}

		case "?":
			m.showHelp = !m.showHelp
			return m, nil
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
		retryInfo := ""
		if m.retryCountdown > 0 {
			retryInfo = fmt.Sprintf(" (retry in %ds)", m.retryCountdown)
		}
		buf.WriteString(errStyle.Render(fmt.Sprintf("  error: %v%s", m.err, retryInfo)))
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
			// Count computing cells for this program
			progComputing := 0
			for _, c := range m.cells {
				if c.prog == item.prog && c.state == "computing" {
					progComputing++
				}
			}
			filled := 8 * done / max(total, 1)
			barStr := barDoneStyle.Render(strings.Repeat("█", filled)) +
				barTodoStyle.Render(strings.Repeat("░", 8-filled))
			status := fmt.Sprintf("%s %d/%d", barStr, done, total)
			if progComputing > 0 {
				status += pendValStyle.Render(fmt.Sprintf(" ⚡%d", progComputing))
			}
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
			cellKey := c.id
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

			// State label with elapsed time and piston for computing cells
			stateLabel := c.state
			if c.state == "computing" {
				// Check if all yields are actually frozen (anomaly)
				allFrozen := len(c.yields) > 0
				for _, y := range c.yields {
					if !y.frozen {
						allFrozen = false
						break
					}
				}
				if allFrozen {
					stateLabel = pendValStyle.Render("computing→frozen")
				} else if c.computingSince != nil {
					stateLabel += " " + fmtDuration(time.Since(*c.computingSince))
				}
				if c.assignedPiston != "" {
					stateLabel += detailDimStyle.Render(" (" + trunc(c.assignedPiston, 16) + ")")
				}
			}

			// Show short ID suffix when multiple cells share the same name
			displayName := c.name
			dupCount := 0
			for _, other := range m.cells {
				if other.prog == c.prog && other.name == c.name {
					dupCount++
				}
			}
			if dupCount > 1 {
				// Extract hash suffix from cell ID for disambiguation
				suffix := c.id
				if idx := strings.LastIndex(suffix, "-"); idx >= 0 && idx < len(suffix)-1 {
					suffix = suffix[idx+1:]
				}
				if len(suffix) > 6 {
					suffix = suffix[:6]
				}
				displayName = c.name + detailDimStyle.Render("#"+suffix)
			}

			line := fmt.Sprintf("%s  %s %s %-20s %s", prefix, arrow, icon, displayName, stateLabel)

			// Show yield info when collapsed
			if !isExpanded {
				if c.state == "frozen" && len(c.yields) == 1 && c.yields[0].value != "" {
					// Single frozen yield — show inline preview
					line += detailDimStyle.Render(" = ") + frozenValStyle.Render(trunc(c.yields[0].value, 40))
				} else if len(c.yields) > 0 {
					// Count frozen yields
					frozenY := 0
					for _, y := range c.yields {
						if y.frozen {
							frozenY++
						}
					}
					if frozenY == len(c.yields) {
						line += footerStyle.Render(fmt.Sprintf("  [%d yields ■]", len(c.yields)))
					} else if frozenY > 0 {
						line += footerStyle.Render(fmt.Sprintf("  [%d/%d yields]", frozenY, len(c.yields)))
					} else {
						line += footerStyle.Render(fmt.Sprintf("  [%d yields]", len(c.yields)))
					}
				}
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
		buf.WriteString("\n")
		buf.WriteString(detailDimStyle.Render("  No programs loaded. Use ct pour <name> <file.cell> to load one."))
		buf.WriteString("\n")
	}

	return buf.String()
}

func (m watchModel) View() tea.View {
	if !m.ready {
		v := tea.NewView("  Loading...")
		v.AltScreen = true
		return v
	}

	// Help overlay
	if m.showHelp {
		help := headerStyle.Render("  ct watch — keybindings") + "\n\n"
		help += "  j / down       Move cursor down\n"
		help += "  k / up         Move cursor up\n"
		help += "  enter / space  Toggle expand/collapse on cell or program\n"
		help += "  e              Expand all programs and cells\n"
		help += "  c              Collapse all cells\n"
		help += "  tab            Jump to next program\n"
		help += "  shift+tab      Jump to previous program\n"
		help += "  g              Jump to top\n"
		help += "  G              Jump to bottom\n"
		help += "  d              Toggle detail pane\n"
		help += "  /              Search / filter cells\n"
		help += "  esc            Close detail, clear filter\n"
		help += "  ?              Toggle this help\n"
		help += "  q / ctrl+c     Quit\n"
		help += "\n" + footerStyle.Render("  Press any key to dismiss")
		v := tea.NewView(help)
		v.AltScreen = true
		return v
	}

	var buf strings.Builder

	// Header with aggregate stats
	now := time.Now().Format("15:04:05")
	spin := ""
	if m.fetching {
		spin = " " + m.spinner.View()
	}
	// Count aggregate cell states
	var totalCells, frozenCells, computingCells int
	for _, counts := range m.programs {
		totalCells += counts[0]
		frozenCells += counts[1]
	}
	for _, c := range m.cells {
		if c.state == "computing" {
			computingCells++
		}
	}
	statsStr := fmt.Sprintf("%d/%d", frozenCells, totalCells)
	if computingCells > 0 {
		statsStr += fmt.Sprintf(" %s", pendValStyle.Render(fmt.Sprintf("⚡%d", computingCells)))
	}
	header := headerStyle.Render(fmt.Sprintf("  ct watch  ·  %s  ·  %d programs  %s", now, len(m.programs), statsStr))
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
		label := " DETAIL "
		padLen := m.width - len(label)
		if padLen < 0 {
			padLen = 0
		}
		left := padLen / 2
		right := padLen - left
		sep := strings.Repeat("─", left) + label + strings.Repeat("─", right)
		buf.WriteString(detailDimStyle.Render(sep) + "\n")
		buf.WriteString(m.detailVP.View())
	}

	// Footer
	detailKey := "d detail"
	if m.showDetail {
		detailKey = "d hide"
	}
	buf.WriteString(footerStyle.Render(fmt.Sprintf("  j/k nav · tab/S-tab prog · g/G top/bot · enter toggle · e expand · c collapse · %s · / search · esc back · ? help · q quit", detailKey)))

	v := tea.NewView(buf.String())
	v.AltScreen = true
	return v
}

func cmdWatch(db *sql.DB, progID string) {
	s := spinner.New()
	model := watchModel{
		db:        db,
		progID:    progID,
		collapsed: make(map[string]bool),
		expanded:  make(map[string]bool),
		spinner:   s,
		stats: watchStats{
			sessionStart: time.Now(),
			cellVisits:   make(map[string]int),
		},
	}
	p := tea.NewProgram(model)
	finalModel, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "watch error: %v\n", err)
		os.Exit(1)
	}

	// Print session stats
	if m, ok := finalModel.(watchModel); ok {
		m.printStats()
	}
}

func (m watchModel) printStats() {
	st := m.stats
	dur := time.Since(st.sessionStart)

	// Finalize detail time if still open
	if st.detailOpenedAt != nil {
		st.detailTime += time.Since(*st.detailOpenedAt)
	}

	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "  ct watch session: %s\n", fmtDuration(dur))
	fmt.Fprintf(os.Stderr, "  nav: %d · expand: %d · collapse: %d · expand-all: %d · collapse-all: %d\n",
		st.navCount, st.expandCount, st.collapseCount, st.expandAll, st.collapseAll)
	fmt.Fprintf(os.Stderr, "  detail: %d opens (%s) · search: %d\n",
		st.detailOpens, fmtDuration(st.detailTime), st.searchCount)

	// Top visited cells
	if len(st.cellVisits) > 0 {
		type kv struct {
			key   string
			count int
		}
		var sorted []kv
		for k, v := range st.cellVisits {
			sorted = append(sorted, kv{k, v})
		}
		// Simple insertion sort (small N)
		for i := 1; i < len(sorted); i++ {
			for j := i; j > 0 && sorted[j].count > sorted[j-1].count; j-- {
				sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
			}
		}
		n := len(sorted)
		if n > 5 {
			n = 5
		}
		fmt.Fprintf(os.Stderr, "  most visited: ")
		for i := 0; i < n; i++ {
			if i > 0 {
				fmt.Fprintf(os.Stderr, ", ")
			}
			fmt.Fprintf(os.Stderr, "%s (%d)", sorted[i].key, sorted[i].count)
		}
		fmt.Fprintf(os.Stderr, "\n")
	}
	fmt.Fprintf(os.Stderr, "\n")
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

	pistonID := genPistonID()
	watch := progID == ""

	// Register piston (program_id = '' for watch mode)
	mustExecDB(db, "DELETE FROM pistons WHERE id = ?", pistonID)
	mustExecDB(db,
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
		mustExecDB(db,
			"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE assigned_piston = ? AND state = 'computing'",
			pistonID)
		mustExecDB(db, "DELETE FROM cell_claims WHERE piston_id = ?", pistonID)
		mustExecDB(db, "UPDATE pistons SET status = 'dead' WHERE id = ?", pistonID)
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
		mustExecDB(db, "UPDATE pistons SET last_heartbeat = NOW() WHERE id = ?", pistonID)

		es := replEvalStep(db, progID, pistonID, "")

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
// scans ALL programs (watch mode). modelHint filters by model_hint when set.
// Returns the action and cell info.
func replEvalStep(db *sql.DB, progID, pistonID string, modelHint string) evalStepResult {
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
		rc, err := findReadyCell(db, progID, "", modelHint)
		if err != nil {
			break // no ready cells
		}

		pid := rc.progID

		// Atomic claim
		res, err := db.Exec(
			"INSERT IGNORE INTO cell_claims (cell_id, piston_id, claimed_at) VALUES (?, ?, NOW())",
			rc.cellID, pistonID)
		if err != nil {
			continue
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			continue
		}

		// Claimed! Handle hard vs soft
		if rc.bodyType == "hard" {
			mustExecDB(db,
				"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
				pistonID, rc.cellID)

			if strings.HasPrefix(rc.body, "literal:") {
				literalVal := strings.TrimPrefix(rc.body, "literal:")
				// Only freeze yields that aren't already frozen (pre-frozen by pour SQL for multi-yield hard cells)
				mustExecDB(db,
					"UPDATE yields SET value_text = ?, is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND is_frozen = FALSE",
					literalVal, rc.cellID)
				mustExecDB(db,
					"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
					rc.cellID)
				mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", rc.cellID)
				mustExecDB(db,
					"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
					pistonID)
				mustExecDB(db,
					"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'Hard cell: literal value', NOW())",
					rc.cellID)
				mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "cell: freeze hard cell "+rc.cellName)

			} else if strings.HasPrefix(rc.body, "sql:") {
				sqlQuery := strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
				yields := getYieldFields(db, pid, rc.cellName)
				var result string
				if err := db.QueryRow(sqlQuery).Scan(&result); err != nil {
					fmt.Printf("  ✗ %s SQL error: %v\n", rc.cellName, err)
					mustExecDB(db,
						"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
						rc.cellID)
					mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", rc.cellID)
					continue
				}
				for _, y := range yields {
					replSubmit(db, pid, rc.cellName, y, result)
				}
			}

			return evalStepResult{
				action: "evaluated", progID: pid,
				cellID: rc.cellID, cellName: rc.cellName,
				body: rc.body, bodyType: rc.bodyType,
			}
		}

		// Soft cell: mark computing and dispatch
		mustExecDB(db,
			"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
			pistonID, rc.cellID)
		mustExecDB(db,
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'claimed', CONCAT('Claimed by piston ', ?), NOW())",
			rc.cellID, pistonID)
		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "cell: claim soft cell "+rc.cellName)

		return evalStepResult{
			action: "dispatch", progID: pid,
			cellID: rc.cellID, cellName: rc.cellName,
			body: rc.body, bodyType: rc.bodyType,
		}
	}

	return evalStepResult{action: "quiescent", progID: progID}
}

// replSubmit writes a yield value, checks deterministic oracles, and
// freezes the cell if all yields are frozen.
func replSubmit(db *sql.DB, progID, cellName, fieldName, value string) (string, string) {
	// Ensure auto-commit is off (stored procedures manage their own commits)
	mustExecDB(db, "SET @@dolt_transaction_commit = 0")

	var cellID string
	err := db.QueryRow(
		"SELECT id FROM cells WHERE program_id = ? AND name = ? AND state = 'computing'",
		progID, cellName).Scan(&cellID)
	if err != nil {
		return "error", fmt.Sprintf("Cell %q not found or not computing", cellName)
	}

	mustExecDB(db, "DELETE FROM yields WHERE cell_id = ? AND field_name = ?", cellID, fieldName)
	mustExecDB(db,
		"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?, FALSE, NULL)",
		cellID, fieldName, value)

	// Check deterministic oracles
	var detCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM oracles WHERE cell_id = ? AND oracle_type = 'deterministic'",
		cellID).Scan(&detCount)

	if detCount > 0 {
		detPass := 0
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
						detPass++
					}
				case cond == "is_json_array":
					if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
						detPass++
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
							detPass++
						}
					}
				}
			}
			rows.Close()
		}

		if detPass < detCount {
			mustExecDB(db,
				"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'oracle_fail', ?, NOW())",
				cellID, fmt.Sprintf("Oracle check failed: %d/%d deterministic passed", detPass, detCount))
			return "oracle_fail", fmt.Sprintf("%d/%d deterministic oracles passed", detPass, detCount)
		}
	}

	// Log semantic oracles (not machine-checked yet — piston self-judges)
	var semCount int
	db.QueryRow(
		"SELECT COUNT(*) FROM oracles WHERE cell_id = ? AND oracle_type = 'semantic'",
		cellID).Scan(&semCount)
	if semCount > 0 {
		semRows, _ := db.Query(
			"SELECT assertion FROM oracles WHERE cell_id = ? AND oracle_type = 'semantic'",
			cellID)
		if semRows != nil {
			for semRows.Next() {
				var assertion string
				semRows.Scan(&assertion)
				mustExecDB(db,
					"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'oracle_semantic', ?, NOW())",
					cellID, fmt.Sprintf("Semantic (trust piston): %s", assertion))
			}
			semRows.Close()
		}
	}

	mustExecDB(db,
		"UPDATE yields SET is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND field_name = ?",
		cellID, fieldName)

	var unfrozen int
	db.QueryRow(
		"SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE",
		cellID).Scan(&unfrozen)

	if unfrozen > 0 {
		// Partial freeze: commit the yield so it persists across sessions
		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: yield %s.%s", cellName, fieldName))
	}

	if unfrozen == 0 {
		mustExecDB(db,
			"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
			cellID)

		// Get piston before deleting claim
		var claimPiston string
		db.QueryRow("SELECT piston_id FROM cell_claims WHERE cell_id = ?", cellID).Scan(&claimPiston)
		mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", cellID)
		if claimPiston != "" {
			mustExecDB(db,
				"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
				claimPiston)
		}

		mustExecDB(db,
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'All yields frozen', NOW())",
			cellID)

		// Record bindings (v2 frame model): which frames this cell read from
		recordBindings(db, progID, cellName, cellID)

		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: freeze %s.%s", cellName, fieldName))

		// Stem cell respawn: replace frozen stem with fresh declared copy
		var bodyType string
		db.QueryRow("SELECT body_type FROM cells WHERE id = ?", cellID).Scan(&bodyType)
		if bodyType == "stem" && progID == "cell-zero-eval" {
			replRespawnStem(db, progID, cellName, cellID)
		}
	}

	return "ok", fmt.Sprintf("Yield frozen: %s.%s", cellName, fieldName)
}

// replRespawnStem replaces a frozen stem cell with a fresh declared copy.
// Only respawns "perpetual" stem cells (like eval-one). Iteration-expanded
// stem cells (name-1, name-2, etc.) are NOT respawned — they stay frozen.
func replRespawnStem(db *sql.DB, progID, cellName, frozenID string) {
	// Don't respawn iteration cells (name ends in -N where N is numeric)
	if isIterationCell(cellName) {
		return
	}

	// Read the body and yield field names from the frozen cell
	var body sql.NullString
	if err := db.QueryRow("SELECT body FROM cells WHERE id = ?", frozenID).Scan(&body); err != nil {
		log.Printf("WARN: respawn %s: read body: %v", cellName, err)
		return
	}

	var yieldFields []string
	rows, err := db.Query("SELECT field_name FROM yields WHERE cell_id = ?", frozenID)
	if err == nil {
		for rows.Next() {
			var f string
			rows.Scan(&f)
			yieldFields = append(yieldFields, f)
		}
		rows.Close()
	}

	// Delete frozen cell (all FK children first: oracles, givens, yields)
	mustExecDB(db, "DELETE FROM oracles WHERE cell_id = ?", frozenID)
	mustExecDB(db, "DELETE FROM givens WHERE cell_id = ?", frozenID)
	mustExecDB(db, "DELETE FROM yields WHERE cell_id = ?", frozenID)
	mustExecDB(db, "DELETE FROM cells WHERE id = ?", frozenID)

	// Insert fresh declared copy with new ID
	var newID string
	db.QueryRow("SELECT CONCAT(?, '-', SUBSTR(MD5(RAND()), 1, 8))", progID[:min(8, len(progID))]).Scan(&newID)

	mustExecDB(db,
		"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES (?, ?, ?, 'stem', ?, 'declared')",
		newID, progID, cellName, body.String)

	for _, f := range yieldFields {
		var yID string
		db.QueryRow("SELECT CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8))").Scan(&yID)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, field_name) VALUES (?, ?, ?)",
			yID, newID, f)
	}

	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: respawn stem %s", cellName))
}

// isIterationCell returns true if the cell name ends in -N (numeric suffix).
func isIterationCell(name string) bool {
	idx := strings.LastIndex(name, "-")
	if idx < 0 || idx == len(name)-1 {
		return false
	}
	suffix := name[idx+1:]
	for _, ch := range suffix {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// replCellCounts returns (total, frozen, ready) cell counts for a program.
func replCellCounts(db *sql.DB, progID string) (total, frozen, ready int) {
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&total)
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'frozen'", progID).Scan(&frozen)
	if err := db.QueryRow(`
		SELECT COUNT(*) FROM cells c
		WHERE c.program_id = ? AND c.state = 'declared'
		AND NOT EXISTS (
		    SELECT 1 FROM givens g
		    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
		    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		    WHERE g.cell_id = c.id AND g.is_optional = FALSE AND y.id IS NULL
		)`, progID).Scan(&ready); err != nil {
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
	rows, err := db.Query("SELECT oracle_type, assertion FROM oracles WHERE cell_id = ?", cellID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var otype, a sql.NullString
		rows.Scan(&otype, &a)
		if a.Valid {
			prefix := "⊨"
			if otype.Valid && otype.String == "semantic" {
				prefix = "⊨~" // semantic (piston-judged)
			}
			out = append(out, prefix+" "+a.String)
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
	if rRows, err := db.Query(`
		SELECT c.id FROM cells c
		WHERE c.program_id = ? AND c.state = 'declared'
		AND NOT EXISTS (
		    SELECT 1 FROM givens g
		    JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
		    LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		    WHERE g.cell_id = c.id AND g.is_optional = FALSE AND y.id IS NULL
		)`, progID); err == nil {
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

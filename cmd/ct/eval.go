package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"time"
)

// cmdRun drives the eval loop. Hard cells freeze inline. Soft cells print
// the resolved prompt and stop — the piston (you) evaluates and calls ct submit.
func cmdRun(db *sql.DB, progID string) {
	pistonID := genPistonID()
	hardSQLFails := map[string]int{} // track hard SQL cell failures to prevent infinite loops
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
					hardSQLFails[cellID.String]++
					fmt.Printf("  ✗ %s SQL error (attempt %d/3): %v\n", cellName.String, hardSQLFails[cellID.String], err)
					if hardSQLFails[cellID.String] >= 3 {
						fmt.Printf("  ⊥ %s — bottomed after 3 SQL failures\n", cellName.String)
						bottomCell(db, progID, cellName.String, cellID.String,
							fmt.Sprintf("hard SQL failed 3x: %v", err))
						mustExec(db, "CALL DOLT_COMMIT('-Am', ?)",
							fmt.Sprintf("cell: bottom hard SQL cell %s after 3 failures", cellName.String))
					} else {
						mustExec(db, "UPDATE cells SET state = 'declared' WHERE id = ?", cellID.String)
					}
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
		// Check if the program is now complete (stem cells excluded per formal model)
		var remaining int
		db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ? AND body_type != 'stem' AND state NOT IN ('frozen', 'bottom')", progID).Scan(&remaining)
		if remaining == 0 {
			fmt.Println("COMPLETE")
			emitCompletionBead(db, progID)
		}
	case "oracle_fail":
		fmt.Printf("✗ %s.%s oracle failed: %s\n", cellName, field, msg)
		fmt.Printf("  → revise and resubmit: ct submit %s %s %s '<revised>'\n", progID, cellName, field)
		os.Exit(1)
	default:
		fmt.Printf("✗ %s: %s\n", result, msg)
		os.Exit(1)
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
		SELECT rc.id, rc.program_id, rc.name, rc.body, rc.body_type, rc.model_hint
		FROM ready_cells rc
		WHERE rc.id NOT IN (SELECT cell_id FROM cell_claims)`

	var queryArgs []interface{}

	if progID != "" {
		readySQL += " AND rc.program_id = ?"
		queryArgs = append(queryArgs, progID)
	}
	if excludeProgram != "" {
		readySQL += " AND rc.program_id != ?"
		queryArgs = append(queryArgs, excludeProgram)
	}
	if modelHint != "" {
		readySQL += " AND (rc.model_hint IS NULL OR rc.model_hint = ?)"
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
	// Join through frames to get the frozen yield from the latest generation.
	// COALESCE handles old yields without frame_id (backward compat).
	// For stem cells with multiple frozen generations, we want the latest.
	rows, err := db.Query(`
		SELECT g.source_cell, g.source_field, y.value_text
		FROM givens g
		JOIN cells c ON c.id = g.cell_id
		JOIN cells src ON src.program_id = c.program_id AND src.name = g.source_cell
		JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field AND y.is_frozen = 1
		LEFT JOIN frames f ON f.id = COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0'))
		WHERE c.program_id = ? AND c.name = ?
		ORDER BY COALESCE(f.generation, 0) DESC`, progID, cellName)
	if err != nil {
		return m
	}
	defer rows.Close()
	seen := make(map[string]bool)          // track seen source_cell+field pairs (latest gen wins)
	bareValues := make(map[string][]string) // collect all values per bare field name
	for rows.Next() {
		var sc, sf, v sql.NullString
		rows.Scan(&sc, &sf, &v)
		qualified := sc.String + "→" + sf.String
		if seen[qualified] {
			continue // already have the latest generation's value
		}
		seen[qualified] = true
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
		SELECT DISTINCT y.field_name FROM yields y JOIN cells c ON c.id = y.cell_id
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

// recordBindings writes binding edges for a frozen cell: which frames it read from.
// Enforces formal model invariants:
//   - I10 generationOrdered: same-cell bindings must go backward in generation
//   - I11 bindingsPointToFrozen: producer frames must be fully frozen
func recordBindings(db *sql.DB, progID, cellName, cellID string) {
	// Find the consumer frame and its generation
	var consumerFrame string
	var consumerGen int
	err := db.QueryRow(
		"SELECT id, generation FROM frames WHERE program_id = ? AND cell_name = ? ORDER BY generation DESC LIMIT 1",
		progID, cellName).Scan(&consumerFrame, &consumerGen)
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

		// Find the producer frame — use the frame_id from the frozen yield we consumed.
		// INNER JOIN to frames ensures the producer frame exists (formal: ∃ f ∈ r.frames).
		var producerFrame string
		var producerGen int
		err := db.QueryRow(`
			SELECT f.id, f.generation
			FROM yields y
			JOIN cells src ON src.id = y.cell_id
			JOIN frames f ON f.id = y.frame_id
			WHERE src.program_id = ? AND src.name = ? AND y.field_name = ? AND y.is_frozen = 1
			  AND y.frame_id IS NOT NULL
			ORDER BY f.generation DESC LIMIT 1`,
			progID, srcCell, srcField).Scan(&producerFrame, &producerGen)
		if err != nil {
			continue
		}

		// I11 (bindingsPointToFrozen): verify the producer frame is fully frozen.
		// Formal spec: r.frameStatus f = .frozen, which requires ALL cell definition
		// fields to have frozen yields for this frame (not just "no unfrozen yields").
		var totalYields, frozenYields int
		db.QueryRow(`
			SELECT COUNT(*), COALESCE(SUM(CASE WHEN y.is_frozen = TRUE THEN 1 ELSE 0 END), 0)
			FROM yields y
			WHERE y.cell_id IN (SELECT id FROM cells WHERE program_id = ? AND name = ?)
			  AND y.frame_id = ?`,
			progID, srcCell, producerFrame).Scan(&totalYields, &frozenYields)
		if totalYields == 0 || frozenYields < totalYields {
			log.Printf("I11 bindingsPointToFrozen: skipping binding from %s.%s frame %s — %d/%d yields frozen", srcCell, srcField, producerFrame, frozenYields, totalYields)
			continue
		}

		// I10 (generationOrdered): for same-cell bindings (stem cells reading their own
		// previous generation), the producer generation must be strictly less than the
		// consumer generation. This prevents cycles in the DAG.
		if srcCell == cellName && producerGen >= consumerGen {
			log.Printf("I10 generationOrdered: skipping same-cell binding %s gen %d -> gen %d (producer must be < consumer)", cellName, producerGen, consumerGen)
			continue
		}

		// Record the binding
		db.Exec(
			"INSERT IGNORE INTO bindings (id, consumer_frame, producer_frame, field_name) VALUES (CONCAT('b-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?)",
			consumerFrame, producerFrame, srcField)
	}
}

// ===================================================================
// Piston: autonomous eval loop (ct next -> think -> ct submit)
// ===================================================================
//
// ct piston              -- loop forever, any program
// ct piston <program-id> -- loop for one program
//
// For LLM pistons (polecats), this is the main entry point. It calls
// ct next internally, prints the cell prompt to stdout, reads the
// piston's answer from a callback mechanism (the LLM session uses
// bash to call ct submit), and loops.
//
// But since the piston IS the LLM session running this command, and
// the LLM can't read its own stdout mid-stream, the piston loop is
// actually: print instructions -> exit -> LLM calls ct submit -> LLM
// calls ct piston again. Ralph mode handles the cycling.
//
// For simplicity, ct piston is a wrapper that:
// 1. Registers once
// 2. Loops: ct next (inline) -> if soft, prints prompt and STOPS
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
			emitCompletionBead(db, progID)
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
// ct next          -- claim any ready cell from any program
// ct next <prog>   -- claim from a specific program
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
			replRelease(db, claimedCellID, claimedPistonID, "interrupt")
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
		emitCompletionBead(db, progID)
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
		// Soft cell claimed. Do NOT release on normal exit — the piston
		// needs the cell to stay in 'computing' for ct submit to find it.
		// Only release on interrupt (handled by signal handler above).
		// Clear the defer-tracked ID so the defer is a no-op on normal return.
		claimedCellID = ""
		claimedPistonID = ""

		// Print everything the piston needs.
		fmt.Printf("PROGRAM: %s\n", es.progID)
		fmt.Printf("CELL: %s\n", es.cellName)
		fmt.Printf("CELL_ID: %s\n", es.cellID)
		fmt.Printf("BODY_TYPE: soft\n")
		fmt.Printf("PISTON: %s\n", pistonID)

		// Resolved inputs
		inputs := resolveInputs(db, es.progID, es.cellName)
		var prompt string
		if isLuaBody(es.body) {
			// Lua soft cell: call body_fn(env) to get the prompt string
			var luaErr error
			prompt, luaErr = evalLuaSoftPrompt(es.body, inputs)
			if luaErr != nil {
				fmt.Printf("  ✗ %s Lua soft prompt error: %v\n", es.cellName, luaErr)
				prompt = fmt.Sprintf("[Lua soft prompt error: %v]", luaErr)
			}
		} else {
			prompt = interpolateBody(es.body, inputs)
		}
		for k, v := range inputs {
			if !strings.Contains(k, "→") {
				continue
			}
			fmt.Printf("GIVEN: %s ≡ %s\n", k, v)
		}

		// Body (the prompt with interpolated values)
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
		replReleaseAll(db, pistonID, "interrupt")
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
	// Reap stale claims (2-minute TTL) — prevents dead pistons from blocking the DAG forever.
	db.Exec(`UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL
		WHERE state = 'computing' AND computing_since < NOW() - INTERVAL 2 MINUTE`)
	db.Exec(`DELETE FROM cell_claims WHERE claimed_at < NOW() - INTERVAL 2 MINUTE`)

	// Single-program mode: check if that program is complete
	// Stem cells are excluded: formal model says programComplete only checks non-stem cells
	if progID != "" {
		var remaining int
		db.QueryRow(
			"SELECT COUNT(*) FROM cells WHERE program_id = ? AND body_type != 'stem' AND state NOT IN ('frozen', 'bottom')",
			progID).Scan(&remaining)
		if remaining == 0 {
			return evalStepResult{action: "complete", progID: progID}
		}
	}

	// Find and claim a ready cell with frame-level mutex (formal: claimMutex I6).
	// The formal model requires: frame exists, is ready, and not already claimed.
	// See Retort.lean claimValid and Claims.lean claimStep.
	failedCells := make(map[string]bool) // track cells that failed this step (e.g. broken SQL)
	for attempt := 0; attempt < 50; attempt++ {
		rc, err := findReadyCell(db, progID, "", modelHint)
		if err != nil {
			break // no ready cells
		}
		if failedCells[rc.cellID] {
			break // only ready cell already failed — stop retrying
		}

		pid := rc.progID

		// Ensure frame exists before claiming (stem cells don't get gen-0 at pour time).
		// Formal: claimValid requires ∃ f ∈ r.frames, f.id = cd.frameId.
		ensureFrameForCell(db, rc.progID, rc.cellName, rc.cellID)

		// Resolve frame ID (formal: ClaimData.frameId)
		frameID := latestFrameID(db, rc.progID, rc.cellName)
		if frameID == "" {
			continue // no frame — cannot satisfy claimValid
		}

		// Atomic frame-level claim (formal: claimMutex — at most one claim per frame).
		// INSERT IGNORE with UNIQUE(frame_id) provides the mutex guarantee.
		// Matches Claims.lean claimStep: `if s.holder fid |>.isNone then ...`
		res, err := db.Exec(
			"INSERT IGNORE INTO cell_claims (cell_id, frame_id, piston_id, claimed_at) VALUES (?, ?, ?, NOW())",
			rc.cellID, frameID, pistonID)
		if err != nil {
			continue
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			continue // frame already claimed — claimValid failed (frameClaim not isNone)
		}

		// Ensure frame exists for this cell (idempotent — gen-0 created at pour time)
		ensureFrameForCell(db, rc.progID, rc.cellName, rc.cellID)

		// Log claim (v2 frame model audit trail)
		frameID = latestFrameID(db, rc.progID, rc.cellName)
		if frameID != "" {
			db.Exec("INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action) VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, 'claimed')",
				frameID, pistonID)
		}

		// Bottom propagation (formal: inputsPoisoned → errorOutputs)
		// If any non-optional dependency is bottomed, this cell bottoms too.
		if hasBottomedDependency(db, rc.progID, rc.cellID) {
			bottomCell(db, rc.progID, rc.cellName, rc.cellID, "bottom: dependency error")
			mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
				fmt.Sprintf("cell: bottom propagation %s", rc.cellName))
			fmt.Printf("  ⊥ %s — bottom propagation (poisoned input)\n", rc.cellName)
			return evalStepResult{
				action: "evaluated", progID: pid,
				cellID: rc.cellID, cellName: rc.cellName,
				body: rc.body, bodyType: rc.bodyType,
			}
		}

		// Claimed! Handle hard vs soft
		if rc.bodyType == "hard" {
			mustExecDB(db,
				"UPDATE cells SET state = 'computing', computing_since = NOW(), assigned_piston = ? WHERE id = ?",
				pistonID, rc.cellID)

			if strings.HasPrefix(rc.body, "literal:") {
				literalVal := strings.TrimPrefix(rc.body, "literal:")
				// Only freeze yields that aren't already frozen (pre-frozen by pour SQL for multi-yield hard cells)
				// Also set frame_id (COALESCE preserves if already set by pour)
				mustExecDB(db,
					"UPDATE yields SET value_text = ?, is_frozen = TRUE, frozen_at = NOW(), frame_id = COALESCE(frame_id, ?) WHERE cell_id = ? AND is_frozen = FALSE",
					literalVal, frameID, rc.cellID)
				mustExecDB(db,
					"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
					rc.cellID)
				mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", rc.cellID)
				mustExecDB(db,
					"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
					pistonID)
				// claim_log: record completion (formal: claims.filter removes claim on freeze)
				if frameID != "" {
					db.Exec("INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action) VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, 'completed')",
						frameID, pistonID)
				}
				mustExecDB(db,
					"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'Hard cell: literal value', NOW())",
					rc.cellID)
				// Claim completion audit trail (frame-level)
				db.Exec("INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action) VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, 'completed')",
					frameID, pistonID)
				mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "cell: freeze hard cell "+rc.cellName)

			} else if strings.HasPrefix(rc.body, "sql:") {
				sqlQuery := strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
				yields := getYieldFields(db, pid, rc.cellName)
				var result string
				if err := db.QueryRow(sqlQuery).Scan(&result); err != nil {
					// Count prior failures from trace to detect repeated errors
					var failCount int
					db.QueryRow("SELECT COUNT(*) FROM trace WHERE cell_id = ? AND event_type = 'released' AND detail LIKE '%failure%'",
						rc.cellID).Scan(&failCount)
					failCount++ // include this attempt
					fmt.Printf("  ✗ %s SQL error (attempt %d/3): %v\n", rc.cellName, failCount, err)
					if failCount >= 3 {
						fmt.Printf("  ⊥ %s — bottomed after 3 SQL failures\n", rc.cellName)
						bottomCell(db, pid, rc.cellName, rc.cellID,
							fmt.Sprintf("hard SQL failed 3x: %v", err))
						mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
							fmt.Sprintf("cell: bottom hard SQL cell %s after 3 failures", rc.cellName))
					} else {
						replRelease(db, rc.cellID, pistonID, "failure")
					}
					continue
				}
				for _, y := range yields {
					replSubmit(db, pid, rc.cellName, y, result)
				}
			} else if isLuaBody(rc.body) {
				// Lua compute cell: evaluate function with resolved givens
				env := resolveInputs(db, pid, rc.cellName)
				result, err := evalLuaCompute(rc.body, env)
				if err != nil {
					fmt.Printf("  ✗ %s Lua compute error: %v\n", rc.cellName, err)
					bottomCell(db, pid, rc.cellName, rc.cellID,
						fmt.Sprintf("lua compute failed: %v", err))
					mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
						fmt.Sprintf("cell: bottom lua compute cell %s", rc.cellName))
					continue
				}
				yields := getYieldFields(db, pid, rc.cellName)
				for _, y := range yields {
					if v, ok := result[y]; ok {
						replSubmit(db, pid, rc.cellName, y, v)
					} else {
						// Yield not in result: bottom
						bottomCell(db, pid, rc.cellName, rc.cellID,
							fmt.Sprintf("lua compute: missing yield %q", y))
						mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
							fmt.Sprintf("cell: bottom lua compute cell %s (missing yield)", rc.cellName))
						break
					}
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

	// Look up frame_id for this cell (latest generation)
	frameID := latestFrameID(db, progID, cellName)

	// Append-only: reject if this yield is already frozen for the current frame.
	// Use frame_id when available; fall back to cell_id-only check for old data.
	var alreadyFrozen int
	if frameID != "" {
		db.QueryRow("SELECT COUNT(*) FROM yields WHERE cell_id = ? AND field_name = ? AND is_frozen = 1 AND COALESCE(frame_id, CONCAT('f-', cell_id, '-0')) = ?",
			cellID, fieldName, frameID).Scan(&alreadyFrozen)
	} else {
		db.QueryRow("SELECT COUNT(*) FROM yields WHERE cell_id = ? AND field_name = ? AND is_frozen = 1",
			cellID, fieldName).Scan(&alreadyFrozen)
	}
	if alreadyFrozen > 0 {
		return "error", "yield already frozen"
	}

	// Write value into existing unfrozen yield slot (created at pour or respawn time)
	res, uerr := db.Exec(
		"UPDATE yields SET value_text = ?, frame_id = COALESCE(frame_id, ?) WHERE cell_id = ? AND field_name = ? AND is_frozen = FALSE",
		value, frameID, cellID, fieldName)
	if uerr != nil {
		return "error", fmt.Sprintf("update yield: %v", uerr)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// No unfrozen slot exists — create one (backward compat with old programs)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES (CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, ?, ?, FALSE, NULL)",
			cellID, frameID, fieldName, value)
	}

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
				// Guard oracles are flow control, not yield validators
				if strings.HasPrefix(cond, "guard:") {
					detPass++ // auto-pass guard oracles in the check loop
					continue
				}
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

	// Freeze the yield — scope to current frame to avoid freezing old-frame yield slots
	if frameID != "" {
		mustExecDB(db,
			"UPDATE yields SET is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND field_name = ? AND COALESCE(frame_id, CONCAT('f-', cell_id, '-0')) = ?",
			cellID, fieldName, frameID)
	} else {
		mustExecDB(db,
			"UPDATE yields SET is_frozen = TRUE, frozen_at = NOW() WHERE cell_id = ? AND field_name = ? AND is_frozen = FALSE",
			cellID, fieldName)
	}

	// Count unfrozen yields for the current frame only
	var unfrozen int
	if frameID != "" {
		db.QueryRow(
			"SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE AND COALESCE(frame_id, CONCAT('f-', cell_id, '-0')) = ?",
			cellID, frameID).Scan(&unfrozen)
	} else {
		db.QueryRow(
			"SELECT COUNT(*) FROM yields WHERE cell_id = ? AND is_frozen = FALSE",
			cellID).Scan(&unfrozen)
	}

	if unfrozen > 0 {
		// Partial freeze: commit the yield so it persists across sessions
		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: yield %s.%s", cellName, fieldName))
	}

	if unfrozen == 0 {
		mustExecDB(db,
			"UPDATE cells SET state = 'frozen', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
			cellID)

		// Get piston and frame_id before deleting claim (formal: freeze filters claims by frameId)
		var claimPiston, claimFrameID string
		db.QueryRow("SELECT piston_id, frame_id FROM cell_claims WHERE cell_id = ?", cellID).Scan(&claimPiston, &claimFrameID)
		mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", cellID)
		if claimPiston != "" {
			mustExecDB(db,
				"UPDATE pistons SET cells_completed = cells_completed + 1, last_heartbeat = NOW() WHERE id = ?",
				claimPiston)
		}

		mustExecDB(db,
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'frozen', 'All yields frozen', NOW())",
			cellID)

		// Record bindings + claim completion (frame-level, matching formal model)
		// Ensure frame exists before recording bindings (idempotent safety net)
		ensureFrameForCell(db, progID, cellName, cellID)
		recordBindings(db, progID, cellName, cellID)
		if claimPiston != "" {
			// Use frame_id from claim if available, fallback to lookup
			frameID := claimFrameID
			if frameID == "" {
				frameID = latestFrameID(db, progID, cellName)
			}
			if frameID != "" {
				db.Exec("INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action) VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, 'completed')",
					frameID, claimPiston)
			}
		}

		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: freeze %s.%s", cellName, fieldName))

		// Guard skip: if iteration cell with satisfied guard, mark remaining as bottom
		checkGuardSkip(db, progID, cellName, cellID)

		// Stem cell respawn: replace frozen stem with fresh declared copy
		var bodyType string
		db.QueryRow("SELECT body_type FROM cells WHERE id = ?", cellID).Scan(&bodyType)
		if bodyType == "stem" {
			replRespawnStem(db, progID, cellName, cellID)
		}
	}

	return "ok", fmt.Sprintf("Yield frozen: %s.%s", cellName, fieldName)
}

// checkGuardSkip checks if an iteration cell has a satisfied guard.
// If so, marks all subsequent iteration cells as bottom.
func checkGuardSkip(db *sql.DB, progID, cellName, cellID string) {
	if !isIterationCell(cellName) {
		return
	}

	// Check for guard oracle
	var guardExpr string
	err := db.QueryRow(
		"SELECT condition_expr FROM oracles WHERE cell_id = ? AND condition_expr LIKE 'guard:%'",
		cellID).Scan(&guardExpr)
	if err != nil {
		return // no guard
	}

	// Parse guard: "guard:FIELD=VALUE"
	guardBody := strings.TrimPrefix(guardExpr, "guard:")
	parts := strings.SplitN(guardBody, "=", 2)
	if len(parts) != 2 {
		return
	}
	guardField := strings.TrimSpace(parts[0])
	guardValue := strings.Trim(strings.TrimSpace(parts[1]), "\"")

	// Check if the guard field's yield matches
	var actualValue string
	err = db.QueryRow(
		"SELECT value_text FROM yields WHERE cell_id = ? AND field_name = ? AND is_frozen = 1",
		cellID, guardField).Scan(&actualValue)
	if err != nil || strings.TrimSpace(actualValue) != guardValue {
		return // guard not satisfied
	}

	// Guard satisfied! Extract base name and current iteration number
	idx := strings.LastIndex(cellName, "-")
	if idx < 0 {
		return
	}
	baseName := cellName[:idx]
	currentN, _ := strconv.Atoi(cellName[idx+1:])

	// Find the max iteration (from the iterate count stored in oracles of sibling cells)
	// Simpler: just mark all declared cells with name > current as bottom
	rows, _ := db.Query(
		"SELECT id, name FROM cells WHERE program_id = ? AND state = 'declared' AND name LIKE ?",
		progID, baseName+"-%")
	if rows == nil {
		return
	}
	defer rows.Close()

	bottomed := 0
	for rows.Next() {
		var sibID, sibName string
		rows.Scan(&sibID, &sibName)
		// Parse sibling iteration number
		sibIdx := strings.LastIndex(sibName, "-")
		if sibIdx < 0 {
			continue
		}
		sibN, err := strconv.Atoi(sibName[sibIdx+1:])
		if err != nil {
			continue // not a numbered iteration (might be a judge)
		}
		if sibN > currentN {
			ensureFrameForCell(db, progID, sibName, sibID)
			bottomCell(db, progID, sibName, sibID, "bottom: guard skip")
			bottomed++
		}
	}

	if bottomed > 0 {
		// Also bottom the judges of bottomed iterations (with frozen yields for propagation)
		for n := currentN + 1; n <= currentN+bottomed; n++ {
			pattern := fmt.Sprintf("%s-%d-judge-%%", baseName, n)
			judgeRows, _ := db.Query(
				"SELECT id, name FROM cells WHERE program_id = ? AND name LIKE ? AND state = 'declared'",
				progID, pattern)
			if judgeRows != nil {
				for judgeRows.Next() {
					var jID, jName string
					judgeRows.Scan(&jID, &jName)
					ensureFrameForCell(db, progID, jName, jID)
					bottomCell(db, progID, jName, jID, "bottom: guard skip")
				}
				judgeRows.Close()
			}
		}
		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
			fmt.Sprintf("cell: guard satisfied at %s, bottomed %d remaining iterations", cellName, bottomed))
		fmt.Printf("  ⊥ guard satisfied at %s — %d iterations skipped\n", cellName, bottomed)
	}
}

// hasBottomedDependency checks if any non-optional given of a cell comes from
// a source cell in 'bottom' state. This implements the formal model's
// inputsPoisoned check (Denotational.lean: inputsPoisoned).
func hasBottomedDependency(db *sql.DB, progID, cellID string) bool {
	var count int
	db.QueryRow(`
		SELECT COUNT(*) FROM givens g
		JOIN cells src ON src.program_id = ? AND src.name = g.source_cell
		WHERE g.cell_id = ? AND g.is_optional = FALSE AND src.state = 'bottom'`,
		progID, cellID).Scan(&count)
	return count > 0
}

// bottomCell marks a cell as bottom and freezes its yields with error values.
// This implements the formal model's bottom propagation (Denotational.lean:
// errorOutputs). The cell's yields are marked is_frozen=TRUE and is_bottom=TRUE
// with a sentinel value, so downstream cells see them as "resolved" and can
// themselves propagate the bottom if needed.
func bottomCell(db *sql.DB, progID, cellName, cellID, reason string) {
	frameID := latestFrameID(db, progID, cellName)
	mustExecDB(db, "UPDATE cells SET state = 'bottom' WHERE id = ?", cellID)
	mustExecDB(db,
		"UPDATE yields SET is_bottom = TRUE, is_frozen = TRUE, value_text = ?, frozen_at = NOW(), frame_id = COALESCE(frame_id, ?) WHERE cell_id = ?",
		reason, frameID, cellID)
	mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", cellID)
	mustExecDB(db,
		"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'bottom', ?, NOW())",
		cellID, reason)
}

// replRelease removes a piston's claim on a cell, resetting the cell to
// 'declared' so another piston can claim it. This is the Go-native
// implementation of the formal RetortOp.release operation.
//
// The formal spec (Retort.lean) defines release as:
//   { r with claims := r.claims.filter (fun c => c.frameId != rd.frameId) }
//
// It only modifies the claims table — cells, frames, yields, bindings,
// and givens are all unchanged by release.
//
// reason: "failure" | "timeout" | "interrupt" — why the claim is being released.
func replRelease(db *sql.DB, cellID, pistonID, reason string) {
	// 1. Get frame_id before deleting claim (formal: release filters by frameId)
	var frameID string
	db.QueryRow("SELECT frame_id FROM cell_claims WHERE cell_id = ? AND piston_id = ?",
		cellID, pistonID).Scan(&frameID)

	// 2. Delete the claim (formal: r.claims.filter (fun c => c.frameId != rd.frameId))
	mustExecDB(db,
		"DELETE FROM cell_claims WHERE cell_id = ? AND piston_id = ?",
		cellID, pistonID)

	// 3. Reset cell state to declared (undo the computing transition)
	mustExecDB(db,
		"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ? AND state = 'computing'",
		cellID)

	// 4. Audit trail: claim_log (frame-level, matching formal model)
	if frameID == "" {
		// Fallback: look up frame from cell metadata (for pre-migration claims)
		var cellName, progID string
		db.QueryRow("SELECT name, program_id FROM cells WHERE id = ?", cellID).Scan(&cellName, &progID)
		frameID = latestFrameID(db, progID, cellName)
	}
	if frameID != "" {
		db.Exec("INSERT IGNORE INTO claim_log (id, frame_id, piston_id, action) VALUES (CONCAT('cl-', SUBSTR(MD5(RAND()), 1, 8)), ?, ?, 'released')",
			frameID, pistonID)
	}

	// 4. Trace log
	mustExecDB(db,
		"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'released', ?, NOW())",
		cellID, fmt.Sprintf("Released by piston %s: %s", pistonID, reason))
}

// replReleaseAll releases all claims held by a piston, resetting their cells
// to 'declared'. Used during piston shutdown / interrupt cleanup.
func replReleaseAll(db *sql.DB, pistonID, reason string) {
	// Find all cells claimed by this piston
	rows, err := db.Query(
		"SELECT cell_id FROM cell_claims WHERE piston_id = ?", pistonID)
	if err != nil {
		return
	}
	var cellIDs []string
	for rows.Next() {
		var cid string
		rows.Scan(&cid)
		cellIDs = append(cellIDs, cid)
	}
	rows.Close()

	for _, cid := range cellIDs {
		replRelease(db, cid, pistonID, reason)
	}
}

// replRespawnStem replaces a frozen stem cell with a fresh declared copy.
// Only respawns "perpetual" stem cells (like eval-one). Iteration-expanded
// stem cells (name-1, name-2, etc.) are NOT respawned — they stay frozen.
// replRespawnStem creates a new frame for a frozen stem cell so it can
// be re-evaluated. The cell row, its oracles, givens, and frozen yields
// all stay untouched (append-only). Only a new frame + fresh yield slots
// are inserted. The readiness check sees the new frame's unfrozen yields
// and treats the cell as ready.
//
// Iteration-expanded stem cells (name-1, name-2, etc.) are NOT respawned.
func replRespawnStem(db *sql.DB, progID, cellName, frozenID string) {
	// Don't respawn iteration cells (name ends in -N where N is numeric)
	if isIterationCell(cellName) {
		return
	}

	// Don't respawn stem cells with no givens — they have nothing to wait
	// for and would immediately become ready again, causing an infinite loop.
	var givenCount int
	db.QueryRow("SELECT COUNT(*) FROM givens WHERE cell_id = ?", frozenID).Scan(&givenCount)
	if givenCount == 0 {
		log.Printf("INFO: stem cell %s/%s has no givens — skipping respawn (would loop)", progID, cellName)
		return
	}

	// Lazy demand check: only spawn gen N+1 when at least one given's
	// source has a yield frozen AFTER the stem's last freeze time.
	// No new data → no spawn → no computation. (Call-by-need / lazy evaluation)
	//
	// Formal model: Retort.demandFromGivens (Retort.lean)
	// The formal model uses a structural check (frozen yield exists for source);
	// the Go code refines this with the frozen_at timestamp for temporal precision.
	// Both are monotone: once demand becomes true it stays true (yields are
	// append-only, so new frozen yields never disappear).
	//
	// Edge cases handled:
	//   - Self-reference (stem depends on itself): the stem's own yields
	//     have frozen_at == lastFreezeTime, so the strict ">" prevents
	//     self-triggering. Only EXTERNAL new data triggers a respawn.
	//   - Optional givens: included in the demand check (any new data,
	//     optional or not, justifies re-evaluation). Optionality only
	//     gates readiness, not demand.
	//   - First freeze (no prior frozen yields): falls through to spawn
	//     unconditionally — the stem must process its initial inputs.
	var lastFreezeTime sql.NullTime
	db.QueryRow(
		"SELECT MAX(frozen_at) FROM yields WHERE cell_id = ? AND is_frozen = 1",
		frozenID).Scan(&lastFreezeTime)

	if lastFreezeTime.Valid {
		// Check: any given has a source yield frozen AFTER our last freeze.
		// Includes optional givens — new optional data is still demand.
		var newWork int
		err := db.QueryRow(`
			SELECT COUNT(*) FROM givens g
			JOIN cells src ON src.program_id = ? AND src.name = g.source_cell
			JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
			  AND y.is_frozen = 1 AND y.frozen_at > ?
			WHERE g.cell_id = ?`,
			progID, lastFreezeTime.Time, frozenID).Scan(&newWork)
		if err != nil {
			log.Printf("WARN: respawn %s: demand check: %v", cellName, err)
			// On error, fall through to spawn (safe: eager is correct, just wasteful)
		} else if newWork == 0 {
			log.Printf("INFO: stem cell %s/%s has no new inputs — lazy skip", progID, cellName)
			return
		}
	}
	// If lastFreezeTime is not valid (no frozen yields yet), this is the
	// first freeze — always respawn (the stem needs to process its initial inputs).

	// Find current max generation for this cell name
	var maxGen int
	err := db.QueryRow(
		"SELECT COALESCE(MAX(generation), -1) FROM frames WHERE program_id = ? AND cell_name = ?",
		progID, cellName).Scan(&maxGen)
	if err != nil {
		log.Printf("WARN: respawn %s: read max gen: %v", cellName, err)
		return
	}
	nextGen := maxGen + 1

	// INSERT new frame at gen+1
	var frameID string
	db.QueryRow("SELECT CONCAT('f-', ?, '-', ?)", frozenID, nextGen).Scan(&frameID)
	if err := execDB(db,
		"INSERT INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, ?)",
		frameID, cellName, progID, nextGen); err != nil {
		log.Printf("WARN: respawn %s: insert frame: %v", cellName, err)
		return
	}

	// Reset cell state back to declared so it can be picked up again.
	// The cell row is immutable in terms of definition (body, givens,
	// oracles) but state must flip back to declared for the eval loop.
	mustExecDB(db,
		"UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?",
		frozenID)

	// Create fresh (unfrozen) yield slots for the new frame.
	// Read yield field names from the existing frozen yields.
	var yieldFields []string
	rows, qerr := db.Query("SELECT DISTINCT field_name FROM yields WHERE cell_id = ?", frozenID)
	if qerr == nil {
		for rows.Next() {
			var f string
			rows.Scan(&f)
			yieldFields = append(yieldFields, f)
		}
		rows.Close()
	}

	for _, f := range yieldFields {
		var yID string
		db.QueryRow("SELECT CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8))").Scan(&yID)
		mustExecDB(db,
			"INSERT INTO yields (id, cell_id, frame_id, field_name) VALUES (?, ?, ?, ?)",
			yID, frozenID, frameID, f)
	}

	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: respawn stem %s (gen %d)", cellName, nextGen))
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

// replBar prints a bar around text.
func replBar(text string) {
	bar := strings.Repeat("━", 56)
	fmt.Println(bar)
	fmt.Printf(" %s\n", text)
	fmt.Println(bar)
}

// replStepSep prints a step separator line.
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

		// Givens — show latest frame's yield value for each given
		if gRows, err := db.Query(`
			SELECT g.source_cell, g.source_field, g.is_optional,
			       y.value_text, COALESCE(y.is_frozen, FALSE), COALESCE(f.generation, 0) AS gen
			FROM givens g
			JOIN cells src ON src.name = g.source_cell AND src.program_id = ?
			LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
			LEFT JOIN frames f ON f.id = COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0'))
			WHERE g.cell_id = ?
			ORDER BY g.source_cell, g.source_field, gen DESC`, progID, c.id); err == nil {
			seenGiven := make(map[string]bool)
			for gRows.Next() {
				var sc, sf sql.NullString
				var opt, frozen sql.NullBool
				var val sql.NullString
				var gen int
				gRows.Scan(&sc, &sf, &opt, &val, &frozen, &gen)

				gKey := sc.String + "." + sf.String
				if seenGiven[gKey] {
					continue // already showed latest generation
				}
				seenGiven[gKey] = true

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

		// Yields — show only the latest frame's yields (avoid duplicates from stem respawn)
		latestFrame := latestFrameID(db, progID, c.name)
		yieldQuery := "SELECT field_name, value_text, is_frozen, is_bottom FROM yields WHERE cell_id = ?"
		var yieldArgs []interface{}
		yieldArgs = append(yieldArgs, c.id)
		if latestFrame != "" {
			yieldQuery += " AND COALESCE(frame_id, CONCAT('f-', cell_id, '-0')) = ?"
			yieldArgs = append(yieldArgs, latestFrame)
		}
		if yRows, err := db.Query(yieldQuery, yieldArgs...); err == nil {
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

// cmdThaw resets a cell to "ready for re-evaluation" by creating a gen N+1
// frame, then cascades to all cells that transitively depend on the target
// via givens. This is the inverse of freeze — it marks cells as needing
// re-evaluation without destroying their history (append-only frames).
func cmdThaw(db *sql.DB, progID, cellName string) {
	// Find the target cell
	var cellID string
	err := db.QueryRow("SELECT id FROM cells WHERE program_id = ? AND name = ?", progID, cellName).Scan(&cellID)
	if err != nil {
		fatal("cell not found: %s/%s", progID, cellName)
	}

	// Thaw the target cell
	thawCell(db, progID, cellName, cellID)

	// Cascade: find all transitive dependents and thaw them too.
	// A cell B depends on A if B has a given with source_cell = A.
	thawed := map[string]bool{cellName: true}
	queue := []string{cellName}
	for len(queue) > 0 {
		src := queue[0]
		queue = queue[1:]
		// Find cells whose givens reference src as source_cell
		rows, qerr := db.Query(`
			SELECT DISTINCT c.name, c.id FROM givens g
			JOIN cells c ON c.id = g.cell_id
			WHERE c.program_id = ? AND g.source_cell = ?`, progID, src)
		if qerr != nil {
			continue
		}
		for rows.Next() {
			var depName, depID string
			rows.Scan(&depName, &depID)
			if !thawed[depName] {
				thawed[depName] = true
				thawCell(db, progID, depName, depID)
				queue = append(queue, depName)
			}
		}
		rows.Close()
	}

	mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", fmt.Sprintf("cell: thaw %s/%s (%d cells)", progID, cellName, len(thawed)))
	fmt.Printf("thawed %d cells in %s\n", len(thawed), progID)
}

// thawCell resets a single cell to declared state and creates a gen N+1 frame
// with fresh yield slots. Existing frozen yields from prior generations are
// preserved (append-only).
func thawCell(db *sql.DB, progID, cellName, cellID string) {
	// Reset cell state to declared
	mustExecDB(db, "UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE id = ?", cellID)
	// Delete any claims
	mustExecDB(db, "DELETE FROM cell_claims WHERE cell_id = ?", cellID)

	// Find max generation for this cell and create gen N+1 frame
	var maxGen int
	db.QueryRow("SELECT COALESCE(MAX(generation), -1) FROM frames WHERE program_id = ? AND cell_name = ?", progID, cellName).Scan(&maxGen)
	nextGen := maxGen + 1
	prefix := progID
	if len(prefix) > 20 {
		prefix = prefix[:20]
	}
	frameID := fmt.Sprintf("f-%s-%s-%d", prefix, cellName, nextGen)
	mustExecDB(db,
		"INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, ?)",
		frameID, cellName, progID, nextGen)

	// Create fresh yield slots for the new frame, mirroring existing field names
	rows, qerr := db.Query("SELECT DISTINCT field_name FROM yields WHERE cell_id = ?", cellID)
	if qerr == nil {
		for rows.Next() {
			var field string
			rows.Scan(&field)
			var yID string
			db.QueryRow("SELECT CONCAT('y-', SUBSTR(MD5(RAND()), 1, 8))").Scan(&yID)
			mustExecDB(db,
				"INSERT INTO yields (id, cell_id, frame_id, field_name) VALUES (?, ?, ?, ?)",
				yID, cellID, frameID, field)
		}
		rows.Close()
	}

	fmt.Printf("  thaw %s (gen %d)\n", cellName, nextGen)
}

// emitCompletionBead creates a Gas Town bead summarizing a completed program's yields.
// This bridges the Cell runtime to the broader workspace: when a program finishes,
// the result is visible in beads as a closed task.
func emitCompletionBead(db *sql.DB, progID string) {
	// Collect frozen yields — latest frame generation per cell+field only
	rows, err := db.Query(`
		SELECT c.name, y.field_name, COALESCE(LEFT(y.value_text, 200), ''), COALESCE(f.generation, 0) AS gen
		FROM cells c
		JOIN yields y ON y.cell_id = c.id
		LEFT JOIN frames f ON f.id = COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0'))
		WHERE c.program_id = ? AND y.is_frozen = TRUE
		ORDER BY c.name, y.field_name, gen DESC`, progID)
	if err != nil {
		return
	}
	defer rows.Close()

	seen := make(map[string]bool)
	var lines []string
	for rows.Next() {
		var cell, field, val string
		var gen int
		rows.Scan(&cell, &field, &val, &gen)
		key := cell + "." + field
		if seen[key] {
			continue
		}
		seen[key] = true
		if val != "" {
			lines = append(lines, fmt.Sprintf("  %s.%s = %s", cell, field, val))
		}
	}

	if len(lines) == 0 {
		return
	}

	// Count cells
	var total int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&total)

	title := fmt.Sprintf("cell program complete: %s (%d cells)", progID, total)
	body := fmt.Sprintf("Program %s finished. All cells frozen.\n\nYields:\n%s",
		progID, strings.Join(lines, "\n"))

	// Try bd create — if bd isn't available, just log
	// Look for bd in PATH and common locations
	bdPath, err := exec.LookPath("bd")
	if err != nil {
		// Try common nix location
		for _, p := range []string{"/run/current-system/sw/bin/bd", "/nix/var/nix/profiles/default/bin/bd"} {
			if _, e := os.Stat(p); e == nil {
				bdPath = p
				break
			}
		}
	}
	if bdPath == "" {
		fmt.Fprintf(os.Stderr, "  (completion bead: bd not found in PATH)\n")
		return
	}

	// Create bead (capture ID for closing)
	c := exec.Command(bdPath, "create", "-t", "task", title, "--description", body, "--silent")
	out, err := c.Output()
	if err != nil {
		fmt.Fprintf(os.Stderr, "  (completion bead: bd create failed: %v)\n", err)
		return
	}
	beadID := strings.TrimSpace(string(out))
	if beadID == "" {
		return
	}
	// Close it immediately
	exec.Command(bdPath, "close", beadID).Run()
	fmt.Fprintf(os.Stderr, "  ✓ completion bead: %s\n", beadID)
}


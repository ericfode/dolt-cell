package main

import (
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
		prompt := interpolateBody(es.body, inputs)
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

// Action constants for evalStepResult — mirrors EffectEval.lean EvalAction.
const (
	actionComplete  = "complete"
	actionQuiescent = "quiescent"
	actionEvaluated = "evaluated" // formal: execPure (hard cell evaluated inline)
	actionDispatch  = "dispatch"  // formal: dispatchReplayable | dispatchNonReplayable
)

// evalStepResult holds the result of a Go-native eval step.
//
// Formal divergence: EffectEval.lean defines EvalAction as a proper inductive
// with five constructors (execPure, dispatchReplayable, dispatchNonReplayable,
// quiescent, complete). Go collapses to four string constants:
//   actionEvaluated = execPure (hard cell inline)
//   actionDispatch  = dispatchReplayable | dispatchNonReplayable
// The formal three-way dispatch is recoverable via the `effect` field.
type evalStepResult struct {
	action   string // actionComplete | actionQuiescent | actionEvaluated | actionDispatch
	progID   string // which program this cell belongs to
	cellID   string
	cellName string
	body     string
	bodyType string
	effect   string // pure, replayable, nonreplayable — recovers formal EvalAction distinction
}

// inferEffect classifies a cell's effect level based on its body type and body.
// Matches the formal model's canonical effect lattice:
//   Pure < Replayable < NonReplayable
//
// Pure:           literal: hard cells (deterministic, no I/O)
// Replayable:     sql: SELECT hard cells, all soft/stem cells (safe to retry)
// NonReplayable:  sql: INSERT/UPDATE/DELETE/CALL (side effects)
func inferEffect(bodyType, body string) string {
	if bodyType == "hard" {
		if strings.HasPrefix(body, "literal:") {
			return "pure"
		}
		if strings.HasPrefix(body, "dml:") {
			return "nonreplayable"
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
	return "replayable"
}

// replEvalStep finds the next ready cell and claims it. When progID is empty,
// scans ALL programs (watch mode). modelHint filters by model_hint when set.
// Returns the action and cell info.
func replEvalStep(db *sql.DB, progID, pistonID string, modelHint string) evalStepResult {
	// Reap stale claims (2-minute TTL).
	// Both operations run in a single multi-statement exec so another piston
	// cannot observe an inconsistent state (cell declared but claim still exists).
	db.Exec(`DELETE FROM cell_claims WHERE claimed_at < NOW() - INTERVAL 2 MINUTE;
		UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL
		WHERE state = 'computing' AND computing_since < NOW() - INTERVAL 2 MINUTE`)

	// Single-program mode: check if that program is complete
	// Stem cells are excluded: formal model says programComplete only checks non-stem cells
	if progID != "" {
		var remaining int
		db.QueryRow(
			"SELECT COUNT(*) FROM cells WHERE program_id = ? AND body_type != 'stem' AND state NOT IN ('frozen', 'bottom')",
			progID).Scan(&remaining)
		if remaining == 0 {
			return evalStepResult{action: actionComplete, progID: progID}
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
				action: actionEvaluated, progID: pid,
				cellID: rc.cellID, cellName: rc.cellName,
				body: rc.body, bodyType: rc.bodyType,
				effect: inferEffect(rc.bodyType, rc.body),
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
				mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)", "cell: freeze hard cell "+rc.cellName)

			} else if strings.HasPrefix(rc.body, "sql:") || strings.HasPrefix(rc.body, "dml:") {
				// dml: is sugar for sql: with NonReplayable classification.
				// inferEffect already classifies DML statements as nonreplayable.
				var sqlQuery string
				var prefix string
				if strings.HasPrefix(rc.body, "dml:") {
					sqlQuery = strings.TrimSpace(strings.TrimPrefix(rc.body, "dml:"))
					prefix = "DML"
				} else {
					sqlQuery = strings.TrimSpace(strings.TrimPrefix(rc.body, "sql:"))
					prefix = "SQL"
				}
				// Sandbox: validate the SQL before execution.
				// Hard cell bodies come from the parser (poured by user), but could
				// contain injected statements if the .cell file was crafted maliciously.
				if err := sandboxHardCellSQL(sqlQuery); err != nil {
					fmt.Printf("  ✗ %s sandbox violation: %v\n", rc.cellName, err)
					bottomCell(db, pid, rc.cellName, rc.cellID,
						fmt.Sprintf("sandbox violation: %v", err))
					mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
						fmt.Sprintf("cell: sandbox violation in %s", rc.cellName))
					failedCells[rc.cellID] = true
					continue
				}
				yields := getYieldFields(db, pid, rc.cellName)
				// Execute SQL and submit yields. For all effect levels, atomicity
				// is provided by DOLT_COMMIT (not MySQL transactions): execute DML,
				// submit yields, then DOLT_COMMIT makes it durable. If any step
				// fails before DOLT_COMMIT, the working set is dirty but uncommitted,
				// and replRelease resets the cell to 'declared'.
				//
				// Formal: EffectEval.lean execNonReplayableTransaction — atomicity
				// is at the Dolt commit level, not the SQL transaction level.
				var result string
				if err := db.QueryRow(sqlQuery).Scan(&result); err != nil {
					var failCount int
					db.QueryRow("SELECT COUNT(*) FROM trace WHERE cell_id = ? AND event_type = 'released' AND detail LIKE '%failure%'",
						rc.cellID).Scan(&failCount)
					failCount++
					fmt.Printf("  ✗ %s %s error (attempt %d/3): %v\n", rc.cellName, prefix, failCount, err)
					if failCount >= 3 {
						fmt.Printf("  ⊥ %s — bottomed after 3 %s failures\n", rc.cellName, prefix)
						bottomCell(db, pid, rc.cellName, rc.cellID,
							fmt.Sprintf("hard %s failed 3x: %v", prefix, err))
						mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
							fmt.Sprintf("cell: bottom hard %s cell %s after 3 failures", prefix, rc.cellName))
					} else {
						replRelease(db, rc.cellID, pistonID, "failure")
					}
					continue
				}
				for _, y := range yields {
					replSubmit(db, pid, rc.cellName, y, result)
				}
			}

			return evalStepResult{
				action: actionEvaluated, progID: pid,
				cellID: rc.cellID, cellName: rc.cellName,
				body: rc.body, bodyType: rc.bodyType,
				effect: inferEffect(rc.bodyType, rc.body),
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
			action: actionDispatch, progID: pid,
			cellID: rc.cellID, cellName: rc.cellName,
			body: rc.body, bodyType: rc.bodyType,
			effect: inferEffect(rc.bodyType, rc.body),
		}
	}

	return evalStepResult{action: actionQuiescent, progID: progID}
}

// checkDeterministicOracle checks a single deterministic oracle condition
// against a value. Returns true if the check passes.
// This is extracted from replSubmit for testability.
func checkDeterministicOracle(cond, value, srcValue string) bool {
	if strings.HasPrefix(cond, "guard:") {
		return true // guard oracles auto-pass
	}
	switch {
	case cond == "not_empty":
		return value != ""
	case cond == "is_json_array":
		return strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]")
	case strings.HasPrefix(cond, "length_matches:"):
		if srcValue == "" {
			return false
		}
		vLen := strings.Count(value, ",") + 1
		sLen := strings.Count(srcValue, ",") + 1
		if strings.TrimSpace(value) == "[]" {
			vLen = 0
		}
		if strings.TrimSpace(srcValue) == "[]" {
			sLen = 0
		}
		return vLen == sLen
	}
	return false
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

	// Validate-before-write: check deterministic oracles BEFORE persisting.
	// If an oracle fails the tuple space is unchanged (no partial write).
	// Formal model: EffectEval.lean vtw_preserves_yields.
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
				// For length_matches, we need to look up the source cell's value from DB
				srcValue := ""
				if strings.HasPrefix(cond, "length_matches:") {
					srcCell := strings.TrimPrefix(cond, "length_matches:")
					db.QueryRow(`
						SELECT y.value_text FROM yields y
						JOIN cells c ON c.id = y.cell_id
						WHERE c.program_id = ? AND c.name = ? AND y.is_frozen = 1
						LIMIT 1`, progID, srcCell).Scan(&srcValue)
				}
				if checkDeterministicOracle(cond, value, srcValue) {
					detPass++
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

	// Write value into existing unfrozen yield slot (created at pour or respawn time)
	// Oracles have already passed — safe to persist.
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

		// Autopour: if the frozen yield has annotation="autopour", parse the
		// value as .cell text and pour it into the retort as a new program.
		// Formal: Autopour.lean autoPourStep — programs as first-class values.
		checkAutopour(db, progID, cellName, cellID, fieldName)

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

// checkAutopour checks if a just-frozen yield has the "autopour" annotation.
// If so, parses the yield value as .cell text and pours it as a new program.
// Formal: Autopour.lean autoPourStep — the autopour operation takes a frozen
// yield value, parses it as a cell program, and pours it into the retort.
// The new program's name is derived from the source program + cell + field.
func checkAutopour(db *sql.DB, progID, cellName, cellID, fieldName string) {
	// Check if this yield has the autopour annotation
	var annotation, value string
	err := db.QueryRow(
		"SELECT COALESCE(annotation, ''), value_text FROM yields WHERE cell_id = ? AND field_name = ? AND is_frozen = 1",
		cellID, fieldName).Scan(&annotation, &value)
	if err != nil || annotation != "autopour" {
		return
	}
	if strings.TrimSpace(value) == "" {
		return // empty value — nothing to pour
	}

	// Parse the yield value as .cell text
	cells, parseErr := parseCellFile(value)
	if parseErr != nil || cells == nil || len(cells) == 0 {
		log.Printf("WARN: autopour %s/%s.%s: parse failed: %v", progID, cellName, fieldName, parseErr)
		mustExecDB(db,
			"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'autopour_fail', ?, NOW())",
			cellID, fmt.Sprintf("autopour parse failed: %v", parseErr))
		return
	}

	// Derive program name: {source_program}-autopour-{cell}-{field}
	newProgID := fmt.Sprintf("%s-autopour-%s-%s", progID, cellName, fieldName)

	// Generate and execute pour SQL, then ensure gen-0 frames exist.
	// Mirrors cmdPour: cellsToSQL generates the INSERTs, ensureFrames
	// creates frames so the cells become ready (visible to ready_cells view).
	sqlText := cellsToSQL(newProgID, cells)
	if _, err := db.Exec(sqlText); err != nil {
		if !strings.Contains(err.Error(), "nothing to commit") {
			log.Printf("WARN: autopour %s: pour failed: %v", newProgID, err)
			mustExecDB(db,
				"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'autopour_fail', ?, NOW())",
				cellID, fmt.Sprintf("autopour pour failed: %v", err))
			return
		}
	}
	ensureFrames(db, newProgID)

	log.Printf("INFO: autopour %s/%s.%s → poured %s (%d cells)", progID, cellName, fieldName, newProgID, len(cells))
	mustExecDB(db,
		"INSERT INTO trace (id, cell_id, event_type, detail, created_at) VALUES (CONCAT('tr-', SUBSTR(MD5(RAND()), 1, 8)), ?, 'autopour', ?, NOW())",
		cellID, fmt.Sprintf("autopour → %s (%d cells)", newProgID, len(cells)))
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
//
// Formal divergence: the formal model checks yields (ys.all (·.isBottom)),
// while Go checks cells.state = 'bottom'. These are logically equivalent
// because bottomCell always sets both cells.state='bottom' AND yields.is_bottom=TRUE,
// but the representation differs. The Go check is O(1) per cell vs O(yields).
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
// Formal divergence: the formal model filters claims by frameId alone.
// Go deletes by (cell_id, piston_id) because cell_claims is keyed by cell_id.
// These are equivalent when each cell has at most one active claim (guaranteed
// by the UNIQUE(frame_id) constraint + one-frame-per-claim invariant).
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


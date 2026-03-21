// piston.go — The piston protocol for Cell runtime.
//
// Pistons are LLM agents that claim soft cells, read prompts, think,
// and submit answers. This is the external evaluation path — the Lua
// runtime handles hard/compute cells, pistons handle soft cells.
//
// Commands: cmdPiston (autonomous loop), cmdNext (claim one),
//           cmdSubmit (submit a yield)
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
//
//	PROGRAM: sort-proof
//	CELL: sort
//	CELL_ID: sp-sort
//	BODY_TYPE: soft
//	BODY: Sort «items» in ascending order.
//	GIVEN: data→items ≡ [4, 1, 7, 3, 9, 2]
//	YIELD: sorted
//	ORACLE: sorted is a permutation of items
//	ORACLE: sorted is in ascending order
//
// Exit codes:
//
//	0 = cell claimed and printed
//	1 = error
//	2 = no ready cells (quiescent)
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

		// Autopour: if frozen yields have is_autopour=TRUE, pour them
		autopourYields(db, progID, cellID)
	}

	return "ok", fmt.Sprintf("Yield frozen: %s.%s", cellName, fieldName)
}

// autopourYields checks for autopour yields on a freshly frozen cell.
// If found, parses and pours the yielded program text into the retort.
func autopourYields(db *sql.DB, progID, cellID string) {
	rows, err := db.Query(
		"SELECT field_name, value_text FROM yields WHERE cell_id = ? AND is_autopour = TRUE AND is_frozen = TRUE AND value_text IS NOT NULL AND value_text != ''",
		cellID)
	if err != nil || rows == nil {
		return
	}
	defer rows.Close()

	for rows.Next() {
		var fieldName, valueText string
		if err := rows.Scan(&fieldName, &valueText); err != nil {
			continue
		}

		// Write the yielded Lua text to a temp file and parse it
		tmpFile, tmpErr := os.CreateTemp("", "autopour-*.lua")
		if tmpErr != nil {
			log.Printf("autopour: %s.%s: create temp: %v", cellID, fieldName, tmpErr)
			continue
		}
		tmpPath := tmpFile.Name()
		_, writeErr := tmpFile.WriteString(valueText)
		tmpFile.Close()
		if writeErr != nil {
			os.Remove(tmpPath)
			log.Printf("autopour: %s.%s: write temp: %v", cellID, fieldName, writeErr)
			continue
		}
		cells, parseErr := LoadLuaProgram(tmpPath)
		os.Remove(tmpPath)
		if parseErr != nil || cells == nil {
			log.Printf("autopour: %s.%s: parse failed: %v", cellID, fieldName, parseErr)
			continue
		}

		// Generate a program name: <parent>-ap-<field>
		subProgID := fmt.Sprintf("%s-ap-%s", progID, fieldName)

		// Generate and execute the pour SQL
		pourSQL := cellsToSQL(subProgID, cells)
		for _, stmt := range splitSQL(pourSQL) {
			stmt = strings.TrimSpace(stmt)
			if stmt == "" || stmt == "USE retort" {
				continue
			}
			execDB(db, stmt)
		}

		mustExecDB(db, "CALL DOLT_COMMIT('-Am', ?)",
			fmt.Sprintf("cell: autopour %s from %s.%s", subProgID, cellID, fieldName))
		log.Printf("autopour: poured %s from %s.%s (%d cells)", subProgID, cellID, fieldName, len(cells))
	}
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

// retort.go — Retort database operations for the Cell runtime.
//
// These functions read from and write to the retort DB (Dolt).
// They implement the tuple space operations: find ready cells,
// resolve inputs, submit yields, record bindings, handle bottom
// propagation, and manage cell lifecycle.
//
// Used by both the piston protocol (piston.go) and the Lua runtime.
package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"strings"
)

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
//
//	{ r with claims := r.claims.filter (fun c => c.frameId != rd.frameId) }
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

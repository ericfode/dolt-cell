package main

import (
	"database/sql"
	"fmt"
)

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

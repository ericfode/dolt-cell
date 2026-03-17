package main

import (
	"database/sql"
	"fmt"
)

func cmdStatus(db *sql.DB, progID string) {
	rows, err := db.Query("CALL cell_status(?)", progID)
	if err != nil {
		fatal("cell_status: %v", err)
	}
	defer rows.Close()

	fmt.Printf("  %-12s %-8s %-6s %-4s %s\n", "CELL", "STATE", "TYPE", "GEN", "YIELD")
	fmt.Printf("  %-12s %-8s %-6s %-4s %s\n", "────", "─────", "────", "───", "─────")
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
		// For stem cells, show latest frame generation
		genStr := ""
		if bodyType.String == "stem" {
			var maxGen sql.NullInt64
			db.QueryRow(
				"SELECT MAX(generation) FROM frames WHERE program_id = ? AND cell_name = ?",
				progID, name.String).Scan(&maxGen)
			if maxGen.Valid {
				genStr = fmt.Sprintf("g%d", maxGen.Int64)
			}
		}
		fmt.Printf("  %-12s %s %-6s %-6s %-4s %s\n", name.String, icon, state.String, bodyType.String, genStr, ys)
	}
}

// cmdFrames shows all frames for a program with their generation and derived status.
// Status is derived from yields and claim_log, not from cells.state.
func cmdFrames(db *sql.DB, progID string) {
	rows, err := db.Query(`
		SELECT f.id, f.cell_name, f.generation, f.created_at
		FROM frames f
		WHERE f.program_id = ?
		ORDER BY f.cell_name, f.generation`, progID)
	if err != nil {
		fatal("frames: %v", err)
	}
	defer rows.Close()

	fmt.Printf("  %-24s %-12s %-4s %-10s %s\n", "FRAME", "CELL", "GEN", "STATUS", "DETAIL")
	fmt.Printf("  %-24s %-12s %-4s %-10s %s\n", "─────", "────", "───", "──────", "──────")
	for rows.Next() {
		var frameID, cellName sql.NullString
		var generation sql.NullInt64
		var createdAt sql.NullTime
		rows.Scan(&frameID, &cellName, &generation, &createdAt)

		// Derive status from yields scoped to this frame (using frame_id)
		status := "pending"
		detail := ""

		var frozenCount, totalCount int
		db.QueryRow(`
			SELECT COUNT(*) FROM yields y
			JOIN cells c ON c.id = y.cell_id
			WHERE c.program_id = ? AND c.name = ?
			  AND COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0')) = ?
			  AND y.is_frozen = 1`,
			progID, cellName.String, frameID.String).Scan(&frozenCount)
		db.QueryRow(`
			SELECT COUNT(*) FROM yields y
			JOIN cells c ON c.id = y.cell_id
			WHERE c.program_id = ? AND c.name = ?
			  AND COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0')) = ?`,
			progID, cellName.String, frameID.String).Scan(&totalCount)

		if totalCount > 0 && frozenCount == totalCount {
			status = "frozen"
			detail = fmt.Sprintf("%d/%d yields", frozenCount, totalCount)
		} else if frozenCount > 0 {
			status = "partial"
			detail = fmt.Sprintf("%d/%d yields", frozenCount, totalCount)
		}

		// Check claim_log for activity
		var lastAction sql.NullString
		db.QueryRow(
			"SELECT action FROM claim_log WHERE frame_id = ? ORDER BY created_at DESC LIMIT 1",
			frameID.String).Scan(&lastAction)
		if lastAction.Valid && status == "pending" {
			switch lastAction.String {
			case "claimed":
				status = "computing"
			case "completed":
				status = "frozen"
			case "timed_out":
				status = "stale"
			}
		}

		// Check for bottom yields scoped to this frame
		var bottomCount int
		db.QueryRow(`
			SELECT COUNT(*) FROM yields y
			JOIN cells c ON c.id = y.cell_id
			WHERE c.program_id = ? AND c.name = ?
			  AND COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0')) = ?
			  AND y.is_bottom = 1`,
			progID, cellName.String, frameID.String).Scan(&bottomCount)
		if bottomCount > 0 {
			status = "bottom"
		}

		icon := map[string]string{"frozen": "■", "computing": "▶", "pending": "○", "partial": "◐", "bottom": "⊥", "stale": "✗"}[status]
		if icon == "" {
			icon = "?"
		}

		fmt.Printf("  %-24s %-12s g%-3d %s %-10s %s\n",
			trunc(frameID.String, 24), cellName.String, generation.Int64, icon, status, detail)
	}
}

func cmdYields(db *sql.DB, progID string) {
	// Show frozen yields from the latest frame generation per cell.
	// Join through frames so stem cells with multiple generations show only the latest.
	rows, err := db.Query(`
		SELECT c.name, y.field_name, y.value_text, y.is_bottom, COALESCE(f.generation, 0) AS gen
		FROM cells c
		JOIN yields y ON y.cell_id = c.id
		LEFT JOIN frames f ON f.id = COALESCE(y.frame_id, CONCAT('f-', y.cell_id, '-0'))
		WHERE c.program_id = ? AND y.is_frozen = 1
		ORDER BY c.name, y.field_name, gen DESC`, progID)
	if err != nil {
		fatal("yields: %v", err)
	}
	defer rows.Close()
	seen := make(map[string]bool)
	for rows.Next() {
		var name, field, value sql.NullString
		var bottom sql.NullBool
		var gen int
		rows.Scan(&name, &field, &value, &bottom, &gen)
		key := name.String + "." + field.String
		if seen[key] {
			continue // already showed latest generation
		}
		seen[key] = true
		icon := "■"
		if bottom.Valid && bottom.Bool {
			icon = "⊥"
		}
		fmt.Printf("  %s %s.%s = %s\n", icon, name.String, field.String, value.String)
	}
}

func cmdHistory(db *sql.DB, progID string) {
	// Trace events
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

	// Claim log (v2 frame model)
	clRows, err := db.Query(`
		SELECT cl.action, cl.piston_id, cl.created_at, f.cell_name
		FROM claim_log cl
		JOIN frames f ON f.id = cl.frame_id
		WHERE f.program_id = ?
		ORDER BY cl.created_at DESC LIMIT 10`, progID)
	if err == nil {
		defer clRows.Close()
		first := true
		for clRows.Next() {
			if first {
				fmt.Println("\n  Claim log:")
				first = false
			}
			var action, pistonID, cellName sql.NullString
			var createdAt sql.NullTime
			clRows.Scan(&action, &pistonID, &createdAt, &cellName)
			ts := ""
			if createdAt.Valid {
				ts = createdAt.Time.Format("15:04:05")
			}
			fmt.Printf("  %s  %-10s  %-10s  %s\n", ts, action.String, cellName.String, trunc(pistonID.String, 30))
		}
	}
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

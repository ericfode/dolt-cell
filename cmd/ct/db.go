package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// execDB wraps db.Exec and returns the error. Use for critical paths
// where silent failure would corrupt state (freeze, claim, submit, commit).
func execDB(db *sql.DB, query string, args ...interface{}) error {
	_, err := db.Exec(query, args...)
	if err != nil {
		log.Printf("ERROR: exec failed: %v (query: %s)", err, query)
	}
	return err
}

// mustExecDB wraps db.Exec with a non-fatal warning log on error.
// Use only for best-effort paths (heartbeat, trace, cleanup).
func mustExecDB(db *sql.DB, query string, args ...interface{}) {
	if _, err := db.Exec(query, args...); err != nil {
		log.Printf("WARN: exec failed: %v (query: %s)", err, query)
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

// ensureFrameForCell creates a frame for a single cell if one doesn't exist.
// For non-stem cells this creates gen-0. For stem cells this creates the next
// generation frame. This is called on-demand when a cell is claimed or frozen.
func ensureFrameForCell(db *sql.DB, progID, cellName, cellID string) {
	// Check if any frame already exists for this cell
	var existing int
	db.QueryRow(
		"SELECT COUNT(*) FROM frames WHERE program_id = ? AND cell_name = ?",
		progID, cellName).Scan(&existing)
	if existing > 0 {
		return // frame already exists
	}
	// Create gen-0 frame
	frameID := "f-" + cellID + "-0"
	db.Exec(
		"INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES (?, ?, ?, 0)",
		frameID, cellName, progID)
}

// latestFrameID returns the frame ID for the latest generation of a cell.
// Returns empty string if no frame exists.
func latestFrameID(db *sql.DB, progID, cellName string) string {
	var frameID string
	err := db.QueryRow(
		"SELECT id FROM frames WHERE program_id = ? AND cell_name = ? ORDER BY generation DESC LIMIT 1",
		progID, cellName).Scan(&frameID)
	if err != nil {
		return ""
	}
	return frameID
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

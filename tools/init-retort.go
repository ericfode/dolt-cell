// init-retort: Create retort database and install stored procedures
//
// Usage: go run tools/init-retort.go [dsn]
//   Default DSN: root@tcp(127.0.0.1:3308)/
//
// This creates the retort database, tables, views, and installs all
// stored procedures from schema/procedures.sql.

package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"

	_ "github.com/go-sql-driver/mysql"
)

func main() {
	dsn := "root@tcp(127.0.0.1:3308)/"
	if len(os.Args) > 1 {
		dsn = os.Args[1]
	}

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		fmt.Fprintf(os.Stderr, "ping: %v\n", err)
		os.Exit(1)
	}

	// Find project root (walk up looking for schema/)
	root := "."
	for _, try := range []string{".", "../..", "../../.."} {
		if _, err := os.Stat(try + "/schema/retort-init.sql"); err == nil {
			root = try
			break
		}
	}

	// Step 1: Create database and tables from retort-init.sql
	// Execute each statement individually (Dolt doesn't support multiStatements well)
	initSQL, err := os.ReadFile(root + "/schema/retort-init.sql")
	if err != nil {
		fmt.Fprintf(os.Stderr, "read retort-init.sql: %v\n", err)
		os.Exit(1)
	}

	initStmts := splitStatements(string(initSQL))
	for _, stmt := range initStmts {
		if _, err := db.Exec(stmt); err != nil {
			first := stmt
			if idx := strings.Index(stmt, "\n"); idx > 0 {
				first = stmt[:idx]
			}
			fmt.Fprintf(os.Stderr, "init [%s]: %v\n", first, err)
			os.Exit(1)
		}
	}
	fmt.Printf("✓ retort database + tables created (%d statements)\n", len(initStmts))

	// Step 2: Install stored procedures from procedures.sql
	procSQL, err := os.ReadFile(root + "/schema/procedures.sql")
	if err != nil {
		fmt.Fprintf(os.Stderr, "read procedures.sql: %v\n", err)
		os.Exit(1)
	}

	// Switch to retort database
	if _, err := db.Exec("USE retort"); err != nil {
		fmt.Fprintf(os.Stderr, "use retort: %v\n", err)
		os.Exit(1)
	}

	// Parse DELIMITER-delimited procedure blocks
	procs := parseProcedures(string(procSQL))
	for _, p := range procs {
		if _, err := db.Exec(p); err != nil {
			first := p
			if idx := strings.Index(p, "\n"); idx > 0 {
				first = p[:idx]
			}
			fmt.Fprintf(os.Stderr, "proc [%s]: %v\n", first, err)
			os.Exit(1)
		}
	}
	fmt.Printf("✓ %d procedure statements installed\n", len(procs))

	// Step 3: Commit
	if _, err := db.Exec("CALL DOLT_COMMIT('-Am', 'init: retort schema + procedures')"); err != nil {
		fmt.Fprintf(os.Stderr, "commit: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("✓ committed")
}

// splitStatements splits SQL on semicolons, skipping comments and empty lines.
func splitStatements(src string) []string {
	var stmts []string
	var buf strings.Builder

	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "--") {
			continue
		}
		buf.WriteString(line)
		buf.WriteString("\n")
		if strings.HasSuffix(trimmed, ";") {
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
			}
			buf.Reset()
		}
	}
	return stmts
}

// parseProcedures splits a SQL file using DELIMITER // and DELIMITER ;
// Returns individual SQL statements ready for execution.
func parseProcedures(src string) []string {
	var stmts []string
	lines := strings.Split(src, "\n")
	var buf strings.Builder
	delim := ";"

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		// Skip pure comment lines when not inside a procedure body
		if strings.HasPrefix(trimmed, "--") && delim == ";" {
			continue
		}

		// Handle DELIMITER directives
		if strings.HasPrefix(trimmed, "DELIMITER") {
			// Flush any buffered content
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
				buf.Reset()
			}
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				delim = parts[1]
			}
			continue
		}

		// Check if line ends with current delimiter
		if delim != ";" && strings.HasSuffix(trimmed, delim) {
			line = strings.TrimSuffix(trimmed, delim)
			buf.WriteString(line)
			buf.WriteString("\n")
			if s := strings.TrimSpace(buf.String()); s != "" {
				stmts = append(stmts, s)
			}
			buf.Reset()
			continue
		}

		buf.WriteString(line)
		buf.WriteString("\n")
	}

	// Flush remaining
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

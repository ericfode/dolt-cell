package main

import (
	"fmt"
	"strings"
)

// sandboxSQL validates that SQL text only contains allowed statements.
// Used to prevent LLM-generated SQL from executing dangerous operations
// like DROP DATABASE, DELETE, or CREATE USER.
func sandboxSQL(sqlText string) error {
	allowed := []string{
		"INSERT INTO cells",
		"INSERT INTO yields",
		"INSERT INTO givens",
		"INSERT INTO oracles",
		"INSERT INTO frames",
		"INSERT IGNORE INTO cells",
		"INSERT IGNORE INTO yields",
		"INSERT IGNORE INTO givens",
		"INSERT IGNORE INTO oracles",
		"INSERT IGNORE INTO frames",
		"UPDATE cells SET",
		"UPDATE yields SET",
		"CALL DOLT_COMMIT",
		"CALL DOLT_ADD",
		"USE retort",
		"SET ",
		"SELECT ",  // needed for hard-cell sql: bodies and cached piston output
	}

	stmts := splitSQLStatements(sqlText)
	for _, stmt := range stmts {
		upper := strings.ToUpper(strings.TrimSpace(stmt))
		if upper == "" {
			continue
		}
		ok := false
		for _, prefix := range allowed {
			if strings.HasPrefix(upper, strings.ToUpper(prefix)) {
				ok = true
				break
			}
		}
		if !ok {
			return fmt.Errorf("sandbox: blocked statement: %s", trunc(stmt, 80))
		}
	}
	return nil
}

// sandboxHardCellSQL validates that a hard cell's SQL body is safe to execute.
// Allows SELECT (replayable) and single-statement DML (nonreplayable).
// Blocks: multi-statement injection, DDL, admin commands.
func sandboxHardCellSQL(sqlQuery string) error {
	stmts := splitSQLStatements(sqlQuery)
	if len(stmts) == 0 {
		return fmt.Errorf("empty SQL body")
	}
	if len(stmts) > 1 {
		return fmt.Errorf("multi-statement SQL not allowed in hard cells (got %d statements)", len(stmts))
	}
	upper := strings.ToUpper(strings.TrimSpace(stmts[0]))
	blocked := []string{"DROP ", "CREATE ", "ALTER ", "TRUNCATE ", "GRANT ", "REVOKE "}
	for _, b := range blocked {
		if strings.HasPrefix(upper, b) {
			return fmt.Errorf("blocked DDL/admin statement: %s", b)
		}
	}
	return nil
}

// splitSQLStatements splits on semicolons, handling basic quoting.
func splitSQLStatements(text string) []string {
	var stmts []string
	var buf strings.Builder
	inQuote := false
	quoteChar := byte(0)

	for i := 0; i < len(text); i++ {
		ch := text[i]
		if inQuote {
			buf.WriteByte(ch)
			if ch == quoteChar {
				// Check for escaped quote
				if i+1 < len(text) && text[i+1] == quoteChar {
					buf.WriteByte(text[i+1])
					i++
				} else {
					inQuote = false
				}
			}
			continue
		}
		if ch == '\'' || ch == '"' {
			inQuote = true
			quoteChar = ch
			buf.WriteByte(ch)
			continue
		}
		if ch == ';' {
			s := strings.TrimSpace(buf.String())
			if s != "" {
				stmts = append(stmts, s)
			}
			buf.Reset()
			continue
		}
		buf.WriteByte(ch)
	}
	if s := strings.TrimSpace(buf.String()); s != "" {
		stmts = append(stmts, s)
	}
	return stmts
}

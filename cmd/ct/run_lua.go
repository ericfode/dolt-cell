package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
)

// cmdRunLua boots a Lua VM, loads a .lua cell program, and runs it
// entirely in Lua. The Go code just provides the DB bridge functions.
//
// This is the Lua-native path: the eval loop, cell body evaluation,
// coroutine handling, sandboxing — ALL in Lua. Go provides:
//   - db_query, db_exec, db_query_row, db_scalar (DB access)
//   - The Lua VM lifecycle
//
// For programs that define their own Retort and call retort:run(),
// this just loads and executes the file. For programs that return a
// cell definition table, this loads the bootstrap first.
func cmdRunLua(db *sql.DB, name, luaFile string) {
	if _, err := os.Stat(luaFile); os.IsNotExist(err) {
		fatal("file not found: %s", luaFile)
	}

	vm := NewCellVM(db)
	defer vm.Close()

	// Check if we should also pour (register cells in retort DB)
	if shouldPour(db, name) {
		fmt.Printf("Pouring %s from %s...\n", name, luaFile)
		cells, err := LoadLuaProgram(luaFile)
		if err != nil {
			fatal("lua parse: %v", err)
		}
		if cells != nil && len(cells) > 0 {
			sqlText := cellsToSQL(name, cells)
			if _, err := db.Exec(sqlText); err != nil {
				if !strings.Contains(err.Error(), "nothing to commit") {
					fatal("pour sql: %v", err)
				}
			}
			ensureFrames(db, name)
			fmt.Printf("✓ %s: %d cells poured\n", name, len(cells))
		}
	}

	// Load and run the Lua program
	fmt.Printf("Running %s in Lua VM...\n", name)
	if err := vm.LoadAndRun(name, luaFile); err != nil {
		fatal("lua run: %v", err)
	}
	fmt.Printf("✓ %s complete\n", name)
}

// shouldPour checks if the program needs to be poured (no cells in DB yet).
func shouldPour(db *sql.DB, progID string) bool {
	var count int
	db.QueryRow("SELECT COUNT(*) FROM cells WHERE program_id = ?", progID).Scan(&count)
	return count == 0
}

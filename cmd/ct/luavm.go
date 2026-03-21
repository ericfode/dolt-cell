package main

// luavm.go — GopherLua integration for the ct cell runtime.
//
// Architecture: The WHOLE cell runtime is Lua. Go is just the shell.
//
//   Go provides:
//     - CLI (main.go)
//     - DB connection (db.go)
//     - Go functions registered into Lua for DB access
//     - The Lua VM lifecycle
//
//   Lua provides:
//     - Cell program loading (tables with body functions)
//     - The eval loop (claim → dispatch → evaluate → submit)
//     - Cell body evaluation (pure compute, soft prompts, coroutine stems)
//     - Effect tier sandboxing (setfenv)
//     - Oracle checking
//     - Bottom propagation
//
// The Go eval.go code is the LEGACY path for .cell files.
// For .lua files, Go boots a Lua VM, loads the bootstrap + program, runs it.
//
// Design doc: docs/plans/2026-03-21-lua-substrate-design.md
// Bead: dc-1cd

import (
	"database/sql"
	"fmt"
	"strings"

	lua "github.com/yuin/gopher-lua"
)

// Effect tier constants (match Lua PURE/REPLAYABLE/NON_REPLAYABLE)
const (
	TierPure          = 1
	TierReplayable    = 2
	TierNonReplayable = 3
)

// CellVM wraps a GopherLua state with the cell runtime loaded.
type CellVM struct {
	L       *lua.LState
	db      *sql.DB
	progID  string
}

// NewCellVM creates a Lua VM with the full cell runtime.
// It opens all libraries (NonReplayable tier) since the bootstrap
// needs coroutines, loadstring, etc. Individual cell bodies are
// sandboxed via setfenv at runtime.
func NewCellVM(db *sql.DB) *CellVM {
	L := lua.NewState()

	vm := &CellVM{L: L, db: db}
	vm.registerDBFunctions()
	vm.registerEventFunctions()

	return vm
}

// Close shuts down the Lua VM.
func (vm *CellVM) Close() {
	vm.L.Close()
}

// LoadAndRun loads a .lua cell program and runs the eval loop.
// This is the main entry point for Lua programs — replaces the
// Go eval loop entirely.
func (vm *CellVM) LoadAndRun(progID, path string) error {
	vm.progID = progID

	// Set program ID as a global
	vm.L.SetGlobal("PROGRAM_ID", lua.LString(progID))

	// Load the cell program file
	if err := vm.L.DoFile(path); err != nil {
		return fmt.Errorf("lua load error: %w", err)
	}

	return nil
}

// LoadBootstrapAndProgram loads the bootstrap runtime, then the program,
// then runs the retort.
func (vm *CellVM) LoadBootstrapAndProgram(progID, bootstrapPath, programPath string) error {
	vm.progID = progID
	vm.L.SetGlobal("PROGRAM_ID", lua.LString(progID))

	// Load bootstrap (cell_runtime.lua — provides hard/soft/compute/stem/autopour + Retort)
	if err := vm.L.DoFile(bootstrapPath); err != nil {
		return fmt.Errorf("bootstrap load error: %w", err)
	}

	// Load the program file
	if err := vm.L.DoFile(programPath); err != nil {
		return fmt.Errorf("program load error: %w", err)
	}

	return nil
}

// registerDBFunctions registers Go functions into the Lua VM for
// database access. These are the tuple space operations that Lua
// code calls to interact with the retort.
func (vm *CellVM) registerDBFunctions() {
	// db_query(sql, ...) → rows as Lua tables
	vm.L.SetGlobal("db_query", vm.L.NewFunction(func(L *lua.LState) int {
		query := L.CheckString(1)
		args := make([]interface{}, 0)
		for i := 2; i <= L.GetTop(); i++ {
			args = append(args, lua.LVAsString(L.Get(i)))
		}

		rows, err := vm.db.Query(query, args...)
		if err != nil {
			L.Push(lua.LNil)
			L.Push(lua.LString(err.Error()))
			return 2
		}
		defer rows.Close()

		cols, _ := rows.Columns()
		result := L.NewTable()
		rowIdx := 0

		for rows.Next() {
			rowIdx++
			vals := make([]sql.NullString, len(cols))
			ptrs := make([]interface{}, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			rows.Scan(ptrs...)

			row := L.NewTable()
			for i, col := range cols {
				if vals[i].Valid {
					row.RawSetString(col, lua.LString(vals[i].String))
				} else {
					row.RawSetString(col, lua.LNil)
				}
			}
			result.RawSetInt(rowIdx, row)
		}

		L.Push(result)
		return 1
	}))

	// db_exec(sql, ...) → rows_affected, error
	vm.L.SetGlobal("db_exec", vm.L.NewFunction(func(L *lua.LState) int {
		query := L.CheckString(1)
		args := make([]interface{}, 0)
		for i := 2; i <= L.GetTop(); i++ {
			args = append(args, lua.LVAsString(L.Get(i)))
		}

		res, err := vm.db.Exec(query, args...)
		if err != nil {
			L.Push(lua.LNumber(0))
			L.Push(lua.LString(err.Error()))
			return 2
		}

		affected, _ := res.RowsAffected()
		L.Push(lua.LNumber(affected))
		return 1
	}))

	// db_query_row(sql, ...) → single row as table, or nil
	vm.L.SetGlobal("db_query_row", vm.L.NewFunction(func(L *lua.LState) int {
		query := L.CheckString(1)
		args := make([]interface{}, 0)
		for i := 2; i <= L.GetTop(); i++ {
			args = append(args, lua.LVAsString(L.Get(i)))
		}

		rows, err := vm.db.Query(query, args...)
		if err != nil {
			L.Push(lua.LNil)
			L.Push(lua.LString(err.Error()))
			return 2
		}
		defer rows.Close()

		if !rows.Next() {
			L.Push(lua.LNil)
			return 1
		}

		cols, _ := rows.Columns()
		vals := make([]sql.NullString, len(cols))
		ptrs := make([]interface{}, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		rows.Scan(ptrs...)

		row := L.NewTable()
		for i, col := range cols {
			if vals[i].Valid {
				row.RawSetString(col, lua.LString(vals[i].String))
			}
		}
		L.Push(row)
		return 1
	}))

	// db_scalar(sql, ...) → single string value, or nil
	vm.L.SetGlobal("db_scalar", vm.L.NewFunction(func(L *lua.LState) int {
		query := L.CheckString(1)
		args := make([]interface{}, 0)
		for i := 2; i <= L.GetTop(); i++ {
			args = append(args, lua.LVAsString(L.Get(i)))
		}

		var result sql.NullString
		err := vm.db.QueryRow(query, args...).Scan(&result)
		if err != nil || !result.Valid {
			L.Push(lua.LNil)
			return 1
		}
		L.Push(lua.LString(result.String))
		return 1
	}))
}

// registerEventFunctions registers Gas City event emission into Lua.
// Lua code calls emit_event("cell.needs_piston", "prog/cell", "message")
// which shells out to `gc event emit`.
func (vm *CellVM) registerEventFunctions() {
	// emit_event(type, subject, message) → emits via gc event emit
	vm.L.SetGlobal("emit_event", vm.L.NewFunction(func(L *lua.LState) int {
		eventType := L.CheckString(1)
		subject := L.CheckString(2)
		message := L.OptString(3, "")
		emitCellEvent(eventType, subject, "", message, nil)
		return 0
	}))

	// emit_needs_piston(program, cell) → shorthand for cell.needs_piston
	vm.L.SetGlobal("emit_needs_piston", vm.L.NewFunction(func(L *lua.LState) int {
		program := L.CheckString(1)
		cell := L.CheckString(2)
		emitNeedsPiston(program, cell, "soft")
		return 0
	}))

	// emit_yield_frozen(program, cell, field) → shorthand for cell.yield_frozen
	vm.L.SetGlobal("emit_yield_frozen", vm.L.NewFunction(func(L *lua.LState) int {
		program := L.CheckString(1)
		cell := L.CheckString(2)
		field := L.CheckString(3)
		emitYieldFrozen(program, cell, field)
		return 0
	}))

	// emit_program_complete(program) → shorthand for cell.program_complete
	vm.L.SetGlobal("emit_program_complete", vm.L.NewFunction(func(L *lua.LState) int {
		program := L.CheckString(1)
		emitProgramComplete(program)
		return 0
	}))
}

// --- Legacy support: LoadLuaProgram for pour.go compatibility ---
// This extracts parsedCell structs from a Lua program for the SQL
// generation pipeline. Used by ct pour when loading .lua files.

func effectTierFromString(s string) int {
	switch strings.ToLower(s) {
	case "pure":
		return TierPure
	case "replayable":
		return TierReplayable
	case "non_replayable", "nonreplayable":
		return TierNonReplayable
	default:
		return TierReplayable
	}
}

func bodyTypeFromLuaCell(kind string, isStem bool) string {
	if isStem {
		return "stem"
	}
	switch kind {
	case "hard":
		return "hard"
	case "compute":
		return "hard"
	case "soft":
		return "soft"
	case "stem":
		return "stem"
	case "autopour":
		return "soft"
	default:
		return "soft"
	}
}

// LoadLuaProgram loads a .lua file and extracts cell definitions as
// parsedCell structs for the SQL generation pipeline (pour.go).
func LoadLuaProgram(path string) ([]parsedCell, error) {
	L := lua.NewState()
	defer L.Close()

	if err := L.DoFile(path); err != nil {
		return nil, fmt.Errorf("lua load error: %w", err)
	}

	top := L.Get(-1)
	progTable, ok := top.(*lua.LTable)
	if !ok {
		gv := L.GetGlobal("program")
		progTable, ok = gv.(*lua.LTable)
		if !ok {
			return nil, fmt.Errorf("lua program must return a table or set global 'program'")
		}
	}

	return extractCells(L, progTable)
}

func extractCells(L *lua.LState, progTable *lua.LTable) ([]parsedCell, error) {
	cellsTable := progTable.RawGetString("cells")
	orderTable := progTable.RawGetString("order")

	if cellsTable == lua.LNil {
		return nil, fmt.Errorf("program table missing 'cells' field")
	}

	ct, ok := cellsTable.(*lua.LTable)
	if !ok {
		return nil, fmt.Errorf("'cells' must be a table")
	}

	var order []string
	if ot, ok := orderTable.(*lua.LTable); ok {
		ot.ForEach(func(_ lua.LValue, v lua.LValue) {
			if s, ok := v.(lua.LString); ok {
				order = append(order, string(s))
			}
		})
	}
	if len(order) == 0 {
		ct.ForEach(func(k lua.LValue, _ lua.LValue) {
			if s, ok := k.(lua.LString); ok {
				order = append(order, string(s))
			}
		})
	}

	var cells []parsedCell
	for _, name := range order {
		cellVal := ct.RawGetString(name)
		cellTbl, ok := cellVal.(*lua.LTable)
		if !ok {
			continue
		}
		pc, err := luaCellToParsed(name, cellTbl)
		if err != nil {
			return nil, fmt.Errorf("cell %q: %w", name, err)
		}
		cells = append(cells, pc)
	}
	return cells, nil
}

func luaCellToParsed(name string, tbl *lua.LTable) (parsedCell, error) {
	pc := parsedCell{name: name}

	kind := luaString(tbl, "kind")
	if kind == "" {
		kind = "soft"
	}

	isStem := luaBool(tbl, "stem")
	if kind == "stem" {
		isStem = true
	}
	pc.bodyType = bodyTypeFromLuaCell(kind, isStem)

	switch kind {
	case "hard":
		bodyTbl := tbl.RawGetString("body")
		if bt, ok := bodyTbl.(*lua.LTable); ok {
			bt.ForEach(func(k lua.LValue, v lua.LValue) {
				pc.yields = append(pc.yields, parsedYield{
					fieldName: lua.LVAsString(k),
					prebound:  lua.LVAsString(v),
				})
			})
			if len(pc.yields) > 0 {
				pc.body = "literal:" + pc.yields[0].prebound
			}
		}

	case "compute", "soft", "stem", "autopour":
		// Body is a Lua function — the Lua runtime evaluates it.
		// Store empty body; the .lua source file is the authority.
		pc.body = ""
		extractYields(tbl, &pc)

		if kind == "stem" {
			pc.bodyType = "stem"
		}

		if kind == "autopour" {
			apTbl := tbl.RawGetString("autopour")
			if at, ok := apTbl.(*lua.LTable); ok {
				apFields := make(map[string]bool)
				at.ForEach(func(_ lua.LValue, v lua.LValue) {
					apFields[lua.LVAsString(v)] = true
				})
				for i := range pc.yields {
					if apFields[pc.yields[i].fieldName] {
						pc.yields[i].autopour = true
					}
				}
			}
		}
	}

	// givens
	givensTbl := tbl.RawGetString("givens")
	if gt, ok := givensTbl.(*lua.LTable); ok {
		gt.ForEach(func(_ lua.LValue, v lua.LValue) {
			s := lua.LVAsString(v)
			parts := strings.SplitN(s, ".", 2)
			if len(parts) == 2 {
				pc.givens = append(pc.givens, parsedGiven{
					sourceCell:  parts[0],
					sourceField: parts[1],
				})
			}
		})
	}

	// oracles
	checksTbl := tbl.RawGetString("checks")
	if checkTbl, ok := checksTbl.(*lua.LTable); ok {
		checkTbl.ForEach(func(_ lua.LValue, v lua.LValue) {
			switch cv := v.(type) {
			case *lua.LTable:
				sem := luaString(cv, "semantic")
				if sem != "" {
					pc.oracles = append(pc.oracles, parsedOracle{
						assertion:  sem,
						oracleType: "semantic",
					})
				}
			case lua.LString:
				pc.oracles = append(pc.oracles, parsedOracle{
					assertion:  string(cv),
					oracleType: "deterministic",
					condExpr:   "not_empty",
				})
			}
		})
	}

	// iterate/recur
	iterVal := tbl.RawGetString("iterate")
	if n, ok := iterVal.(lua.LNumber); ok {
		pc.iterate = int(n)
	}
	recurTbl := tbl.RawGetString("recur")
	if rt, ok := recurTbl.(*lua.LTable); ok {
		maxVal := rt.RawGetString("max")
		if n, ok := maxVal.(lua.LNumber); ok {
			pc.iterate = int(n)
		}
	}

	return pc, nil
}

func extractYields(tbl *lua.LTable, pc *parsedCell) {
	yieldsTbl := tbl.RawGetString("yields")
	if yt, ok := yieldsTbl.(*lua.LTable); ok {
		yt.ForEach(func(_ lua.LValue, v lua.LValue) {
			pc.yields = append(pc.yields, parsedYield{
				fieldName: lua.LVAsString(v),
			})
		})
	}
}

// NewPureVM creates a Lua VM restricted to the Pure tier.
func NewPureVM() *lua.LState {
	opts := lua.Options{SkipOpenLibs: true}
	L := lua.NewState(opts)
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)
	for _, name := range []string{"dofile", "loadfile", "loadstring", "load"} {
		L.SetGlobal(name, lua.LNil)
	}
	return L
}

func luaString(tbl *lua.LTable, key string) string {
	v := tbl.RawGetString(key)
	if s, ok := v.(lua.LString); ok {
		return string(s)
	}
	return ""
}

func luaBool(tbl *lua.LTable, key string) bool {
	v := tbl.RawGetString(key)
	if b, ok := v.(lua.LBool); ok {
		return bool(b)
	}
	return false
}

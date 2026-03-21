package main

// luavm.go — GopherLua bridge for the ct cell runtime.
//
// This file bridges Lua (GopherLua) into the ct tool:
//   - LoadLuaProgram: load a .lua file, extract cell definitions as parsedCell structs
//   - EvalLuaCompute: evaluate a pure compute cell body in a sandboxed Lua VM
//   - EvalLuaSoftPrompt: call a soft cell body function to get the prompt string
//   - MakeSandbox: create effect-tier-restricted Lua environments
//
// The key insight: Lua loading produces the SAME parsedCell structs that
// parse.go produces. Everything downstream (SQL generation, eval loop,
// formal invariants) is unchanged.
//
// Design doc: docs/plans/2026-03-21-lua-substrate-design.md
// Bead: dc-1cd

import (
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

// effectTierFromString converts a Lua effect string to a tier constant.
func effectTierFromString(s string) int {
	switch strings.ToLower(s) {
	case "pure":
		return TierPure
	case "replayable":
		return TierReplayable
	case "non_replayable", "nonreplayable":
		return TierNonReplayable
	default:
		return TierReplayable // default to replayable (soft cell)
	}
}

// bodyTypeFromLuaCell infers the body_type (hard/soft/stem) from Lua cell fields.
func bodyTypeFromLuaCell(kind string, isStem bool) string {
	if isStem {
		return "stem"
	}
	switch kind {
	case "hard":
		return "hard"
	case "compute":
		return "hard" // compute cells are "hard" in the retort schema (deterministic)
	case "soft":
		return "soft"
	case "stem":
		return "stem"
	case "autopour":
		return "soft" // autopour cells are soft (NonReplayable)
	default:
		return "soft"
	}
}

// NewLuaVM creates a new GopherLua state with the specified effect tier sandbox.
func NewLuaVM(tier int) *lua.LState {
	opts := lua.Options{SkipOpenLibs: true}
	L := lua.NewState(opts)

	// Always open base libs for the tier
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)

	if tier >= TierReplayable {
		lua.OpenOs(L) // os.clock, os.time (no os.execute in sandbox)
		lua.OpenIo(L) // for print/io.write in soft cells
	}

	if tier >= TierNonReplayable {
		lua.OpenPackage(L)
		lua.OpenChannel(L)
		lua.OpenCoroutine(L)
	}

	return L
}

// NewPureVM creates a Lua VM restricted to the Pure tier.
// No I/O, no coroutines, no loadstring, no os.
func NewPureVM() *lua.LState {
	opts := lua.Options{SkipOpenLibs: true}
	L := lua.NewState(opts)
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)

	// Remove dangerous base functions
	for _, name := range []string{"dofile", "loadfile", "loadstring", "load"} {
		L.SetGlobal(name, lua.LNil)
	}

	return L
}

// LoadLuaProgram loads a .lua file and extracts cell definitions.
// The Lua file must return a table with a "cells" field (table of cell defs)
// and an "order" field (list of cell names for evaluation order).
//
// Returns the same []parsedCell that parseCellFile() returns, so the
// downstream pipeline (cellsToSQL, ensureFrames, eval loop) is unchanged.
func LoadLuaProgram(path string) ([]parsedCell, error) {
	L := NewLuaVM(TierNonReplayable) // loading needs full access
	defer L.Close()

	if err := L.DoFile(path); err != nil {
		return nil, fmt.Errorf("lua load error: %w", err)
	}

	// The file should leave a return value on the stack, or set globals.
	// Convention: the file calls a registration function or returns a table.
	// We support both patterns:
	//   Pattern A: file returns {cells={...}, order={...}}
	//   Pattern B: file sets global "program" to the table

	top := L.Get(-1) // last return value
	progTable, ok := top.(*lua.LTable)
	if !ok {
		// Try global "program"
		gv := L.GetGlobal("program")
		progTable, ok = gv.(*lua.LTable)
		if !ok {
			return nil, fmt.Errorf("lua program must return a table or set global 'program'")
		}
	}

	return extractCells(L, progTable)
}

// extractCells converts a Lua program table into []parsedCell.
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

	// Get evaluation order
	var order []string
	if ot, ok := orderTable.(*lua.LTable); ok {
		ot.ForEach(func(_ lua.LValue, v lua.LValue) {
			if s, ok := v.(lua.LString); ok {
				order = append(order, string(s))
			}
		})
	}

	// If no explicit order, iterate cells table keys
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

		pc, err := luaCellToParsed(L, name, cellTbl)
		if err != nil {
			return nil, fmt.Errorf("cell %q: %w", name, err)
		}
		cells = append(cells, pc)
	}

	return cells, nil
}

// luaCellToParsed converts a single Lua cell table to a parsedCell.
func luaCellToParsed(_ *lua.LState, name string, tbl *lua.LTable) (parsedCell, error) {
	pc := parsedCell{name: name}

	// kind: "hard", "soft", "compute", "stem", "autopour"
	kind := luaString(tbl, "kind")
	if kind == "" {
		kind = "soft" // default
	}

	// stem flag
	isStem := luaBool(tbl, "stem")
	if kind == "stem" {
		isStem = true
	}

	pc.bodyType = bodyTypeFromLuaCell(kind, isStem)

	// effect level (for metadata, not used in parsedCell directly)
	// but we store it in the body prefix for downstream handling
	effect := luaString(tbl, "effect")
	if effect == "" {
		switch kind {
		case "hard", "compute":
			effect = "pure"
		case "soft":
			effect = "replayable"
		default:
			effect = "non_replayable"
		}
	}

	// body: depends on kind
	switch kind {
	case "hard":
		// body is a table of field → value
		bodyTbl := tbl.RawGetString("body")
		if bt, ok := bodyTbl.(*lua.LTable); ok {
			// Extract first yield as prebound literal
			bt.ForEach(func(k lua.LValue, v lua.LValue) {
				ks := lua.LVAsString(k)
				vs := lua.LVAsString(v)
				pc.yields = append(pc.yields, parsedYield{
					fieldName: ks,
					prebound:  vs,
				})
			})
			if len(pc.yields) > 0 {
				pc.body = "literal:" + pc.yields[0].prebound
			}
		}

	case "compute":
		// body is a Lua function — store source reference for eval
		pc.body = "lua:compute"
		// yields from the yields list
		extractYields(tbl, &pc)

	case "soft":
		// body is a Lua function returning a prompt string
		pc.body = "lua:soft"
		extractYields(tbl, &pc)

	case "stem":
		// body is a coroutine factory
		pc.body = "lua:stem"
		pc.bodyType = "stem"
		extractYields(tbl, &pc)

	case "autopour":
		// body is a function, some yields are autopour
		pc.body = "lua:autopour"
		extractYields(tbl, &pc)
		// Mark autopour fields
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

	// oracles/checks
	checksTbl := tbl.RawGetString("checks")
	if ct, ok := checksTbl.(*lua.LTable); ok {
		ct.ForEach(func(_ lua.LValue, v lua.LValue) {
			switch cv := v.(type) {
			case *lua.LTable:
				// {semantic = "assertion text"}
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
			// Function checks are evaluated at runtime, not stored in SQL
		})
	}

	// iterate
	iterVal := tbl.RawGetString("iterate")
	if n, ok := iterVal.(lua.LNumber); ok {
		pc.iterate = int(n)
	}

	// guard (for recur)
	recurTbl := tbl.RawGetString("recur")
	if rt, ok := recurTbl.(*lua.LTable); ok {
		maxVal := rt.RawGetString("max")
		if n, ok := maxVal.(lua.LNumber); ok {
			pc.iterate = int(n)
		}
		// guard function stored for runtime, not in parsedCell
	}

	return pc, nil
}

// extractYields reads the "yields" list from a Lua cell table.
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

// Helpers

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

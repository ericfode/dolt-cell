package main

// luavm.go — GopherLua bridge for Lua cell programs.
//
// At pour time: loadLuaProgram() executes a .lua file and extracts cell
// definitions by intercepting retort:pour() calls.
//
// At eval time: evalLuaCompute() and evalLuaSoftPrompt() execute the stored
// Lua function source with the resolved givens as env.

import (
	"bytes"
	"fmt"
	"os"
	"strings"

	lua "github.com/yuin/gopher-lua"
)

// luaCellRecord holds a single cell intercepted during Lua file loading.
type luaCellRecord struct {
	name    string
	kind    string // "hard", "soft", "compute", "stem"
	effect  int    // 1=pure, 2=replayable, 3=non_replayable
	body    *lua.LFunction
	bodyTbl *lua.LTable // for hard: the fields table
	givens  []string
	yields  []string
	checks  []string
}

// loadLuaProgram executes a .lua cell program and returns parsed cell
// definitions. The Lua file's dofile("...cell_runtime.lua") call is
// intercepted and replaced with a Go-implemented cell runtime that records
// pour() calls without running the actual DAG evaluation.
func loadLuaProgram(path string) ([]parsedCell, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %v", path, err)
	}

	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	defer L.Close()

	// Open safe libs only (no io, no os, no package)
	lua.OpenPackage(L)
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)

	// Suppress io output during loading
	ioT := L.NewTable()
	L.SetField(ioT, "write", L.NewFunction(func(L *lua.LState) int { return 0 }))
	L.SetField(ioT, "read", L.NewFunction(func(L *lua.LState) int { return 0 }))
	L.SetGlobal("io", ioT)

	// Suppress print
	L.SetGlobal("print", L.NewFunction(func(L *lua.LState) int { return 0 }))

	// Collect poured cells here
	var records []luaCellRecord

	// Build the cell runtime module (replaces dofile("...cell_runtime.lua"))
	rtModule := buildCellRuntime(L, &records)

	// Override dofile: intercept any path ending in cell_runtime.lua
	L.SetGlobal("dofile", L.NewFunction(func(L *lua.LState) int {
		p := L.CheckString(1)
		if strings.HasSuffix(p, "cell_runtime.lua") {
			L.Push(rtModule)
			return 1
		}
		// Fallback: actually load the file
		if err := L.DoFile(p); err != nil {
			L.RaiseError("%v", err)
		}
		return L.GetTop()
	}))

	if err := L.DoFile(path); err != nil {
		return nil, fmt.Errorf("lua: %v", err)
	}

	return luaRecordsToParsed(src, records)
}

// buildCellRuntime constructs the Lua module table that replaces the
// standalone cell_runtime.lua. It records pour() calls in *records.
func buildCellRuntime(L *lua.LState, records *[]luaCellRecord) *lua.LTable {
	rt := L.NewTable()

	L.SetField(rt, "PURE", lua.LNumber(1))
	L.SetField(rt, "REPLAYABLE", lua.LNumber(2))
	L.SetField(rt, "NON_REPLAYABLE", lua.LNumber(3))

	// rt.hard(fields) → cell table
	L.SetField(rt, "hard", L.NewFunction(func(L *lua.LState) int {
		fields := L.CheckTable(1)
		t := L.NewTable()
		L.SetField(t, "kind", lua.LString("hard"))
		L.SetField(t, "effect", lua.LNumber(1))
		L.SetField(t, "body_tbl", fields)
		L.Push(t)
		return 1
	}))

	// rt.soft(givens, yields, body_fn, checks?) → cell table
	L.SetField(rt, "soft", L.NewFunction(func(L *lua.LState) int {
		givens := L.CheckTable(1)
		yields := L.CheckTable(2)
		bodyFn := L.CheckFunction(3)
		t := L.NewTable()
		L.SetField(t, "kind", lua.LString("soft"))
		L.SetField(t, "effect", lua.LNumber(2))
		L.SetField(t, "givens", givens)
		L.SetField(t, "yields", yields)
		L.SetField(t, "body", bodyFn)
		if L.GetTop() >= 4 {
			L.SetField(t, "checks", L.CheckTable(4))
		}
		L.Push(t)
		return 1
	}))

	// rt.compute(givens, yields, body_fn) → cell table (Pure effect)
	L.SetField(rt, "compute", L.NewFunction(func(L *lua.LState) int {
		givens := L.CheckTable(1)
		yields := L.CheckTable(2)
		bodyFn := L.CheckFunction(3)
		t := L.NewTable()
		L.SetField(t, "kind", lua.LString("compute"))
		L.SetField(t, "effect", lua.LNumber(1))
		L.SetField(t, "givens", givens)
		L.SetField(t, "yields", yields)
		L.SetField(t, "body", bodyFn)
		L.Push(t)
		return 1
	}))

	// rt.stem(givens, yields, factory_fn) → cell table
	L.SetField(rt, "stem", L.NewFunction(func(L *lua.LState) int {
		givens := L.CheckTable(1)
		yields := L.CheckTable(2)
		bodyFn := L.CheckFunction(3)
		t := L.NewTable()
		L.SetField(t, "kind", lua.LString("stem"))
		L.SetField(t, "effect", lua.LNumber(3))
		L.SetField(t, "givens", givens)
		L.SetField(t, "yields", yields)
		L.SetField(t, "body", bodyFn)
		L.Push(t)
		return 1
	}))

	// rt.Retort — the retort class
	retortProto := L.NewTable()

	// Retort.new() → new retort instance
	L.SetField(retortProto, "new", L.NewFunction(func(L *lua.LState) int {
		r := L.NewTable()

		// Attach __index metamethod so r:pour() works
		meta := L.NewTable()
		L.SetField(meta, "__index", retortProto)
		L.SetMetatable(r, meta)

		L.Push(r)
		return 1
	}))

	// Retort:pour(name, cell_def) — records the cell
	L.SetField(retortProto, "pour", L.NewFunction(func(L *lua.LState) int {
		name := L.CheckString(2)
		cellDef := L.CheckTable(3)
		rec := extractCellRecord(L, name, cellDef)
		*records = append(*records, rec)
		return 0
	}))

	// Retort:run() — no-op in loading mode
	L.SetField(retortProto, "run", L.NewFunction(func(L *lua.LState) int { return 0 }))
	// Retort:dump() — no-op
	L.SetField(retortProto, "dump", L.NewFunction(func(L *lua.LState) int { return 0 }))

	L.SetField(rt, "Retort", retortProto)
	return rt
}

// extractCellRecord reads a Lua cell-definition table into a luaCellRecord.
func extractCellRecord(L *lua.LState, name string, t *lua.LTable) luaCellRecord {
	rec := luaCellRecord{name: name}

	if kv := L.GetField(t, "kind"); kv != lua.LNil {
		rec.kind = kv.String()
	}
	if ev, ok := L.GetField(t, "effect").(lua.LNumber); ok {
		rec.effect = int(ev)
	}

	// body function
	if bv, ok := L.GetField(t, "body").(*lua.LFunction); ok {
		rec.body = bv
	}
	// hard cell: body_tbl
	if tv, ok := L.GetField(t, "body_tbl").(*lua.LTable); ok {
		rec.bodyTbl = tv
	}

	// givens list
	if gv, ok := L.GetField(t, "givens").(*lua.LTable); ok {
		gv.ForEach(func(_, v lua.LValue) {
			rec.givens = append(rec.givens, v.String())
		})
	}
	// yields list
	if yv, ok := L.GetField(t, "yields").(*lua.LTable); ok {
		yv.ForEach(func(_, v lua.LValue) {
			rec.yields = append(rec.yields, v.String())
		})
	}
	// checks list
	if cv, ok := L.GetField(t, "checks").(*lua.LTable); ok {
		cv.ForEach(func(_, v lua.LValue) {
			rec.checks = append(rec.checks, v.String())
		})
	}

	return rec
}

// luaRecordsToParsed converts luaCellRecords to parsedCell structs.
func luaRecordsToParsed(src []byte, records []luaCellRecord) ([]parsedCell, error) {
	var cells []parsedCell
	for _, rec := range records {
		pc, err := luaRecordToParsed(src, rec)
		if err != nil {
			return nil, fmt.Errorf("cell %q: %v", rec.name, err)
		}
		cells = append(cells, pc)
	}
	return cells, nil
}

func luaRecordToParsed(src []byte, rec luaCellRecord) (parsedCell, error) {
	givens := luaGivensToGivens(rec.givens)

	switch rec.kind {
	case "hard":
		// Extract prebound field values from the body_tbl
		var yields []parsedYield
		if rec.bodyTbl != nil {
			rec.bodyTbl.ForEach(func(k, v lua.LValue) {
				yields = append(yields, parsedYield{
					fieldName: k.String(),
					prebound:  v.String(),
				})
			})
		} else if len(rec.yields) > 0 {
			for _, y := range rec.yields {
				yields = append(yields, parsedYield{fieldName: y})
			}
		}
		return parsedCell{
			name:     rec.name,
			bodyType: "hard",
			yields:   yields,
			givens:   givens,
		}, nil

	case "soft":
		var yields []parsedYield
		for _, y := range rec.yields {
			yields = append(yields, parsedYield{fieldName: y})
		}
		var oracles []parsedOracle
		for _, c := range rec.checks {
			oracles = append(oracles, parsedOracle{
				assertion:  c,
				oracleType: "semantic",
			})
		}
		body := luaFnBody(src, rec.body)
		return parsedCell{
			name:     rec.name,
			bodyType: "soft",
			body:     body,
			givens:   givens,
			yields:   yields,
			oracles:  oracles,
		}, nil

	case "compute":
		var yields []parsedYield
		for _, y := range rec.yields {
			yields = append(yields, parsedYield{fieldName: y})
		}
		body := luaFnBody(src, rec.body)
		return parsedCell{
			name:     rec.name,
			bodyType: "hard", // compute = Pure tier
			body:     body,
			givens:   givens,
			yields:   yields,
		}, nil

	case "stem":
		var yields []parsedYield
		for _, y := range rec.yields {
			yields = append(yields, parsedYield{fieldName: y})
		}
		body := luaFnBody(src, rec.body)
		return parsedCell{
			name:     rec.name,
			bodyType: "stem",
			body:     body,
			givens:   givens,
			yields:   yields,
		}, nil

	default:
		return parsedCell{}, fmt.Errorf("unknown cell kind %q", rec.kind)
	}
}

// luaFnBody extracts the Lua function source using line number info from
// the function's proto, or falls back to a "lua:fn" marker.
// Strips any trailing comma from the last line (function is often an arg).
func luaFnBody(src []byte, fn *lua.LFunction) string {
	if fn == nil {
		return "lua:fn"
	}
	proto := fn.Proto
	if proto == nil {
		return "lua:fn"
	}
	start := proto.LineDefined
	end := proto.LastLineDefined
	extracted := extractLines(src, start, end)
	if extracted == "" {
		return "lua:fn"
	}
	// Strip trailing comma that appears when function is a table/call argument
	extracted = strings.TrimRight(extracted, " \t")
	if strings.HasSuffix(extracted, ",") {
		extracted = extracted[:len(extracted)-1]
	}
	return "lua:\n" + extracted
}

// extractLines returns lines [startLine, endLine] (1-indexed, inclusive) from src.
func extractLines(src []byte, startLine, endLine int) string {
	lines := bytes.Split(src, []byte("\n"))
	if startLine < 1 || endLine > len(lines) || startLine > endLine {
		return ""
	}
	return string(bytes.Join(lines[startLine-1:endLine], []byte("\n")))
}

// luaGivensToGivens converts "source.field" strings to parsedGiven structs.
func luaGivensToGivens(gs []string) []parsedGiven {
	var givens []parsedGiven
	for _, g := range gs {
		optional := false
		if strings.HasSuffix(g, "?") {
			optional = true
			g = strings.TrimSuffix(g, "?")
		}
		parts := strings.SplitN(g, ".", 2)
		if len(parts) == 2 {
			givens = append(givens, parsedGiven{
				sourceCell:  parts[0],
				sourceField: parts[1],
				optional:    optional,
			})
		}
	}
	return givens
}

// evalLuaCompute executes a stored Lua compute function source with the
// given env map and returns the result as field→value map.
// The body starts with "lua:\n" followed by the function source.
func evalLuaCompute(body string, env map[string]string) (map[string]string, error) {
	fnSrc := strings.TrimPrefix(body, "lua:\n")
	if fnSrc == "" || fnSrc == "lua:fn" {
		return nil, fmt.Errorf("empty Lua compute body")
	}

	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	defer L.Close()
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)

	// Build env table
	envT := L.NewTable()
	for k, v := range env {
		L.SetField(envT, k, lua.LString(v))
	}
	L.SetGlobal("__env", envT)

	// Execute: call the function, store result in __result global
	script := fmt.Sprintf("local __f = %s\n__result = __f(__env)", fnSrc)
	if err := L.DoString(script); err != nil {
		return nil, fmt.Errorf("lua compute: %v", err)
	}

	result := make(map[string]string)
	rv := L.GetGlobal("__result")
	if tbl, ok := rv.(*lua.LTable); ok {
		tbl.ForEach(func(k, v lua.LValue) {
			result[k.String()] = v.String()
		})
	}
	return result, nil
}

// evalLuaSoftPrompt executes a stored Lua soft-cell function source with the
// given env map and returns the prompt string.
// The body starts with "lua:\n" followed by the function source.
func evalLuaSoftPrompt(body string, env map[string]string) (string, error) {
	fnSrc := strings.TrimPrefix(body, "lua:\n")
	if fnSrc == "" || fnSrc == "lua:fn" {
		return "", fmt.Errorf("empty Lua soft body")
	}

	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	defer L.Close()
	lua.OpenBase(L)
	lua.OpenTable(L)
	lua.OpenString(L)
	lua.OpenMath(L)

	// Build env table — resolveInputs provides "source.field", "source→field", bare "field"
	envT := L.NewTable()
	for k, v := range env {
		L.SetField(envT, k, lua.LString(v))
		// Also add bare field name (last component after dot)
		if idx := strings.LastIndex(k, "."); idx >= 0 {
			L.SetField(envT, k[idx+1:], lua.LString(v))
		}
	}
	L.SetGlobal("__env", envT)

	// Execute: call the function, store result in __result global
	script := fmt.Sprintf("local __f = %s\n__result = __f(__env)", fnSrc)
	if err := L.DoString(script); err != nil {
		return "", fmt.Errorf("lua soft prompt: %v", err)
	}

	rv := L.GetGlobal("__result")
	if rv == lua.LNil {
		return "", fmt.Errorf("lua soft prompt: function returned nothing")
	}
	return rv.String(), nil
}

// isLuaBody reports whether a cell body was produced by Lua (starts with "lua:").
func isLuaBody(body string) bool {
	return strings.HasPrefix(body, "lua:")
}

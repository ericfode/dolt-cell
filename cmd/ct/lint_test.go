package main

import (
	"os"
	"testing"
)

func TestLint_Clean(t *testing.T) {
	tmpFile := writeTempLua(t, `
return {
  cells = {
    topic = { kind = "hard", body = { subject = "hello" } },
    use = {
      kind = "soft",
      givens = { "topic.subject" },
      yields = { "result" },
    },
  },
  order = { "topic", "use" },
}
`)
	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram: %v", err)
	}
	errs := lintCells(cells)
	if len(errs) != 0 {
		t.Errorf("clean program should have no errors: %v", errs)
	}
}

func TestLint_DanglingGiven(t *testing.T) {
	tmpFile := writeTempLua(t, `
return {
  cells = {
    use = {
      kind = "soft",
      givens = { "nonexistent.field" },
      yields = { "result" },
    },
  },
  order = { "use" },
}
`)
	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram: %v", err)
	}
	errs := lintCells(cells)
	found := false
	for _, e := range errs {
		if contains(e, "dangling") {
			found = true
		}
	}
	if !found {
		t.Errorf("should detect dangling given, got: %v", errs)
	}
}

func TestLint_DuplicateName(t *testing.T) {
	// Two cells with the same name — LoadLuaProgram returns only one since
	// Lua tables overwrite duplicate keys. Simulate duplicate by building
	// parsedCells directly.
	cells := []parsedCell{
		{name: "foo", bodyType: "hard", yields: []parsedYield{{fieldName: "x", prebound: "1"}}},
		{name: "foo", bodyType: "hard", yields: []parsedYield{{fieldName: "y", prebound: "2"}}},
	}
	errs := lintCells(cells)
	found := false
	for _, e := range errs {
		if contains(e, "duplicate") {
			found = true
		}
	}
	if !found {
		t.Errorf("should detect duplicate cell name, got: %v", errs)
	}
}

func TestLint_NoYields(t *testing.T) {
	// A cell with no yields — construct directly since LoadLuaProgram
	// would require a yields field.
	cells := []parsedCell{
		{name: "empty", bodyType: "soft", body: "Body with no yields."},
	}
	errs := lintCells(cells)
	found := false
	for _, e := range errs {
		if contains(e, "no yields") {
			found = true
		}
	}
	if !found {
		t.Errorf("should detect cell with no yields, got: %v", errs)
	}
}

func TestLint_Cycle(t *testing.T) {
	tmpFile := writeTempLua(t, `
return {
  cells = {
    a = {
      kind = "soft",
      givens = { "b.x" },
      yields = { "x" },
    },
    b = {
      kind = "soft",
      givens = { "a.x" },
      yields = { "x" },
    },
  },
  order = { "a", "b" },
}
`)
	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram: %v", err)
	}
	errs := lintCells(cells)
	found := false
	for _, e := range errs {
		if contains(e, "cycle") {
			found = true
		}
	}
	if !found {
		t.Errorf("should detect dependency cycle, got: %v", errs)
	}
}

func TestLint_IterationValid(t *testing.T) {
	tmpFile := writeTempLua(t, `
return {
  cells = {
    seed = { kind = "hard", body = { text = "hello" } },
    refine = {
      kind = "stem",
      givens = { "seed.text" },
      yields = { "text" },
      iterate = 3,
    },
    final = {
      kind = "soft",
      givens = { "refine.text" },
      yields = { "result" },
    },
  },
  order = { "seed", "refine", "final" },
}
`)
	cells, err := LoadLuaProgram(tmpFile)
	if err != nil {
		t.Fatalf("LoadLuaProgram: %v", err)
	}
	errs := lintCells(cells)
	if len(errs) != 0 {
		t.Errorf("iteration program should be valid: %v", errs)
	}
}

func TestLint_AllExamples(t *testing.T) {
	files := []string{
		"../../examples/haiku.lua",
		"../../examples/haiku-refine.lua",
		"../../examples/fact-check.lua",
		"../../examples/code-audit.lua",
		"../../examples/parallel-research.lua",
	}
	for _, f := range files {
		t.Run(f, func(t *testing.T) {
			data, err := readFileIfExists(f)
			if err != nil {
				t.Skip(err)
			}
			_ = data
			cells, err := LoadLuaProgram(f)
			if err != nil {
				t.Skipf("cannot load %s: %v", f, err)
			}
			if cells == nil {
				t.Skipf("no cells in %s", f)
			}
			errs := lintCells(cells)
			if len(errs) > 0 {
				t.Errorf("%s has lint errors: %v", f, errs)
			}
		})
	}
}

func readFileIfExists(path string) ([]byte, error) {
	return os.ReadFile(path)
}

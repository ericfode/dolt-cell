package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseAllExamples(t *testing.T) {
	files, err := filepath.Glob("../../examples/*.cell")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		name := filepath.Base(f)
		t.Run(name, func(t *testing.T) {
			data, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			cells := parseCellFile(string(data))
			if cells == nil {
				t.Skipf("Phase B cannot parse %s (falls back to Phase A)", name)
				return
			}
			sql := cellsToSQL(name[:len(name)-5], cells)
			t.Logf("✓ %s: %d cells, %d bytes SQL", name, len(cells), len(sql))
		})
	}
}

func TestParseCellZero(t *testing.T) {
	data, err := os.ReadFile("../../examples/cell-zero.cell")
	if err != nil {
		t.Fatalf("read cell-zero.cell: %v", err)
	}

	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil — Phase B cannot parse cell-zero.cell")
	}

	// Expected cells: context, pour, oracle-semantic, claim, dispatch, evaluate, submit, eval-loop, spawn, crystallize
	expected := []struct {
		name     string
		bodyType string
		nGivens  int
		nYields  int
		nOracles int
	}{
		{"context", "hard", 0, 2, 0},
		{"pour", "stem", 2, 1, 1},
		{"oracle-semantic", "stem", 1, 1, 1},
		{"claim", "stem", 1, 1, 1},
		{"dispatch", "stem", 2, 1, 1},
		{"evaluate", "stem", 1, 1, 1},
		{"submit", "stem", 3, 1, 1},
		{"eval-loop", "stem", 4, 1, 1},
		{"spawn", "stem", 2, 1, 1},
		{"crystallize", "stem", 2, 1, 1},
	}

	if len(cells) != len(expected) {
		t.Fatalf("expected %d cells, got %d", len(expected), len(cells))
	}

	for i, exp := range expected {
		c := cells[i]
		if c.name != exp.name {
			t.Errorf("cell[%d]: name=%q, want %q", i, c.name, exp.name)
		}
		if c.bodyType != exp.bodyType {
			t.Errorf("cell[%d] %s: bodyType=%q, want %q", i, exp.name, c.bodyType, exp.bodyType)
		}
		if len(c.givens) != exp.nGivens {
			t.Errorf("cell[%d] %s: %d givens, want %d", i, exp.name, len(c.givens), exp.nGivens)
		}
		if len(c.yields) != exp.nYields {
			t.Errorf("cell[%d] %s: %d yields, want %d", i, exp.name, len(c.yields), exp.nYields)
		}
		if len(c.oracles) != exp.nOracles {
			t.Errorf("cell[%d] %s: %d oracles, want %d", i, exp.name, len(c.oracles), exp.nOracles)
		}
	}

	// Verify SQL generation doesn't panic
	sql := cellsToSQL("cell-zero", cells)
	if sql == "" {
		t.Fatal("cellsToSQL returned empty string")
	}

	// Verify all new eval-step cells are stem type
	evalCells := []string{"claim", "dispatch", "evaluate", "submit", "eval-loop"}
	for _, name := range evalCells {
		for _, c := range cells {
			if c.name == name {
				if c.bodyType != "stem" {
					t.Errorf("%s: bodyType=%q, want stem", name, c.bodyType)
				}
				if c.body == "" {
					t.Errorf("%s: body is empty", name)
				}
			}
		}
	}

	t.Logf("✓ cell-zero.cell: %d cells parsed, SQL generated (%d bytes)", len(cells), len(sql))
}

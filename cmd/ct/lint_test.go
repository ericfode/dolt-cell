package main

import (
	"os"
	"testing"
)

func TestLint_Clean(t *testing.T) {
	cells := parseCellFile(`cell topic
  yield subject = "hello"

cell use
  given topic.subject
  yield result
  ---
  Use «subject».
  ---
`)
	errs := lintCells(cells)
	if len(errs) != 0 {
		t.Errorf("clean program should have no errors: %v", errs)
	}
}

func TestLint_DanglingGiven(t *testing.T) {
	cells := parseCellFile(`cell use
  given nonexistent.field
  yield result
  ---
  Body.
  ---
`)
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
	cells := parseCellFile(`cell foo
  yield x = "1"

cell foo
  yield y = "2"
`)
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
	cells := parseCellFile(`cell empty
  ---
  Body with no yields.
  ---
`)
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
	cells := parseCellFile(`cell a
  given b.x
  yield x
  ---
  Body.
  ---

cell b
  given a.x
  yield x
  ---
  Body.
  ---
`)
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
	cells := parseCellFile(`cell seed
  yield text = "hello"

cell refine (stem)
  given seed.text
  yield text
  recur (max 3)
  ---
  Improve «text».
  ---

cell final
  given refine.text
  yield result
  ---
  Done.
  ---
`)
	errs := lintCells(cells)
	if len(errs) != 0 {
		t.Errorf("iteration program should be valid: %v", errs)
	}
}

func TestLint_AllExamples(t *testing.T) {
	files := []string{
		"../../examples/haiku.cell",
		"../../examples/haiku-refine.cell",
		"../../examples/fact-check.cell",
		"../../examples/code-audit.cell",
		"../../examples/parallel-research.cell",
	}
	for _, f := range files {
		t.Run(f, func(t *testing.T) {
			data, err := readFileIfExists(f)
			if err != nil {
				t.Skip(err)
			}
			cells := parseCellFile(string(data))
			if cells == nil {
				t.Skipf("cannot parse %s", f)
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

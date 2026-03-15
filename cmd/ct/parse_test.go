package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
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

	// cell-zero has only deterministic oracles (not_empty), so SQL should contain NO judge cells
	if strings.Contains(sql, "-judge-") {
		t.Error("cell-zero should not generate judge cells (all oracles are deterministic)")
	}
}

func TestExplicitSemanticOracle(t *testing.T) {
	input := `⊢ data
  yield items ≡ [1,2,3]

⊢ process
  given data→items
  yield result
  ∴ Sort «items» ascending.
  ⊨~ result is well-formatted and readable
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if len(cells) != 2 {
		t.Fatalf("expected 2 cells, got %d", len(cells))
	}

	proc := cells[1]
	if len(proc.oracles) != 1 {
		t.Fatalf("process: expected 1 oracle, got %d", len(proc.oracles))
	}
	o := proc.oracles[0]
	if o.oracleType != "semantic" {
		t.Errorf("⊨~ oracle: type=%q, want semantic", o.oracleType)
	}
	if o.condExpr != "" {
		t.Errorf("⊨~ oracle: condExpr=%q, want empty (semantic oracles have no condition)", o.condExpr)
	}
	if o.assertion != "result is well-formatted and readable" {
		t.Errorf("assertion=%q", o.assertion)
	}
}

func TestSemanticNotEmptyStaysDeterministic(t *testing.T) {
	// ⊨ "is not empty" should still classify as deterministic, not generate a judge
	input := `⊢ cell
  yield text
  ∴ Write something.
  ⊨ text is not empty
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	o := cells[0].oracles[0]
	if o.oracleType != "deterministic" {
		t.Errorf("'is not empty' should be deterministic, got %q", o.oracleType)
	}

	sql := cellsToSQL("test", cells)
	if strings.Contains(sql, "-judge-") {
		t.Error("deterministic oracle should not generate judge cells")
	}
}

func TestJudgeCellGeneration(t *testing.T) {
	input := `⊢ data
  yield items ≡ [4,1,7,3]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» ascending.
  ⊨~ sorted is in ascending order
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("judge-test", cells)

	// Should contain the judge cell
	if !strings.Contains(sql, "sort-judge-1") {
		t.Fatal("SQL should contain sort-judge-1 judge cell")
	}

	// Judge should be a stem cell
	if !strings.Contains(sql, "'stem'") {
		t.Error("judge cell should be body_type='stem'")
	}

	// Judge should depend on sort→sorted
	if !strings.Contains(sql, "'sort', 'sorted'") {
		t.Error("judge cell should have given sort→sorted")
	}

	// Judge should yield verdict
	if !strings.Contains(sql, "'verdict'") {
		t.Error("judge cell should yield verdict")
	}

	// Judge body should reference the assertion
	if !strings.Contains(sql, "sorted is in ascending order") {
		t.Error("judge body should contain the oracle assertion text")
	}

	// Judge should have a not_empty oracle on verdict
	if !strings.Contains(sql, "'not_empty'") {
		t.Error("judge cell should have not_empty oracle on verdict")
	}

	t.Logf("✓ judge cell generated:\n%s", sql)
}

func TestIterationWithSemanticOracle(t *testing.T) {
	input := `⊢ seed
  yield text ≡ Draft essay about cats.

⊢∘ refine × 3
  given seed→text
  yield text
  ∴∴ Improve «text». Make it clearer.
  ⊨~ text reads naturally and flows well
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("iter-judge", cells)

	// Each iteration step should have its own judge
	for i := 1; i <= 3; i++ {
		judgeName := fmt.Sprintf("refine-%d-judge-1", i)
		if !strings.Contains(sql, judgeName) {
			t.Errorf("missing judge cell %s", judgeName)
		}
	}

	// Judge cells should reference their iteration step, not the template
	if !strings.Contains(sql, "'refine-1', 'text'") {
		t.Error("refine-1-judge should depend on refine-1→text")
	}
	if !strings.Contains(sql, "'refine-2', 'text'") {
		t.Error("refine-2-judge should depend on refine-2→text")
	}
	if !strings.Contains(sql, "'refine-3', 'text'") {
		t.Error("refine-3-judge should depend on refine-3→text")
	}

	t.Logf("✓ iteration judges generated:\n%s", sql)
}

func TestMultipleSemanticOracles(t *testing.T) {
	input := `⊢ data
  yield items ≡ [1,2,3]

⊢ analyze
  given data→items
  yield summary
  yield chart
  ∴ Analyze «items» and produce a summary and chart.
  ⊨~ summary captures key trends
  ⊨~ chart is properly labeled
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("multi-oracle", cells)

	// Should have 2 judge cells
	if !strings.Contains(sql, "analyze-judge-1") {
		t.Error("missing analyze-judge-1")
	}
	if !strings.Contains(sql, "analyze-judge-2") {
		t.Error("missing analyze-judge-2")
	}

	// Each judge should take BOTH yields as input
	// Count occurrences of 'analyze', 'summary' (given references)
	count := strings.Count(sql, "'analyze', 'summary'")
	if count < 2 {
		t.Errorf("expected 2 judge givens for 'summary', got %d", count)
	}
	count = strings.Count(sql, "'analyze', 'chart'")
	if count < 2 {
		t.Errorf("expected 2 judge givens for 'chart', got %d", count)
	}
}

func TestFactCheckExample(t *testing.T) {
	data, err := os.ReadFile("../../examples/fact-check.cell")
	if err != nil {
		t.Fatalf("read fact-check.cell: %v", err)
	}

	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// 3 cells: topic, answer, simplify
	if len(cells) != 3 {
		t.Fatalf("expected 3 cells, got %d", len(cells))
	}

	// answer has 3 oracles: 1 deterministic + 2 semantic
	answer := cells[1]
	if len(answer.oracles) != 3 {
		t.Fatalf("answer: expected 3 oracles, got %d", len(answer.oracles))
	}
	if answer.oracles[0].oracleType != "deterministic" {
		t.Error("answer oracle[0] should be deterministic")
	}
	if answer.oracles[1].oracleType != "semantic" {
		t.Error("answer oracle[1] should be semantic")
	}
	if answer.oracles[2].oracleType != "semantic" {
		t.Error("answer oracle[2] should be semantic")
	}

	sql := cellsToSQL("fact-check", cells)

	// 2 judge cells for answer (semantic oracles at index 1 and 2)
	if !strings.Contains(sql, "answer-judge-2") {
		t.Error("missing answer-judge-2")
	}
	if !strings.Contains(sql, "answer-judge-3") {
		t.Error("missing answer-judge-3")
	}

	// 1 judge cell for simplify (semantic oracle at index 1)
	if !strings.Contains(sql, "simplify-judge-2") {
		t.Error("missing simplify-judge-2")
	}

	// Total: should NOT have judge-1 for either (those are deterministic)
	if strings.Contains(sql, "answer-judge-1") {
		t.Error("answer oracle[0] is deterministic, should not generate judge-1")
	}
	if strings.Contains(sql, "simplify-judge-1") {
		t.Error("simplify oracle[0] is deterministic, should not generate judge-1")
	}

	t.Logf("✓ fact-check.cell: 3 cells → %d judge cells generated\n%s", 3, sql)
}

func TestMixedOracles(t *testing.T) {
	// A cell with both deterministic and semantic oracles
	// Only semantic ones should generate judge cells
	input := `⊢ data
  yield items ≡ [4,1,7]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» ascending.
  ⊨ sorted is not empty
  ⊨~ sorted is in strictly ascending order
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("mixed", cells)

	// The semantic oracle is at index 1 (0-indexed), so judge is "sort-judge-2"
	if !strings.Contains(sql, "sort-judge-2") {
		t.Error("semantic oracle at index 1 should generate sort-judge-2")
	}
	// Deterministic oracle at index 0 should NOT generate a judge
	if strings.Contains(sql, "sort-judge-1") {
		t.Error("deterministic oracle should not generate sort-judge-1")
	}

	t.Logf("✓ mixed oracles SQL:\n%s", sql)
}

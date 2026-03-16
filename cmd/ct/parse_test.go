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

	// Feedback wiring: refine-2 should have optional given from refine-1-judge-1→verdict
	if !strings.Contains(sql, "'refine-1-judge-1', 'verdict'") {
		t.Error("refine-2 should have optional given refine-1-judge-1→verdict")
	}
	// refine-3 should have optional given from refine-2-judge-1→verdict
	if !strings.Contains(sql, "'refine-2-judge-1', 'verdict'") {
		t.Error("refine-3 should have optional given refine-2-judge-1→verdict")
	}

	// refine-1 should NOT have judge feedback (it's the first iteration)
	// Check that no given has cell_id='ij-refine-1' and references a judge
	lines := strings.Split(sql, "\n")
	for _, line := range lines {
		if strings.Contains(line, "'ij-refine-1'") && strings.Contains(line, "judge") && strings.Contains(line, "verdict") {
			t.Errorf("refine-1 should not have judge feedback given: %s", line)
		}
	}

	// refine-2 and refine-3 bodies should mention «verdict»
	if !strings.Contains(sql, "«verdict»") {
		t.Error("iteration bodies for i>1 should reference «verdict» feedback")
	}

	t.Logf("✓ iteration with judge feedback:\n%s", sql)
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

func TestRefineWithJudgeExample(t *testing.T) {
	data, err := os.ReadFile("../../examples/refine-with-judge.cell")
	if err != nil {
		t.Fatal(err)
	}

	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// 3 parsed cells: prompt, draft, refine (iteration template)
	if len(cells) != 3 {
		t.Fatalf("expected 3 parsed cells, got %d", len(cells))
	}

	sql := cellsToSQL("refine-with-judge", cells)

	// Expansion should produce:
	// prompt (hard), draft (stem),
	// refine-1 + refine-1-judge-1 + refine-1-judge-2,
	// refine-2 (with feedback) + refine-2-judge-1 + refine-2-judge-2,
	// refine-3 (with feedback) + refine-3-judge-1 + refine-3-judge-2
	// = 2 + 3*3 = 11 cells total in SQL
	cellCount := strings.Count(sql, "INSERT INTO cells")
	if cellCount != 11 {
		t.Errorf("expected 11 cells in SQL (2 base + 3 iterations * 3 [cell + 2 judges]), got %d", cellCount)
	}

	// refine-2 should have 2 judge feedback givens (from refine-1-judge-1 and refine-1-judge-2)
	if !strings.Contains(sql, "'refine-1-judge-1', 'verdict', TRUE") {
		t.Error("refine-2 should have optional given from refine-1-judge-1→verdict")
	}
	if !strings.Contains(sql, "'refine-1-judge-2', 'verdict', TRUE") {
		t.Error("refine-2 should have optional given from refine-1-judge-2→verdict")
	}

	t.Logf("✓ refine-with-judge: %d cells in SQL", cellCount)
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

func TestHaikuMultiLineBody(t *testing.T) {
	data, err := os.ReadFile("../../examples/haiku.cell")
	if err != nil {
		t.Fatal(err)
	}

	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// Find critique cell
	var critique *parsedCell
	for i := range cells {
		if cells[i].name == "critique" {
			critique = &cells[i]
			break
		}
	}
	if critique == nil {
		t.Fatal("critique cell not found")
	}

	// Check that critique body includes the multi-line content
	if !strings.Contains(critique.body, "Critique this haiku") {
		t.Error("critique body missing first line")
	}

	// The ⊨ oracle should be parsed, not eaten by continuation
	if len(critique.oracles) != 1 {
		t.Errorf("critique: expected 1 oracle, got %d", len(critique.oracles))
	} else if !strings.Contains(critique.oracles[0].assertion, "at least 2 sentences") {
		t.Errorf("critique oracle assertion=%q", critique.oracles[0].assertion)
	}

	t.Logf("✓ haiku critique body: %q", critique.body)
	t.Logf("  body_type: %s, givens: %d, yields: %d, oracles: %d",
		critique.bodyType, len(critique.givens), len(critique.yields), len(critique.oracles))
}

func TestIterationTemplateReference(t *testing.T) {
	// "given refine→text" should auto-resolve to "given refine-3→text"
	// when ⊢∘ refine × 3 exists
	input := `⊢ prompt
  yield topic ≡ Write about cats.

⊢ draft
  given prompt→topic
  yield text
  ∴ Write a first draft about «topic».

⊢∘ refine × 3
  given draft→text
  yield text
  ∴∴ Improve «text».

⊢ final
  given refine→text
  yield summary
  ∴ Summarize «text» in one sentence.
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("iter-ref", cells)

	// "final" cell should depend on refine-3→text, not refine→text
	if strings.Contains(sql, "'refine', 'text'") {
		t.Error("final cell should not reference template name 'refine' directly")
	}
	if !strings.Contains(sql, "'refine-3', 'text'") {
		t.Error("final cell should reference 'refine-3' (last iteration)")
	}

	t.Logf("✓ iteration template reference resolved:\n%s", sql)
}

func TestIterationTemplateReferenceDoesNotAffectExplicit(t *testing.T) {
	// Explicit references like "given refine-1→text" should not be rewritten
	input := `⊢ seed
  yield text ≡ Hello.

⊢∘ refine × 3
  given seed→text
  yield text
  ∴∴ Improve «text».

⊢ compare
  given refine-1→text
  given refine→text
  yield comparison
  ∴ Compare first iteration «text» with final «text».
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("explicit-ref", cells)

	// refine-1→text should stay as refine-1 (explicit, not a template name)
	if !strings.Contains(sql, "'refine-1', 'text'") {
		t.Error("explicit reference refine-1→text should be preserved")
	}
	// refine→text should be rewritten to refine-3→text
	if !strings.Contains(sql, "'refine-3', 'text'") {
		t.Error("template reference refine→text should resolve to refine-3")
	}
}

func TestGatherWildcard(t *testing.T) {
	input := `⊢ topic
  yield question ≡ How do LLMs work?

⊢∘ research × 3
  given topic→question
  yield finding
  ∴∴ Research a unique aspect of «question». Return one key finding.

⊢ synthesize
  given research-*→finding
  yield summary
  ∴ Combine all findings into a coherent summary.
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("gather-test", cells)

	// synthesize should have 3 givens (research-1, research-2, research-3)
	for i := 1; i <= 3; i++ {
		ref := fmt.Sprintf("'research-%d', 'finding'", i)
		if !strings.Contains(sql, ref) {
			t.Errorf("synthesize should have given research-%d→finding", i)
		}
	}

	// Should NOT contain the wildcard form
	if strings.Contains(sql, "research-*") {
		t.Error("wildcard research-* should be expanded, not literal")
	}

	t.Logf("✓ gather wildcard expanded:\n%s", sql)
}

// ===================================================================
// v2 syntax tests
// ===================================================================

func TestV2BasicCellDecl(t *testing.T) {
	input := `cell topic
  yield subject = "autumn rain"
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if len(cells) != 1 {
		t.Fatalf("expected 1 cell, got %d", len(cells))
	}
	c := cells[0]
	if c.name != "topic" {
		t.Errorf("name=%q, want topic", c.name)
	}
	if c.bodyType != "hard" {
		t.Errorf("bodyType=%q, want hard", c.bodyType)
	}
	if len(c.yields) != 1 || c.yields[0].prebound != "autumn rain" {
		t.Errorf("yield prebound=%q, want 'autumn rain'", c.yields[0].prebound)
	}
}

func TestV2StemCell(t *testing.T) {
	input := `cell eval-one (stem)
  yield status
  ---
  Find work and evaluate it.
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if len(cells) != 1 {
		t.Fatalf("expected 1 cell, got %d", len(cells))
	}
	c := cells[0]
	if c.name != "eval-one" {
		t.Errorf("name=%q, want eval-one", c.name)
	}
	if c.bodyType != "stem" {
		t.Errorf("bodyType=%q, want stem", c.bodyType)
	}
	if !strings.Contains(c.body, "Find work") {
		t.Errorf("body=%q, missing 'Find work'", c.body)
	}
}

func TestV2DotNotationGiven(t *testing.T) {
	input := `cell topic
  yield subject = "cats"

cell compose
  given topic.subject
  yield poem
  ---
  Write about «subject».
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if len(cells) != 2 {
		t.Fatalf("expected 2 cells, got %d", len(cells))
	}
	compose := cells[1]
	if len(compose.givens) != 1 {
		t.Fatalf("compose: expected 1 given, got %d", len(compose.givens))
	}
	g := compose.givens[0]
	if g.sourceCell != "topic" || g.sourceField != "subject" {
		t.Errorf("given: %s.%s, want topic.subject", g.sourceCell, g.sourceField)
	}
	if g.optional {
		t.Error("given should not be optional")
	}
}

func TestV2OptionalGiven(t *testing.T) {
	input := `cell refine (stem)
  given? judge.verdict
  yield text
  ---
  Revise based on feedback.
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	g := cells[0].givens[0]
	if !g.optional {
		t.Error("given? should be optional")
	}
	if g.sourceCell != "judge" || g.sourceField != "verdict" {
		t.Errorf("given: %s.%s, want judge.verdict", g.sourceCell, g.sourceField)
	}
}

func TestV2FencedBody(t *testing.T) {
	input := `cell compose
  given topic.subject
  yield poem
  ---
  Write a haiku about «subject».

  Follow the 5-7-5 structure.
  Return three lines.
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	c := cells[0]
	if !strings.Contains(c.body, "Write a haiku") {
		t.Errorf("body missing 'Write a haiku': %q", c.body)
	}
	if !strings.Contains(c.body, "Return three lines") {
		t.Errorf("body missing 'Return three lines': %q", c.body)
	}
	// Blank line preserved
	if !strings.Contains(c.body, "\n\n") {
		t.Errorf("body should preserve blank line: %q", c.body)
	}
}

func TestV2HardComputedSQL(t *testing.T) {
	input := `cell count-words
  given compose.poem
  yield total
  ---
  sql: SELECT COUNT(*) FROM items
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	c := cells[0]
	if c.bodyType != "hard" {
		t.Errorf("bodyType=%q, want hard (sql: body)", c.bodyType)
	}
	if !strings.HasPrefix(c.body, "sql:") {
		t.Errorf("body should start with 'sql:': %q", c.body)
	}
}

func TestV2CheckOracle(t *testing.T) {
	input := `cell answer
  given topic.question
  yield text
  ---
  Answer «question».
  ---
  check text is not empty
  check~ text is factually accurate
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	c := cells[0]
	if len(c.oracles) != 2 {
		t.Fatalf("expected 2 oracles, got %d", len(c.oracles))
	}
	// check → deterministic (auto-classified)
	if c.oracles[0].oracleType != "deterministic" {
		t.Errorf("oracle[0]: type=%q, want deterministic", c.oracles[0].oracleType)
	}
	if c.oracles[0].condExpr != "not_empty" {
		t.Errorf("oracle[0]: condExpr=%q, want not_empty", c.oracles[0].condExpr)
	}
	// check~ → semantic
	if c.oracles[1].oracleType != "semantic" {
		t.Errorf("oracle[1]: type=%q, want semantic", c.oracles[1].oracleType)
	}
}

func TestV2GatherBracket(t *testing.T) {
	input := `cell topic
  yield question = "How do LLMs work?"

cell research (stem)
  given topic.question
  yield finding
  recur (max 3)
  ---
  Research a unique aspect of «question».
  ---

cell synthesize
  given research[*].finding
  yield summary
  ---
  Combine all findings.
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// Find synthesize cell
	var synth *parsedCell
	for i := range cells {
		if cells[i].name == "synthesize" {
			synth = &cells[i]
			break
		}
	}
	if synth == nil {
		t.Fatal("synthesize cell not found")
	}

	// Gather bracket should expand to research-1, research-2, research-3
	sql := cellsToSQL("gather-v2", cells)
	for i := 1; i <= 3; i++ {
		ref := fmt.Sprintf("'research-%d', 'finding'", i)
		if !strings.Contains(sql, ref) {
			t.Errorf("synthesize should have given research-%d.finding in SQL", i)
		}
	}
}

func TestV2RecurIteration(t *testing.T) {
	input := `cell seed
  yield text = "Draft about cats."

cell refine (stem)
  given seed.text
  yield text
  recur (max 3)
  ---
  Improve «text».
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// refine has recur (max 3) — should expand to refine-1, refine-2, refine-3
	sql := cellsToSQL("recur-v2", cells)
	for i := 1; i <= 3; i++ {
		name := fmt.Sprintf("'refine-%d'", i)
		if !strings.Contains(sql, name) {
			t.Errorf("SQL should contain expanded cell %s", name)
		}
	}

	// refine-2 should chain from refine-1
	if !strings.Contains(sql, "'refine-1', 'text'") {
		t.Error("refine-2 should have given refine-1.text")
	}
}

func TestV2RecurWithGuard(t *testing.T) {
	input := `cell compose
  yield poem

cell reflect (stem)
  given compose.poem
  yield poem
  yield settled
  recur until settled = "SETTLED" (max 4)
  ---
  Refine «poem». Return SETTLED or REVISING.
  ---
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	// reflect should have iterate=4 and a guard
	var reflect *parsedCell
	for i := range cells {
		if cells[i].name == "reflect" {
			reflect = &cells[i]
			break
		}
	}
	if reflect == nil {
		t.Fatal("reflect cell not found")
	}
	if reflect.iterate != 4 {
		t.Errorf("iterate=%d, want 4", reflect.iterate)
	}
	if reflect.guard == "" {
		t.Error("guard should not be empty")
	}
}

func TestV2ParseCellZero(t *testing.T) {
	data, err := os.ReadFile("../../examples/cell-zero.cell")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil — cannot parse v2 cell-zero.cell")
	}

	// cell-zero has: context, pour, oracle-semantic, claim, dispatch, evaluate, submit, eval-loop, spawn, crystallize
	if len(cells) != 10 {
		t.Fatalf("expected 10 cells, got %d", len(cells))
	}

	// context is a hard cell with 2 prebound yields
	if cells[0].name != "context" {
		t.Errorf("cell[0].name=%q, want context", cells[0].name)
	}
	if cells[0].bodyType != "hard" {
		t.Errorf("context bodyType=%q, want hard", cells[0].bodyType)
	}

	// pour is a stem cell
	pour := cells[1]
	if pour.name != "pour" {
		t.Errorf("cell[1].name=%q, want pour", pour.name)
	}
	if pour.bodyType != "stem" {
		t.Errorf("pour bodyType=%q, want stem", pour.bodyType)
	}
	if len(pour.givens) != 2 {
		t.Errorf("pour: %d givens, want 2", len(pour.givens))
	}

	// Verify SQL generation works
	sql := cellsToSQL("cell-zero", cells)
	if sql == "" {
		t.Fatal("cellsToSQL returned empty")
	}
}

func TestV2ParseHaiku(t *testing.T) {
	data, err := os.ReadFile("../../examples/haiku.cell")
	if err != nil {
		t.Fatal(err)
	}
	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil — cannot parse v2 haiku.cell")
	}
	if len(cells) != 4 {
		t.Fatalf("expected 4 cells, got %d", len(cells))
	}

	// Verify critique has a semantic oracle
	var critique *parsedCell
	for i := range cells {
		if cells[i].name == "critique" {
			critique = &cells[i]
		}
	}
	if critique == nil {
		t.Fatal("critique not found")
	}
	if len(critique.oracles) != 1 {
		t.Fatalf("critique: expected 1 oracle, got %d", len(critique.oracles))
	}
	if critique.oracles[0].oracleType != "semantic" {
		t.Errorf("critique oracle type=%q, want semantic", critique.oracles[0].oracleType)
	}
}

func TestV2ParseHaikuRefine(t *testing.T) {
	data, err := os.ReadFile("../../examples/haiku-refine.cell")
	if err != nil {
		t.Fatal(err)
	}
	cells := parseCellFile(string(data))
	if cells == nil {
		t.Fatal("parseCellFile returned nil — cannot parse v2 haiku-refine.cell")
	}

	// haiku-refine: topic, compose, reflect(stem+recur), poem, evolution
	if len(cells) != 5 {
		t.Fatalf("expected 5 cells, got %d", len(cells))
	}

	// reflect has recur until settled = "SETTLED" (max 4)
	var reflect *parsedCell
	for i := range cells {
		if cells[i].name == "reflect" {
			reflect = &cells[i]
		}
	}
	if reflect == nil {
		t.Fatal("reflect not found")
	}
	if reflect.bodyType != "stem" {
		t.Errorf("reflect bodyType=%q, want stem", reflect.bodyType)
	}
	if reflect.iterate != 4 {
		t.Errorf("reflect iterate=%d, want 4", reflect.iterate)
	}

	// evolution gathers reflect[*].poem and reflect[*].settled
	var evo *parsedCell
	for i := range cells {
		if cells[i].name == "evolution" {
			evo = &cells[i]
		}
	}
	if evo == nil {
		t.Fatal("evolution not found")
	}
	// Should have gather givens: compose.poem + reflect[*].poem + reflect[*].settled = 3 raw givens
	// The [*] will expand during SQL generation
	if len(evo.givens) < 3 {
		t.Errorf("evolution: expected at least 3 givens, got %d", len(evo.givens))
	}
}

func TestV2YieldUnquoted(t *testing.T) {
	// yield NAME = VALUE without quotes should work
	input := `cell topic
  yield subject = autumn rain on a temple roof
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}
	if cells[0].yields[0].prebound != "autumn rain on a temple roof" {
		t.Errorf("prebound=%q, want 'autumn rain on a temple roof'", cells[0].yields[0].prebound)
	}
}

func TestV2AllExamplesParse(t *testing.T) {
	files, err := filepath.Glob("../../examples/*.cell")
	if err != nil {
		t.Fatal(err)
	}
	var failed []string
	for _, f := range files {
		name := filepath.Base(f)
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		cells := parseCellFile(string(data))
		if cells == nil {
			failed = append(failed, name)
		}
	}
	if len(failed) > 0 {
		t.Errorf("failed to parse %d v2 files: %v", len(failed), failed)
	}
}

func TestGatherWildcardWithTemplateRef(t *testing.T) {
	// Both gather and template ref in same program
	input := `⊢ seed
  yield text ≡ Hello.

⊢∘ step × 4
  given seed→text
  yield result
  ∴∴ Process «text».

⊢ collect
  given step-*→result
  yield all
  ∴ Collect all results.

⊢ final
  given step→result
  yield summary
  ∴ Use the final result.
`
	cells := parseCellFile(input)
	if cells == nil {
		t.Fatal("parseCellFile returned nil")
	}

	sql := cellsToSQL("both-test", cells)

	// collect should have 4 givens (step-1..step-4)
	for i := 1; i <= 4; i++ {
		ref := fmt.Sprintf("'step-%d', 'result'", i)
		if !strings.Contains(sql, ref) {
			t.Errorf("collect should have given step-%d→result", i)
		}
	}

	// final should have only step-4 (template ref = last)
	// Count occurrences of step-4 in givens — should appear for both collect AND final
	count := strings.Count(sql, "'step-4', 'result'")
	if count < 2 {
		t.Errorf("step-4→result should appear in both collect and final givens, got %d occurrences", count)
	}
}

package main

// cellsql.go — SQL generation from parsedCell structs.
//
// This is the bridge between Lua cell definitions (via LoadLuaProgram)
// and the Retort database schema. It generates INSERT statements for
// cells, givens, yields, oracles, and frames.
//
// Extracted from the old parse.go — only the SQL generation and type
// definitions survive. The parser itself is gone (replaced by Lua).

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"strings"
)

var validNameRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]*$`)

// parsedCell represents one cell extracted from a Lua program.
type parsedCell struct {
	name     string
	bodyType string // hard, soft, stem
	body     string
	givens   []parsedGiven
	yields   []parsedYield
	oracles  []parsedOracle
	iterate  int    // >0 means iteration expansion count
	guard    string // guard expression for guarded recursion
}

type parsedGiven struct {
	sourceCell  string
	sourceField string
	optional    bool
}

type parsedYield struct {
	fieldName string
	prebound  string // non-empty for hard literal yields
	autopour  bool   // [autopour] annotation
}

type parsedOracle struct {
	assertion  string
	oracleType string // deterministic or semantic
	condExpr   string // condition_expr or empty
}

func cellsToSQL(programID string, cells []parsedCell) string {
	var sb strings.Builder
	sb.WriteString("USE retort;\n")

	// Use full program name as cell ID prefix (no abbreviation — avoids collisions)
	prefix := programID

	// Build iteration template map: name → N (for reference resolution)
	iterTemplates := map[string]int{}
	for _, c := range cells {
		if c.iterate > 0 {
			iterTemplates[c.name] = c.iterate
		}
	}

	// Resolve iteration references in givens (non-template cells only).
	for i := range cells {
		if cells[i].iterate > 0 {
			continue // don't rewrite the template's own givens
		}
		var expanded []parsedGiven
		for _, g := range cells[i].givens {
			// Gather wildcard: "given refine-*→text" → all iteration steps
			if strings.HasSuffix(g.sourceCell, "-*") {
				base := strings.TrimSuffix(g.sourceCell, "-*")
				if n, ok := iterTemplates[base]; ok {
					for k := 1; k <= n; k++ {
						expanded = append(expanded, parsedGiven{
							sourceCell:  fmt.Sprintf("%s-%d", base, k),
							sourceField: g.sourceField,
							optional:    g.optional,
						})
					}
					continue
				}
			}
			// Template reference: "given refine→text" → last step
			if n, ok := iterTemplates[g.sourceCell]; ok {
				g.sourceCell = fmt.Sprintf("%s-%d", g.sourceCell, n)
			}
			expanded = append(expanded, g)
		}
		cells[i].givens = expanded
	}

	for _, c := range cells {
		if c.iterate > 0 {
			// Expand ⊢∘ iteration (judge cells generated per-iteration)
			expandIteration(&sb, programID, prefix, c)
			continue
		}
		writeCell(&sb, programID, prefix, c)
		writeJudgeCells(&sb, programID, prefix, c)
	}

	sb.WriteString(fmt.Sprintf("CALL DOLT_COMMIT('-Am', 'pour: %s');\n", programID))
	return sb.String()
}

func writeCell(sb *strings.Builder, programID, prefix string, c parsedCell) {
	cellID := safeID(prefix + "-" + c.name)

	// Determine body
	body := c.body
	if c.bodyType == "hard" && body == "" {
		// Hard cell with pre-bound yields
		if len(c.yields) == 1 && c.yields[0].prebound != "" {
			body = "literal:" + c.yields[0].prebound
		} else {
			body = "literal:_"
		}
	}

	// For multi-yield hard cells with all pre-bound, set state=frozen directly
	allPrebound := c.bodyType == "hard" && len(c.yields) > 0
	for _, y := range c.yields {
		if y.prebound == "" {
			allPrebound = false
		}
	}
	state := "declared"
	if allPrebound && len(c.yields) > 1 {
		state = "frozen"
	}

	sb.WriteString(fmt.Sprintf(
		"INSERT INTO cells (id, program_id, name, body_type, body, state) VALUES ('%s', '%s', '%s', '%s', '%s', '%s');\n",
		escape(cellID), escape(programID), escape(c.name), c.bodyType, escape(body), state))

	// Frame (v2): all cells get gen-0 frame at pour time
	frameID := "f-" + cellID + "-0"
	sb.WriteString(fmt.Sprintf(
		"INSERT IGNORE INTO frames (id, cell_name, program_id, generation) VALUES ('%s', '%s', '%s', 0);\n",
		escape(frameID), escape(c.name), escape(programID)))

	// Givens
	for _, g := range c.givens {
		gID := safeID(fmt.Sprintf("g-%s-%s-%s-%s", prefix, c.name, g.sourceCell, g.sourceField))
		opt := "FALSE"
		if g.optional {
			opt = "TRUE"
		}
		sb.WriteString(fmt.Sprintf(
			"INSERT INTO givens (id, cell_id, source_cell, source_field, is_optional) VALUES ('%s', '%s', '%s', '%s', %s);\n",
			escape(gID), escape(cellID), escape(g.sourceCell), escape(g.sourceField), opt))
	}

	// Yields — all cells get frame_id referencing gen-0 frame created above
	frameIDVal := fmt.Sprintf("'%s'", escape("f-"+cellID+"-0"))
	for _, y := range c.yields {
		yID := safeID(fmt.Sprintf("y-%s-%s-%s", prefix, c.name, y.fieldName))
		autopourVal := "FALSE"
		if y.autopour {
			autopourVal = "TRUE"
		}
		if allPrebound && len(c.yields) > 1 {
			// Pre-freeze each yield with its value
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, is_autopour, frozen_at) VALUES ('%s', '%s', %s, '%s', '%s', TRUE, %s, NOW());\n",
				escape(yID), escape(cellID), frameIDVal, escape(y.fieldName), escape(y.prebound), autopourVal))
		} else {
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, frame_id, field_name, is_autopour) VALUES ('%s', '%s', %s, '%s', %s);\n",
				escape(yID), escape(cellID), frameIDVal, escape(y.fieldName), autopourVal))
		}
	}

	// Oracles
	for i, o := range c.oracles {
		oID := safeID(fmt.Sprintf("o-%s-%s-%d", prefix, c.name, i+1))
		condExpr := "NULL"
		if o.condExpr != "" {
			condExpr = fmt.Sprintf("'%s'", escape(o.condExpr))
		}
		sb.WriteString(fmt.Sprintf(
			"INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('%s', '%s', '%s', '%s', %s);\n",
			escape(oID), escape(cellID), o.oracleType, escape(o.assertion), condExpr))
	}

	// Guard oracle (for iteration cells with recur until GUARD)
	if c.guard != "" {
		gID := safeID(fmt.Sprintf("o-%s-%s-guard", prefix, c.name))
		sb.WriteString(fmt.Sprintf(
			"INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('%s', '%s', 'deterministic', 'guard: %s', 'guard:%s');\n",
			escape(gID), escape(cellID), escape(c.guard), escape(c.guard)))
	}
}

func expandIteration(sb *strings.Builder, programID, prefix string, c parsedCell) {
	// Find the chaining field: a given whose source_field matches a yield field_name
	chainField := ""
	chainSource := ""
	for _, g := range c.givens {
		for _, y := range c.yields {
			if g.sourceField == y.fieldName {
				chainField = g.sourceField
				chainSource = g.sourceCell
				break
			}
		}
	}

	// Detect semantic oracles — their judges will feed back into subsequent iterations
	var semanticIndices []int
	for j, o := range c.oracles {
		if o.oracleType == "semantic" {
			semanticIndices = append(semanticIndices, j)
		}
	}

	for i := 1; i <= c.iterate; i++ {
		iter := parsedCell{
			name:     fmt.Sprintf("%s-%d", c.name, i),
			bodyType: c.bodyType,
			body:     c.body,
			yields:   c.yields,
			oracles:  append([]parsedOracle{}, c.oracles...), // copy
			guard:    c.guard,
		}

		// Copy givens, replacing the chaining source
		for _, g := range c.givens {
			ng := g
			if g.sourceField == chainField {
				if i == 1 {
					ng.sourceCell = chainSource // first iteration: original source
				} else {
					ng.sourceCell = fmt.Sprintf("%s-%d", c.name, i-1)
				}
			}
			iter.givens = append(iter.givens, ng)
		}

		// For i > 1: wire previous iteration's judge verdicts as optional givens
		if i > 1 && len(semanticIndices) > 0 {
			for _, j := range semanticIndices {
				prevJudge := fmt.Sprintf("%s-%d-judge-%d", c.name, i-1, j+1)
				iter.givens = append(iter.givens, parsedGiven{
					sourceCell:  prevJudge,
					sourceField: "verdict",
					optional:    true,
				})
			}
			iter.body += " If «verdict» feedback is available from a previous judge, address it."
		}

		writeCell(sb, programID, prefix, iter)
		writeJudgeCells(sb, programID, prefix, iter)
	}
}

// writeJudgeCells generates stem cell judges for each semantic oracle on a cell.
// Each judge takes the original cell's yields as input and produces a verdict.
func writeJudgeCells(sb *strings.Builder, programID, prefix string, c parsedCell) {
	for i, o := range c.oracles {
		if o.oracleType != "semantic" {
			continue
		}

		judgeName := fmt.Sprintf("%s-judge-%d", c.name, i+1)
		// Build guillemet references for all yields
		var refs []string
		for _, y := range c.yields {
			refs = append(refs, "«"+y.fieldName+"»")
		}
		refStr := strings.Join(refs, ", ")
		if refStr == "" {
			refStr = "«output»"
		}

		judgeBody := fmt.Sprintf(
			"Judge whether %s satisfies: \"%s\". Answer YES or NO on the first line, followed by a brief explanation.",
			refStr, o.assertion)

		// Judge takes all yields from the original cell as input
		var givens []parsedGiven
		for _, y := range c.yields {
			givens = append(givens, parsedGiven{
				sourceCell:  c.name,
				sourceField: y.fieldName,
			})
		}

		judge := parsedCell{
			name:     judgeName,
			bodyType: "stem",
			body:     judgeBody,
			givens:   givens,
			yields:   []parsedYield{{fieldName: "verdict"}},
			oracles:  []parsedOracle{{assertion: "verdict is not empty", oracleType: "deterministic", condExpr: "not_empty"}},
		}
		writeCell(sb, programID, prefix, judge)
	}
}

// safeID truncates IDs that exceed VARCHAR(64) by hashing the overflow.
func safeID(id string) string {
	if len(id) <= 64 {
		return id
	}
	// Keep a readable prefix + hash suffix
	h := fmt.Sprintf("%x", sha256.Sum256([]byte(id)))
	prefix := id[:48]
	return prefix + "-" + h[:15]
}

func escape(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

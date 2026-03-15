package main

// Phase B: deterministic parser for core .cell turnstyle syntax.
// Falls back to stem cell parser (Phase A) for anything it can't handle.
//
// Handles: ⊢, given, given?, yield, yield ≡, ∴, ∴∴, ⊢=, ⊨, ⊢∘
// Does NOT handle: multi-line bodies (∴ spanning lines), guard clauses,
// spawners (⊢⊢), or any syntax not in the v0.1 spec.

import (
	"fmt"
	"strconv"
	"strings"
)

// parsedCell represents one cell extracted from .cell syntax.
type parsedCell struct {
	name     string
	bodyType string // hard, soft, stem
	body     string
	givens   []parsedGiven
	yields   []parsedYield
	oracles  []parsedOracle
	iterate  int // >0 means ⊢∘ expansion count
}

type parsedGiven struct {
	sourceCell  string
	sourceField string
	optional    bool
}

type parsedYield struct {
	fieldName string
	prebound  string // non-empty for yield NAME ≡ VALUE
}

type parsedOracle struct {
	assertion string
	oracleType string // deterministic or semantic
	condExpr   string // condition_expr or empty
}

// parseCell parses .cell turnstyle syntax into structured cells.
// Returns nil if the syntax can't be handled deterministically.
func parseCellFile(text string) []parsedCell {
	lines := strings.Split(text, "\n")
	var cells []parsedCell
	var cur *parsedCell

	for _, raw := range lines {
		line := strings.TrimRight(raw, " \t\r")
		trimmed := strings.TrimSpace(line)

		if trimmed == "" {
			continue
		}

		// Cell declaration: ⊢ NAME or ⊢∘ NAME × N
		if strings.HasPrefix(trimmed, "⊢∘ ") {
			if cur != nil {
				cells = append(cells, *cur)
			}
			cur = &parsedCell{bodyType: "soft"}
			rest := strings.TrimPrefix(trimmed, "⊢∘ ")
			// Parse: NAME × N or NAME x N
			parts := strings.Split(rest, "×")
			if len(parts) == 1 {
				parts = strings.Split(rest, "x")
			}
			if len(parts) != 2 {
				return nil // can't parse iteration
			}
			cur.name = strings.TrimSpace(parts[0])
			n, err := strconv.Atoi(strings.TrimSpace(parts[1]))
			if err != nil {
				return nil
			}
			cur.iterate = n
			continue
		}

		if strings.HasPrefix(trimmed, "⊢ ") {
			if cur != nil {
				cells = append(cells, *cur)
			}
			cur = &parsedCell{bodyType: "soft"}
			cur.name = strings.TrimPrefix(trimmed, "⊢ ")
			continue
		}

		if cur == nil {
			continue // skip lines before first cell
		}

		// Given: given X→Y or given? X→Y
		if strings.HasPrefix(trimmed, "given? ") || strings.HasPrefix(trimmed, "given ") {
			optional := strings.HasPrefix(trimmed, "given? ")
			rest := trimmed
			if optional {
				rest = strings.TrimPrefix(trimmed, "given? ")
			} else {
				rest = strings.TrimPrefix(trimmed, "given ")
			}
			// Parse X→Y
			parts := strings.SplitN(rest, "→", 2)
			if len(parts) != 2 {
				return nil
			}
			cur.givens = append(cur.givens, parsedGiven{
				sourceCell:  strings.TrimSpace(parts[0]),
				sourceField: strings.TrimSpace(parts[1]),
				optional:    optional,
			})
			continue
		}

		// Yield: yield NAME ≡ VALUE or yield NAME
		if strings.HasPrefix(trimmed, "yield ") {
			rest := strings.TrimPrefix(trimmed, "yield ")
			if strings.Contains(rest, "≡") {
				parts := strings.SplitN(rest, "≡", 2)
				cur.yields = append(cur.yields, parsedYield{
					fieldName: strings.TrimSpace(parts[0]),
					prebound:  strings.TrimSpace(parts[1]),
				})
				cur.bodyType = "hard"
			} else {
				cur.yields = append(cur.yields, parsedYield{
					fieldName: strings.TrimSpace(rest),
				})
			}
			continue
		}

		// Stem cell body: ∴∴ TEXT
		if strings.HasPrefix(trimmed, "∴∴ ") {
			cur.body = strings.TrimPrefix(trimmed, "∴∴ ")
			cur.bodyType = "stem"
			continue
		}

		// Soft cell body: ∴ TEXT
		if strings.HasPrefix(trimmed, "∴ ") {
			cur.body = strings.TrimPrefix(trimmed, "∴ ")
			cur.bodyType = "soft"
			continue
		}

		// Hard cell body: ⊢= TEXT
		if strings.HasPrefix(trimmed, "⊢= ") {
			cur.body = strings.TrimPrefix(trimmed, "⊢= ")
			cur.bodyType = "hard"
			continue
		}

		// Oracle: ⊨ TEXT
		if strings.HasPrefix(trimmed, "⊨ ") {
			assertion := strings.TrimPrefix(trimmed, "⊨ ")
			o := parsedOracle{assertion: assertion, oracleType: "semantic"}
			// Classify deterministic oracles
			lower := strings.ToLower(assertion)
			if strings.Contains(lower, "not empty") || strings.Contains(lower, "is not empty") {
				o.oracleType = "deterministic"
				o.condExpr = "not_empty"
			} else if strings.Contains(lower, "valid json array") || strings.Contains(lower, "is a valid json array") {
				o.oracleType = "deterministic"
				o.condExpr = "is_json_array"
			} else if strings.Contains(lower, "permutation of") {
				// Extract source cell from "X is a permutation of Y"
				// The source cell is the word after "of"
				idx := strings.Index(lower, "permutation of ")
				if idx >= 0 {
					rest := assertion[idx+len("permutation of "):]
					srcCell := strings.Fields(rest)[0]
					o.oracleType = "deterministic"
					o.condExpr = "length_matches:" + srcCell
				}
			}
			cur.oracles = append(cur.oracles, o)
			continue
		}
	}
	if cur != nil {
		cells = append(cells, *cur)
	}

	return cells
}

// cellsToSQL converts parsed cells to SQL INSERT statements.
func cellsToSQL(programID string, cells []parsedCell) string {
	var sb strings.Builder
	sb.WriteString("USE retort;\n")

	// Abbreviate program ID for cell ID prefix
	prefix := programID
	if len(prefix) > 4 {
		// Use initials: sort-proof → sp, game-of-life → gol, cell-zero → cz
		parts := strings.Split(prefix, "-")
		abbr := ""
		for _, p := range parts {
			if len(p) > 0 {
				abbr += string(p[0])
			}
		}
		if len(abbr) >= 2 {
			prefix = abbr
		}
	}

	for _, c := range cells {
		if c.iterate > 0 {
			// Expand ⊢∘ iteration
			expandIteration(&sb, programID, prefix, c)
			continue
		}
		writeCell(&sb, programID, prefix, c)
	}

	sb.WriteString(fmt.Sprintf("CALL DOLT_COMMIT('-Am', 'pour: %s');\n", programID))
	return sb.String()
}

func writeCell(sb *strings.Builder, programID, prefix string, c parsedCell) {
	cellID := prefix + "-" + c.name

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

	// Givens
	for _, g := range c.givens {
		gID := fmt.Sprintf("g-%s-%s", c.name, g.sourceField)
		opt := "FALSE"
		if g.optional {
			opt = "TRUE"
		}
		sb.WriteString(fmt.Sprintf(
			"INSERT INTO givens (id, cell_id, source_cell, source_field, is_optional) VALUES ('%s', '%s', '%s', '%s', %s);\n",
			escape(gID), escape(cellID), escape(g.sourceCell), escape(g.sourceField), opt))
	}

	// Yields
	for _, y := range c.yields {
		yID := fmt.Sprintf("y-%s-%s", c.name, y.fieldName)
		if allPrebound && len(c.yields) > 1 {
			// Pre-freeze each yield with its value
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, field_name, value_text, is_frozen, frozen_at) VALUES ('%s', '%s', '%s', '%s', TRUE, NOW());\n",
				escape(yID), escape(cellID), escape(y.fieldName), escape(y.prebound)))
		} else {
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, field_name) VALUES ('%s', '%s', '%s');\n",
				escape(yID), escape(cellID), escape(y.fieldName)))
		}
	}

	// Oracles
	for i, o := range c.oracles {
		oID := fmt.Sprintf("o-%s-%d", c.name, i+1)
		condExpr := "NULL"
		if o.condExpr != "" {
			condExpr = fmt.Sprintf("'%s'", escape(o.condExpr))
		}
		sb.WriteString(fmt.Sprintf(
			"INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr) VALUES ('%s', '%s', '%s', '%s', %s);\n",
			escape(oID), escape(cellID), o.oracleType, escape(o.assertion), condExpr))
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

	for i := 1; i <= c.iterate; i++ {
		iter := parsedCell{
			name:     fmt.Sprintf("%s-%d", c.name, i),
			bodyType: c.bodyType,
			body:     c.body,
			yields:   c.yields,
			oracles:  c.oracles,
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

		writeCell(sb, programID, prefix, iter)
	}
}

func escape(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

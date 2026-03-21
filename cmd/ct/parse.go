package main

// Phase B: deterministic parser for core .cell turnstyle syntax.
// Falls back to stem cell parser (Phase A) for anything it can't handle.
//
// Handles: ⊢, given, given?, yield, yield ≡, ∴, ∴∴, ⊢=, ⊨, ⊨~, ⊢∘
// Does NOT handle: guard clauses, spawners (⊢⊢), or any syntax not in
// the v0.1 spec.
//
// Semantic oracles (⊨~ or auto-classified) generate judge stem cells:
// a separate cell that takes the original output and yields a verdict.

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var validNameRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]*$`)

// parsedCell represents one cell extracted from .cell syntax.
type parsedCell struct {
	name     string
	bodyType string // hard, soft, stem
	body     string
	givens   []parsedGiven
	yields   []parsedYield
	oracles  []parsedOracle
	iterate  int    // >0 means iteration expansion count
	guard    string // guard expression for guarded recursion (e.g., `settled = "SETTLED"`)
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

// parseCellFile parses .cell syntax. Tries v2 (ASCII) first, falls back to v1 (Unicode).
// Returns an error if any cell or field name is invalid.
func parseCellFile(text string) ([]parsedCell, error) {
	var cells []parsedCell
	if cells = parseCellFileV2(text); cells == nil {
		cells = parseCellFileV1(text)
	}
	if cells == nil {
		return nil, nil
	}
	if err := validateCellNames(cells); err != nil {
		return nil, err
	}
	return cells, nil
}

// validateCellNames checks that all cell names and field names match [a-zA-Z][a-zA-Z0-9_-]*.
func validateCellNames(cells []parsedCell) error {
	for _, c := range cells {
		if !validNameRe.MatchString(c.name) {
			return fmt.Errorf("invalid cell name %q: must match [a-zA-Z][a-zA-Z0-9_-]*", c.name)
		}
		for _, y := range c.yields {
			if !validNameRe.MatchString(y.fieldName) {
				return fmt.Errorf("invalid field name %q in cell %q: must match [a-zA-Z][a-zA-Z0-9_-]*", y.fieldName, c.name)
			}
		}
		for _, g := range c.givens {
			if !validNameRe.MatchString(g.sourceField) {
				return fmt.Errorf("invalid field name %q in given of cell %q: must match [a-zA-Z][a-zA-Z0-9_-]*", g.sourceField, c.name)
			}
		}
	}
	return nil
}

// parseCellFileV2 parses v2 ASCII syntax: cell NAME, ---, given X.Y, check, recur, iterate.
func parseCellFileV2(text string) []parsedCell {
	lines := strings.Split(text, "\n")

	// Quick detect: v2 files have "cell " or "iterate " at column 0, not "⊢ "
	hasV2 := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if (strings.HasPrefix(trimmed, "cell ") || strings.HasPrefix(trimmed, "iterate ")) && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
			hasV2 = true
			break
		}
	}
	if !hasV2 {
		return nil
	}

	var cells []parsedCell
	var cur *parsedCell
	inBody := false

	for _, raw := range lines {
		line := strings.TrimRight(raw, " \t\r")
		trimmed := strings.TrimSpace(line)
		isIndented := len(line) > 0 && (line[0] == ' ' || line[0] == '\t')

		// Blank line
		if trimmed == "" {
			if inBody && cur != nil {
				cur.body += "\n"
			}
			continue
		}

		// Inside body fence — check BEFORE comment/cell-decl to avoid mismatches.
		// Body content can appear at column 0 (e.g. prose inside --- fences),
		// so cell/iterate declarations CANNOT be moved before this check.
		if inBody && cur != nil {
			if isIndented && trimmed == "---" {
				// Closing fence
				inBody = false
				// Infer hard type from sql: body
				body := strings.TrimRight(cur.body, " \t\n\r")
				cur.body = body
				if cur.bodyType != "stem" && (strings.HasPrefix(body, "sql:") || strings.HasPrefix(body, "dml:")) {
					cur.bodyType = "hard"
				}
				continue
			}
			// Body content
			if cur.body == "" {
				cur.body = trimmed
			} else {
				cur.body += "\n" + trimmed
			}
			continue
		}

		// Comment (but not --- fence)
		if strings.HasPrefix(trimmed, "--") && trimmed != "---" {
			continue
		}

		// Cell declaration at column 0: cell NAME or cell NAME (stem)
		if strings.HasPrefix(trimmed, "cell ") && !isIndented {
			if cur != nil {
				cur.body = strings.TrimRight(cur.body, " \t\n\r")
				cells = append(cells, *cur)
			}
			cur = &parsedCell{bodyType: "soft"}
			rest := strings.TrimPrefix(trimmed, "cell ")
			if strings.HasSuffix(rest, "(stem)") {
				cur.name = strings.TrimSpace(strings.TrimSuffix(rest, "(stem)"))
				cur.bodyType = "stem"
			} else {
				cur.name = strings.TrimSpace(rest)
			}
			continue
		}

		// Iteration declaration at column 0: iterate NAME N
		if strings.HasPrefix(trimmed, "iterate ") && !isIndented {
			if cur != nil {
				cur.body = strings.TrimRight(cur.body, " \t\n\r")
				cells = append(cells, *cur)
			}
			cur = &parsedCell{bodyType: "soft"}
			rest := strings.TrimPrefix(trimmed, "iterate ")
			parts := strings.Fields(rest)
			if len(parts) != 2 {
				return nil
			}
			cur.name = parts[0]
			n, err := strconv.Atoi(parts[1])
			if err != nil {
				return nil
			}
			cur.iterate = n
			continue
		}

		if cur == nil {
			continue
		}

		// Indented structural keywords
		if isIndented {
			// Body fence opening: ---
			if trimmed == "---" {
				inBody = true
				cur.body = ""
				continue
			}

			// Given: given X.Y, given? X.Y, given X[*].Y
			if strings.HasPrefix(trimmed, "given? ") || strings.HasPrefix(trimmed, "given ") {
				optional := strings.HasPrefix(trimmed, "given? ")
				rest := trimmed
				if optional {
					rest = strings.TrimPrefix(trimmed, "given? ")
				} else {
					rest = strings.TrimPrefix(trimmed, "given ")
				}

				// Parse dot notation: X.Y, X[*].Y, X[N].Y
				dotIdx := strings.LastIndex(rest, ".")
				if dotIdx < 0 {
					return nil
				}
				source := strings.TrimSpace(rest[:dotIdx])
				field := strings.TrimSpace(rest[dotIdx+1:])

				// Handle bracket notation
				if bracketIdx := strings.Index(source, "["); bracketIdx >= 0 {
					baseName := source[:bracketIdx]
					closeBracket := strings.Index(source, "]")
					if closeBracket < 0 {
						return nil
					}
					idx := source[bracketIdx+1 : closeBracket]
					if idx == "*" {
						source = baseName + "-*"
					} else {
						source = baseName + "-" + idx
					}
				}

				cur.givens = append(cur.givens, parsedGiven{
					sourceCell:  source,
					sourceField: field,
					optional:    optional,
				})
				continue
			}

			// Yield: yield NAME = VALUE or yield NAME
			if strings.HasPrefix(trimmed, "yield ") {
				rest := strings.TrimPrefix(trimmed, "yield ")
				if eqIdx := strings.Index(rest, " = "); eqIdx >= 0 {
					name := strings.TrimSpace(rest[:eqIdx])
					value := strings.TrimSpace(rest[eqIdx+3:])
					// Strip surrounding quotes if present
					if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
						value = value[1 : len(value)-1]
					}
					cur.yields = append(cur.yields, parsedYield{
						fieldName: name,
						prebound:  value,
					})
					if cur.bodyType != "stem" {
						cur.bodyType = "hard"
					}
				} else {
					// strip : TYPE suffix if present
					fname := strings.TrimSpace(rest)
					if colonIdx := strings.Index(fname, " : "); colonIdx >= 0 {
						fname = strings.TrimSpace(fname[:colonIdx])
					}
					// strip [annotation] suffix if present (e.g., "evaluated [autopour]")
					if bracketIdx := strings.Index(fname, " ["); bracketIdx >= 0 {
						fname = strings.TrimSpace(fname[:bracketIdx])
					}
					cur.yields = append(cur.yields, parsedYield{
						fieldName: fname,
					})
				}
				continue
			}

			// Recur: recur until GUARD (max N) or recur (max N)
			if strings.HasPrefix(trimmed, "recur ") {
				rest := strings.TrimPrefix(trimmed, "recur ")
				// Find (max N)
				maxIdx := strings.Index(rest, "(max ")
				if maxIdx < 0 {
					return nil
				}
				closeIdx := strings.Index(rest[maxIdx:], ")")
				if closeIdx < 0 {
					return nil
				}
				nStr := strings.TrimSpace(rest[maxIdx+5 : maxIdx+closeIdx])
				n, err := strconv.Atoi(nStr)
				if err != nil {
					return nil
				}
				cur.iterate = n

				// Parse guard if present
				if strings.HasPrefix(rest, "until ") {
					guardStr := strings.TrimSpace(rest[6:maxIdx])
					cur.guard = guardStr
				}
				continue
			}

			// Oracle: check~ TEXT (always semantic)
			if strings.HasPrefix(trimmed, "check~ ") {
				assertion := strings.TrimPrefix(trimmed, "check~ ")
				cur.oracles = append(cur.oracles, parsedOracle{
					assertion:  assertion,
					oracleType: "semantic",
				})
				continue
			}

			// Oracle: check TEXT (auto-classified)
			if strings.HasPrefix(trimmed, "check ") {
				assertion := strings.TrimPrefix(trimmed, "check ")
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
					idx := strings.Index(lower, "permutation of ")
					if idx >= 0 {
						rest := assertion[idx+len("permutation of "):]
						refField := strings.Fields(rest)[0]
						srcCellName := refField
						for _, g := range cur.givens {
							if g.sourceField == refField {
								srcCellName = g.sourceCell
								break
							}
						}
						o.oracleType = "deterministic"
						o.condExpr = "length_matches:" + srcCellName
					}
				}
				cur.oracles = append(cur.oracles, o)
				continue
			}
		}

	}

	if cur != nil {
		cur.body = strings.TrimRight(cur.body, " \t\n\r")
		cells = append(cells, *cur)
	}

	// Trim all bodies
	for i := range cells {
		cells[i].body = strings.TrimRight(cells[i].body, " \t\n\r")
	}

	return cells
}

// parseCellFileV1 parses v1 Unicode turnstyle syntax (⊢, ∴, ⊨, →).
// Returns nil if the syntax can't be handled deterministically.
func parseCellFileV1(text string) []parsedCell {
	lines := strings.Split(text, "\n")
	var cells []parsedCell
	var cur *parsedCell
	inBody := false // true while accumulating multi-line body text

	for _, raw := range lines {
		line := strings.TrimRight(raw, " \t\r")
		trimmed := strings.TrimSpace(line)
		isIndented := len(line) > 0 && (line[0] == ' ' || line[0] == '\t')

		// Blank line: preserve in multi-line body, skip otherwise
		if trimmed == "" {
			if inBody && cur != nil {
				cur.body += "\n"
			}
			continue
		}

		// Comment lines (-- ...) — skip
		if strings.HasPrefix(trimmed, "--") {
			continue
		}

		// Cell declaration: ⊢ NAME or ⊢∘ NAME × N
		// Always breaks body continuation.
		if strings.HasPrefix(trimmed, "⊢∘ ") {
			inBody = false
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
			inBody = false
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

		// Structural keywords: only recognized when indented (under ⊢ declaration).
		// Unindented "given" or "yield" in body text won't be misinterpreted.
		if isIndented {
			// Given: given X→Y or given? X→Y
			if strings.HasPrefix(trimmed, "given? ") || strings.HasPrefix(trimmed, "given ") {
				inBody = false
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
				inBody = false
				rest := strings.TrimPrefix(trimmed, "yield ")
				if strings.Contains(rest, "≡") {
					parts := strings.SplitN(rest, "≡", 2)
					cur.yields = append(cur.yields, parsedYield{
						fieldName: strings.TrimSpace(parts[0]),
						prebound:  strings.TrimSpace(parts[1]),
					})
					cur.bodyType = "hard"
				} else {
					fname := strings.TrimSpace(rest)
					// strip [annotation] suffix if present
					if bracketIdx := strings.Index(fname, " ["); bracketIdx >= 0 {
						fname = strings.TrimSpace(fname[:bracketIdx])
					}
					cur.yields = append(cur.yields, parsedYield{
						fieldName: fname,
					})
				}
				continue
			}
		}

		// Stem cell body: ∴∴ TEXT
		if strings.HasPrefix(trimmed, "∴∴ ") {
			cur.body = strings.TrimPrefix(trimmed, "∴∴ ")
			cur.bodyType = "stem"
			inBody = true
			continue
		}

		// Soft cell body: ∴ TEXT
		if strings.HasPrefix(trimmed, "∴ ") {
			cur.body = strings.TrimPrefix(trimmed, "∴ ")
			cur.bodyType = "soft"
			inBody = true
			continue
		}

		// Hard cell body: ⊢= TEXT
		if strings.HasPrefix(trimmed, "⊢= ") {
			cur.body = strings.TrimPrefix(trimmed, "⊢= ")
			cur.bodyType = "hard"
			inBody = true
			continue
		}

		// Explicit semantic oracle: ⊨~ TEXT (always semantic, never auto-classified)
		if strings.HasPrefix(trimmed, "⊨~ ") {
			inBody = false
			assertion := strings.TrimPrefix(trimmed, "⊨~ ")
			cur.oracles = append(cur.oracles, parsedOracle{
				assertion:  assertion,
				oracleType: "semantic",
			})
			continue
		}

		// Oracle: ⊨ TEXT
		if strings.HasPrefix(trimmed, "⊨ ") {
			inBody = false
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
				// Extract the referenced field name, then find the source cell
				// "sorted is a permutation of items" → field "items" → given data→items → cell "data"
				idx := strings.Index(lower, "permutation of ")
				if idx >= 0 {
					rest := assertion[idx+len("permutation of "):]
					refField := strings.Fields(rest)[0]
					// Look up which given provides this field
					srcCellName := refField // fallback to field name
					for _, g := range cur.givens {
						if g.sourceField == refField {
							srcCellName = g.sourceCell
							break
						}
					}
					o.oracleType = "deterministic"
					o.condExpr = "length_matches:" + srcCellName
				}
			}
			cur.oracles = append(cur.oracles, o)
			continue
		}

		// Body continuation: any unmatched line when in body mode
		if inBody && cur != nil {
			cur.body += "\n" + trimmed
			continue
		}
	}
	if cur != nil {
		cur.body = strings.TrimRight(cur.body, " \t\n\r")
		cells = append(cells, *cur)
	}

	// Trim trailing whitespace from all bodies
	for i := range cells {
		cells[i].body = strings.TrimRight(cells[i].body, " \t\n\r")
	}

	return cells
}

// cellsToSQL converts parsed cells to SQL INSERT statements.
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
		if allPrebound && len(c.yields) > 1 {
			// Pre-freeze each yield with its value
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, frame_id, field_name, value_text, is_frozen, frozen_at) VALUES ('%s', '%s', %s, '%s', '%s', TRUE, NOW());\n",
				escape(yID), escape(cellID), frameIDVal, escape(y.fieldName), escape(y.prebound)))
		} else {
			sb.WriteString(fmt.Sprintf(
				"INSERT INTO yields (id, cell_id, frame_id, field_name) VALUES ('%s', '%s', %s, '%s');\n",
				escape(yID), escape(cellID), frameIDVal, escape(y.fieldName)))
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

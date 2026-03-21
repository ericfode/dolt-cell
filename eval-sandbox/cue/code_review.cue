// code_review.cue — Code review pipeline in CUE
//
// Translates code-review-reference.cell into CUE's constraint model.
//
// Pipeline:
//   source (pure literal: the code to review)
//     → analyze (soft: LLM finds bugs/issues, formats as bullets)
//       → count-findings (pure compute: count "- " occurrences)
//         → prioritize (soft: LLM ranks by severity, writes exec summary)
//
// CUE strengths on display:
//   1. References enforce the DAG — prioritize CANNOT be defined before
//      analyze because it references analyze.compute values directly.
//   2. Constraints (#Cell definition) validate structural correctness.
//   3. Pure compute replaces the sql: body using strings.Count.
//
// CUE limitations on display:
//   1. No user-defined functions — count_findings logic is inline,
//      not reusable across programs.
//   2. No loops/recursion — the "fold over findings" is purely structural.
//   3. No runtime execution — soft cells have rendered prompt text but
//      the LLM output is NOT in this file (that requires a runtime).

import "strings"

// ── Schema ─────────────────────────────────────────────────────────────────

#Effect: "pure" | "replayable" | "non-replayable"

#Cell: {
	name:     string
	effect:   #Effect
	body?:    string
	literal?: {[string]: _}
	compute?: {[string]: _}
	check?:   [...string]
}

// ── Cell 1: source — hard literal ──────────────────────────────────────────
//
// The code under review. Pure value — no computation, no LLM.
// Changing this value is the only thing needed to review different code.

source: #Cell & {
	name:   "source"
	effect: "pure"
	literal: {
		code: "def is_prime(n): return all(n % i != 0 for i in range(2, n))"
	}
}

// ── Cell 2: analyze — soft (replayable) ────────────────────────────────────
//
// LLM reviews the code. The prompt is rendered with the source literal
// via CUE string interpolation. This is the rendered prompt, not the output.
//
// Note: In the reference .cell file, «code» uses guillemet syntax.
// In CUE, \(source.literal.code) is the equivalent — but it only works
// because source is a hard literal with a concrete CUE value.
// If source were a soft cell (LLM output), we'd need a placeholder.

analyze: #Cell & {
	name:   "analyze"
	effect: "replayable"
	body: """
		Review this Python function for correctness, performance, and style:

		\(source.literal.code)

		Identify all bugs, edge cases, and potential improvements. Format each finding as a bullet point starting with "- ".
		"""
	check: ["findings contains at least 3 bullet points"]
}

// ── Cell 3: count-findings — pure compute ──────────────────────────────────
//
// Replaces sql: in the reference. Counts bullet points in the findings.
//
// In the reference, this runs SQL:
//   SELECT (LENGTH(f.value_text) - LENGTH(REPLACE(f.value_text, '- ', ''))) / 2
//
// In CUE, we use strings.Count on a demo output to show the computation works.
// A real runtime would substitute the actual LLM output here.
//
// The _demo_findings constant shows what analyze would return — this makes
// count-findings a fully evaluable pure-compute cell at spec time.

_demo_findings: """
	- Bug: range(2, n) excludes n, so is_prime(n) returns True for n=1 (range is empty, all() vacuously true)
	- Bug: is_prime(0) and is_prime(1) return True (vacuously true)
	- Bug: is_prime(2) returns True but for wrong reason — range(2,2) is empty
	- Performance: O(n) — should check only up to sqrt(n)
	- Style: no docstring or type hints
	"""

_findings_lines: strings.Split(strings.TrimSpace(_demo_findings), "\n")
_bullet_lines: [for l in _findings_lines if strings.HasPrefix(strings.TrimSpace(l), "- ") {l}]
_bullet_count: len(_bullet_lines)

count_findings: #Cell & {
	name:   "count-findings"
	effect: "pure"
	// Given: analyze.findings (demonstrated with _demo_findings above)
	compute: {
		total:           _bullet_count
		demo_input_used: true // flag: real runtime replaces _demo_findings
	}
}

// ── Cell 4: prioritize — soft (replayable) ─────────────────────────────────
//
// Takes both analyze.findings and count-findings.total as givens.
// CUE interpolation renders both into the prompt body.
//
// This cell has TWO dependencies, both visible in the body template.
// The DAG is structurally enforced: this cell MUST come after the others.

prioritize: #Cell & {
	name:   "prioritize"
	effect: "replayable"
	body: """
		Given \(count_findings.compute.total) findings from the code review:

		\(_demo_findings)

		Prioritize these findings by severity (critical first, minor last). For each, classify as BUG, PERFORMANCE, or STYLE. Write a one-paragraph executive summary suitable for a pull request comment.
		"""
	check: ["summary is not empty"]
}

// ── Program manifest ────────────────────────────────────────────────────────
//
// CUE's reference graph naturally encodes the DAG.
// The cells list is ordered by dependency (topological sort).

code_review_program: {
	name: "code-review"
	cells: [source, analyze, count_findings, prioritize]
	dag: {
		source:           []
		analyze:          ["source.code"]
		"count-findings": ["analyze.findings"]
		prioritize:       ["analyze.findings", "count-findings.total"]
	}
	// Effect lattice verification: all cells satisfy Pure <= Replayable
	// No NonReplayable cells in this program (read-only analysis)
	max_effect: "replayable"
}

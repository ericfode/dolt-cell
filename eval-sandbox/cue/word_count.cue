// word_count.cue — Pure compute cell: count words in a string
//
// This file demonstrates pure computation in CUE as a replacement for
// the sql: bodies in the original .cell syntax.
//
// In the reference .cell files, "count" cells use sql: with SQL string
// functions (LENGTH, REPLACE, TRIM). CUE's stdlib is a better fit:
// it's deterministic, typesafe, and doesn't require a database.
//
// Demonstrated computations:
//   1. Basic word count (split on spaces)
//   2. Line count (split on newlines)
//   3. Character count (len on string directly)
//   4. Bullet-point count (filter lines by prefix)
//   5. Word frequency (not expressible in CUE — shown as limitation)
//
// CUE strength: all of these are evaluated at constraint-check time.
// The output is not a promise — it's a proven value.
//
// CUE limitation: no user-defined functions. Each computation is
// written inline. If you need word_count in three cells, you write
// the same three lines three times. There is no def/fn abstraction.

import "strings"

// ── Schema ─────────────────────────────────────────────────────────────────

#WordCountResult: {
	words:      int & >=0
	lines:      int & >=1
	chars:      int & >=0
	paragraphs: int & >=1
}

// ── Input: the text to analyze ─────────────────────────────────────────────
//
// In the cell language this would be a hard literal cell.
// In a real program, this value flows in via givens from another cell.

_input_text: """
	autumn rain falls soft
	a frog leaps through silver drops
	temple bell echoes
	"""

// ── Computation 1: basic word count ───────────────────────────────────────
//
// Split on whitespace (newlines and spaces), filter empty strings.
// CUE's strings.Fields does exactly this (splits on any whitespace).

_fields: strings.Fields(_input_text)
_word_count: len(_fields)

// ── Computation 2: line count ──────────────────────────────────────────────

_lines: strings.Split(strings.TrimSpace(_input_text), "\n")
_line_count: len(_lines)

// ── Computation 3: character count (excluding newlines) ───────────────────

_no_newlines: strings.Replace(_input_text, "\n", "", -1)
_no_tabs: strings.Replace(_no_newlines, "\t", "", -1)
_char_count: len(_no_tabs)

// ── Computation 4: paragraph count ────────────────────────────────────────
// (paragraphs separated by blank lines)

_paragraphs: strings.Split(strings.TrimSpace(_input_text), "\n\n")
_para_count: len(_paragraphs)

// ── Cell definition ────────────────────────────────────────────────────────
//
// This is what the word_count cell looks like as a CUE struct.
// The compute field holds the evaluated results.

#Cell: {
	name:    string
	effect:  "pure" | "replayable" | "non-replayable"
	compute: _
	check?:  [...string]
}

word_count: #Cell & {
	name:   "word-count"
	effect: "pure"
	compute: #WordCountResult & {
		words:      _word_count
		lines:      _line_count
		chars:      _char_count
		paragraphs: _para_count
	}
	check: [
		"words >= 0",
		"lines >= 1",
	]
}

// ── Replicated for multiple inputs ─────────────────────────────────────────
//
// Demonstrating the LIMITATION: no user-defined functions.
// To count words in a different string, we must repeat the computation.
// There is no def word_count(s) { ... } in CUE.
//
// Workaround: define a #WordCounter schema that parameterizes on input.
// This is CUE's idiom: schemas + & (unification) instead of functions.

#WordCounter: {
	input: string
	// Private computed fields
	_ws:   strings.Fields(input)
	_ls:   strings.Split(strings.TrimSpace(input), "\n")
	result: {
		words: len(_ws)
		lines: len(_ls)
		chars: len(strings.Replace(strings.Replace(input, "\n", "", -1), "\t", "", -1))
	}
}

// Apply the schema to different inputs — the "function call" is unification
haiku_counts: #WordCounter & {
	input: "autumn rain falls soft\na frog leaps through silver drops\ntemple bell echoes"
}

code_counts: #WordCounter & {
	input: "def is_prime(n): return all(n % i != 0 for i in range(2, n))"
}

// ── Summary ────────────────────────────────────────────────────────────────
//
// Both are fully evaluated at CUE eval time — no runtime needed.

summary: {
	haiku: haiku_counts.result
	code:  code_counts.result
	note:  "All values computed by CUE constraint evaluation, not a runtime"
}

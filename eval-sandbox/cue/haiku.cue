// haiku.cue — Haiku generation in CUE
//
// Translates haiku-reference.cell into CUE's constraint/config model.
//
// Cell dependency chain:
//   topic (pure literal)
//     → compose (soft/replayable — LLM writes the poem)
//       → count-words (pure compute — string ops)
//         → critique (soft/replayable — LLM evaluates)
//
// CUE strength here: struct references ARE the dependency graph.
// The given values are resolved by CUE's reference model —
// topic.yields.subject flows into compose.body via string interpolation.
// No runtime needed to wire dependencies: CUE evaluates the DAG.

import "strings"

// ── Schema ────────────────────────────────────────────────────────────────

// Effect lattice: Pure < Replayable < NonReplayable
#Effect: "pure" | "replayable" | "non-replayable"

// A yield field is either a hard literal or an unresolved slot (for LLM).
// "unresolved" means the runtime/piston fills this in at evaluation time.
#YieldField: {
	value:    _
	resolved: bool
}

// A cell in the program. Givens are CUE references to other cells' yields.
// body: the LLM prompt template (already rendered via CUE interpolation).
// check: invariants that must hold after the cell evaluates.
#Cell: {
	name:    string
	effect:  #Effect
	body?:   string           // soft cell: prompt sent to LLM
	literal?: {[string]: _}  // pure literal: values baked in
	compute?: {[string]: _}  // pure compute: CUE expressions
	check?:  [...string]
	stem?:   bool
	autopour?: bool
}

// ── Cell 1: topic — hard literal ─────────────────────────────────────────
//
// Pure cell: no computation, no LLM.
// The value is baked into the definition itself.
// In the cell language: `yield subject = "autumn rain on a temple roof"`

topic: #Cell & {
	name:   "topic"
	effect: "pure"
	literal: {
		subject: "autumn rain on a temple roof"
	}
}

// ── Cell 2: compose — soft (replayable) ──────────────────────────────────
//
// The LLM writes the haiku. body is the prompt, already rendered
// with the literal value from topic via CUE string interpolation.
//
// CUE key insight: `topic.literal.subject` is a direct reference.
// No runtime wiring needed — CUE resolves this at eval time.
// This IS the dependency graph made explicit in the type system.

compose: #Cell & {
	name:   "compose"
	effect: "replayable"
	body: "Write a haiku about \(topic.literal.subject). Follow the traditional 5-7-5 syllable structure across exactly three lines. Return only the three lines of the haiku, separated by newlines."
	check: ["poem follows 5-7-5 syllable structure"]
}

// ── Cell 3: count-words — pure compute ───────────────────────────────────
//
// Replaces the sql: body in the reference. CUE can do this natively
// using strings.Split. We operate on a KNOWN value here so CUE can
// fully evaluate it at constraint-check time.
//
// In the original .cell file, count-words runs sql: on the frozen yield.
// In CUE, we compute on a concrete string using stdlib.
//
// Limitation: because compose.body is a prompt (not the poem itself),
// we demonstrate the computation on the topic text instead — showing
// what word-count WOULD compute if the poem were a literal value.
// A real runtime would substitute the LLM's output into this cell.

_demo_poem: "autumn rain falls soft\na frog leaps through silver drops\ntemple bell echoes"
_poem_words: strings.Split(strings.TrimSpace(_demo_poem), "\n")
_all_words: [for line in _poem_words for w in strings.Split(line, " ") {w}]

count_words: #Cell & {
	name:   "count-words"
	effect: "pure"
	// Given: compose.poem (demonstrated with _demo_poem above)
	// In a live runtime this would receive the frozen yield value.
	compute: {
		total:      len(_all_words)
		line_count: len(_poem_words)
	}
}

// ── Cell 4: critique — soft (replayable) ─────────────────────────────────
//
// Reads two givens: compose.poem and count-words.total.
// CUE interpolates count_words.compute.total into the body string.
// The «guillemet» references from the .cell syntax become \(field) here.

critique: #Cell & {
	name:   "critique"
	effect: "replayable"
	body: """
		Critique this haiku (word count: \(count_words.compute.total)):

		\(_demo_poem)

		Evaluate: Does it follow 5-7-5 syllable structure? Does the imagery
		evoke the subject? Is there a seasonal reference (kigo)? Is there a
		cutting word (kireji) or pause between images? Rate overall quality from 1-5.
		"""
	check: ["review contains at least 2 sentences"]
}

// ── Program manifest ──────────────────────────────────────────────────────
//
// CUE lets us describe the whole program as a struct.
// The dependency order is implicit in the reference graph.

haiku_program: {
	name:  "haiku"
	cells: [topic, compose, count_words, critique]
	dag: {
		"topic":       []
		"compose":     ["topic.subject"]
		"count-words": ["compose.poem"]
		"critique":    ["compose.poem", "count-words.total"]
	}
}

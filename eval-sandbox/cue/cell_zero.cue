// cell_zero.cue — The Metacircular Evaluator in CUE
//
// Translates cell-zero-reference.zygo into CUE's constraint model.
//
// This is the most revealing test for CUE as a cell language substrate.
// The cell language achieves metacircularity via:
//   - hard literal cells (pure values)
//   - soft cells (replayable, LLM-evaluated)
//   - pure compute cells (deterministic expressions)
//   - stem cells (perpetual, return :more)
//   - autopour (a cell that yields a program for the runtime to pour)
//
// CUE can express:
//   [x] hard literal cells — struct fields with concrete values
//   [x] soft cell prompts — rendered body strings
//   [x] pure compute — CUE expressions (strings, arithmetic)
//   [x] autopour as DATA — a cell that yields a #Program struct
//   [x] effect annotations — the #Effect enum
//   [x] check constraints — listed as string annotations
//   [ ] stem cells — NO. Perpetual looping is not expressible in CUE.
//   [ ] autopour as EXECUTION — CUE can describe the program; cannot pour it.
//   [ ] metacircularity proper — CUE can describe an evaluator but not BE one.
//
// The central insight: In the cell language, eval = pour.
// In CUE, eval = CUE evaluation (constraint solving).
// CUE IS metacircular for its own kind of values (constraints).
// But it cannot evaluate cell programs — it can only validate their shape.

import "strings"

// ── Schema ─────────────────────────────────────────────────────────────────

#Effect: "pure" | "replayable" | "non-replayable"

// A full cell program — the value that autopour yields
#Program: {
	name:  string
	cells: [...#CellDef]
}

#CellDef: {
	name:    string
	effect:  #Effect
	body?:   string
	givens:  [...string]
	yields:  [...string]
	stem?:   bool
	autopour?: bool
	check?:  [...string]
}

// A cell in the current program
#Cell: {
	name:    string
	effect:  #Effect
	body?:   string
	literal?: {[string]: _}
	compute?: {[string]: _}
	check?:  [...string]
	stem?:   bool
	autopour?: bool
}

// ── PART 1: The Universal Evaluator ───────────────────────────────────────

// Cell: request — soft (replayable)
// An external agent fills in the program to evaluate.
// CUE models this as a cell with a prompt body and no concrete givens.

request: #Cell & {
	name:   "request"
	effect: "replayable"
	body: "Yield the program name and S-expression source text for the program to be evaluated."
	check: ["program_name is not empty", "program_text is not empty"]
}

// Cell: evaluator — non-replayable, AUTOPOUR
// This is the heart of the metacircular evaluator.
// It takes program_text and yields it for autopour.
//
// In CUE, the "autopour" effect is modeled as a cell that yields a #Program.
// CUE can describe the STRUCTURE of autopour but not execute it.
//
// The program_text given is modeled here as a placeholder string (unknown
// at spec time — it flows from request at runtime).

evaluator: #Cell & {
	name:     "evaluator"
	effect:   "non-replayable"
	autopour: true
	// Givens: request.program_text, request.program_name
	// These are runtime values — not resolvable by CUE eval.
	// We annotate them as strings to show the dependency.
	compute: {
		// The autopour value IS the program_text.
		// eval = pour. The evaluator's yield IS the program.
		// In CUE, we can state the identity: evaluated = program_text
		identity_law: "evaluated = program_text (eval is pour)"
		autopour_target: "evaluated"
	}
	check: ["evaluated is not empty"]
}

// ── PART 2: Observing Results ──────────────────────────────────────────────

// Cell: status — replayable (observe primitive)
// In the Zygo substrate, this uses observe (not sql:).
// In CUE, we model the shape of the status computation.

status: #Cell & {
	name:   "status"
	effect: "replayable"
	// Given: evaluator.name (the name of the poured program)
	body: """
		Observe the program named {evaluator.name} in the retort.
		Return its status: one of "not_found", "error", "complete", "running".
		Check: if 0 cells found → not_found. If any cell state = bottom → error.
		If all cells frozen → complete. Otherwise → running.
		"""
	// The pure-compute version of this logic (from the zygo reference):
	compute: {
		// This is the STATIC SCHEMA of the status logic.
		// The actual evaluation requires observe (runtime primitive).
		logic: """
			let cells = observe(name, :cells)
			let total = len(cells)
			let bottoms = len(filter(c => c.state == "bottom", cells))
			let unfrozen = len(filter(c => c.state != "frozen", cells))
			state = if total == 0: "not_found"
			     elif bottoms > 0: "error"
			     elif unfrozen == 0: "complete"
			     else: "running"
			"""
	}
}

// ── PART 3: Self-Evaluation Analysis ──────────────────────────────────────
//
// Can this evaluator evaluate itself?
// CUE can REASON about this statically.

self_eval_analysis: {
	question: "If request.program_text = <source of this program>, does it diverge?"
	answer:   "No. The poured copy has an unsatisfied dependency (request.program_text)."
	reason:   "The DAG acts as a natural termination condition — inert copies are safe."
	fuel_needed_for_self_eval: false
	fuel_needed_for_chained_autopour: true
	// CUE can express this analysis as a constraint:
	// self_eval_terminates is always true because:
	// - A poured copy of this program needs request.program_text
	// - No external agent provides it
	// - The copy is inert (unsatisfied given = no frozen yield)
	self_eval_terminates: true
}

// ── PART 4: The Perpetual Evaluator (stem version) ─────────────────────────
//
// Stem cells run forever, returning :more each cycle.
// CUE CANNOT express this. Perpetual loops are not CUE values.
//
// What we CAN do: describe the shape of a stem cell and annotate
// what the runtime must provide.

perpetual_request: #Cell & {
	name:   "perpetual-request"
	effect: "non-replayable"
	stem:   true
	// CUE limitation: stem: true is just metadata.
	// The actual perpetual behavior cannot be expressed in CUE.
	// We document what the runtime needs to do.
	compute: {
		loop_behavior: ":more returned each cycle to request next iteration"
		observe_call:  "observe(\"cell-zero\", :pending-requests)"
		quiescent:     "if pending = nil → yield empty values, return :more"
		active:        "if pending → yield {program_name, program_text}, return :more"
	}
}

perpetual_evaluator: #Cell & {
	name:     "perpetual-evaluator"
	effect:   "non-replayable"
	stem:     true
	autopour: true
	// Given: perpetual_request.program_text, perpetual_request.program_name
	compute: {
		loop_behavior: ":more returned each cycle"
		quiescent:     "if program_text == \"\" → yield {poured: \"\", status: \"quiescent\"}, return :more"
		active:        "if program_text != \"\" → yield {poured: program_text, status: \"evaluating\"}, return :more"
	}
}

// ── PART 5: Demonstration — Hard Literal + Soft + Pure Compute ────────────

// Hard literal cell: pure value, no computation
example_topic: #Cell & {
	name:   "example-topic"
	effect: "pure"
	literal: {
		subject: "the metacircular evaluator"
	}
}

// Soft cell: LLM-evaluated. Prompt body rendered with literal.
example_haiku: #Cell & {
	name:   "example-haiku"
	effect: "replayable"
	body: "Write a haiku about \(example_topic.literal.subject). Follow 5-7-5 syllable structure. Return only the three lines."
	check: ["poem is not empty", "poem follows 5-7-5 syllable pattern"]
}

// Pure compute cell: replaces sql: in old syntax.
// Demonstrates CUE's native computation on a known value.
_demo_poem: "eval is but pour\nthe cell receives its own text\ninert copy blooms"
_demo_words: strings.Fields(_demo_poem)

example_word_count: #Cell & {
	name:   "example-word-count"
	effect: "pure"
	// Given: example-haiku.poem (demonstrated with _demo_poem)
	// Uses strings.Fields which splits on any whitespace (spaces + newlines).
	// This is the CUE equivalent of the Zygo: (len (split (trim poem) " "))
	// but more correct since the poem has newlines between lines.
	compute: {
		total: len(_demo_words)
	}
}

// ── Autopour as Data: the program yielded by evaluator ────────────────────
//
// This is CUE's best approximation of autopour.
// The evaluator cell's yield IS a #Program struct.
// When program_text = source of some program, the yield = that program.
//
// We show a concrete example: what if the evaluator receives haiku.cue
// as its program_text? It would yield this program struct for autopour.

_haiku_program_as_data: #Program & {
	name: "haiku-autopoured"
	cells: [
		{
			name:    "topic"
			effect:  "pure"
			givens:  []
			yields:  ["subject"]
		},
		{
			name:    "compose"
			effect:  "replayable"
			givens:  ["topic.subject"]
			yields:  ["poem"]
			body:    "Write a haiku about the given subject."
		},
	]
}

// The evaluator cell yielding a program for autopour
evaluator_yields: {
	evaluated: _haiku_program_as_data
	name:      "haiku-autopoured"
	// autopour: the runtime receives this struct and pours it
	// In CUE: this is just data. In the runtime: this triggers a pour.
}

// ── Program Manifest ───────────────────────────────────────────────────────

cell_zero_program: {
	name: "cell-zero"
	cells: [request, evaluator, status, perpetual_request, perpetual_evaluator, example_topic, example_haiku, example_word_count]
	dag: {
		request:              []
		evaluator:            ["request.program_text", "request.program_name"]
		status:               ["evaluator.name"]
		"perpetual-request":  []  // observe (runtime primitive)
		"perpetual-evaluator": ["perpetual-request.program_text", "perpetual-request.program_name"]
		"example-topic":      []
		"example-haiku":      ["example-topic.subject"]
		"example-word-count": ["example-haiku.poem"]
	}
	metacircularity: {
		// CUE's own metacircularity: CUE constraints describe CUE constraints.
		// A #Cell is a CUE struct that describes a cell. This IS metacircular
		// in CUE's sense — the schema describes itself via the definition system.
		cue_is_metacircular: true
		cell_lang_metacircular_in_cue: false
		reason: """
			CUE can describe the STRUCTURE of the metacircular evaluator,
			validate its shape, and render prompt bodies. But CUE cannot
			EXECUTE it: there is no pour, no observe, no stem loop, no autopour.
			The cell language's metacircularity requires a runtime.
			CUE's metacircularity is constraint-level: definitions constrain
			values that instantiate those definitions. This is real but different.
			"""
	}
}

// village_sim.cue — World simulation with iteration in CUE
//
// Translates village-sim-reference.cell into CUE's constraint model.
//
// The original uses `iterate day 5` — a stem/recur primitive that
// runs a cell N times, passing world_state from each iteration to the next.
//
// CUE CANNOT express dynamic iteration. CUE is a constraint language,
// not an imperative or functional one. There is no:
//   - recursion
//   - loops
//   - mutation
//   - time-stepped simulation
//
// What CUE CAN express:
//   1. The static shape of the program (cell definitions, dependencies)
//   2. The schema of world state (what a valid state looks like)
//   3. The construction phase (pure literal parameters)
//   4. The rendered prompt bodies for each phase (construction + simulation)
//   5. A FIXED UNROLLED version of N simulation steps
//
// This file shows all of the above, including an honest unrolled
// 3-step simulation using #SimStep schemas.
//
// The key insight: CUE can validate that a simulation step is WELL-FORMED
// (schema compliance) but cannot EXECUTE it. The iterate primitive is
// beyond CUE's expressive power. That's not a bug — CUE is a config
// language, not a computation language.

// ── Schema ─────────────────────────────────────────────────────────────────

#Effect: "pure" | "replayable" | "non-replayable"

#Cell: {
	name:     string
	effect:   #Effect
	body?:    string
	literal?: {[string]: _}
	check?:   [...string]
	// iterate: the cell language's loop primitive — not expressible in CUE
	// We annotate it as metadata only
	iterate?: {
		count: int & >=1
		note:  string
	}
}

// Schema for world state — what every simulation tick must produce
#Person: {
	name:          string
	role:          string
	identity:      string
	state:         string
	secret:        string
	relationships: {[string]: string}
	day_fn:        string
}

#WorldState: {
	day:             int & >=0
	setting:         _
	rules:           _
	active_conflicts: [...string]
	people:          [...#Person]
	history:         [...string]
	world_mood:      string
}

// ── Cell 1: params — hard literal ──────────────────────────────────────────
//
// The two knobs that define everything. Change these, get a different world.
// Pure literal: baked into the program definition.

params: #Cell & {
	name:   "params"
	effect: "pure"
	literal: {
		population: 5
		// Note: the premise is just the completing clause, not the full phrase.
		// The bodies say: "A world in which \(params.literal.premise)"
		premise:    "everyone was tiny fluffy cows"
	}
}

// ── Cell 2: world-constructor — soft (replayable) ──────────────────────────
//
// LLM builds the world from the premise. Three yields: setting, rules, seeds.
// CUE renders the prompt body with literal values interpolated.

world_constructor: #Cell & {
	name:   "world-constructor"
	effect: "replayable"
	body: """
		You are a world-builder. Given this premise:
		"A world in which \(params.literal.premise)"

		Construct the world by returning three things as JSON:

		SETTING: {"name": "...", "era": "...", "geography": "...", "atmosphere": "...", "key_locations": ["...", "..."]}

		RULES: {"premise_mechanic": "how the premise works mechanically", "constraints": ["...", "..."], "escalation_pattern": "how tension increases over time"}

		SEEDS_OF_CONFLICT: ["a specific tension that will grow", "another one", "a hidden truth waiting to surface"]

		The setting should make the premise's consequences INEVITABLE and INTERESTING.
		The rules should be consistent — the world follows its own logic.
		The seeds should guarantee the simulation produces drama, not stasis.
		"""
	check: ["setting is not empty", "rules is not empty"]
}

// ── Cell 3: person-constructor — soft (replayable) ─────────────────────────
//
// LLM creates N people. References world-constructor yields and params.
// In the original: given world-constructor.setting, .rules, .seeds_of_conflict
//
// Note: world_constructor.body is the PROMPT, not the output. We document the
// dependency as a given reference — the runtime resolves it, not CUE eval.

person_constructor: #Cell & {
	name:   "person-constructor"
	effect: "replayable"
	// Givens (runtime resolves, rendered as placeholders here):
	//   params.population, params.premise
	//   world-constructor.setting, .rules, .seeds_of_conflict
	body: """
		You are a character designer. Create exactly \(params.literal.population) people for this world.

		WORLD: {world-constructor.setting}
		RULES: {world-constructor.rules}
		SEEDS OF CONFLICT: {world-constructor.seeds_of_conflict}
		PREMISE: "A world in which \(params.literal.premise)"

		Return a JSON array of \(params.literal.population) people. Each person is:
		{
		  "name": "...",
		  "role": "their function in this world",
		  "identity": "2-sentence backstory",
		  "state": "their current emotional/physical state",
		  "secret": "something they're hiding",
		  "relationships": {"OtherName": "one-word feeling"},
		  "day_fn": "INSTRUCTIONS FOR THIS PERSON'S STEP FUNCTION: ..."
		}
		"""
	check: ["people is not empty", "people contains exactly the requested number of characters"]
}

// ── Cell 4: assemble — soft (replayable) ───────────────────────────────────
//
// Assembles all constructor outputs into initial_state.
// Pure-ish (just JSON assembly) but classified replayable because it
// depends on soft-cell outputs.

assemble: #Cell & {
	name:   "assemble"
	effect: "replayable"
	body: """
		Assemble the initial world state from its components.

		Return a single JSON object:
		{
		  "day": 0,
		  "setting": {world-constructor.setting},
		  "rules": {world-constructor.rules},
		  "active_conflicts": {world-constructor.seeds_of_conflict},
		  "people": {person-constructor.people},
		  "history": [],
		  "world_mood": "initial atmosphere description"
		}

		Do NOT modify any values — just assemble them into one object.
		Validate that all people have day_fn fields and relationships reference real names.
		"""
	check: ["initial_state is not empty"]
}

// ── Cell 5: day (iterate) — soft, ITERATION PATTERN ───────────────────────
//
// THIS IS WHERE CUE HITS ITS WALL.
//
// The cell language has: `iterate day 5`
// This means: run this cell 5 times, threading world_state through.
//   day_0(initial_state) → world_state_1
//   day_1(world_state_1) → world_state_2
//   ...
//   day_4(world_state_4) → world_state_5
//
// CUE has no iteration, no recursion, no mutation.
// The workaround: STATIC UNROLLING.
// Define N separate cells (day_0, day_1, ...) where each references the previous.
// This works for a known N but doesn't generalize.
//
// We show an unrolled 3-step version below to prove the pattern.

// The "iterate" cell as a CUE definition — annotated with the limitation
day_cell_template: #Cell & {
	name:   "day"
	effect: "replayable"
	iterate: {
		count: 5
		note:  "NOT EXECUTABLE IN CUE — unrolled below as day_0..day_2"
	}
	body: """
		You are the simulation kernel. You receive the complete world state as JSON.

		WORLD STATE:
		{world_state}

		Execute ONE tick of the simulation. This is a functional fold:

		STEP 1 — MAP: For each person in people[], execute their day_fn
		STEP 2 — REDUCE: Collect all actions. Determine CONSEQUENCES
		STEP 3 — EVOLVE: For each person, update state, relationships, day_fn, secret
		STEP 4 — ADVANCE: Increment day, update conflicts, history, world_mood

		Return: WORLD_STATE (evolved JSON) followed by NARRATIVE (5-8 sentences).
		"""
	check: ["world_state is not empty", "narrative is not empty"]
}

// Unrolled iteration: 3 explicit steps
// Each step references the previous step's output as its input.
// This IS expressible in CUE — it's just verbose and static.

#SimStep: {
	step:     int & >=0
	input_from: string // name of the cell providing world_state input
	body:     string
}

day_0: #SimStep & {
	step:        0
	input_from:  "assemble.initial_state"
	body: "Execute day 0 simulation tick with initial state from assemble.initial_state."
}

day_1: #SimStep & {
	step:        1
	input_from:  "day_0 world_state output"
	body: "Execute day 1 simulation tick. Input: evolved state from day 0."
}

day_2: #SimStep & {
	step:        2
	input_from:  "day_1 world_state output"
	body: "Execute day 2 simulation tick. Input: evolved state from day 1."
}

// ── Cell 6: epilogue — soft (replayable) ───────────────────────────────────

epilogue: #Cell & {
	name:   "epilogue"
	effect: "replayable"
	body: """
		The simulation of "a world in which \(params.literal.premise)" has run for 5 days.

		FINAL WORLD STATE:
		{day.world_state}

		LAST DAY:
		{day.narrative}

		Write the epilogue (3-4 paragraphs):
		1. The arc: how did the premise reshape these people over 5 days?
		2. The secrets: what was revealed, what stayed hidden?
		3. The evolution: compare each person's final day_fn to their original
		4. End with one sentence about what this world becomes.
		"""
	check: ["story is not empty", "story demonstrates how the premise mechanic drove character evolution"]
}

// ── Program manifest ────────────────────────────────────────────────────────

village_sim_program: {
	name: "village-sim"
	cells: [params, world_constructor, person_constructor, assemble, day_cell_template, epilogue]
	dag: {
		params:              []
		"world-constructor": ["params.premise"]
		"person-constructor": [
			"params.population",
			"params.premise",
			"world-constructor.setting",
			"world-constructor.rules",
			"world-constructor.seeds_of_conflict",
		]
		assemble: [
			"world-constructor.setting",
			"world-constructor.rules",
			"world-constructor.seeds_of_conflict",
			"person-constructor.people",
		]
		day: ["assemble.initial_state"]  // iterate: threads world_state
		epilogue: ["day.world_state", "day.narrative", "params.premise"]
	}
	iteration_note: """
		The `iterate day 5` primitive is NOT expressible in CUE.
		CUE cannot thread state through successive evaluations.
		The static unrolled form (day_0..day_N) works for fixed N
		but loses the language's iterate primitive semantics.
		This is CUE's fundamental limitation as a config language.
		"""
}

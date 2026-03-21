// village-sim.jsonnet — World simulation with iteration
//
// Demonstrates:
//   - Hard literal parameters cell
//   - Multiple soft cells with complex multi-field yields
//   - Iterate cell (stem-like: recurs N times, threading state)
//   - Epilogue cell consuming final iteration state
//
// The "iterate" cell type is the key challenge. Jsonnet has no native
// notion of recursion with state threading. We represent it as a cell
// with type: "iterate" and a count field — the runtime handles the loop.
// Each iteration feeds its yields back as the next iteration's givens.
//
// This is the honest Jsonnet representation: the structure is declarative,
// the looping semantics are delegated to the runtime.

// ── Helpers ──────────────────────────────────────────────────────────────────

local hardLiteral(name, yieldValues) = {
  name: name,
  effect: "pure",
  givens: [],
  yields: std.objectFields(yieldValues),
  body: { type: "literal", value: yieldValues },
  checks: [],
};

local softCell(name, givens, yields, template, checks=[]) = {
  name: name,
  effect: "replayable",
  givens: givens,
  yields: yields,
  body: { type: "soft", template: template },
  checks: checks,
};

// Iterate cell: like a stem cell but bounded. Runs `count` times.
// Each cycle receives its own previous yields merged back as givens.
// The seed_given provides the initial state on cycle 0.
local iterateCell(name, seed_given, count, yields, template, checks=[]) = {
  name: name,
  effect: "replayable",
  // On cycle 0: givens come from seed_given. On cycle N>0: givens come
  // from the previous cycle's own yields. The runtime manages this threading.
  givens: [seed_given],
  yields: yields,
  iterate: { count: count, seed: seed_given, state_field: yields[0] },
  body: { type: "soft", template: template },
  checks: checks,
};

// ── Cells ────────────────────────────────────────────────────────────────────

local params = hardLiteral("params", {
  population: 5,
  premise: "a world in which everyone was tiny fluffy cows",
});

local worldConstructor = softCell(
  name="world-constructor",
  givens=["params.premise"],
  yields=["setting", "rules", "seeds_of_conflict"],
  template=(
    "You are a world-builder. Given this premise:\n" +
    "\"A world in which {{premise}}\"\n\n" +
    "Construct the world by returning three things as JSON:\n\n" +
    "SETTING: {\"name\": \"...\", \"era\": \"...\", \"geography\": \"...\", " +
    "\"atmosphere\": \"...\", \"key_locations\": [\"...\", \"...\"]}\n\n" +
    "RULES: {\"premise_mechanic\": \"how the premise works mechanically\", " +
    "\"constraints\": [\"...\", \"...\"], " +
    "\"escalation_pattern\": \"how tension increases over time\"}\n\n" +
    "SEEDS_OF_CONFLICT: [\"a specific tension that will grow\", " +
    "\"another one\", \"a hidden truth waiting to surface\"]\n\n" +
    "The setting should make the premise's consequences INEVITABLE and INTERESTING.\n" +
    "The rules should be consistent — the world follows its own logic.\n" +
    "The seeds should guarantee the simulation produces drama, not stasis."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(setting)" },
    { type: "deterministic", expr: "not_empty(rules)" },
  ],
);

local personConstructor = softCell(
  name="person-constructor",
  givens=[
    "params.population",
    "params.premise",
    "world-constructor.setting",
    "world-constructor.rules",
    "world-constructor.seeds_of_conflict",
  ],
  yields=["people"],
  template=(
    "You are a character designer. Create exactly {{population}} people for this world.\n\n" +
    "WORLD: {{setting}}\n" +
    "RULES: {{rules}}\n" +
    "SEEDS OF CONFLICT: {{seeds_of_conflict}}\n" +
    "PREMISE: \"A world in which {{premise}}\"\n\n" +
    "Return a JSON array of {{population}} people. Each person is:\n" +
    "{\n" +
    "  \"name\": \"...\",\n" +
    "  \"role\": \"their function in this world\",\n" +
    "  \"identity\": \"2-sentence backstory\",\n" +
    "  \"state\": \"current emotional/physical state\",\n" +
    "  \"secret\": \"something they're hiding\",\n" +
    "  \"relationships\": {\"OtherName\": \"one-word feeling\"},\n" +
    "  \"day_fn\": \"INSTRUCTIONS FOR THIS PERSON'S STEP FUNCTION: ...\"\n" +
    "}\n\n" +
    "Design rules:\n" +
    "- Each person must have a DIFFERENT relationship to the premise\n" +
    "- At least one person benefits from the premise, one suffers from it\n" +
    "- Relationships should create triangles\n" +
    "- Each day_fn must be specific enough that a different LLM could play this person\n" +
    "- Secrets should interconnect — no isolated storylines"
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(people)" },
    { type: "semantic", assertion: "people contains exactly the requested number of characters with interconnected secrets" },
  ],
);

local assemble = softCell(
  name="assemble",
  givens=[
    "world-constructor.setting",
    "world-constructor.rules",
    "world-constructor.seeds_of_conflict",
    "person-constructor.people",
  ],
  yields=["initial_state"],
  template=(
    "Assemble the initial world state from its components.\n\n" +
    "Return a single JSON object:\n" +
    "{\n" +
    "  \"day\": 0,\n" +
    "  \"setting\": {{setting}},\n" +
    "  \"rules\": {{rules}},\n" +
    "  \"active_conflicts\": {{seeds_of_conflict}},\n" +
    "  \"people\": {{people}},\n" +
    "  \"history\": [],\n" +
    "  \"world_mood\": \"initial atmosphere description\"\n" +
    "}\n\n" +
    "Do NOT modify any values — just assemble them into one object.\n" +
    "Validate that all people have day_fn fields and relationships reference real names."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(initial_state)" },
  ],
);

// The iterate cell is the crux. It runs 5 times, threading world_state
// back into itself each cycle. On cycle 0, seed is assemble.initial_state.
// On cycles 1-4, world_state is the previous cycle's world_state output.
//
// Limitation: Jsonnet cannot express the self-referential looping natively.
// The "iterate" descriptor is a declaration — the runtime implements the fold.
local day = iterateCell(
  name="day",
  seed_given="assemble.initial_state",
  count=5,
  yields=["world_state", "narrative"],
  template=(
    "You are the simulation kernel. You receive the complete world state as JSON.\n\n" +
    "WORLD STATE:\n{{world_state}}\n\n" +
    "Execute ONE tick of the simulation. This is a functional fold:\n\n" +
    "STEP 1 — MAP: For each person in people[], execute their day_fn:\n" +
    "  - Read their day_fn (their personal step function)\n" +
    "  - Given their state, relationships, and the world's active_conflicts,\n" +
    "    determine their ACTION for today\n\n" +
    "STEP 2 — REDUCE: Collect all actions. Determine CONSEQUENCES:\n" +
    "  - How do actions interact? (conflicts, cooperation, accidents)\n" +
    "  - What does the premise mechanic cause to happen?\n" +
    "  - One UNEXPECTED consequence that nobody planned\n\n" +
    "STEP 3 — EVOLVE: For each person, update state, relationships, day_fn, secret.\n\n" +
    "STEP 4 — ADVANCE: Increment day, update active_conflicts, world_mood, history[].\n\n" +
    "Return:\n" +
    "WORLD_STATE: The complete evolved JSON.\n" +
    "NARRATIVE: 5-8 sentences telling what happened today as a STORY."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(world_state)" },
    { type: "deterministic", expr: "not_empty(narrative)" },
  ],
);

local epilogue = softCell(
  name="epilogue",
  givens=["day.world_state", "day.narrative", "params.premise"],
  yields=["story"],
  template=(
    "The simulation of \"a world in which {{premise}}\" has run for 5 days.\n\n" +
    "FINAL WORLD STATE:\n{{world_state}}\n\n" +
    "LAST DAY:\n{{narrative}}\n\n" +
    "Write the epilogue (3-4 paragraphs):\n" +
    "1. The arc: how did the premise reshape these people over 5 days?\n" +
    "2. The secrets: what was revealed, what stayed hidden?\n" +
    "3. The evolution: compare each person's final day_fn to their original\n" +
    "4. End with one sentence about what this world becomes."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(story)" },
    { type: "semantic", assertion: "story demonstrates how the premise mechanic drove character evolution" },
  ],
);

// ── Program ──────────────────────────────────────────────────────────────────

{
  program: "village-sim",
  cells: [
    params,
    worldConstructor,
    personConstructor,
    assemble,
    day,
    epilogue,
  ],
}

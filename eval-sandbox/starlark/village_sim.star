# village_sim.star — World Simulation with Iteration in Starlark
#
# Maps to village-sim-reference.cell:
#   cell params           → hard literal (pure)
#   cell world-constructor → soft cell (replayable)
#   cell person-constructor → soft cell (replayable, multi-given)
#   cell assemble         → soft cell (replayable, assembles state)
#   iterate day 5         → iteration pattern (stem-like loop)
#   cell epilogue         → soft cell (reads final iteration state)
#
# KEY CHALLENGE: "iterate day 5" in .cell syntax is a special construct.
# It declares a cell that re-runs up to N times, with output feeding
# back as input (world_state → next world_state).
#
# In Starlark, we model this as:
#   1. An iterate() helper that calls the step function N times
#   2. Each step gets the previous output as its context
#   3. Results are accumulated in a list (day[0]..day[N-1])
#
# This is the MOST INTERESTING part of the bakeoff: does Starlark's
# functional model express fixed-point iteration cleanly?
# Answer: yes, but the feedback loop requires explicit state threading.

# ============================================================
# RUNTIME HELPERS
# ============================================================

def resolve_givens(cells, cell_name):
    """Resolve a cell's givens into a context dict."""
    cell = cells[cell_name]
    ctx = {}
    for given in cell.get("givens", []):
        parts = given.split(".")
        source_name = parts[0]
        field_name = parts[1]
        src = cells.get(source_name, {})
        val = src.get("value", {}).get(field_name, None)
        ctx[field_name] = val if val != None else "[missing: %s]" % given
    return ctx

def render_template(template, ctx):
    """Substitute {field} references in a template string."""
    result = template
    for k, v in ctx.items():
        result = result.replace("{" + k + "}", str(v))
    return result

def simulate_llm_cell(cell_name, ctx, yields_list):
    """
    Simulate LLM output for named cells. Returns a dict of field:value.
    Real runtime would send the rendered body to the piston.
    """
    result = {}

    if cell_name == "world-constructor":
        result["setting"] = '{"name": "Meadowfield", "era": "pastoral-fantasy", "geography": "rolling hills dotted with tiny barns", "atmosphere": "deceptively serene"}'
        result["rules"] = '{"premise_mechanic": "all inhabitants are tiny fluffy cows who think in grass-metaphors", "constraints": ["no predators exist but the cows invent them", "social status measured in fluffiness"], "escalation_pattern": "fluffiness anxiety spirals toward a great shearing"}'
        result["seeds_of_conflict"] = '["The Great Fluffiness Census is coming", "Someone has been secretly un-fluffing their neighbors", "A rumor: the Shearing is not a myth"]'

    elif cell_name == "person-constructor":
        result["people"] = (
            '[{"name": "Bovina", "role": "Elder", "identity": "Oldest cow in Meadowfield. Remembers the last Shearing.", "state": "anxious", "secret": "She caused the last Shearing by over-fluffing", "relationships": {"Clover": "protective", "Moo": "suspicious"}, "day_fn": "You are Bovina. You hoard fluffy secrets and warn others vaguely."}, ' +
            '{"name": "Clover", "role": "Idealist", "identity": "Young optimist who believes fluffiness is a right.", "state": "hopeful", "secret": "Clover has been secretly fluffing Moo at night", "relationships": {"Bovina": "reverent", "Moo": "devoted"}, "day_fn": "You are Clover. You redistribute fluffiness and hide your generosity."}, ' +
            '{"name": "Moo", "role": "Skeptic", "identity": "Refuses to believe in the Shearing. Questions everything.", "state": "defiant", "secret": "Moo is actually the Shearer in disguise", "relationships": {"Bovina": "distrustful", "Clover": "grateful"}, "day_fn": "You are Moo. You deny the Shearing while secretly preparing it."}]'
        )

    elif cell_name == "assemble":
        result["initial_state"] = (
            '{"day": 0, "setting": ' + ctx.get("setting", "{}") + ', ' +
            '"active_conflicts": ["The Great Fluffiness Census approaches"], ' +
            '"people": ' + ctx.get("people", "[]") + ', ' +
            '"history": [], ' +
            '"world_mood": "Tense pastoral serenity"}'
        )

    elif cell_name == "epilogue":
        world_state = ctx.get("world_state", "{}")
        narrative = ctx.get("narrative", "")
        premise = ctx.get("premise", "")
        result["story"] = (
            "After five days in a world of tiny fluffy cows, the premise had worked its terrible logic. " +
            "Bovina's guilt over the last Shearing finally broke her silence on day three. " +
            "Clover's secret midnight fluffing was exposed, splitting the village between admiration and outrage. " +
            "And Moo — the Shearer in disguise — revealed themselves on the final day, not with blades, " +
            "but with a mirror, showing each cow exactly how fluffy they truly were. " +
            "The Great Fluffiness Census never came. The cows had measured themselves into understanding. " +
            "Meadowfield became a world where fluffiness was neither hoarded nor redistributed, " +
            "but simply acknowledged — which was, it turned out, the only thing any of them had wanted."
        )

    else:
        for field in yields_list:
            result[field] = "[LLM response for %s.%s]" % (cell_name, field)

    return result

def run_cell(cells, cell_name):
    """Evaluate a single cell. Stores result in cells[cell_name]['value']."""
    cell = cells[cell_name]
    body = cell.get("body", None)
    ctx = resolve_givens(cells, cell_name)

    if body == None:
        return cell.get("value", {})

    if type(body) == type(""):
        _rendered = render_template(body, ctx)
        result = simulate_llm_cell(cell_name, ctx, cell["yields"])
    else:
        result = body(ctx)

    cells[cell_name]["value"] = result
    return result

def print_yield(field, val, indent):
    """Print a yield value, truncating long strings."""
    prefix = " " * indent
    v_str = str(val)
    if len(v_str) > 100:
        v_str = v_str[:97] + "..."
    print("%syield %s = %s" % (prefix, field, v_str))

# ============================================================
# ITERATION PRIMITIVE
#
# "iterate day 5" in .cell becomes iterate_cell() in Starlark.
#
# The iterate cell in .cell:
#   - Has a self-referential given: it reads its own previous yield
#   - The first iteration reads from assemble.initial_state
#   - Subsequent iterations read from day.world_state (previous cycle)
#   - The runtime handles the feedback loop
#
# In Starlark:
#   - We cannot express a genuinely self-referential cell in pure data
#   - Instead, iterate_cell() is an explicit loop function
#   - It takes an initial state and a step function, runs N times
#   - Each step returns (new_state, narrative)
#
# This IS the core limitation: Starlark cannot express the feedback
# loop declaratively. The iterate primitive needs explicit threading.
# ============================================================

def simulate_day_step(step_num, world_state, narrative_prev):
    """
    Simulate one day of the world simulation.
    In the real runtime, the piston would receive the full world_state
    as context and return updated world_state + narrative.
    """
    # Extract day number from world_state string (simplified)
    day_num = step_num + 1

    narratives = [
        ("Day 1: Bovina calls an emergency meeting. The Census is near. Clover whispers, " +
         "'Don't be afraid — fluffiness is not a finite resource.' Moo snorts: 'Prove it.' " +
         "That night, three cows wake to find themselves inexplicably fluffier."),
        ("Day 2: The mysterious overnight re-fluffing causes panic. 'Someone is TAKING our fluffiness,' " +
         "cries Tuft. Clover says nothing, ears flat. Bovina watches Clover too carefully. " +
         "'It's happening again,' she thinks."),
        ("Day 3: Bovina confesses. The last Shearing was her fault — she over-fluffed until the Shearer came. " +
         "'I thought more was better.' The village goes quiet. Clover finally admits the midnight operations. " +
         "Moo disappears into the barn."),
        ("Day 4: Moo emerges from the barn carrying something metallic. Everyone freezes. " +
         "'It's not blades,' Moo says. 'It's a mirror.' The cows see themselves — finally, accurately. " +
         "Most are fluffier than they knew. Some are less. All are enough."),
        ("Day 5: The Census arrives. The Counters find no one to count — the cows have dissolved the " +
         "concept of comparative fluffiness. The Shearer, never summoned, does not come. " +
         "Meadowfield is free, which is to say: uncertain, honest, and alive."),
    ]

    narrative = narratives[step_num] if step_num < len(narratives) else "Day %d: The simulation continues." % day_num

    # Update world state string (simplified — real runtime would parse/evolve full JSON)
    new_state = world_state.replace('"day": %d' % step_num, '"day": %d' % day_num)
    if new_state == world_state:
        # Fallback: just mark progression
        new_state = '{"day": %d, "world_mood": "evolving", "history": ["day %d complete"]}' % (day_num, day_num)

    return (new_state, narrative)

def iterate_cell(cells, initial_state_cell, num_iterations):
    """
    Execute the iterate pattern: runs step function N times.

    iterate day 5
      given assemble.initial_state
      yield world_state
      yield narrative

    Maps to: iterate_cell(cells, "assemble", 5)

    Returns a list of (world_state, narrative) tuples — one per iteration.
    The final tuple represents what 'day.world_state' and 'day.narrative' resolve to.
    """
    # Get the initial state from the seed cell
    seed = cells[initial_state_cell].get("value", {})
    current_state = seed.get("initial_state", "{}")
    current_narrative = ""

    results = []
    for i in range(num_iterations):
        (new_state, new_narrative) = simulate_day_step(i, current_state, current_narrative)
        results.append({"world_state": new_state, "narrative": new_narrative})
        current_state = new_state
        current_narrative = new_narrative
        print("")
        print("  [day iteration %d/%d]" % (i + 1, num_iterations))
        print("  narrative: %s" % new_narrative[:80])

    # Store the FINAL iteration's values as what downstream cells see
    final = results[num_iterations - 1]
    cells["day"] = {
        "name": "day",
        "effect": "replayable",
        "givens": [],
        "yields": ["world_state", "narrative"],
        "stem": False,
        "autopour": [],
        "body": None,
        "value": final,
        "checks": ["world_state is not empty", "narrative is not empty"],
        "_all_iterations": results,
    }
    return results

# ============================================================
# PROGRAM DEFINITION
# ============================================================

# ── Parameters (hard literal) ─────────────────────────────────
cell_params = {
    "name": "params",
    "effect": "pure",
    "givens": [],
    "yields": ["population", "premise"],
    "stem": False,
    "autopour": [],
    "body": None,
    "value": {
        "population": 3,
        "premise": "a world in which everyone was tiny fluffy cows",
    },
    "checks": [],
}

# ── World constructor (soft cell) ────────────────────────────
# This is the world-building cell. Its body is a long multi-paragraph
# LLM prompt. In .cell, triple-dash blocks handle this naturally.
# In Starlark: string concatenation with \n to simulate paragraphs.
cell_world_constructor = {
    "name": "world-constructor",
    "effect": "replayable",
    "givens": ["params.premise"],
    "yields": ["setting", "rules", "seeds_of_conflict"],
    "stem": False,
    "autopour": [],
    "body": (
        "You are a world-builder. Given this premise: " +
        "\"A world in which {premise}\"\n\n" +
        "Construct the world by returning three things as JSON:\n" +
        "SETTING: {\"name\": \"...\", \"era\": \"...\", ...}\n" +
        "RULES: {\"premise_mechanic\": \"...\", \"constraints\": [...], ...}\n" +
        "SEEDS_OF_CONFLICT: [\"...\", \"...\", \"...\"]"
    ),
    "value": {},
    "checks": ["setting is not empty", "rules is not empty"],
}

# ── Person constructor (soft cell, many givens) ───────────────
cell_person_constructor = {
    "name": "person-constructor",
    "effect": "replayable",
    "givens": [
        "params.population",
        "params.premise",
        "world-constructor.setting",
        "world-constructor.rules",
        "world-constructor.seeds_of_conflict",
    ],
    "yields": ["people"],
    "stem": False,
    "autopour": [],
    "body": (
        "You are a character designer. Create exactly {population} people for this world.\n" +
        "WORLD: {setting}\nRULES: {rules}\nSEEDS: {seeds_of_conflict}\n" +
        "Return a JSON array of {population} people, each with name, role, identity, " +
        "state, secret, relationships, and day_fn fields."
    ),
    "value": {},
    "checks": ["people is not empty"],
}

# ── Assembler (soft cell) ─────────────────────────────────────
cell_assemble = {
    "name": "assemble",
    "effect": "replayable",
    "givens": [
        "world-constructor.setting",
        "world-constructor.rules",
        "world-constructor.seeds_of_conflict",
        "person-constructor.people",
    ],
    "yields": ["initial_state"],
    "stem": False,
    "autopour": [],
    "body": (
        "Assemble the initial world state. Return a single JSON object with: " +
        "day, setting, rules, active_conflicts, people, history, world_mood. " +
        "SETTING: {setting}\nPEOPLE: {people}"
    ),
    "value": {},
    "checks": ["initial_state is not empty"],
}

# ── Epilogue (soft cell, reads from final iteration) ─────────
cell_epilogue = {
    "name": "epilogue",
    "effect": "replayable",
    "givens": ["day.world_state", "day.narrative", "params.premise"],
    "yields": ["story"],
    "stem": False,
    "autopour": [],
    "body": (
        "The simulation of \"{premise}\" has run for 5 days.\n\n" +
        "FINAL STATE: {world_state}\nLAST DAY: {narrative}\n\n" +
        "Write the epilogue (3-4 paragraphs): " +
        "the arc, the secrets revealed, the character evolution."
    ),
    "value": {},
    "checks": ["story is not empty"],
}

# ============================================================
# PROGRAM REGISTRY AND EXECUTION
# ============================================================

cells = {
    "params": cell_params,
    "world-constructor": cell_world_constructor,
    "person-constructor": cell_person_constructor,
    "assemble": cell_assemble,
    # "day" is added dynamically by iterate_cell()
    "epilogue": cell_epilogue,
}

def main():
    print("=== village_sim.star — World Simulation with Iteration ===")
    print("")

    # Phase 1: Construction (static DAG cells)
    construction_order = [
        "params",
        "world-constructor",
        "person-constructor",
        "assemble",
    ]

    print("--- CONSTRUCTION PHASE ---")
    for cell_name in construction_order:
        cell = cells[cell_name]
        value = run_cell(cells, cell_name)
        print("")
        effect = cell.get("effect", "pure")
        print("cell %s (%s)" % (cell_name, effect))
        for k, v in value.items():
            print_yield(k, v, 2)

    # Phase 2: Simulation (iterate day 5)
    print("")
    print("--- SIMULATION PHASE: iterate day 5 ---")
    print("")
    print("cell day (replayable) [iterate x5]")
    print("  given assemble.initial_state")
    print("  yield world_state")
    print("  yield narrative")
    print("")
    print("  Iteration pattern: world_state(n) = step(world_state(n-1))")
    print("  The feedback loop is explicit in Starlark (cannot be declarative).")
    print("")
    results = iterate_cell(cells, "assemble", 5)

    print("")
    print("  Final day values (what downstream cells see):")
    final = results[4]
    for k, v in final.items():
        print_yield(k, v, 4)

    # Phase 3: Epilogue
    print("")
    print("--- EPILOGUE PHASE ---")
    epilogue_value = run_cell(cells, "epilogue")
    print("")
    print("cell epilogue (replayable)")
    for k, v in epilogue_value.items():
        print_yield(k, v, 2)

    print("")
    print("=== DESIGN ANALYSIS: iterate in Starlark ===")
    print("")
    print("The 'iterate day 5' construct has no direct Starlark equivalent.")
    print("")
    print("Original .cell syntax:")
    print("  iterate day 5")
    print("    given assemble.initial_state")
    print("    yield world_state")
    print("    yield narrative")
    print("    --- (LLM body that reads world_state and emits world_state') ---")
    print("")
    print("Starlark representation:")
    print("  def iterate_cell(cells, seed_cell, n):")
    print("    state = cells[seed_cell]['value']['initial_state']")
    print("    for i in range(n):")
    print("      (state, narrative) = step(i, state, narrative)")
    print("    cells['day'] = {'value': {'world_state': state, 'narrative': narrative}}")
    print("")
    print("Key differences:")
    print("  1. Feedback loop is IMPERATIVE in Starlark, DECLARATIVE in .cell")
    print("  2. Starlark cannot express 'given self.world_state' — the self-reference")
    print("     must be threaded through a function parameter")
    print("  3. The iterate count (5) is a parameter to a function, not a language keyword")
    print("  4. All iterations are computed eagerly; .cell could lazily evaluate")
    print("  5. Starlark expresses WHAT the iteration DOES but not THAT it iterates")
    print("     — the structural form is lost")
    print("")
    print("Verdict: iterate is the HARDEST .cell construct to express in Starlark.")
    print("It is achievable but loses the declarative form that makes .cell readable.")

main()

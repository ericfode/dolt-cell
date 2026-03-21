-- village-sim.lua
-- World simulation: parameterized construction → iterative simulation → epilogue
-- Demonstrates complex DAG with construction phase (pure → soft chain)
-- and simulation phase (iterate via sequential soft cells).
-- Run with: ~/go/bin/glua village-sim.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ═══════════════════════════════════════
-- PARAMETERS
-- ═══════════════════════════════════════

local params = rt.hard({
  population = "5",
  premise = "a world in which everyone was tiny fluffy cows"
})

-- ═══════════════════════════════════════
-- CONSTRUCTION: pure functions, no side effects
-- ═══════════════════════════════════════

local world_constructor = rt.soft(
  { "params.premise" },
  { "setting", "rules", "seeds_of_conflict" },
  function(env)
    return string.format(
      "You are a world-builder. Premise: 'A world in which %s'\n\n" ..
      "Return JSON for:\n" ..
      "SETTING: {name, era, geography, atmosphere, key_locations}\n" ..
      "RULES: {premise_mechanic, constraints, escalation_pattern}\n" ..
      "SEEDS_OF_CONFLICT: [3 specific tensions]\n\n" ..
      "Make the premise's consequences INEVITABLE and INTERESTING.",
      env.premise)
  end,
  { "setting is not empty", "rules is not empty" }
)

local person_constructor = rt.soft(
  { "params.population", "params.premise", "world_constructor.setting",
    "world_constructor.rules", "world_constructor.seeds_of_conflict" },
  { "people" },
  function(env)
    return string.format(
      "Create %s people for this world. Setting: %s, Rules: %s\n\n" ..
      "Each person: {name, role, identity, state, secret, relationships, day_fn}. " ..
      "Each must relate differently to the premise. Secrets interconnect.",
      tostring(env.population), tostring(env.setting), tostring(env.rules))
  end,
  { "people is not empty" }
)

local assemble = rt.soft(
  { "world_constructor.setting", "world_constructor.rules",
    "world_constructor.seeds_of_conflict", "person_constructor.people" },
  { "initial_state" },
  function(env)
    return string.format(
      "Assemble initial world state from:\n" ..
      "Setting: %s\nRules: %s\nConflicts: %s\nPeople: %s\n\n" ..
      "Return single JSON: {day:0, setting, rules, active_conflicts, people, history:[], world_mood}",
      tostring(env.setting), tostring(env.rules),
      tostring(env.seeds_of_conflict), tostring(env.people))
  end,
  { "initial_state is not empty" }
)

-- ═══════════════════════════════════════
-- SIMULATION: sequential day cells (original used iterate)
-- In the real runtime, iterate would be a stem cell.
-- Here we chain 3 day cells to show the pattern.
-- ═══════════════════════════════════════

local function make_day(n, given_state)
  return rt.soft(
    { given_state },
    { "world_state", "narrative" },
    function(env)
      return string.format(
        "You are the simulation kernel. Day %d.\n\n" ..
        "WORLD STATE:\n%s\n\n" ..
        "Execute ONE tick: MAP (run each person's day_fn) → " ..
        "REDUCE (determine consequences) → EVOLVE (update states, rewrite day_fns) → " ..
        "ADVANCE (increment day, update conflicts, append to history).\n\n" ..
        "Return WORLD_STATE (evolved JSON) and NARRATIVE (5-8 sentences, include dialogue).",
        n, tostring(env.world_state or env.initial_state))
    end,
    { "world_state is not empty", "narrative is not empty" }
  )
end

local day1 = make_day(1, "assemble.initial_state")
local day2 = make_day(2, "day1.world_state")
local day3 = make_day(3, "day2.world_state")

-- ═══════════════════════════════════════
-- EPILOGUE
-- ═══════════════════════════════════════

local epilogue = rt.soft(
  { "day3.world_state", "day3.narrative", "params.premise" },
  { "story" },
  function(env)
    return string.format(
      "Simulation of '%s' ran for 3 days.\n\nFinal state: %s\nLast day: %s\n\n" ..
      "Write epilogue (3-4 paragraphs): the arc, the secrets, the evolution, the future.",
      tostring(env.premise), tostring(env.world_state), tostring(env.narrative))
  end,
  { "story is not empty" }
)

-- ═══════════════════════════════════════
-- LLM SIMULATOR
-- ═══════════════════════════════════════

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    world_constructor = {
      setting = '{"name":"Meadowshire","era":"pastoral","geography":"rolling hills","atmosphere":"gentle, absurd"}',
      rules = '{"premise_mechanic":"all people are tiny fluffy cows","constraints":["hooves not hands","grass diet"],"escalation_pattern":"herd dynamics intensify"}',
      seeds_of_conflict = '["the barn is too small","one cow wants to leave","a wolf was spotted"]'
    },
    person_constructor = {
      people = '[{"name":"Buttercup","role":"mayor","state":"content","secret":"fears wolves","day_fn":"graze, give speeches, worry privately"}]'
    },
    assemble = {
      initial_state = '{"day":0,"people":[{"name":"Buttercup"}],"history":[],"world_mood":"peaceful"}'
    },
    day1 = {
      world_state = '{"day":1,"people":[{"name":"Buttercup","state":"worried"}],"history":["Day 1: Buttercup heard howling"],"world_mood":"tense"}',
      narrative = "Buttercup called a town meeting. 'Has anyone else heard the howling?' she asked. The other cows shifted nervously."
    },
    day2 = {
      world_state = '{"day":2,"people":[{"name":"Buttercup","state":"determined"}],"history":["Day 1: howling","Day 2: formed patrol"],"world_mood":"resolute"}',
      narrative = "The patrol found tracks. 'These are old,' Buttercup noted with relief. But she posted guards anyway."
    },
    day3 = {
      world_state = '{"day":3,"people":[{"name":"Buttercup","state":"proud"}],"history":["Day 1: howling","Day 2: patrol","Day 3: false alarm"],"world_mood":"relieved"}',
      narrative = "The wolf turned out to be a lost dog. Meadowshire celebrated with extra hay."
    },
    epilogue = {
      story = "Over three days, tiny fluffy cows proved that even the smallest beings can face their fears. " ..
        "Buttercup's secret terror of wolves transformed into public courage. " ..
        "The herd grew closer through shared adversity. " ..
        "Meadowshire would remember the week the wolf came — and turned out to be a friend."
    },
  }
  return sims[cell_name]
end

io.write("=== VILLAGE SIMULATION ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("params", params)
retort:pour("world_constructor", world_constructor)
retort:pour("person_constructor", person_constructor)
retort:pour("assemble", assemble)
retort:pour("day1", day1)
retort:pour("day2", day2)
retort:pour("day3", day3)
retort:pour("epilogue", epilogue)
retort:run()
retort:dump()

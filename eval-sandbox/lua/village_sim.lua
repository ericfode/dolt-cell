-- village_sim.lua
-- World simulation using coroutines for the iterate/stem pattern.
-- Mirrors village-sim-reference.cell
-- Run with: ~/go/bin/glua village_sim.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

-- Parameters: hard literal, changes the entire simulation
local params = rt.hard({
  population = 3,
  premise    = "everyone was tiny fluffy cows"
})

-- World constructor: soft cell, LLM builds the world
local world_constructor = rt.soft(
  { "params.premise" },
  { "setting", "rules", "seeds_of_conflict" },
  function(env)
    return string.format([[
You are a world-builder. Given this premise: "A world in which %s"

Return three JSON fields:
SETTING: {"name":"...","era":"...","geography":"...","atmosphere":"..."}
RULES: {"premise_mechanic":"...","constraints":["..."],"escalation_pattern":"..."}
SEEDS_OF_CONFLICT: ["a tension that will grow","another one","a hidden truth"]

The setting should make the premise inevitable and interesting.]], env.premise)
  end
)

-- Person constructor: soft cell, creates the cast
local person_constructor = rt.soft(
  { "params.population", "params.premise",
    "world_constructor.setting", "world_constructor.rules",
    "world_constructor.seeds_of_conflict" },
  { "people" },
  function(env)
    return string.format([[
Create exactly %s characters for this world.
WORLD: %s
RULES: %s
SEEDS: %s
PREMISE: "A world in which %s"

Return JSON array of %s people, each with: name, role, state, secret, day_fn.
day_fn is their behavioral instruction for each simulation step.]],
      tostring(env.population),
      tostring(env.setting), tostring(env.rules),
      tostring(env.seeds_of_conflict),
      tostring(env.premise),
      tostring(env.population))
  end
)

-- Assemble: pure compute — just combines components into initial_state
-- No LLM needed: deterministic assembly of parts
local assemble = rt.compute(
  { "world_constructor.setting", "world_constructor.rules",
    "world_constructor.seeds_of_conflict", "person_constructor.people" },
  { "initial_state" },
  function(env)
    -- Build a Lua table representing the initial world state.
    return {
      initial_state = {
        day = 0,
        setting = env.setting,
        rules = env.rules,
        active_conflicts = env.seeds_of_conflict,
        people = env.people,
        history = {},
        world_mood = "The tiny fluffy world stirs at dawn."
      }
    }
  end
)

-- ============================================================
-- STEM CELL: the simulation loop
--
-- This is the key feature: a coroutine that yields one day of
-- simulation per resume, returning "more" to request the next cycle.
--
-- Corresponds to: iterate day 5 in village-sim-reference.cell
-- ============================================================
local MAX_DAYS = 5

local day = rt.stem(
  { "assemble.initial_state" },
  { "world_state", "narrative" },
  -- factory_fn: receives env on first resume, then loops
  function(env)
    local state = env.initial_state
    local day_num = 0

    -- Each coroutine.yield is one simulation tick
    while day_num < MAX_DAYS do
      day_num = day_num + 1
      -- In real runtime: send state to LLM, get evolved state back.
      -- Here: simulate the fold with deterministic logic.
      local narrative = sim_tick(state, day_num)
      state = advance_state(state, day_num, narrative)

      local result = { world_state = state, narrative = narrative }
      local signal = coroutine.yield(result, "more")
      if signal == "stop" then break end
    end
    -- Final yield without "more" — stem terminates
    return { world_state = state, narrative = "The simulation ends." }
  end
)

-- ============================================================
-- SIMULATION HELPERS
-- (These substitute for LLM calls in the iterate cell body)
-- ============================================================

-- Simulate one tick: map person day_fns, reduce consequences
function sim_tick(state, day_num)
  local people = state.people or {}
  local actions = {}
  for _, person in ipairs(people) do
    table.insert(actions, person.name .. " " .. person.action_today)
  end

  local templates = {
    "Day %d: The tiny cows gathered near %s. %s",
    "Day %d: Tension rose when %s revealed their secret near %s.",
    "Day %d: A thunderstorm scattered the herd across %s. %s",
    "Day %d: The elder cow called a meeting at %s. %s",
    "Day %d: By nightfall at %s, everything had changed. %s",
  }
  local idx = math.min(day_num, #templates)
  local location = (state.setting and state.setting.name) or "the meadow"
  local event = #actions > 0 and table.concat(actions, "; ") or "The world held its breath."
  return string.format(templates[idx], day_num, location, event)
end

function advance_state(state, day_num, narrative)
  local new_state = {}
  for k, v in pairs(state) do new_state[k] = v end
  new_state.day = day_num
  new_state.world_mood = "Day " .. day_num .. " mood: " ..
    ({"tense","curious","electric","sorrowful","resolved"})[day_num] or "uncertain"
  -- Append to history
  local hist = {}
  for _, h in ipairs(state.history or {}) do table.insert(hist, h) end
  table.insert(hist, "Day " .. day_num .. ": " .. narrative:sub(1, 60))
  new_state.history = hist
  return new_state
end

-- Epilogue: soft cell that reads the final world state
local epilogue = rt.soft(
  { "day.world_state", "day.narrative", "params.premise" },
  { "story" },
  function(env)
    local ws = env.world_state
    local hist = (ws and ws.history) and ws.history or {}
    local hist_str = table.concat(hist, "\n")
    return string.format([[
The simulation of "a world in which %s" has run for %d days.

HISTORY:
%s

LAST NARRATIVE:
%s

Write the epilogue (3-4 paragraphs):
1. The arc: how did the premise reshape these people?
2. The secrets: what was revealed, what stayed hidden?
3. The evolution: compare first and last day.
4. End with one sentence about what this world becomes.]],
      tostring(env.premise),
      MAX_DAYS,
      hist_str,
      tostring(env.narrative))
  end
)

-- ============================================================
-- LLM SIMULATOR
-- ============================================================
local SIM_SETTING = { name="Meadowmere", era="pastoral", geography="rolling hills",
                      atmosphere="dreamy and warm" }
local SIM_RULES   = { premise_mechanic="tiny fluffy cows communicate by nuzzling",
                      constraints={"must nuzzle to share secrets","size limits reach"},
                      escalation_pattern="secrets spread via nuzzle chains" }
local SIM_SEEDS   = { "the largest cow is secretly afraid of grass",
                      "two cows love the same patch of clover",
                      "the fence was built by someone who wanted them trapped" }
local SIM_PEOPLE  = {
  { name="Blossom", role="elder",  state="serene",   secret="fears the fence",
    action_today="wandered to the east pasture" },
  { name="Clover",  role="young",  state="restless", secret="knows the gate code",
    action_today="nuzzled Blossom urgently" },
  { name="Thistle", role="outcast",state="wary",     secret="built the fence",
    action_today="watched from the hill" },
}

local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "world_constructor" then
    return { setting = SIM_SETTING, rules = SIM_RULES, seeds_of_conflict = SIM_SEEDS }
  elseif cell_name == "person_constructor" then
    return { people = SIM_PEOPLE }
  elseif cell_name == "epilogue" then
    local ws = env.world_state
    local days = (ws and ws.day) or MAX_DAYS
    return {
      story = string.format(
        "For %d days the tiny fluffy cows of Meadowmere lived out their premise. " ..
        "Blossom's fear of the fence was exposed on day 3 when Clover's nuzzle-chain " ..
        "reached the whole herd. Thistle, the fence-builder, faced the consequences. " ..
        "The clover patch dispute resolved into shared grazing. " ..
        "In the end, Meadowmere became a world where secrets survive no more than " ..
        "three nuzzles.",
        days
      )
    }
  end
  return nil
end

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== VILLAGE SIMULATION PROGRAM ===\n\n")

local retort = rt.Retort.new()
retort.llm_sim = simulate_llm

retort:pour("params",            params)
retort:pour("world_constructor", world_constructor)
retort:pour("person_constructor",person_constructor)
retort:pour("assemble",          assemble)
retort:pour("day",               day)
retort:pour("epilogue",          epilogue)

-- Custom run: stem cell needs multiple passes
io.write("Running DAG (stem cell will tick " .. MAX_DAYS .. " times)...\n\n")

-- Pour non-stem cells first
local non_stem = {"params","world_constructor","person_constructor","assemble"}
local stem_retort = rt.Retort.new()
stem_retort.llm_sim = simulate_llm
for _, n in ipairs(non_stem) do
  stem_retort:pour(n, retort.cells[n] or
    ({params=params,world_constructor=world_constructor,
      person_constructor=person_constructor,assemble=assemble})[n])
end
stem_retort:run()

-- Now manually drive the stem cell (day) for MAX_DAYS ticks
io.write("\n--- RUNNING STEM CELL: day (" .. MAX_DAYS .. " ticks) ---\n")
local assemble_yields = stem_retort.yields["assemble"]
local day_env = { initial_state = assemble_yields and assemble_yields.initial_state or {} }

local day_co = coroutine.create(day.body)
local last_world_state, last_narrative

for tick = 1, MAX_DAYS do
  local ok, result, signal
  if tick == 1 then
    ok, result, signal = coroutine.resume(day_co, day_env)
  else
    ok, result, signal = coroutine.resume(day_co, "continue")
  end

  if ok and type(result) == "table" then
    last_world_state = result.world_state
    last_narrative   = result.narrative
    io.write(string.format("  tick %d [%s]: %s\n", tick,
      signal or "final",
      tostring(last_narrative):sub(1, 80)))
  else
    io.write("  tick " .. tick .. " error: " .. tostring(result) .. "\n")
    break
  end
end

io.write("\n--- STEM CELL FINAL STATE ---\n")
if last_world_state then
  io.write("  day = " .. tostring(last_world_state.day) .. "\n")
  io.write("  mood = " .. tostring(last_world_state.world_mood) .. "\n")
  io.write("  history:\n")
  for _, h in ipairs(last_world_state.history or {}) do
    io.write("    " .. h .. "\n")
  end
end

-- Run epilogue with final state
io.write("\n--- EPILOGUE ---\n")
local epi_env = {
  world_state = last_world_state,
  narrative   = last_narrative,
  premise     = "everyone was tiny fluffy cows"
}
local epi_prompt = epilogue.body(epi_env)
io.write("[soft] epilogue prompt (first 100 chars):\n  " ..
  epi_prompt:sub(1,100) .. "...\n\n")

local epi_result = simulate_llm("epilogue", epi_prompt, {"story"}, epi_env)
if epi_result then
  io.write("STORY:\n" .. epi_result.story .. "\n")
end

-- ============================================================
-- COROUTINE STEM CELL ANATOMY
-- ============================================================
io.write("\n=== COROUTINE → STEM CELL MAPPING ===\n")
io.write([[
  coroutine.create(fn)     → stem cell instantiation
  coroutine.resume(co, env)→ claim + execute one generation
  coroutine.yield(val,"more") → NonReplayable yield + request next cycle
  coroutine.status(co)     → "suspended"=pending, "dead"=frozen
  return val               → final yield, no more cycles
]])

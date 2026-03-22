-- bottom-guard-skip.lua
-- Guard-skip vs failure: iterative countdown with early guard.
-- In real runtime: stem cell with recur until step = "done" (max 5).
-- Guard fires when step = "done", skipping remaining iterations.
-- Cells that gather via [*] receive only the non-skipped steps.
-- In simplified runtime: compute runs all steps, soft collects the trace.
-- Note: gather semantics (given countdown[*].step) require real ct runtime.
-- Run with: ~/go/bin/glua bottom-guard-skip.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local seed = rt.hard({ n = "3" })

-- Countdown: runs until n <= 0 (guard), max 5 steps. Returns step trace.
-- In real runtime: stem cell that yields step values one at a time.
local countdown = rt.compute(
  { "seed.n" },
  { "step", "steps_taken" },
  function(env)
    local n = tonumber(env.n) or 0
    local steps = {}
    local max = 5
    for _ = 1, max do
      n = n - 1
      local val = n <= 0 and "done" or tostring(n)
      steps[#steps+1] = val
      if val == "done" then break end  -- guard fires
    end
    return {
      step        = steps[#steps],
      steps_taken = table.concat(steps, ", ")
    }
  end
)

-- collect: in real runtime uses given countdown[*].step to gather all generations.
-- Here: reads the trace from countdown.steps_taken.
local collect = rt.soft(
  { "countdown.steps_taken" },
  { "trace" },
  function(env)
    return string.format(
      "Format the countdown trace as a JSON array. Steps: %s. Return TRACE as JSON array.",
      tostring(env.steps_taken))
  end,
  { "trace is valid json array" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    collect = { trace = '["2", "1", "done"]' }
  }
  return sims[cell_name]
end

io.write("=== BOTTOM GUARD SKIP (stem with early guard, 3→2→1→done) ===\n\n")
io.write("Note: gather semantics (given[*]) not modeled; real ct runtime required\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("seed", seed)
retort:pour("countdown", countdown)
retort:pour("collect", collect)
retort:run()
retort:dump()

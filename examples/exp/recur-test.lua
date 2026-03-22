-- recur-test.lua
-- Iterative refinement: Collatz sequence computation.
-- In the real runtime, uses a stem cell with recur (max 3 steps).
-- In this simplified runtime: modeled as a pure compute cell that
-- runs all 3 Collatz steps at once and returns the final result.
-- The step trace is also included for inspection.
-- Run with: ~/go/bin/glua recur-test.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local seed = rt.hard({ number = "7" })

-- Compute: runs 3 Collatz steps from seed.number, returns final value.
-- In real runtime this would be a stem that yields one step at a time.
local compute = rt.compute(
  { "seed.number" },
  { "result", "trace" },
  function(env)
    local n = tonumber(env.number) or 1
    local steps = {}
    for _ = 1, 3 do
      if n % 2 == 0 then n = math.floor(n / 2) else n = 3 * n + 1 end
      steps[#steps+1] = tostring(n)
    end
    return {
      result = tostring(n),
      trace  = table.concat(steps, " → ")
    }
  end
)

io.write("=== RECUR TEST (Collatz, 3 steps from 7) ===\n\n")
io.write("Note: real runtime uses stem with recur (max 3); modeled as compute here\n\n")
local retort = rt.Retort.new()
retort:pour("seed", seed)
retort:pour("compute", compute)
retort:run()
retort:dump()

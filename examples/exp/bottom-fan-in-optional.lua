-- bottom-fan-in-optional.lua
-- Bottom propagation: fan-in with optional givens — graceful degradation.
-- Producer b bottoms. Consumer has given? b.val (optional) → consumer still fires.
-- In this simplified runtime: we model optional givens by excluding them from
-- the strict givens list. The body handles missing values gracefully.
-- Run with: ~/go/bin/glua bottom-fan-in-optional.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local a = rt.hard({ val_a = "alpha" })

-- b bottoms: simulates sql: SELECT * FROM nonexistent_table_fanin_opt
local b = rt.compute(
  {},
  { "val_b" },
  function(_)
    error("table 'nonexistent_table_fanin_opt' does not exist")
  end
)

local c = rt.hard({ val_c = "gamma" })

-- Consumer: a.val_a is required; b.val_b and c.val_c are optional (given?).
-- Modeled by only including required givens in the strict list.
-- Body reads env.val_b / env.val_c defensively.
local consumer = rt.soft(
  { "a.val_a" },
  { "merged" },
  function(env)
    -- Optional: b and c may or may not be available
    local parts = { env.val_a or "?" }
    if env.val_b then parts[#parts+1] = env.val_b end
    if env.val_c then parts[#parts+1] = env.val_c end
    return "Merge available values: " .. table.concat(parts, ", ") .. ". Return MERGED."
  end,
  { "merged is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    -- Consumer fires with only a.val_a available (b bottomed, c not in strict givens)
    consumer = { merged = "alpha" }
  }
  return sims[cell_name]
end

io.write("=== BOTTOM FAN-IN OPTIONAL (b bottoms, consumer still fires) ===\n\n")
io.write("Expected: a=frozen, b=bottom, c=frozen, consumer=frozen (optional b skipped)\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("a", a)
retort:pour("b", b)
retort:pour("c", c)
retort:pour("consumer", consumer)
retort:run()
retort:dump()

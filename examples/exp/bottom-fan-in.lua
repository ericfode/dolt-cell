-- bottom-fan-in.lua
-- Bottom propagation: fan-in — 3 producers, one (b) bottoms.
-- Consumer has ALL THREE as required givens → consumer bottoms too.
-- In this simplified runtime: b=bottom, consumer stays pending (stall).
-- Run with: ~/go/bin/glua bottom-fan-in.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local a = rt.hard({ val = "alpha" })

-- b bottoms: simulates sql: SELECT * FROM nonexistent_table_fanin
local b = rt.compute(
  {},
  { "val" },
  function(_)
    error("table 'nonexistent_table_fanin' does not exist")
  end
)

local c = rt.hard({ val = "gamma" })

-- Consumer requires a.val, b.val, c.val — all required.
-- Since b is bottom, consumer cannot satisfy its givens.
-- Note: all three fields are named "val" — build_env resolves to last one.
local consumer = rt.soft(
  { "a.val", "b.val", "c.val" },
  { "merged" },
  function(env)
    return string.format(
      "Concatenate alpha, b_val, and gamma separated by commas. Got: %s",
      tostring(env.val))
  end,
  { "merged is not empty" }
)

io.write("=== BOTTOM FAN-IN (required given bottoms) ===\n\n")
io.write("Expected: b=bottom, consumer stays pending (stall)\n\n")
local retort = rt.Retort.new()
retort:pour("a", a)
retort:pour("b", b)
retort:pour("c", c)
retort:pour("consumer", consumer)
retort:run()
retort:dump()

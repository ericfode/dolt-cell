-- bottom-propagation.lua
-- Bottom propagation: source bottoms via compute error → dependents stall.
-- In the real runtime, downstream cells would transition to bottom automatically.
-- In this simplified runtime: source=bottom, downstream stay pending (stall).
-- Run with: ~/go/bin/glua bottom-propagation.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- source bottoms: simulates sql: SELECT * FROM nonexistent_table_xyz
local source = rt.compute(
  {},
  { "data" },
  function(_)
    error("table 'nonexistent_table_xyz' does not exist")
  end
)

local downstream = rt.soft(
  { "source.data" },
  { "result" },
  function(env)
    return string.format("Process \"%s\" and return it uppercased.", env.data)
  end,
  {}
)

local final = rt.soft(
  { "downstream.result" },
  { "output" },
  function(env)
    return string.format("Summarize \"%s\" in one sentence.", env.result)
  end,
  {}
)

io.write("=== BOTTOM PROPAGATION ===\n\n")
io.write("Expected: source=bottom, downstream+final stay pending (stall)\n\n")
local retort = rt.Retort.new()
retort:pour("source", source)
retort:pour("downstream", downstream)
retort:pour("final", final)
retort:run()
retort:dump()

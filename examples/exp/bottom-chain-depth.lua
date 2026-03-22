-- bottom-chain-depth.lua
-- Bottom propagation through a deep chain: root → step-1 → step-2 → step-3 → step-4.
-- Root bottoms; every downstream cell should bottom (stay pending in simplified runtime).
-- Run with: ~/go/bin/glua bottom-chain-depth.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- root bottoms: simulates sql: SELECT * FROM table_that_does_not_exist_xyz
local root = rt.compute(
  {},
  { "data" },
  function(_)
    error("table 'table_that_does_not_exist_xyz' does not exist")
  end
)

local step1 = rt.soft(
  { "root.data" },
  { "out" },
  function(env) return string.format("Echo \"%s\" verbatim.", env.data) end,
  {}
)

local step2 = rt.soft(
  { "step1.out" },
  { "out" },
  function(env) return string.format("Echo \"%s\" verbatim.", env.out) end,
  {}
)

local step3 = rt.soft(
  { "step2.out" },
  { "out" },
  function(env) return string.format("Echo \"%s\" verbatim.", env.out) end,
  {}
)

local step4 = rt.soft(
  { "step3.out" },
  { "out" },
  function(env) return string.format("Echo \"%s\" verbatim.", env.out) end,
  {}
)

io.write("=== BOTTOM CHAIN DEPTH (5 cells) ===\n\n")
io.write("Expected: root=bottom, all steps stay pending (stall)\n\n")
local retort = rt.Retort.new()
retort:pour("root", root)
retort:pour("step1", step1)
retort:pour("step2", step2)
retort:pour("step3", step3)
retort:pour("step4", step4)
retort:run()
retort:dump()

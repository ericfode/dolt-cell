-- bottom-unsatisfiable-given.lua
-- Unsatisfiable given: orphan references a yield that no cell produces.
-- The runtime cannot resolve "nowhere.nothing" — orphan stays pending forever (stall).
-- This tests that the runtime handles the unresolvable reference gracefully.
-- Run with: ~/go/bin/glua bottom-unsatisfiable-given.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({ greeting = "hello" })

-- orphan: references "nowhere.nothing" — no cell named "nowhere" exists.
-- givens_satisfied will never return true → stays pending → stall.
local orphan = rt.soft(
  { "nowhere.nothing" },
  { "result" },
  function(env)
    return string.format("Echo \"%s\" verbatim.", tostring(env.nothing))
  end,
  {}
)

io.write("=== BOTTOM UNSATISFIABLE GIVEN ===\n\n")
io.write("Expected: source=frozen, orphan stays pending (stall — 'nowhere' doesn't exist)\n\n")
local retort = rt.Retort.new()
retort:pour("source", source)
retort:pour("orphan", orphan)
retort:run()
retort:dump()

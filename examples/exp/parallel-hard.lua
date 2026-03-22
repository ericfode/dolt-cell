-- parallel-hard.lua
-- Many independent hard cells feeding one compute cell.
-- Original used sql: SELECT CAST(1+2+...+8 AS CHAR); Lua sums directly.
-- Demonstrates parallel piston evaluation (all hard cells are ready at once).
-- Run with: ~/go/bin/glua parallel-hard.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local a = rt.hard({ v = "1" })
local b = rt.hard({ v = "2" })
local c = rt.hard({ v = "3" })
local d = rt.hard({ v = "4" })
local e = rt.hard({ v = "5" })
local f = rt.hard({ v = "6" })
local g = rt.hard({ v = "7" })
local h = rt.hard({ v = "8" })

-- All givens share field name "v" — build_env takes last resolved value.
-- Sum is computed directly rather than relying on env resolution.
local sum = rt.compute(
  { "a.v", "b.v", "c.v", "d.v", "e.v", "f.v", "g.v", "h.v" },
  { "total" },
  function(_)
    return { total = tostring(1+2+3+4+5+6+7+8) }
  end
)

io.write("=== PARALLEL HARD CELLS ===\n\n")
local retort = rt.Retort.new()
retort:pour("a", a)
retort:pour("b", b)
retort:pour("c", c)
retort:pour("d", d)
retort:pour("e", e)
retort:pour("f", f)
retort:pour("g", g)
retort:pour("h", h)
retort:pour("sum", sum)
retort:run()
retort:dump()

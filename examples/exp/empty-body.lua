-- empty-body.lua
-- Edge case: hard cells with literal yields (no body/LLM needed).
-- One yields a value, one yields an empty string.
-- Run with: ~/go/bin/glua empty-body.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local bare = rt.hard({ value = "works" })

local empty_val = rt.hard({ text = "" })

io.write("=== EMPTY BODY / BARE HARD CELLS ===\n\n")
local retort = rt.Retort.new()
retort:pour("bare", bare)
retort:pour("empty_val", empty_val)
retort:run()
retort:dump()

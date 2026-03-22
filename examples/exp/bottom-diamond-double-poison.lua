-- bottom-diamond-double-poison.lua
-- Diamond where BOTH paths bottom: source → left_fail (oracle) + right_fail (SQL).
-- merge requires both — both are bottom → merge stays pending (stall).
-- Verifies the runtime doesn't double-report or deadlock.
-- Run with: ~/go/bin/glua bottom-diamond-double-poison.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({ text = "hello world" })

-- left_fail: oracle check "result is valid json array" fails on plain text → bottom
local left_fail = rt.compute(
  { "source.text" },
  { "result" },
  function(env)
    local val = env.text
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: result is not a valid json array")
    end
    return { result = val }
  end
)

-- right_fail: simulates sql: SELECT * FROM nonexistent_table_abc → bottom
local right_fail = rt.compute(
  { "source.text" },
  { "result" },
  function(_)
    error("table 'nonexistent_table_abc' does not exist")
  end
)

-- merge requires both — both are bottom → stays pending
local merge = rt.soft(
  { "left_fail.result", "right_fail.result" },
  { "combined" },
  function(env)
    return string.format("Merge %s and %s into one string.", env.result, env.result)
  end,
  {}
)

io.write("=== BOTTOM DIAMOND DOUBLE POISON (both paths bottom) ===\n\n")
io.write("Expected: left_fail=bottom, right_fail=bottom, merge stays pending (stall)\n\n")
local retort = rt.Retort.new()
retort:pour("source", source)
retort:pour("left_fail", left_fail)
retort:pour("right_fail", right_fail)
retort:pour("merge", merge)
retort:run()
retort:dump()

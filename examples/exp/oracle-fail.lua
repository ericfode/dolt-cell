-- oracle-fail.lua
-- Deterministic oracle failure: check "result is valid json array" on non-JSON.
-- In the real runtime: the check fails deterministically after each attempt,
-- exhausting retries → cell bottoms. Modeled here with a compute cell that
-- validates and errors.
-- Run with: ~/go/bin/glua oracle-fail.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local input = rt.hard({ data = "not json at all" })

-- Simulate oracle failure: the LLM echoes the input (not JSON),
-- so the "valid json array" check always fails → bottom.
local process = rt.compute(
  { "input.data" },
  { "result" },
  function(env)
    local val = env.data
    -- Oracle check: must be valid JSON array
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: result is not a valid json array (got: " .. tostring(val) .. ")")
    end
    return { result = val }
  end
)

io.write("=== ORACLE FAIL (bottom) ===\n\n")
io.write("Expected: process bottoms due to oracle failure\n\n")
local retort = rt.Retort.new()
retort:pour("input", input)
retort:pour("process", process)
retort:run()
retort:dump()

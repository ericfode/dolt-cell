-- bottom-oracle-failure.lua
-- Oracle failure exhausts retries → cell bottoms → dependent bottoms.
-- raw → parse (oracle "is valid json array" always fails) → consumer.
-- In the real runtime: parse bottoms after retry exhaustion, consumer bottoms too.
-- Modeled with compute that errors + consumer depends on it.
-- Run with: ~/go/bin/glua bottom-oracle-failure.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local raw = rt.hard({ data = "this is plain text, not json" })

-- parse: oracle "is valid json array" will never pass for plain text → bottom
local parse = rt.compute(
  { "raw.data" },
  { "parsed" },
  function(env)
    local val = env.data
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: parsed is not a valid json array (after retry exhaustion)")
    end
    return { parsed = val }
  end
)

-- consumer depends on parse.parsed → stays pending since parse bottomed
local consumer = rt.soft(
  { "parse.parsed" },
  { "report" },
  function(env)
    return string.format("Summarize %s in one sentence.", env.parsed)
  end,
  { "report is not empty" }
)

io.write("=== BOTTOM ORACLE FAILURE → DOWNSTREAM ===\n\n")
io.write("Expected: raw=frozen, parse=bottom, consumer stays pending (stall)\n\n")
local retort = rt.Retort.new()
retort:pour("raw", raw)
retort:pour("parse", parse)
retort:pour("consumer", consumer)
retort:run()
retort:dump()

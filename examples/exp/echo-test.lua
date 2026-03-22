-- echo-test.lua
-- Simple program for testing single-step claim: greeting → shout
-- Run with: ~/go/bin/glua echo-test.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local greeting = rt.hard({ message = "Hello from Cell!" })

local shout = rt.soft(
  { "greeting.message" },
  { "loud" },
  function(env)
    return string.format(
      "Convert the following text to ALL CAPS. Output only the uppercase text, nothing else.\n\nText: %s",
      env.message)
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    shout = { loud = "HELLO FROM CELL!" }
  }
  return sims[cell_name]
end

io.write("=== ECHO TEST ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("greeting", greeting)
retort:pour("shout", shout)
retort:run()
retort:dump()

-- next-test.lua
-- Simple linear chain for testing single-step cell claiming.
-- a (hard) → b (soft: reverse) → c (soft: uppercase)
-- Run with: ~/go/bin/glua next-test.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local a = rt.hard({ x = "hello" })

local b = rt.soft(
  { "a.x" },
  { "y" },
  function(env)
    return string.format("Reverse the string \"%s\". Return only the reversed string.", env.x)
  end,
  {}
)

local c = rt.soft(
  { "b.y" },
  { "z" },
  function(env)
    return string.format("Uppercase \"%s\". Return only the uppercased string.", env.y)
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    b = { y = "olleh" },
    c = { z = "OLLEH" }
  }
  return sims[cell_name]
end

io.write("=== NEXT TEST (linear chain) ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("a", a)
retort:pour("b", b)
retort:pour("c", c)
retort:run()
retort:dump()

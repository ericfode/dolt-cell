-- math-verify.lua
-- LLM solves an equation; pure compute verifies the answer.
-- Demonstrates proof-carrying computation: soft produces, compute checks.
-- Run with: ~/go/bin/glua math-verify.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local problem = rt.hard({ equation = "3x + 7 = 22" })

local solve = rt.soft(
  { "problem.equation" },
  { "x" },
  function(env)
    return string.format(
      "Solve the equation \"%s\" for x. Output ONLY the numeric value, nothing else.",
      env.equation)
  end,
  {}
)

-- Pure Lua verification: substitute x back into 3x + 7 = 22
local verify = rt.compute(
  { "solve.x" },
  { "check" },
  function(env)
    local x = tonumber(env.x)
    if x == nil then error("x is not numeric: " .. tostring(env.x)) end
    local lhs = 3 * x + 7
    local result = math.abs(lhs - 22) < 0.001 and "PASS" or "FAIL"
    return { check = result }
  end
)

local explain = rt.soft(
  { "solve.x", "verify.check" },
  { "summary" },
  function(env)
    return string.format(
      "The equation was 3x + 7 = 22. The LLM solved x = %s. Verification: %s. Write a one-sentence explanation.",
      tostring(env.x), tostring(env.check))
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    solve   = { x = "5" },
    explain = { summary = "The LLM correctly solved 3x + 7 = 22 to get x = 5, which verifies as PASS since 3(5) + 7 = 22." }
  }
  return sims[cell_name]
end

io.write("=== MATH VERIFY (proof-carrying) ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("problem", problem)
retort:pour("solve", solve)
retort:pour("verify", verify)
retort:pour("explain", explain)
retort:run()
retort:dump()

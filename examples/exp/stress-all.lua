-- stress-all.lua
-- Stress test: hard literals, pure compute, soft cells, optional givens,
-- multi-yield, and deterministic oracles. No stems to avoid stall issues.
-- Run with: ~/go/bin/glua stress-all.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local constants = rt.hard({
  pi_approx = "3.14159",
  e_approx  = "2.71828"
})

local user_input = rt.hard({
  name = "Alice",
  age  = "30"
})

local greeting = rt.soft(
  { "user_input.name", "user_input.age" },
  { "message" },
  function(env)
    return string.format(
      "Write a single-sentence birthday greeting for %s who is turning %s. Be warm but brief.",
      env.name, env.age)
  end,
  { "message is not empty" }
)

-- Replaces sql: SELECT CASE WHEN ABS(CAST('3.14159' AS DECIMAL) - 3.14159) < 0.001 THEN 'VALID' ...
local math_check = rt.compute(
  { "constants.pi_approx" },
  { "validation" },
  function(env)
    local pi = tonumber(env.pi_approx) or 0
    local result = math.abs(pi - 3.14159) < 0.001 and "VALID" or "INVALID"
    return { validation = result }
  end
)

-- Replaces sql: SELECT CAST(3.14159 + 2.71828 AS CHAR)
local compute_sum = rt.compute(
  { "constants.pi_approx", "constants.e_approx" },
  { "sum" },
  function(env)
    -- Both fields have different names here (pi_approx vs e_approx);
    -- build_env resolves by field name — both are in env by their source cell field.
    local pi = tonumber(env.pi_approx) or 0
    local e  = tonumber(env.e_approx)  or 0
    return { sum = tostring(pi + e) }
  end
)

local report = rt.soft(
  { "greeting.message", "math_check.validation", "compute_sum.sum", "user_input.name" },
  { "final" },
  function(env)
    return string.format(
      'Create a JSON summary: {"greeting": "%s", "pi_valid": "%s", "pi_plus_e": "%s", "name": "%s"}',
      tostring(env.message), tostring(env.validation), tostring(env.sum), tostring(env.name))
  end,
  { "final is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    greeting = {
      message = "Happy 30th birthday, Alice — may this decade bring you as much joy as you bring others!"
    },
    report = {
      final = '{"greeting":"Happy 30th birthday, Alice!","pi_valid":"VALID","pi_plus_e":"5.85987","name":"Alice"}'
    }
  }
  return sims[cell_name]
end

io.write("=== STRESS ALL ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("constants", constants)
retort:pour("user_input", user_input)
retort:pour("greeting", greeting)
retort:pour("math_check", math_check)
retort:pour("compute_sum", compute_sum)
retort:pour("report", report)
retort:run()
retort:dump()

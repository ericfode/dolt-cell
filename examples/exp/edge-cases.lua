-- edge-cases.lua
-- Edge case stress test: optional givens, multi-yield, json check.
-- config (optional) + data → analyze → transform → merge.
-- Optional givens: the body reads them from env if present.
-- Run with: ~/go/bin/glua edge-cases.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local config = rt.hard({ mode = "strict", limit = "100" })

local data = rt.hard({ items = "[5, 2, 8, 1, 9, 3]" })

-- Optional config.mode — include config in givens so env.mode is available,
-- but the cell can also operate without it.
local analyze = rt.soft(
  { "data.items", "config.mode" },
  { "summary" },
  function(env)
    local mode_clause = env.mode and ("If mode is \"" .. env.mode .. "\", validate all are positive integers. ") or ""
    return string.format(
      "Analyze %s. %sCount elements and find the sum. Return: \"count=N sum=M valid=true/false\"",
      env.items, mode_clause)
  end,
  { "summary is not empty" }
)

local transform = rt.soft(
  { "data.items", "config.limit" },
  { "result" },
  function(env)
    return string.format(
      "Take %s and double each number. If any doubled value exceeds %s, mark it as \"OVER\". " ..
      "Return a JSON array of the results.",
      env.items, tostring(env.limit or "100"))
  end,
  { "result is valid json array" }
)

local merge_cell = rt.soft(
  { "analyze.summary", "transform.result" },
  { "report" },
  function(env)
    return string.format(
      "Combine the analysis \"%s\" with the transformation %s into a single JSON object " ..
      "with fields \"analysis\" and \"transformation\".",
      tostring(env.summary), tostring(env.result))
  end,
  { "report is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    analyze   = { summary = "count=6 sum=28 valid=true" },
    transform = { result  = "[10, 4, 16, 2, 18, 6]" },
    merge_cell = {
      report = '{"analysis":"count=6 sum=28 valid=true","transformation":[10,4,16,2,18,6]}'
    }
  }
  return sims[cell_name]
end

io.write("=== EDGE CASES (optional givens, multi-yield) ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("config", config)
retort:pour("data", data)
retort:pour("analyze", analyze)
retort:pour("transform", transform)
retort:pour("merge_cell", merge_cell)
retort:run()
retort:dump()

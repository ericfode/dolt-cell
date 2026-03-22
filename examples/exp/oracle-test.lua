-- oracle-test.lua
-- Test various oracle types: deterministic (json check) and semantic (~).
-- seed → sort-json → summarize.
-- Run with: ~/go/bin/glua oracle-test.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local seed = rt.hard({ data = "[3, 1, 4, 1, 5, 9, 2, 6]" })

local sort_json = rt.soft(
  { "seed.data" },
  { "sorted" },
  function(env)
    return string.format(
      "Sort the following JSON array of numbers in ascending order. " ..
      "Output ONLY a JSON array of numbers, nothing else.\n\nData: %s",
      env.data)
  end,
  { "sorted is valid json array",
    "sorted is a permutation of data",
    "sorted is in ascending order" }
)

local summarize = rt.soft(
  { "seed.data", "sort_json.sorted" },
  { "report" },
  function(env)
    return string.format(
      "The original data was %s and the sorted result is %s.\n\n" ..
      "Write a JSON object with fields: \"count\" (number of elements), " ..
      "\"min\" (smallest), \"max\" (largest), \"sorted\" (the sorted array).",
      tostring(env.data), tostring(env.sorted))
  end,
  { "report is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    sort_json = { sorted = "[1, 1, 2, 3, 4, 5, 6, 9]" },
    summarize = {
      report = '{"count":8,"min":1,"max":9,"sorted":[1,1,2,3,4,5,6,9]}'
    }
  }
  return sims[cell_name]
end

io.write("=== ORACLE TEST ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("seed", seed)
retort:pour("sort_json", sort_json)
retort:pour("summarize", summarize)
retort:run()
retort:dump()

-- sort-proof.lua
-- Sort with verification: data → sort → report
-- Run with: ~/go/bin/glua sort-proof.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local data = rt.hard({ items = "[4, 1, 7, 3, 9, 2]" })

local sort_cell = rt.soft(
  { "data.items" },
  { "sorted" },
  function(env)
    return string.format("Sort %s in ascending order.", env.items)
  end,
  { "sorted is a permutation of items", "sorted is in ascending order" }
)

local report = rt.soft(
  { "sort_cell.sorted" },
  { "summary" },
  function(env)
    return string.format("Write a one-sentence summary of the sort result: %s", tostring(env.sorted))
  end
)

local function simulate_llm(cell_name, _, _, _)
  if cell_name == "sort_cell" then
    return { sorted = "[1, 2, 3, 4, 7, 9]" }
  elseif cell_name == "report" then
    return { summary = "The six integers were sorted in ascending order: 1, 2, 3, 4, 7, 9." }
  end
end

io.write("=== SORT PROOF ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("data", data)
retort:pour("sort_cell", sort_cell)
retort:pour("report", report)
retort:run()
retort:dump()

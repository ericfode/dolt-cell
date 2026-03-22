-- diamond-dep.lua
-- Diamond dependency: source → path_left + path_right → merge.
-- Tests that merge only runs after both branches are frozen.
-- Pattern: A→B, A→C, B→D, C→D.
-- Run with: ~/go/bin/glua diamond-dep.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({ data = "The quick brown fox" })

local path_left = rt.soft(
  { "source.data" },
  { "words" },
  function(env)
    return string.format("Count the words in \"%s\". Return ONLY the number.", env.data)
  end,
  {}
)

local path_right = rt.soft(
  { "source.data" },
  { "chars" },
  function(env)
    return string.format(
      "Count the characters (including spaces) in \"%s\". Return ONLY the number.", env.data)
  end,
  {}
)

local merge = rt.soft(
  { "path_left.words", "path_right.chars" },
  { "ratio" },
  function(env)
    return string.format(
      "Compute the average word length: divide %s characters by %s words. " ..
      "Round to 1 decimal place. Return ONLY the number.",
      tostring(env.chars), tostring(env.words))
  end,
  { "ratio is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    path_left  = { words = "4" },
    path_right = { chars = "19" },
    merge      = { ratio = "4.8" }
  }
  return sims[cell_name]
end

io.write("=== DIAMOND DEPENDENCY ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("source", source)
retort:pour("path_left", path_left)
retort:pour("path_right", path_right)
retort:pour("merge", merge)
retort:run()
retort:dump()

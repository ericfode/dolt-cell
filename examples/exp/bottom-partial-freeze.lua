-- bottom-partial-freeze.lua
-- Partial freeze: independent branches, one succeeds, one fails.
-- good_branch succeeds; bad_branch bottoms (oracle failure).
-- good_leaf runs; bad_leaf stays pending (stall).
-- Program reaches quiescence with mixed frozen/pending cells.
-- Run with: ~/go/bin/glua bottom-partial-freeze.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local input = rt.hard({ text = "Four score and seven years ago" })

local good_branch = rt.soft(
  { "input.text" },
  { "words" },
  function(env)
    return string.format("Count the words in \"%s\". Return ONLY the integer.", env.text)
  end,
  { "words is not empty" }
)

-- bad_branch bottoms: returns text verbatim, oracle wants json array
local bad_branch = rt.compute(
  { "input.text" },
  { "data" },
  function(env)
    local val = env.text
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: data is not a valid json array")
    end
    return { data = val }
  end
)

local good_leaf = rt.soft(
  { "good_branch.words" },
  { "report" },
  function(env)
    return string.format("The word count is %s. Write one sentence about it.", env.words)
  end,
  { "report is not empty" }
)

local bad_leaf = rt.soft(
  { "bad_branch.data" },
  { "report" },
  function(env)
    return string.format("Summarize %s in one sentence.", env.data)
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    good_branch = { words = "7" },
    good_leaf   = { report = "The text contains 7 words, a phrase from Lincoln's Gettysburg Address." }
  }
  return sims[cell_name]
end

io.write("=== BOTTOM PARTIAL FREEZE (mixed frozen/pending) ===\n\n")
io.write("Expected: good_branch=frozen, bad_branch=bottom, good_leaf=frozen, bad_leaf=pending\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("input", input)
retort:pour("good_branch", good_branch)
retort:pour("bad_branch", bad_branch)
retort:pour("good_leaf", good_leaf)
retort:pour("bad_leaf", bad_leaf)
retort:run()
retort:dump()

-- bottom-diamond-poison.lua
-- Diamond with one poisoned path: source → count_words (succeeds) + force_fail (bottoms).
-- merge requires both — so merge stays pending (stall).
-- force_fail bottoms via oracle failure (check n is valid json array, but n is text).
-- Run with: ~/go/bin/glua bottom-diamond-poison.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({ text = "The quick brown fox jumps over the lazy dog" })

local count_words = rt.soft(
  { "source.text" },
  { "n" },
  function(env)
    return string.format("Count the words in \"%s\". Return ONLY the integer.", env.text)
  end,
  { "n is not empty" }
)

-- force_fail: returns text verbatim — oracle "is valid json array" always fails → bottom
local force_fail = rt.compute(
  { "source.text" },
  { "n" },
  function(env)
    local val = env.text
    -- Oracle: must be valid JSON array — it never will be
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: n is not a valid json array")
    end
    return { n = val }
  end
)

-- merge requires both count_words.n AND force_fail.n
-- force_fail is bottom → merge stays pending
local merge = rt.soft(
  { "count_words.n", "force_fail.n" },
  { "summary" },
  function(env)
    return string.format(
      "Combine word count %s with parsed data into a JSON object.",
      tostring(env.n))
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    count_words = { n = "9" }
  }
  return sims[cell_name]
end

io.write("=== BOTTOM DIAMOND POISON (one path bottoms) ===\n\n")
io.write("Expected: count_words=frozen, force_fail=bottom, merge stays pending (stall)\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("source", source)
retort:pour("count_words", count_words)
retort:pour("force_fail", force_fail)
retort:pour("merge", merge)
retort:run()
retort:dump()

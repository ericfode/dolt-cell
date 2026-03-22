-- multi-yield.lua
-- Test multiple yields from one soft cell, followed by a pure compute check.
-- Original used sql: SELECT CASE WHEN ... to validate word_count > 0.
-- Lua compute cell does the same check directly.
-- Run with: ~/go/bin/glua multi-yield.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local input = rt.hard({
  text = "The quick brown fox jumps over the lazy dog near the riverbank at sunset."
})

local analyze = rt.soft(
  { "input.text" },
  { "word_count", "char_count", "longest_word" },
  function(env)
    return string.format(
      "Analyze the following text. Return exactly three lines, each with ONLY the value:\n" ..
      "Line 1: word count (just the number)\n" ..
      "Line 2: character count including spaces (just the number)\n" ..
      "Line 3: the longest word (just the word)\n\nText: %s",
      env.text)
  end,
  {}
)

-- Verify word_count is a positive integer (replaces the original sql: check)
local verify_count = rt.compute(
  { "analyze.word_count" },
  { "check" },
  function(env)
    local n = tonumber(env.word_count)
    if n == nil or n <= 0 then
      error("word_count must be a positive integer, got: " .. tostring(env.word_count))
    end
    return { check = "PASS" }
  end
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    analyze = {
      word_count   = "13",
      char_count   = "73",
      longest_word = "riverbank"
    }
  }
  return sims[cell_name]
end

io.write("=== MULTI-YIELD ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("input", input)
retort:pour("analyze", analyze)
retort:pour("verify_count", verify_count)
retort:run()
retort:dump()

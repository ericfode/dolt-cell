-- haiku.lua
-- Haiku generation: hard literal + soft + pure compute + oracle critique
-- Mirrors haiku-reference.cell
-- Run with: ~/go/bin/glua haiku.lua

local rt = dofile("cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

-- Hard literal: pure value, no computation
local topic = rt.hard({
  subject = "autumn rain on a temple roof"
})

-- Soft cell: LLM-evaluated prompt
-- body_fn(env) returns the prompt string sent to the LLM
local compose = rt.soft(
  { "topic.subject" },              -- givens
  { "poem" },                       -- yields
  function(env)
    return string.format(
      "Write a haiku about %s. " ..
      "Follow the traditional 5-7-5 syllable structure across exactly three lines. " ..
      "Return only the three lines of the haiku, separated by newlines.",
      env.subject
    )
  end,
  { "poem contains at least 2 newlines" }
)

-- Pure compute: count words (replaces sql: in reference)
-- Demonstrates string.gmatch for text processing
local count_words = rt.compute(
  { "compose.poem" },
  { "total" },
  function(env)
    local n = 0
    for _ in string.gmatch(tostring(env.poem), "%S+") do
      n = n + 1
    end
    return { total = n }
  end
)

-- Soft cell (oracle/critic): takes poem + word count, yields review
local critique = rt.soft(
  { "compose.poem", "count_words.total" },
  { "review" },
  function(env)
    return string.format(
      "Critique this haiku (word count: %s):\n\n%s\n\n" ..
      "Evaluate: Does it follow 5-7-5 syllable structure? " ..
      "Does the imagery evoke the subject? " ..
      "Is there a seasonal reference (kigo)? " ..
      "Is there a cutting word (kireji) or pause between images? " ..
      "Rate overall quality from 1-5.",
      tostring(env.total), tostring(env.poem)
    )
  end,
  { "review contains at least 2 sentences" }
)

-- ============================================================
-- LLM SIMULATOR
-- Substitutes for real LLM calls so the file runs standalone.
-- In production, each soft cell sends its prompt to the piston.
-- ============================================================
local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "compose" then
    return {
      poem = "Temple eaves weeping\nAncient cedar drinks the grey\nStone holds what falls"
    }
  elseif cell_name == "critique" then
    local poem = env.poem or "(unknown)"
    local total = env.total or 0
    return {
      review = string.format(
        "This haiku demonstrates strong imagery and seasonal awareness. " ..
        "The structure follows 5-7-5 (score 4/5). " ..
        "The word count is %d. " ..
        "The kigo 'autumn rain' is implied through 'weeping' and 'grey'. " ..
        "A natural kireji pause appears between lines 2 and 3. " ..
        "Overall quality: 4/5.",
        total
      )
    }
  end
  return nil
end

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== HAIKU PROGRAM ===\n\n")

local retort = rt.Retort.new()
retort.llm_sim = simulate_llm

retort:pour("topic",       topic)
retort:pour("compose",     compose)
retort:pour("count_words", count_words)
retort:pour("critique",    critique)

retort:run()
retort:dump()

-- ============================================================
-- BONUS: Show cell table structure directly
-- Demonstrates "tables as universal data structure"
-- ============================================================
io.write("\n=== CELL TABLE STRUCTURE ===\n")
io.write("topic.kind    = " .. topic.kind .. "\n")
io.write("topic.effect  = " .. topic.effect .. " (PURE=" .. rt.PURE .. ")\n")
io.write("compose.kind  = " .. compose.kind .. "\n")
io.write("compose.givens[1] = " .. (compose.givens[1] or "nil") .. "\n")
io.write("count_words.kind = " .. count_words.kind .. "\n")
io.write("count_words.givens[1] = " .. (count_words.givens[1] or "nil") .. "\n")

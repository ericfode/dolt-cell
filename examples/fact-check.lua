-- fact-check.lua
-- Fact checking: answer → simplify (stem for reading-level adaptation)
-- Run with: ~/go/bin/glua fact-check.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local topic = rt.hard({
  question = "What are the three laws of thermodynamics? Explain each in one sentence."
})

local answer = rt.soft(
  { "topic.question" },
  { "explanation" },
  function(env)
    return string.format("Answer %s clearly and accurately.", env.question)
  end,
  { "explanation is not empty" }
)

-- "stem" in the original but only runs once — use soft
local simplify = rt.soft(
  { "answer.explanation" },
  { "summary" },
  function(env)
    return string.format(
      "Rewrite this at a 6th-grade reading level. Keep it accurate but use simple words:\n\n%s",
      tostring(env.explanation)
    )
  end,
  { "summary is not empty" }
)

local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "answer" then
    return {
      explanation =
        "1. Zeroth Law: If two systems are each in thermal equilibrium with a third, " ..
        "they are in equilibrium with each other. " ..
        "2. First Law: Energy cannot be created or destroyed, only transformed. " ..
        "3. Second Law: The total entropy of an isolated system always increases. " ..
        "4. Third Law: As temperature approaches absolute zero, entropy approaches a minimum."
    }
  elseif cell_name == "simplify" then
    return {
      summary =
        "1. If thing A is the same temperature as thing C, and thing B is too, then A and B " ..
        "are the same temperature. 2. You can't make energy from nothing — you can only change " ..
        "it from one form to another. 3. Things naturally get messier over time. " ..
        "4. You can never cool something down to absolutely zero degrees."
    }
  end
  return nil
end

io.write("=== FACT CHECK PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("topic", topic)
retort:pour("answer", answer)
retort:pour("simplify", simplify)
retort:run()
retort:dump()

-- chain-reason.lua
-- Multi-step LLM reasoning chain: topic → define → argue-for + argue-against → synthesize.
-- Demonstrates a fork-and-join DAG (both parallel branches feed the synthesis).
-- Run with: ~/go/bin/glua chain-reason.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local topic = rt.hard({ subject = "the trolley problem" })

local define = rt.soft(
  { "topic.subject" },
  { "definition" },
  function(env)
    return string.format(
      "Define \"%s\" in exactly two sentences. Be precise and academic.",
      env.subject)
  end,
  {}
)

local argue_for = rt.soft(
  { "topic.subject", "define.definition" },
  { "argument" },
  function(env)
    return string.format(
      "Given this definition of \"%s\": %s\n\n" ..
      "Write a compelling argument FOR the utilitarian position (pull the lever). Three sentences max.",
      env.subject, tostring(env.definition))
  end,
  {}
)

local argue_against = rt.soft(
  { "topic.subject", "define.definition" },
  { "argument" },
  function(env)
    return string.format(
      "Given this definition of \"%s\": %s\n\n" ..
      "Write a compelling argument AGAINST pulling the lever (deontological position). Three sentences max.",
      env.subject, tostring(env.definition))
  end,
  {}
)

local synthesize = rt.soft(
  { "argue_for.argument", "argue_against.argument" },
  { "synthesis" },
  function(env)
    -- Both sources have field "argument" — build_env resolves to the last one.
    -- In the real runtime, givens are namespaced. Here we use explicit values in the prompt.
    return string.format(
      "You have two arguments about the trolley problem.\n\n" ..
      "FOR pulling the lever: %s\n\n" ..
      "AGAINST pulling the lever: %s\n\n" ..
      "Write a balanced two-sentence synthesis that acknowledges both positions without taking a side.",
      tostring(env.argument), tostring(env.argument))
  end,
  { "synthesis is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    define = {
      definition = "The trolley problem is a moral dilemma in which a person must choose " ..
        "between allowing a runaway trolley to kill five people or diverting it to kill one. " ..
        "It serves as a thought experiment to explore utilitarian versus deontological ethics."
    },
    argue_for = {
      argument = "Pulling the lever maximizes overall welfare by saving five lives at the cost of one. " ..
        "Utilitarian ethics demands we minimize total harm, and inaction that causes five deaths is worse than action causing one. " ..
        "Rational agents ought to prefer outcomes that preserve the greatest number of lives."
    },
    argue_against = {
      argument = "Pulling the lever makes you a moral agent directly responsible for one person's death. " ..
        "Deontological ethics holds that actively causing harm is categorically different from allowing harm to occur. " ..
        "Using a person as a mere means to save others violates their inherent dignity."
    },
    synthesize = {
      synthesis = "Both positions recognize the moral weight of human life, but disagree on whether active intervention or restraint better honors that weight. " ..
        "The dilemma ultimately reveals that our intuitions about harm, agency, and responsibility resist any single ethical framework."
    }
  }
  return sims[cell_name]
end

io.write("=== CHAIN REASONING (trolley problem) ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("topic", topic)
retort:pour("define", define)
retort:pour("argue_for", argue_for)
retort:pour("argue_against", argue_against)
retort:pour("synthesize", synthesize)
retort:run()
retort:dump()

-- parallel-research.lua
-- Parallel research: multiple stem investigators + synthesis via gather
-- Demonstrates stem cells for parallel work and gather pattern.
-- Run with: ~/go/bin/glua parallel-research.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local topic = rt.hard({
  question = "What are the most promising approaches to AI alignment?"
})

-- Three parallel investigators (in real runtime, dispatched simultaneously)
-- The original .cell used a stem with max 3, but parallel soft cells
-- better model the actual semantics: independent, concurrent research.
local investigate_1 = rt.soft(
  { "topic.question" },
  { "finding" },
  function(env)
    return string.format(
      "Research a distinct aspect of: %s\nFocus on training-based approaches. " ..
      "Return one substantive finding with evidence.", env.question)
  end
)

local investigate_2 = rt.soft(
  { "topic.question" },
  { "finding" },
  function(env)
    return string.format(
      "Research a distinct aspect of: %s\nFocus on interpretability approaches. " ..
      "Return one substantive finding with evidence.", env.question)
  end
)

local investigate_3 = rt.soft(
  { "topic.question" },
  { "finding" },
  function(env)
    return string.format(
      "Research a distinct aspect of: %s\nFocus on oversight and verification approaches. " ..
      "Return one substantive finding with evidence.", env.question)
  end
)

-- Synthesize: gathers all findings
local synthesize = rt.soft(
  { "investigate_1.finding", "investigate_2.finding", "investigate_3.finding" },
  { "summary" },
  function(env)
    return string.format(
      "Synthesize these research findings about AI alignment:\n\n%s\n\n" ..
      "Identify agreements, contradictions, and gaps.",
      tostring(env.finding)
    )
  end,
  { "summary is not empty" }
)

local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "investigate_1" then
    return { finding = "Constitutional AI trains models to follow principles via self-critique. " ..
      "Anthropic's research shows it reduces harmful outputs by 50-80% compared to RLHF alone." }
  elseif cell_name == "investigate_2" then
    return { finding = "Mechanistic interpretability aims to reverse-engineer neural network " ..
      "computations. Recent work on sparse autoencoders has identified human-interpretable features." }
  elseif cell_name == "investigate_3" then
    return { finding = "Debate and amplification use AI systems to check each other's reasoning. " ..
      "Irving et al. showed that debate helps non-experts judge complex arguments." }
  elseif cell_name == "synthesize" then
    return {
      summary = "Three complementary approaches emerge: Constitutional AI (behavioral training), " ..
        "mechanistic interpretability (understanding internals), and debate (external verification). " ..
        "These address different layers — behavior, mechanism, and oversight — suggesting a " ..
        "defense-in-depth strategy rather than any single solution."
    }
  end
  return nil
end

io.write("=== PARALLEL RESEARCH PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("topic", topic)
retort:pour("investigate_1", investigate_1)
retort:pour("investigate_2", investigate_2)
retort:pour("investigate_3", investigate_3)
retort:pour("synthesize", synthesize)
retort:run()
retort:dump()

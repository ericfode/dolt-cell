-- research-index.lua
-- Research DAG: parallel scans → cross-reference → assess → build index
-- Demonstrates wide parallel DAGs (3 independent scans feed synthesis).
-- Run with: ~/go/bin/glua research-index.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local question = rt.hard({
  topic = "How do production systems verify LLM outputs? Survey approaches, tools, and tradeoffs."
})

-- Three parallel research scans
local scan_academic = rt.soft(
  { "question.topic" },
  { "papers" },
  function(env)
    return string.format(
      "Survey academic research on: %s\n" ..
      "List 6-8 key papers with one-sentence summaries. JSON array format.", env.topic)
  end,
  { "papers is a valid JSON array" }
)

local scan_industry = rt.soft(
  { "question.topic" },
  { "tools" },
  function(env)
    return string.format(
      "Survey production tools for LLM output verification: " ..
      "Guardrails AI, NeMo, LMQL, Guidance, Outlines, Instructor. JSON array format.", env.topic)
  end,
  { "tools is a valid JSON array" }
)

local scan_patterns = rt.soft(
  { "question.topic" },
  { "patterns" },
  function(env)
    return string.format(
      "Identify recurring design patterns for LLM verification: " ..
      "structural, semantic, statistical, adversarial, human-in-loop. JSON array format.", env.topic)
  end,
  { "patterns is a valid JSON array" }
)

-- Cross-reference: depends on all three scans
local cross_reference = rt.soft(
  { "scan_academic.papers", "scan_industry.tools", "scan_patterns.patterns" },
  { "matrix" },
  function(env)
    return string.format(
      "Cross-reference: for each tool in %s, identify which patterns from %s " ..
      "it implements and which papers from %s it draws from. Markdown table.",
      tostring(env.tools), tostring(env.patterns), tostring(env.papers))
  end,
  { "matrix is not empty" }
)

-- Assess for cell language
local assess = rt.soft(
  { "scan_patterns.patterns", "cross_reference.matrix" },
  { "recommendations" },
  function(env)
    return string.format(
      "Given patterns %s and landscape %s, what verification approaches " ..
      "should Cell adopt? Rank by impact × ease. 5 items max.",
      tostring(env.patterns), tostring(env.matrix))
  end,
  { "recommendations is not empty" }
)

-- Build final index
local build_index = rt.soft(
  { "scan_academic.papers", "scan_industry.tools", "scan_patterns.patterns",
    "cross_reference.matrix", "assess.recommendations" },
  { "index" },
  function(env)
    return "Compile a structured research index from all upstream findings. " ..
      "Sections: Executive Summary, Academic Landscape, Production Tools, " ..
      "Design Patterns, Cross-Reference Matrix, Recommendations."
  end,
  { "index is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    scan_academic = { papers = '[{"name":"RLHF","approach":"reward models","key_insight":"human feedback alignment"}]' },
    scan_industry = { tools = '[{"name":"Guardrails AI","type":"framework","mechanism":"validators + re-ask"}]' },
    scan_patterns = { patterns = '[{"name":"schema validation","category":"structural","when":"structured output"}]' },
    cross_reference = { matrix = "| Tool | Patterns | Papers |\n|------|----------|--------|\n| Guardrails | schema validation | RLHF |" },
    assess = { recommendations = "1. Schema validation (high impact, easy)\n2. Semantic oracles (high impact, medium)\n3. Statistical monitoring (medium, medium)" },
    build_index = { index = "# LLM Output Verification Research Index\n\n## Executive Summary\nThree approaches dominate: structural validation, semantic checking, and statistical monitoring." },
  }
  return sims[cell_name]
end

io.write("=== RESEARCH INDEX PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("question", question)
retort:pour("scan_academic", scan_academic)
retort:pour("scan_industry", scan_industry)
retort:pour("scan_patterns", scan_patterns)
retort:pour("cross_reference", cross_reference)
retort:pour("assess", assess)
retort:pour("build_index", build_index)
retort:run()
retort:dump()

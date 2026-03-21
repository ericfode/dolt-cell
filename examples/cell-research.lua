-- cell-research.lua
-- Cell researching itself: survey state → survey reviews → identify gaps
-- → research prior art → synthesize plan. Self-improvement as DAG.
-- Run with: ~/go/bin/glua cell-research.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local survey_state = rt.soft(
  {},
  { "summary" },
  function(_)
    return "Read the current Cell runtime design and implementation state. " ..
      "Produce structured summary: BUILT (working), DESIGNED (not built), UNDESIGNED (gaps). " ..
      "Cite file names and line counts."
  end
)

local survey_reviews = rt.soft(
  {},
  { "findings" },
  function(_)
    return "Read adversarial review documents. For each reviewer: " ..
      "(1) v1 concerns resolved by v2, (2) new v2 concerns, " ..
      "(3) whether those are still open. Focus on OPEN concerns."
  end
)

local identify_gaps = rt.soft(
  { "survey_state.summary", "survey_reviews.findings" },
  { "gaps" },
  function(env)
    return string.format(
      "Given state: %s\nAnd review concerns: %s\n\n" ..
      "Identify 5 most critical gaps. For each: what's missing, why it matters, " ..
      "how hard to fix, who should fix it. Rank by impact × feasibility.",
      tostring(env.summary), tostring(env.findings))
  end
)

local research_prior_art = rt.soft(
  { "identify_gaps.gaps" },
  { "research" },
  function(env)
    return string.format(
      "For top 3 gaps: %s\n\nResearch prior art from: Airflow, Prefect, Temporal, " ..
      "Dagster, LangGraph, CrewAI, AutoGen. For each gap: 2-3 approaches with tradeoffs.",
      tostring(env.gaps))
  end
)

local synthesize = rt.soft(
  { "identify_gaps.gaps", "research_prior_art.research" },
  { "plan" },
  function(env)
    return string.format(
      "Gaps: %s\nPrior art: %s\n\n" ..
      "Write 5-item sprint plan ordered by priority. For each: what to build, why, " ..
      "effort estimate, acceptance criteria, files to modify. " ..
      "Item 1 must be immediately actionable by a polecat.",
      tostring(env.gaps), tostring(env.research))
  end
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    survey_state = { summary = "BUILT: ct pour/status/yields/watch, cell parser v2, retort schema. " ..
      "DESIGNED: crystallization, autopour. UNDESIGNED: cross-program givens, effect inference." },
    survey_reviews = { findings = "OPEN: Mara — no formal proof of termination. " ..
      "Deng — SQL injection in procedures.sql. Ravi — no observability/metrics." },
    identify_gaps = { gaps = "1. SQL injection in procedures.sql (HIGH, quick fix)\n" ..
      "2. No termination proof (HIGH, needs Lean work)\n" ..
      "3. No metrics/observability (MEDIUM, moderate effort)" },
    research_prior_art = { research = "1. SQL injection: Temporal uses parameterized queries. " ..
      "2. Termination: Airflow uses DAG depth limits. 3. Observability: Dagster has built-in metrics." },
    synthesize = { plan = "1. Fix SQL injection in procedures.sql (2h, parameterize all queries)\n" ..
      "2. Add DAG depth limit to eval loop (4h)\n3. Add basic metrics counters (8h)\n" ..
      "4. Prove termination in Lean (2d)\n5. Stretch: cross-program givens design doc" },
  }
  return sims[cell_name]
end

io.write("=== CELL SELF-RESEARCH PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("survey_state", survey_state)
retort:pour("survey_reviews", survey_reviews)
retort:pour("identify_gaps", identify_gaps)
retort:pour("research_prior_art", research_prior_art)
retort:pour("synthesize", synthesize)
retort:run()
retort:dump()

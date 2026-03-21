-- design-doc.lua
-- Design document generator: request → research → draft → review → final
-- Demonstrates complex DAG with parallel research and iterative review.
-- Run with: ~/go/bin/glua design-doc.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local request = rt.hard({
  feature = "Add a ct watch command that shows a live TUI dashboard of all programs " ..
    "and their cell states, updating every 2 seconds",
  constraints = "Must use bubbletea v2. Must handle 100+ cells without lag. " ..
    "Must show frozen yields inline."
})

-- Research: single soft cell (original was stem with max 3, but runtime
-- stalls on multi-generation stems; a real runtime would dispatch 3 pistons)
local research = rt.soft(
  { "request.feature", "request.constraints" },
  { "prior_art", "api_surface", "risks" },
  function(env)
    return string.format(
      "Research: %s\nConstraints: %s\n\n" ..
      "Investigate: 1) Prior art 2) API surface (bubbletea components) 3) Technical risks",
      env.feature, env.constraints)
  end,
  { "prior_art is not empty" }
)

local draft = rt.soft(
  { "request.feature", "request.constraints", "research.prior_art", "research.risks" },
  { "doc", "sections" },
  function(env)
    return string.format(
      "Write a design document for: %s\n" ..
      "Prior art: %s\nRisks: %s\n\n" ..
      "Sections: Problem Statement, Proposed Solution, Architecture, " ..
      "Data Flow, Error Handling, Testing Strategy, Open Questions.",
      env.feature, tostring(env.prior_art), tostring(env.risks))
  end,
  { "doc is not empty" }
)

local review = rt.soft(
  { "draft.doc", "request.constraints" },
  { "verdict", "feedback" },
  function(env)
    return string.format(
      "Review this design against constraints: %s\n\n%s\n\n" ..
      "Check: addresses constraints? concrete data structures? " ..
      "complete error handling? realistic testing?\n" ..
      "Return APPROVED or NEEDS_REVISION, then detailed feedback.",
      tostring(env.constraints), tostring(env.doc))
  end
)

local final = rt.soft(
  { "draft.doc", "review.feedback", "review.verdict" },
  { "document" },
  function(env)
    return string.format(
      "Produce final design doc. Start from draft, incorporate review feedback.\n" ..
      "Verdict: %s\nFeedback: %s\nDraft: %s",
      tostring(env.verdict), tostring(env.feedback), tostring(env.doc))
  end,
  { "document is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    research = {
      prior_art = "ct status exists (table view), lazygit uses bubbletea for git TUI",
      api_surface = "viewport, table, spinner components from bubbletea",
      risks = "Dolt query latency >100ms could cause UI jank at 2s refresh"
    },
    draft = {
      doc = "# ct watch Design\n\n## Problem\nNeed live dashboard for cell state monitoring.\n\n" ..
        "## Solution\nBubbletea TUI with table component, 2s poll interval.\n\n" ..
        "## Architecture\nModel: cellState map, Update: poll + render, View: table.",
      sections = "Problem, Solution, Architecture, Data Flow, Error Handling, Testing"
    },
    review = {
      verdict = "APPROVED",
      feedback = "Design is solid. Minor: add graceful degradation when Dolt is slow."
    },
    final = {
      document = "# ct watch Design (Final)\n\n## Problem\nLive cell state monitoring.\n\n" ..
        "## Solution\nBubbletea TUI, 2s poll, graceful degradation on Dolt latency.\n\n" ..
        "Approved with minor feedback incorporated."
    },
  }
  return sims[cell_name]
end

io.write("=== DESIGN DOC GENERATOR ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("request", request)
retort:pour("research", research)
retort:pour("draft", draft)
retort:pour("review", review)
retort:pour("final", final)
retort:run()
retort:dump()

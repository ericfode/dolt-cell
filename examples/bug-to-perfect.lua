-- bug-to-perfect.lua
-- Full bug fix cycle: diagnose → implement → review → ship
-- The Cell equivalent of the mol-bug-to-perfect formula.
-- Run with: ~/go/bin/glua bug-to-perfect.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local bug = rt.hard({
  id = "REPLACE_WITH_BUG_ID",
  description = "REPLACE_WITH_BUG_DESCRIPTION"
})

local diagnose = rt.soft(
  { "bug.id", "bug.description" },
  { "root_cause", "go_fix", "lean_fix", "test_plan" },
  function(env)
    return string.format(
      "Diagnose bug %s: %s\n\n" ..
      "Determine: 1) Root cause (file, function, what's wrong) " ..
      "2) Go fix (exact code change) 3) Lean model change if needed " ..
      "4) Test plan (what proves it's fixed). Be concrete.",
      env.id, env.description)
  end,
  { "root_cause is not empty" }
)

local implement = rt.soft(
  { "diagnose.go_fix", "diagnose.lean_fix", "diagnose.test_plan" },
  { "code_change", "test_result", "build_status" },
  function(env)
    return string.format(
      "Implement the fix: %s\n\n" ..
      "1. Apply Go code change 2. Build 3. Update Lean if needed: %s\n" ..
      "4. Run tests 5. Add test per: %s\n\nReport changes, build output, test output.",
      tostring(env.go_fix), tostring(env.lean_fix), tostring(env.test_plan))
  end,
  { "build_status is not empty" }
)

local review = rt.soft(
  { "bug.description", "implement.code_change", "implement.test_result" },
  { "grade", "feedback" },
  function(env)
    return string.format(
      "Review bug fix for: %s\nChanges: %s\nTests: %s\n\n" ..
      "Grade A-F on: Feynman (minimal?), Dijkstra (Go matches Lean?), " ..
      "Hoare (test coverage?), Wadler (code quality?), Sussman (composability?). " ..
      "All A → grade='A', otherwise grade='REVISE' with specific feedback.",
      tostring(env.description), tostring(env.code_change), tostring(env.test_result))
  end
)

local ship = rt.soft(
  { "review.grade", "review.feedback", "implement.code_change" },
  { "status" },
  function(env)
    return string.format(
      "Grade: %s. %s\n" ..
      "If A: commit, push, close bug. If not A: report feedback and remaining work.",
      tostring(env.grade),
      env.grade == "A" and "Ship it." or "Feedback: " .. tostring(env.feedback))
  end,
  { "status is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    diagnose = {
      root_cause = "Off-by-one in parse.go:parseGivens — skips last given field",
      go_fix = "parse.go:145: change `i < len(givens)-1` to `i < len(givens)`",
      lean_fix = "",
      test_plan = "Add TestParseMultipleGivens with 3 givens, verify all 3 parsed"
    },
    implement = {
      code_change = "Fixed parse.go:145 loop bound, added TestParseMultipleGivens",
      test_result = "PASS (12/12 tests)",
      build_status = "ok"
    },
    review = { grade = "A", feedback = "Clean fix, good test coverage." },
    ship = { status = "Committed: fix parse.go off-by-one in given parsing. Tests pass." },
  }
  return sims[cell_name]
end

io.write("=== BUG-TO-PERFECT PIPELINE ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("bug", bug)
retort:pour("diagnose", diagnose)
retort:pour("implement", implement)
retort:pour("review", review)
retort:pour("ship", ship)
retort:run()
retort:dump()

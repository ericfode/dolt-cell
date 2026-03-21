-- code-review.lua
-- Code review DAG: source → analyze → count → prioritize
-- Demonstrates sql: body → pure Lua compute conversion.
-- Run with: ~/go/bin/glua code-review.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

local source = rt.hard({
  code = "def is_prime(n): return all(n % i != 0 for i in range(2, n))"
})

local analyze = rt.soft(
  { "source.code" },
  { "findings" },
  function(env)
    return string.format(
      "Review this Python function for correctness, performance, and style:\n\n" ..
      "%s\n\n" ..
      "Identify all bugs, edge cases, and potential improvements. " ..
      "Format each finding as a bullet point starting with '- '.",
      env.code
    )
  end,
  { "findings contains at least 3 bullet points" }
)

-- Pure compute: replaces the sql: body with Lua string counting
local count_findings = rt.compute(
  { "analyze.findings" },
  { "total" },
  function(env)
    local count = 0
    for _ in string.gmatch(tostring(env.findings), "%- ") do
      count = count + 1
    end
    return { total = count }
  end
)

local prioritize = rt.soft(
  { "analyze.findings", "count_findings.total" },
  { "summary" },
  function(env)
    return string.format(
      "Given %s findings from the code review:\n\n%s\n\n" ..
      "Prioritize these findings by severity (critical first, minor last). " ..
      "For each, classify as BUG, PERFORMANCE, or STYLE. " ..
      "Write a one-paragraph executive summary suitable for a pull request comment.",
      tostring(env.total), tostring(env.findings)
    )
  end,
  { "summary is not empty" }
)

-- ============================================================
-- LLM SIMULATOR
-- ============================================================
local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "analyze" then
    return {
      findings =
        "- BUG: is_prime(0) returns True (0 is not prime)\n" ..
        "- BUG: is_prime(1) returns True (1 is not prime)\n" ..
        "- PERFORMANCE: range(2, n) checks all values; range(2, int(n**0.5)+1) suffices\n" ..
        "- STYLE: Function lacks docstring and type hints\n" ..
        "- BUG: is_prime(-1) returns True (negative numbers are not prime)"
    }
  elseif cell_name == "prioritize" then
    return {
      summary =
        "CRITICAL: Three bugs found — the function incorrectly identifies 0, 1, and " ..
        "negative numbers as prime. These are edge cases that should be handled with " ..
        "an early guard clause (if n < 2: return False). PERFORMANCE: The trial " ..
        "division checks up to n-1 instead of sqrt(n), making it O(n) instead of " ..
        "O(sqrt(n)). STYLE: Missing docstring and type annotations. Recommendation: " ..
        "fix the edge cases first (correctness), then optimize the range."
    }
  end
  return nil
end

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== CODE REVIEW PROGRAM ===\n\n")

local retort = rt.Retort.new()
retort.llm_sim = simulate_llm

retort:pour("source",         source)
retort:pour("analyze",        analyze)
retort:pour("count_findings", count_findings)
retort:pour("prioritize",     prioritize)

retort:run()
retort:dump()

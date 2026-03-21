-- code_review.lua
-- Code review pipeline: chained soft cells with pure compute in the middle.
-- Mirrors code-review-reference.cell
-- Run with: ~/go/bin/glua code_review.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

-- Hard literal: the code to review
local source = rt.hard({
  code = "def is_prime(n): return all(n % i != 0 for i in range(2, n))"
})

-- Soft cell: analyze the code for bugs/issues
-- Body function returns the LLM prompt string
local analyze = rt.soft(
  { "source.code" },
  { "findings" },
  function(env)
    return string.format(
      "Review this Python function for correctness, performance, and style:\n\n%s\n\n" ..
      "Identify all bugs, edge cases, and potential improvements. " ..
      "Format each finding as a bullet point starting with \"- \".",
      env.code
    )
  end,
  { "findings contains at least 3 bullet points" }
)

-- Pure compute: count bullet points (replaces sql: COUNT in reference)
-- Demonstrates string pattern matching as a data transform
local count_findings = rt.compute(
  { "analyze.findings" },
  { "total" },
  function(env)
    local n = 0
    -- Count lines starting with "- "
    for _ in string.gmatch(tostring(env.findings), "\n%- ") do
      n = n + 1
    end
    -- Also count if first line starts with "- "
    if tostring(env.findings):match("^%- ") then
      n = n + 1
    end
    return { total = n }
  end
)

-- Soft cell: prioritize findings into executive summary
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
local SIMULATED_FINDINGS = [[- BUG: is_prime(1) returns True — 1 is not prime (range(2,1) is empty, all() returns True on empty)
- BUG: is_prime(0) and is_prime(-1) return True — negative numbers and zero handled incorrectly
- PERFORMANCE: range(2, n) checks all the way to n-1; only need range(2, int(sqrt(n))+1)
- PERFORMANCE: all() with generator is elegant but creates a generator object per call; no early exit on n=2
- STYLE: function missing docstring and type hints
- STYLE: single-line lambda style obscures logic; separate into guard clauses for clarity
- EDGE CASE: is_prime(2) returns True (correct), is_prime(3) returns True (correct) — but only by accident of range semantics]]

local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "analyze" then
    return { findings = SIMULATED_FINDINGS }

  elseif cell_name == "prioritize" then
    local total = env.total or 0
    return {
      summary = string.format(
        "CRITICAL (%d findings total): Two correctness bugs — is_prime returns True for 0, 1, " ..
        "and negative numbers due to range(2,n) being empty for n<=2. " ..
        "PERFORMANCE: The O(n) scan should be O(sqrt(n)); replace range(2,n) with range(2,int(n**0.5)+1). " ..
        "STYLE: Add docstring, type hints, and guard clauses. " ..
        "Recommend blocking this PR until the two BUG items are fixed.",
        total
      )
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

-- ============================================================
-- SHOW THE DAG SHAPE
-- Cell dependency graph: source → analyze → count_findings → prioritize
--                                  └──────────────────────────┘
-- ============================================================
io.write("\n=== DAG SHAPE ===\n")
local cells = { source = source, analyze = analyze,
                count_findings = count_findings, prioritize = prioritize }
local order = { "source", "analyze", "count_findings", "prioritize" }
for _, name in ipairs(order) do
  local c = cells[name]
  local givens_str = ""
  if c.givens then
    givens_str = " ← [" .. table.concat(c.givens, ", ") .. "]"
  end
  io.write(string.format("  %-20s (%s)%s\n", name, c.kind, givens_str))
end

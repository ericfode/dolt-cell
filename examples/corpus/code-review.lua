-- code-review.lua
-- Code review pipeline: source → analyze findings → summarize report
-- Demonstrates a 2-step analysis chain.
-- Run with: ~/go/bin/glua code-review.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({
  code = "function add(a, b) { return a + b; }",
  language = "javascript"
})

local analyze = rt.soft(
  { "source.code", "source.language" },
  { "findings" },
  function(env)
    return string.format(
      "Review the following %s code. List bugs, style issues, and improvements " ..
      "as a JSON array of objects with keys: severity, category, message.\n\n" ..
      "Code:\n%s\n\nReturn FINDINGS as a JSON array.",
      env.language, env.code)
  end,
  { "findings is a valid JSON array" }
)

local summary = rt.soft(
  { "analyze.findings" },
  { "report" },
  function(env)
    return string.format(
      "Summarize the following code review findings into a one-paragraph report.\n\n" ..
      "Findings: %s\n\nReturn REPORT.",
      env.findings)
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    analyze = {
      findings = '[{"severity":"low","category":"style","message":"No JSDoc comment for the function"},' ..
                 '{"severity":"info","category":"improvement","message":"Consider adding parameter type hints"}]'
    },
    summary = {
      report = "The add function is functionally correct with no bugs. " ..
               "Minor style improvements suggested: add a JSDoc comment for documentation " ..
               "and consider TypeScript annotations for type safety in larger codebases."
    }
  }
  return sims[cell_name]
end

io.write("=== CODE REVIEW ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("source", source)
retort:pour("analyze", analyze)
retort:pour("summary", summary)
retort:run()
retort:dump()

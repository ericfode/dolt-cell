-- code-audit.lua
-- Multi-stage code audit: inventory → security + architecture → synthesize
-- Demonstrates parallel analysis branches feeding a synthesis cell.
-- Run with: ~/go/bin/glua code-audit.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local target = rt.hard({
  repo = "doltcell/crew/helix",
  files = "cmd/ct/main.go, cmd/ct/parse.go, schema/retort-init.sql"
})

local inventory = rt.soft(
  { "target.repo", "target.files" },
  { "summary", "hotspots", "loc_estimate" },
  function(env)
    return string.format(
      "Read files %s from %s. For each: line count, responsibility, " ..
      "top 3 complexity hotspots. Return structured summary + ranked hotspots.",
      env.files, env.repo)
  end,
  { "summary is not empty" }
)

local security_scan = rt.soft(
  { "target.files", "inventory.hotspots" },
  { "findings" },
  function(env)
    return string.format(
      "Review hotspots for security issues:\n%s\n\n" ..
      "Focus on: SQL injection, path traversal, command injection, info disclosure. " ..
      "For each: severity, location, description, remediation.",
      tostring(env.hotspots))
  end,
  { "findings is not empty" }
)

local architecture_review = rt.soft(
  { "inventory.summary", "inventory.loc_estimate" },
  { "assessment" },
  function(env)
    return string.format(
      "Based on codebase summary (~%s lines):\n%s\n\n" ..
      "1. Is architecture appropriate for scale?\n" ..
      "2. Are responsibilities well-separated?\n" ..
      "3. Coupling risks? 4. What breaks if codebase doubles?",
      tostring(env.loc_estimate), tostring(env.summary))
  end
)

local synthesize = rt.soft(
  { "security_scan.findings", "architecture_review.assessment" },
  { "report" },
  function(env)
    return string.format(
      "Combine security findings and architecture assessment into audit report.\n\n" ..
      "Security: %s\n\nArchitecture: %s\n\n" ..
      "Structure: Executive Summary, Critical Findings, Architecture Concerns, Recommendations.",
      tostring(env.findings), tostring(env.assessment))
  end,
  { "report is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    inventory = {
      summary = "3 files: main.go (CLI entry, 200 LOC), parse.go (cell parser, 350 LOC), retort-init.sql (schema, 150 LOC)",
      hotspots = "1. parse.go:parseBody — recursive descent with 6 cases\n2. main.go:handleEval — orchestrates full eval loop\n3. retort-init.sql:cell_eval_step — 40-line stored procedure",
      loc_estimate = "700"
    },
    security_scan = {
      findings = "MEDIUM: parse.go:45 — user input concatenated into SQL query string. " ..
        "Remediation: use parameterized queries. LOW: main.go:120 — error message includes file path."
    },
    architecture_review = {
      assessment = "Architecture is appropriate for ~700 LOC. parse.go handles too many concerns " ..
        "(lexing + parsing + validation). Recommend splitting into lex.go + parse.go + validate.go."
    },
    synthesize = {
      report = "## Executive Summary\nSmall codebase with one medium security issue and " ..
        "moderate coupling in the parser. No critical vulnerabilities.\n\n" ..
        "## Recommendations\n1. Fix SQL concatenation in parse.go:45\n2. Split parse.go into 3 files"
    },
  }
  return sims[cell_name]
end

io.write("=== CODE AUDIT PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("target", target)
retort:pour("inventory", inventory)
retort:pour("security_scan", security_scan)
retort:pour("architecture_review", architecture_review)
retort:pour("synthesize", synthesize)
retort:run()
retort:dump()

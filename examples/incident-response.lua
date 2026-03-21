-- incident-response.lua
-- On-call incident investigation: triage → parallel investigate → root cause
-- → remediation → postmortem. Demonstrates parallel branches + synthesis.
-- Run with: ~/go/bin/glua incident-response.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local incident = rt.hard({
  description = "Dolt server returning 'database not found: retort' intermittently. " ..
    "Affects ct pour and ct run. Server shows as running (PID alive, port open). " ..
    "Occurs after ~30 minutes of inactivity.",
  severity = "P2"
})

local triage = rt.soft(
  { "incident.description", "incident.severity" },
  { "category", "initial_hypothesis", "investigation_plan" },
  function(env)
    return string.format(
      "Triage incident: %s (severity: %s)\n\n" ..
      "Classify category (data loss, connectivity, performance, config, bug). " ..
      "Form initial hypothesis. Plan 3 parallel investigation threads.",
      env.description, env.severity)
  end,
  { "category is not empty" }
)

-- Three parallel investigation threads (original used stems)
local investigate_logs = rt.soft(
  { "incident.description", "triage.investigation_plan" },
  { "findings" },
  function(env)
    return string.format(
      "LOG ANALYSIS for: %s\nPlan: %s\n\n" ..
      "Check Dolt server logs, system logs, error output. " ..
      "Look for error patterns, memory/disk warnings, connection timeouts.",
      env.description, tostring(env.investigation_plan))
  end,
  { "findings is not empty" }
)

local investigate_state = rt.soft(
  { "incident.description", "triage.investigation_plan" },
  { "findings" },
  function(env)
    return string.format(
      "STATE INSPECTION for: %s\n\n" ..
      "Check: SHOW DATABASES, disk usage of .dolt-data/, orphan test databases, " ..
      "connection count. Report concrete findings.",
      env.description)
  end,
  { "findings is not empty" }
)

local investigate_repro = rt.soft(
  { "incident.description", "triage.investigation_plan" },
  { "findings" },
  function(env)
    return string.format(
      "REPRODUCTION for: %s\n\n" ..
      "Try to reproduce: 1) Check current state 2) Run ct pour/run " ..
      "3) Simulate inactivity 4) Check again. Report: reproducible? conditions? timing?",
      env.description)
  end,
  { "findings is not empty" }
)

local root_cause = rt.soft(
  { "triage.initial_hypothesis", "investigate_logs.findings",
    "investigate_state.findings", "investigate_repro.findings" },
  { "analysis", "confirmed_cause", "confidence" },
  function(env)
    return string.format(
      "Synthesize investigation findings:\n" ..
      "- Logs: %s\n- State: %s\n- Repro: %s\n\n" ..
      "Against hypothesis: %s\n\n" ..
      "Determine root cause with confidence (HIGH/MEDIUM/LOW).",
      tostring(env.findings), tostring(env.findings), tostring(env.findings),
      tostring(env.initial_hypothesis))
  end
)

local remediation = rt.soft(
  { "root_cause.confirmed_cause", "root_cause.confidence", "incident.severity" },
  { "plan", "approved" },
  function(env)
    return string.format(
      "Remediation plan for: %s (confidence: %s, severity: %s)\n\n" ..
      "Include: 1) Immediate mitigation 2) Root cause fix " ..
      "3) Verification steps 4) Monitoring. " ..
      "Self-review: is this safe? Return APPROVED or NEEDS_REVISION.",
      tostring(env.confirmed_cause), tostring(env.confidence), tostring(env.severity))
  end,
  { "plan is not empty" }
)

local postmortem = rt.soft(
  { "incident.description", "incident.severity",
    "root_cause.analysis", "root_cause.confirmed_cause", "remediation.plan" },
  { "document" },
  function(env)
    return string.format(
      "Write postmortem: %s (severity: %s)\n" ..
      "Root cause: %s\nRemediation: %s\n\n" ..
      "Sections: Summary, Timeline, Root Cause, Impact, Remediation, " ..
      "Lessons Learned, Action Items. Factual, no blame.",
      tostring(env.description), tostring(env.severity),
      tostring(env.confirmed_cause), tostring(env.plan))
  end,
  { "document is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    triage = {
      category = "connectivity",
      initial_hypothesis = "Dolt drops idle connections after timeout, loses database handle",
      investigation_plan = "1) Check logs for timeout/disconnect 2) Inspect server state 3) Reproduce with wait"
    },
    investigate_logs = { findings = "Server log shows 'connection reset by peer' at T-32min. " ..
      "No memory warnings. TCP keepalive disabled." },
    investigate_state = { findings = "SHOW DATABASES lists 'retort' when connected fresh. " ..
      "3 orphan test databases found. 47 idle connections in processlist." },
    investigate_repro = { findings = "Reproducible: after 30min idle, next query gets 'database not found'. " ..
      "Fresh connection works. Issue is stale connection handle, not missing database." },
    root_cause = {
      analysis = "All three threads converge: stale connection pool. Dolt server-side timeout " ..
        "kills idle connections but Go client doesn't detect it. Next query on dead connection fails.",
      confirmed_cause = "Go SQL driver connection pool holds stale connections after Dolt server-side timeout",
      confidence = "HIGH"
    },
    remediation = {
      plan = "1. IMMEDIATE: Add ConnMaxIdleTime=5m to sql.DB config\n" ..
        "2. ROOT FIX: Enable TCP keepalive on Dolt connections\n" ..
        "3. VERIFY: Run ct pour, wait 35min, run ct pour again\n" ..
        "4. MONITOR: Add connection pool metrics to ct status",
      approved = "APPROVED"
    },
    postmortem = {
      document = "# Incident Postmortem: Intermittent 'database not found'\n\n" ..
        "## Summary\nStale connection pool caused intermittent failures after idle periods.\n\n" ..
        "## Root Cause\nGo SQL driver held connections past Dolt's server-side timeout.\n\n" ..
        "## Action Items\n- Add ConnMaxIdleTime (owner: glassblower)\n- Add pool metrics (owner: scribe)"
    },
  }
  return sims[cell_name]
end

io.write("=== INCIDENT RESPONSE PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("incident", incident)
retort:pour("triage", triage)
retort:pour("investigate_logs", investigate_logs)
retort:pour("investigate_state", investigate_state)
retort:pour("investigate_repro", investigate_repro)
retort:pour("root_cause", root_cause)
retort:pour("remediation", remediation)
retort:pour("postmortem", postmortem)
retort:run()
retort:dump()

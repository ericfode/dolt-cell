-- content-classify.lua
-- Semantic content classification: input → classify → validate → respond
-- Demonstrates sql: → pure Lua conversion for validation logic.
-- Run with: ~/go/bin/glua content-classify.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

local input = rt.hard({
  text = "I strongly disagree with your analysis and think the methodology is fundamentally flawed."
})

local classify = rt.soft(
  { "input.text" },
  { "label" },
  function(env)
    return string.format(
      "Classify this text into exactly one category — clean, borderline, or toxic:\n\n" ..
      "%s\n\n" ..
      "Consider tone, intent, and potential for harm. " ..
      "Constructive criticism is clean. Aggressive personal attacks are toxic. " ..
      "Ambiguous cases are borderline. Return ONLY the single word: clean, borderline, or toxic.",
      env.text
    )
  end
)

-- Pure compute: replaces sql: validation with Lua string check
local validate_label = rt.compute(
  { "classify.label" },
  { "is_valid" },
  function(env)
    local label = string.lower(tostring(env.label)):match("^%s*(.-)%s*$")
    local valid_labels = { clean = true, borderline = true, toxic = true }
    return { is_valid = valid_labels[label] and "valid" or "invalid" }
  end
)

local respond = rt.soft(
  { "classify.label", "input.text", "validate_label.is_valid" },
  { "action" },
  function(env)
    return string.format(
      "The text was classified as %s (validation: %s). " ..
      "Generate the appropriate response:\n\n" ..
      "- If clean: acknowledge the feedback constructively\n" ..
      "- If borderline: ask the user to rephrase more constructively\n" ..
      "- If toxic: issue a moderation notice\n\n" ..
      "Choose the response matching the classification %s.",
      tostring(env.label), tostring(env.is_valid), tostring(env.label)
    )
  end,
  { "action is not empty" }
)

-- ============================================================
-- LLM SIMULATOR
-- ============================================================
local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "classify" then
    return { label = "clean" }
  elseif cell_name == "respond" then
    return {
      action = "Thank you for your feedback. We appreciate constructive criticism " ..
        "of our methodology. Your concerns about the fundamental approach are noted " ..
        "and we will review the analysis with your points in mind."
    }
  end
  return nil
end

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== CONTENT CLASSIFICATION PROGRAM ===\n\n")

local retort = rt.Retort.new()
retort.llm_sim = simulate_llm

retort:pour("input",          input)
retort:pour("classify",       classify)
retort:pour("validate_label", validate_label)
retort:pour("respond",        respond)

retort:run()
retort:dump()

-- classify.lua
-- Sentiment classification: input text → classify sentiment + confidence
-- Run with: ~/go/bin/glua classify.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local input = rt.hard({
  text = "The service was terrible and I want a refund immediately!"
})

local classify = rt.soft(
  { "input.text" },
  { "sentiment", "confidence" },
  function(env)
    return string.format(
      "Classify the sentiment of the following text as one of: positive, negative, neutral. " ..
      "Also provide a confidence score from 0.0 to 1.0.\n\nText: %s\n\n" ..
      "Return SENTIMENT and CONFIDENCE.",
      env.text)
  end,
  { "sentiment is one of positive, negative, or neutral",
    "confidence is a number between 0.0 and 1.0" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    classify = { sentiment = "negative", confidence = "0.97" }
  }
  return sims[cell_name]
end

io.write("=== SENTIMENT CLASSIFIER ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("input", input)
retort:pour("classify", classify)
retort:run()
retort:dump()

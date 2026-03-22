-- translation.lua
-- Round-trip translation: source text → translate → back-translate
-- Demonstrates a simple 3-cell chain.
-- Run with: ~/go/bin/glua translation.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local source = rt.hard({
  text = "Hello, how are you today?",
  target_lang = "Spanish"
})

local translate = rt.soft(
  { "source.text", "source.target_lang" },
  { "translated" },
  function(env)
    return string.format(
      "Translate the following text into %s.\n\nText: %s\n\nReturn TRANSLATED.",
      env.target_lang, env.text)
  end,
  {}
)

local back_translate = rt.soft(
  { "translate.translated" },
  { "round_trip" },
  function(env)
    return string.format(
      "Translate the following text back into English.\n\nText: %s\n\n" ..
      "Return ROUND_TRIP.",
      env.translated)
  end,
  { "round_trip preserves the meaning of the original text" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    translate     = { translated = "Hola, ¿cómo estás hoy?" },
    back_translate = { round_trip = "Hello, how are you today?" }
  }
  return sims[cell_name]
end

io.write("=== ROUND-TRIP TRANSLATION ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("source", source)
retort:pour("translate", translate)
retort:pour("back_translate", back_translate)
retort:run()
retort:dump()

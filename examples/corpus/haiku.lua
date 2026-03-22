-- haiku.lua
-- Haiku composition: topic → compose poem
-- Run with: ~/go/bin/glua haiku.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local topic = rt.hard({
  subject = "autumn leaves"
})

local compose = rt.soft(
  { "topic.subject" },
  { "poem" },
  function(env)
    return string.format(
      "Write a haiku about %s. " ..
      "A haiku has exactly three lines following the 5-7-5 syllable pattern.\n\n" ..
      "Return POEM.",
      env.subject)
  end,
  { "poem has exactly three lines",
    "poem follows 5-7-5 syllable pattern" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    compose = {
      poem = "Crimson leaves descend\nWhispering through silent air\nEarth receives their gift"
    }
  }
  return sims[cell_name]
end

io.write("=== HAIKU COMPOSER ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("topic", topic)
retort:pour("compose", compose)
retort:run()
retort:dump()

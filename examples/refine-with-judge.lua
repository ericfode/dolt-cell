-- refine-with-judge.lua
-- Draft → refine chain for haiku about recursion
-- Run with: ~/go/bin/glua refine-with-judge.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local prompt = rt.hard({ topic = "Write a haiku about recursion." })

local draft = rt.soft(
  { "prompt.topic" },
  { "text" },
  function(env)
    return string.format("Write a first attempt responding to %s", env.topic)
  end,
  { "text is not empty" }
)

local refine = rt.soft(
  { "draft.text" },
  { "text" },
  function(env)
    return string.format(
      "Improve this haiku. Make it more evocative and precise. " ..
      "Keep the 5-7-5 syllable structure:\n\n%s", tostring(env.text))
  end
)

local function simulate_llm(cell_name, _, _, _)
  if cell_name == "draft" then
    return { text = "Function calls self\nSmaller pieces every time\nBase case ends it all" }
  elseif cell_name == "refine" then
    return { text = "A mirror holds glass\nReflection reflecting deep\nTurtle all the way" }
  end
end

io.write("=== REFINE WITH JUDGE ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("prompt", prompt)
retort:pour("draft", draft)
retort:pour("refine", refine)
retort:run()
retort:dump()

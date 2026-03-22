-- guillemet-escape.lua
-- Edge case: yield value containing literal guillemet characters «».
-- The template string contains «x» and «formula» which are NOT
-- interpolation targets — they are literal characters in the value.
-- The LLM should echo the template without interpreting the guillemets.
-- Run with: ~/go/bin/glua guillemet-escape.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- Note: In Lua we use string literal — guillemets are just characters.
local meta = rt.hard({
  template = "The value of \xC2\xABx\xC2\xBB is computed by \xC2\xABformula\xC2\xBB"
  -- «x» = U+00AB x U+00BB; «formula» similarly
})

local process = rt.soft(
  { "meta.template" },
  { "result" },
  function(env)
    return string.format(
      "Echo the following string exactly as given. Do not interpret or expand any special markers inside it.\n\nString: %s\n\nReturn RESULT.",
      env.template)
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    process = {
      result = "The value of \xC2\xABx\xC2\xBB is computed by \xC2\xABformula\xC2\xBB"
    }
  }
  return sims[cell_name]
end

io.write("=== GUILLEMET ESCAPE ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("meta", meta)
retort:pour("process", process)
retort:run()
retort:dump()

-- special-chars.lua
-- Edge case: special characters in yield values (quotes, emoji, JSON).
-- Run with: ~/go/bin/glua special-chars.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local quotes = rt.hard({ text = 'She said "hello" to \'them\'' })

local unicode = rt.hard({ emoji = "Hello \xF0\x9F\x8C\x8D World" })

local json_val = rt.hard({ data = '{"key": "value", "count": 42}' })

local consumer = rt.soft(
  { "quotes.text", "unicode.emoji", "json_val.data" },
  { "summary" },
  function(env)
    return string.format(
      "Concatenate these three values separated by \" | \":\n1: %s\n2: %s\n3: %s\n\nReturn SUMMARY.",
      tostring(env.text), tostring(env.emoji), tostring(env.data))
  end,
  {}
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    consumer = {
      summary = 'She said "hello" to \'them\' | Hello \xF0\x9F\x8C\x8D World | {"key": "value", "count": 42}'
    }
  }
  return sims[cell_name]
end

io.write("=== SPECIAL CHARACTERS ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("quotes", quotes)
retort:pour("unicode", unicode)
retort:pour("json_val", json_val)
retort:pour("consumer", consumer)
retort:run()
retort:dump()

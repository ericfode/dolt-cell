-- fibonacci.lua
-- Fibonacci sequence: seed n → compute first n Fibonacci numbers
-- Run with: ~/go/bin/glua fibonacci.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local seed = rt.hard({
  n = "10"
})

local compute_seq = rt.soft(
  { "seed.n" },
  { "sequence" },
  function(env)
    return string.format(
      "Generate the first %s Fibonacci numbers as a JSON array. " ..
      "The sequence starts: [1, 1, 2, 3, 5, ...]\n\n" ..
      "Return SEQUENCE as a JSON array with exactly %s elements.",
      env.n, env.n)
  end,
  { "sequence is a valid JSON array",
    "sequence has exactly seed.n elements" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    compute_seq = { sequence = "[1, 1, 2, 3, 5, 8, 13, 21, 34, 55]" }
  }
  return sims[cell_name]
end

io.write("=== FIBONACCI SEQUENCE ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("seed", seed)
retort:pour("compute_seq", compute_seq)
retort:run()
retort:dump()

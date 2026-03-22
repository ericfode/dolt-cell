-- bottom-optional-given-survives.lua
-- Optional given absorbs bottom: enrich bottoms (oracle failure), but
-- report uses given? enrich.extra so report still fires with available data.
-- Modeled by not including enrich in report's strict givens.
-- Run with: ~/go/bin/glua bottom-optional-given-survives.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local data = rt.hard({ items = "[1, 2, 3, 4, 5]" })

-- enrich bottoms: tries to return roman numerals but oracle wants json array
local enrich = rt.compute(
  { "data.items" },
  { "extra" },
  function(env)
    -- Returns comma-separated roman numerals — fails "is valid json array" check
    local val = "I, II, III, IV, V"
    if not (val and val:match("^%s*%[")) then
      error("oracle failure: extra is not a valid json array")
    end
    return { extra = val }
  end
)

-- report: given data.items (required), given? enrich.extra (optional).
-- Since enrich is optional, report fires without it.
local report = rt.soft(
  { "data.items" },
  { "summary" },
  function(env)
    -- enrich.extra not in strict givens — env.extra will be nil
    local extra_clause = env.extra and (" With enrichment: " .. env.extra .. ".") or ""
    return string.format(
      "Summarize %s.%s Return SUMMARY.",
      env.items, extra_clause)
  end,
  { "summary is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    report = { summary = "The list [1, 2, 3, 4, 5] contains 5 positive integers with a sum of 15." }
  }
  return sims[cell_name]
end

io.write("=== BOTTOM OPTIONAL GIVEN SURVIVES ===\n\n")
io.write("Expected: data=frozen, enrich=bottom, report=frozen (optional enrich skipped)\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("data", data)
retort:pour("enrich", enrich)
retort:pour("report", report)
retort:run()
retort:dump()

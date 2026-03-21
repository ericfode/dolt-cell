-- haiku-refine.lua
-- Iterative refinement: compose → reflect (stem) → final poem + evolution
-- Demonstrates stem cells via coroutines and gather via history tracking.
-- Run with: ~/go/bin/glua haiku-refine.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- ============================================================

-- Hard literal: the topic to compose about
local topic = rt.hard({
  subject = "lantern light on snow — a door left open at dusk"
})

-- Soft cell: initial composition
local compose = rt.soft(
  { "topic.subject" },
  { "poem", "notes" },
  function(env)
    return string.format(
      "Write a haiku about %s. " ..
      "Follow the traditional 5-7-5 syllable structure across exactly three lines. " ..
      "Aim for a seasonal reference (kigo) and a cutting moment (kireji). " ..
      "Return the haiku on the first three lines, then a blank line, " ..
      "then one sentence of notes on your choices.",
      env.subject
    )
  end
)

-- Stem cell: iterative refinement via coroutine
-- Each generation reads the current poem, critiques, and revises.
-- Yields "more" until settled or max generations reached.
local reflect = rt.stem(
  { "compose.poem", "compose.notes" },
  { "poem", "notes", "settled" },
  function(env)
    local poem = env.poem
    local notes = env.notes
    local max_gens = 4

    for gen = 1, max_gens do
      -- In real runtime, each generation sends a prompt to the LLM.
      -- Here we simulate the refinement loop.
      local prompt = string.format(
        "You are refining a haiku through successive passes. Current version:\n\n" ..
        "%s\n\nPrevious notes: %s\n\n" ..
        "Critique on: syllable accuracy, imagery economy, kigo, kireji.\n" ..
        "Then write an improved version. If already perfect, return unchanged.\n" ..
        "Format: haiku on lines 1-3, SETTLED or REVISING on line 5, " ..
        "explanation on line 6.",
        tostring(poem), tostring(notes)
      )
      _ = prompt  -- would be sent to LLM in real runtime

      -- Simulate: refine for 2 generations, then settle
      if gen < 3 then
        poem = poem  -- in real runtime: LLM response
        notes = "Pass " .. gen .. ": tightened imagery"
        local settled = "REVISING"
        coroutine.yield({ poem = poem, notes = notes, settled = settled }, "more")
      else
        notes = "Pass " .. gen .. ": settled — no further improvement possible"
        local settled = "SETTLED"
        coroutine.yield({ poem = poem, notes = notes, settled = settled })
        return
      end
    end
  end
)

-- Final poem: just passes through the settled version
local poem_final = rt.soft(
  { "reflect.poem" },
  { "final" },
  function(env)
    return string.format(
      "Return this poem exactly as-is, with no changes:\n%s",
      tostring(env.poem)
    )
  end,
  { "final has exactly three lines" }
)

-- Evolution tracker: gathers all versions (simulates gather)
-- In real runtime, this would use reflect[*].poem to get all generations.
-- Here we use a compute cell that reads the retort's yield history.
local evolution = rt.compute(
  { "compose.poem", "reflect.poem" },
  { "timeline" },
  function(env)
    -- In the real runtime, reflect[*].poem would give us all generations.
    -- Here we can only see the final reflect.poem. A full implementation
    -- would track the coroutine yield history.
    local timeline = string.format(
      "Draft 0 (compose): %s\nFinal (reflect): %s",
      tostring(env.poem) ~= "nil" and env.poem or "(compose poem)",
      tostring(env.poem)
    )
    return { timeline = timeline }
  end
)

-- ============================================================
-- LLM SIMULATOR
-- ============================================================
local function simulate_llm(cell_name, prompt, yield_fields, env)
  if cell_name == "compose" then
    return {
      poem = "Lantern paints the snow\nAn open door breathes the dusk\nLight learns to let go",
      notes = "Kigo: snow (winter). Kireji: pivot at 'breathes'. Personification of light."
    }
  elseif cell_name == "poem_final" then
    return {
      final = env.poem or "Lantern paints the snow\nAn open door breathes the dusk\nLight learns to let go"
    }
  end
  return nil
end

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== HAIKU REFINEMENT PROGRAM ===\n\n")

local retort = rt.Retort.new()
retort.llm_sim = simulate_llm

retort:pour("topic",      topic)
retort:pour("compose",    compose)
retort:pour("reflect",    reflect)
retort:pour("poem_final", poem_final)
retort:pour("evolution",  evolution)

retort:run()
retort:dump()

-- Show stem cell behavior
io.write("\n=== STEM CELL NOTES ===\n")
io.write("reflect.kind = " .. reflect.kind .. "\n")
io.write("reflect.effect = " .. reflect.effect ..
  " (NON_REPLAYABLE=" .. rt.NON_REPLAYABLE .. ")\n")
io.write("Stem cells use coroutines: yield({...}, 'more') for each generation\n")
io.write("The 'recur until settled = SETTLED (max 4)' pattern becomes a for loop\n")

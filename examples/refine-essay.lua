-- refine-essay.lua
-- Essay refinement: draft → refine (stem, recur) → judge
-- Demonstrates iterative refinement via coroutine.
-- Run with: ~/go/bin/glua refine-essay.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local prompt = rt.hard({
  topic = "Explain why content-addressable storage matters for version control, in 3 sentences."
})

-- Soft cell: initial draft
local draft = rt.soft(
  { "prompt.topic" },
  { "text" },
  function(env)
    return string.format("Write a first draft responding to %s. Be concise but substantive.", env.topic)
  end,
  { "text is not empty" }
)

-- Stem cell: iterative refinement (recur until fixpoint, max 3)
local refine = rt.stem(
  { "draft.text" },
  { "text" },
  function(env)
    local text = env.text
    local versions = {
      "Content-addressable storage names objects by their hash, making every version " ..
        "immutable and verifiable. This lets version control detect corruption, deduplicate " ..
        "identical content, and merge branches efficiently. The hash IS the identity — " ..
        "if two files have the same hash, they are the same file, period.",
      "Content-addressable storage assigns each object an identity derived from its content. " ..
        "This makes every version immutable, deduplication automatic, and corruption detectable. " ..
        "The hash is the identity: same content, same name, always.",
      "Content-addressable storage assigns each object an identity derived from its content. " ..
        "This makes every version immutable, deduplication automatic, and corruption detectable. " ..
        "The hash is the identity: same content, same name, always."
    }
    for i, v in ipairs(versions) do
      if i < #versions and v ~= versions[i + 1] then
        coroutine.yield({ text = v }, "more")
      else
        coroutine.yield({ text = v })
        return
      end
    end
  end
)

-- Judge: compare draft vs refined
local judge = rt.soft(
  { "draft.text", "refine.text" },
  { "verdict" },
  function(env)
    return string.format(
      "Compare the original draft with the refined version. Which is better and why?\n\n" ..
      "Original:\n%s\n\nRefined:\n%s\n\nOne paragraph.",
      tostring(env.text), tostring(env.text)
    )
  end,
  { "verdict is not empty" }
)

local function simulate_llm(cell_name, prompt_str, yield_fields, env)
  if cell_name == "draft" then
    return {
      text = "Content-addressable storage is important for version control because " ..
        "it uses hashes to identify content. This means files are stored by their " ..
        "content rather than their name. Git uses this approach."
    }
  elseif cell_name == "judge" then
    return {
      verdict = "The refined version is substantially better. It replaces vague claims " ..
        "('important', 'uses hashes') with precise consequences (immutability, deduplication, " ..
        "corruption detection). The final sentence crystallizes the key insight — hash as " ..
        "identity — into a memorable formulation."
    }
  end
  return nil
end

io.write("=== ESSAY REFINEMENT PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("prompt", prompt)
retort:pour("draft", draft)
retort:pour("refine", refine)
retort:pour("judge", judge)
retort:run()
retort:dump()

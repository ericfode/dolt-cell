-- word_count.lua
-- Pure compute cells: word counting, string splitting, text analysis.
-- These REPLACE sql: bodies — deterministic, no LLM, no DB.
-- Run with: ~/go/bin/glua word_count.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- CELL DEFINITIONS
-- All cells here are Pure (effect = PURE, kind = "compute")
-- ============================================================

-- Hard literal: input text
local input_text = rt.hard({
  text = [[The tiny cows of Meadowmere had secrets no nuzzle could keep.
Blossom knew about the fence. Clover knew about the gate.
Thistle knew everything but said nothing at all.
The meadow waited. The clover grew. The truth would come.]]
})

-- Pure compute: count words using string.gmatch
local word_count = rt.compute(
  { "input_text.text" },
  { "total", "unique" },
  function(env)
    local text = tostring(env.text)
    local counts = {}
    local total = 0
    -- Tokenize: lowercase, strip punctuation
    for word in string.gmatch(text:lower(), "[%a]+") do
      total = total + 1
      counts[word] = (counts[word] or 0) + 1
    end
    -- Count unique words
    local unique = 0
    for _ in pairs(counts) do unique = unique + 1 end
    return { total = total, unique = unique }
  end
)

-- Pure compute: split into lines, count sentences
local line_stats = rt.compute(
  { "input_text.text" },
  { "lines", "sentences", "avg_words_per_line" },
  function(env)
    local text = tostring(env.text)
    -- Count lines
    local lines = 0
    for _ in string.gmatch(text, "[^\n]+") do lines = lines + 1 end
    -- Count sentences (end with . ! ?)
    local sentences = 0
    for _ in string.gmatch(text, "[%.%!%?]") do sentences = sentences + 1 end
    -- Count total words for average
    local total_words = 0
    for _ in string.gmatch(text, "%S+") do total_words = total_words + 1 end
    local avg = lines > 0 and math.floor((total_words / lines) * 10) / 10 or 0
    return { lines = lines, sentences = sentences, avg_words_per_line = avg }
  end
)

-- Pure compute: find most frequent words (top N)
local top_words = rt.compute(
  { "input_text.text" },
  { "top3", "frequencies" },
  function(env)
    local text = tostring(env.text)
    local counts = {}
    -- Build frequency table
    for word in string.gmatch(text:lower(), "[%a]+") do
      if #word > 3 then  -- skip short words
        counts[word] = (counts[word] or 0) + 1
      end
    end
    -- Sort by frequency
    local ranked = {}
    for word, count in pairs(counts) do
      table.insert(ranked, { word = word, count = count })
    end
    table.sort(ranked, function(a, b) return a.count > b.count end)
    -- Build top-3 string
    local top3_parts = {}
    for i = 1, math.min(3, #ranked) do
      table.insert(top3_parts, ranked[i].word .. "(" .. ranked[i].count .. ")")
    end
    return {
      top3 = table.concat(top3_parts, ", "),
      frequencies = #ranked
    }
  end
)

-- Pure compute: build a summary table from all the stats
-- Demonstrates a cell that reads from MULTIPLE upstream cells
local summary = rt.compute(
  { "word_count.total", "word_count.unique",
    "line_stats.lines", "line_stats.sentences", "line_stats.avg_words_per_line",
    "top_words.top3", "top_words.frequencies" },
  { "report" },
  function(env)
    local report = string.format(
      "TEXT ANALYSIS REPORT\n" ..
      "  Words (total):     %s\n" ..
      "  Words (unique):    %s\n" ..
      "  Lines:             %s\n" ..
      "  Sentences:         %s\n" ..
      "  Avg words/line:    %s\n" ..
      "  Distinct forms:    %s\n" ..
      "  Top 3 content words: %s\n" ..
      "  Type/token ratio:  %.2f%%",
      tostring(env.total), tostring(env.unique),
      tostring(env.lines), tostring(env.sentences),
      tostring(env.avg_words_per_line),
      tostring(env.frequencies),
      tostring(env.top3),
      (tonumber(env.unique) or 0) / math.max((tonumber(env.total) or 1), 1) * 100
    )
    return { report = report }
  end
)

-- ============================================================
-- POUR AND RUN (no LLM simulator needed — all pure compute)
-- ============================================================
io.write("=== WORD COUNT (PURE COMPUTE) PROGRAM ===\n\n")

local retort = rt.Retort.new()
-- No llm_sim needed — all cells are pure

retort:pour("input_text", input_text)
retort:pour("word_count", word_count)
retort:pour("line_stats", line_stats)
retort:pour("top_words",  top_words)
retort:pour("summary",    summary)

retort:run()
retort:dump()

-- ============================================================
-- SHOW THE COMPUTED REPORT DIRECTLY
-- ============================================================
io.write("\n=== FINAL REPORT ===\n")
if retort.yields["summary"] then
  io.write(retort.yields["summary"].report .. "\n")
end

-- ============================================================
-- DEMONSTRATE EFFECT PURITY
-- All these cells are PURE — no LLM, no DB, no side effects.
-- The effect lattice is enforced by the runtime.
-- ============================================================
io.write("\n=== EFFECT AUDIT ===\n")
local cells_list = {
  { "input_text",  input_text },
  { "word_count",  word_count },
  { "line_stats",  line_stats },
  { "top_words",   top_words },
  { "summary",     summary },
}
local effect_names = { [1]="PURE", [2]="REPLAYABLE", [3]="NON_REPLAYABLE" }
for _, pair in ipairs(cells_list) do
  local name, cell = pair[1], pair[2]
  io.write(string.format("  %-15s kind=%-8s effect=%s\n",
    name, cell.kind, effect_names[cell.effect]))
end
io.write("\nAll cells pure — no LLM invocations, no DB queries.\n")
io.write("This is what replaces sql: bodies: pure Lua functions.\n")

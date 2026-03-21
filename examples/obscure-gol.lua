-- obscure-gol.lua
-- Game of Life in the most obscure language: find → design → implement → test → review
-- Demonstrates dynamic methodology: research shapes the build process.
-- Run with: ~/go/bin/glua obscure-gol.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local find_language = rt.soft(
  {},
  { "language", "justification", "hello_world", "dev_loop" },
  function(_)
    return "Find the most obscure, esoteric programming language that is " ..
      "Turing-complete and has a working interpreter. Avoid Brainfuck, Malbolge, " ..
      "Whitespace. Find something truly forgotten.\n\n" ..
      "Then define a dev methodology for THIS language: how to structure programs, " ..
      "represent data, iterate, do I/O, and the build order for Game of Life.\n\n" ..
      "Return: LANGUAGE, JUSTIFICATION, HELLO_WORLD (code), DEV_LOOP (methodology)."
  end,
  { "language is not empty", "dev_loop is not empty" }
)

local design = rt.soft(
  { "find_language.language", "find_language.hello_world", "find_language.dev_loop" },
  { "architecture", "data_structures", "build_order" },
  function(env)
    return string.format(
      "Design Game of Life in %s.\nDev methodology: %s\nHello world: %s\n\n" ..
      "Need: 10x10 grid, birth/survive/death rules, 5 generations, glider pattern.\n" ..
      "Return: ARCHITECTURE, DATA_STRUCTURES, BUILD_ORDER.",
      tostring(env.language), tostring(env.dev_loop), tostring(env.hello_world))
  end,
  { "architecture is not empty" }
)

local implement = rt.soft(
  { "find_language.language", "find_language.hello_world", "find_language.dev_loop",
    "design.architecture", "design.data_structures", "design.build_order" },
  { "source_code" },
  function(env)
    return string.format(
      "Implement Game of Life in %s.\nDev methodology: %s\n" ..
      "Architecture: %s\nData structures: %s\nBuild order: %s\n\n" ..
      "10x10 grid, glider at (1,1), 5 generations, print each. " ..
      "Return ONLY the complete source code.",
      tostring(env.language), tostring(env.dev_loop),
      tostring(env.architecture), tostring(env.data_structures), tostring(env.build_order))
  end,
  { "source_code is not empty" }
)

local test_plan = rt.soft(
  { "find_language.language", "find_language.dev_loop", "implement.source_code" },
  { "test_cases", "expected_gen1" },
  function(env)
    return string.format(
      "Write test plan for %s Game of Life.\nCode: %s\n\n" ..
      "Return: TEST_CASES (3-5 cases) and EXPECTED_GEN1 (10x10 grid after gen 1).",
      tostring(env.language), tostring(env.source_code):sub(1, 200))
  end,
  { "test_cases is not empty" }
)

local review = rt.soft(
  { "find_language.language", "find_language.justification", "find_language.dev_loop",
    "implement.source_code", "test_plan.test_cases", "test_plan.expected_gen1" },
  { "verdict", "critique", "obscurity_score" },
  function(env)
    return string.format(
      "Review GoL in %s (%s).\nCode: %s\nTests: %s\n\n" ..
      "Evaluate: follows methodology? correct? GoL rules right? " ..
      "How obscure is the language (1-10)?\n" ..
      "Return: verdict (PASS/FAIL), critique, obscurity_score.",
      tostring(env.language), tostring(env.justification),
      tostring(env.source_code):sub(1, 200), tostring(env.test_cases))
  end,
  { "verdict is not empty" }
)

local function simulate_llm(cell_name, _, _, _)
  local sims = {
    find_language = {
      language = "Befunge-93",
      justification = "2D grid-based language where the instruction pointer moves in four directions — perfect irony for implementing a 2D grid simulation",
      hello_world = '"!dlroW ,olleH">:#,_@',
      dev_loop = "1. Think in 2D — code IS a grid. 2. Use stack for data. " ..
        "3. Build primitives first (push, pop, arithmetic). 4. Use directional arrows for flow control. " ..
        "5. Debug by tracing the instruction pointer path."
    },
    design = {
      architecture = "Store grid as 100-cell region of Befunge playfield (rows 20-29, cols 0-9)",
      data_structures = "Each cell is 0 (dead) or 1 (alive) in the Befunge grid. Stack holds neighbor count.",
      build_order = "1. Grid init 2. Neighbor count 3. Rule application 4. Display 5. Generation loop"
    },
    implement = {
      source_code = 'v  Game of Life in Befunge-93\n>  "Befunge GoL",,,,,,,,,,,,25*,v\n   ... (200 lines of arrow-based madness)'
    },
    test_plan = {
      test_cases = "1. Glider moves one step diag after gen 1\n2. Still life (block) stays unchanged\n3. Blinker oscillates period 2",
      expected_gen1 = "..........\n..#.......\n...#......\n.###......\n..........\n..........\n..........\n..........\n..........\n.........."
    },
    review = {
      verdict = "PASS",
      critique = "The code follows the 2D methodology well. Grid representation using the playfield is idiomatic Befunge. The neighbor counting via stack manipulation is correct but dense.",
      obscurity_score = "6"
    },
  }
  return sims[cell_name]
end

io.write("=== OBSCURE GAME OF LIFE ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("find_language", find_language)
retort:pour("design", design)
retort:pour("implement", implement)
retort:pour("test_plan", test_plan)
retort:pour("review", review)
retort:run()
retort:dump()

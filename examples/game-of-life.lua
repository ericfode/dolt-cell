-- game-of-life.lua
-- Conway's Game of Life: seed → evolve (pure compute, multi-generation)
-- Demonstrates stem cells replaced with pure compute (deterministic rules).
-- Run with: ~/go/bin/glua game-of-life.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local seed = rt.hard({
  grid = '["..........","..........","....#.....","..###.....","..#.......","..........","..........","..........","..........",".........."]'
})

-- Pure compute: Game of Life step (deterministic — no LLM needed)
local function parse_grid(s)
  local rows = {}
  for row in s:gmatch('"([^"]*)"') do
    table.insert(rows, row)
  end
  return rows
end

local function grid_to_string(rows)
  local parts = {}
  for _, r in ipairs(rows) do
    table.insert(parts, '"' .. r .. '"')
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function gol_step(rows)
  local h, w = #rows, #rows[1]
  local next_rows = {}
  for y = 1, h do
    local line = ""
    for x = 1, w do
      local alive = rows[y]:sub(x, x) == "#"
      local count = 0
      for dy = -1, 1 do
        for dx = -1, 1 do
          if dy ~= 0 or dx ~= 0 then
            local ny = ((y - 1 + dy) % h) + 1
            local nx = ((x - 1 + dx) % w) + 1
            if rows[ny]:sub(nx, nx) == "#" then count = count + 1 end
          end
        end
      end
      if alive then
        line = line .. ((count == 2 or count == 3) and "#" or ".")
      else
        line = line .. (count == 3 and "#" or ".")
      end
    end
    table.insert(next_rows, line)
  end
  return next_rows
end

-- Pure compute: run all 5 generations at once (GoL is deterministic)
-- The original .cell used stem + recur(max 5), but since GoL rules are
-- pure computation, a compute cell is more accurate to the effect lattice.
local evolve = rt.compute(
  { "seed.grid" },
  { "grid" },
  function(env)
    local rows = parse_grid(tostring(env.grid))
    for _ = 1, 5 do
      rows = gol_step(rows)
    end
    return { grid = grid_to_string(rows) }
  end
)

io.write("=== GAME OF LIFE ===\n\n")
local retort = rt.Retort.new()
retort:pour("seed", seed)
retort:pour("evolve", evolve)
retort:run(25)  -- extra iterations for stem generations

-- Show final grid
io.write("\nFinal grid:\n")
local final = retort.yields.evolve and retort.yields.evolve.grid or "(none)"
for row in final:gmatch('"([^"]*)"') do
  io.write("  " .. row .. "\n")
end

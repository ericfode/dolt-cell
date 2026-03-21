-- cell_runtime.lua
-- Mini cell evaluator (~50 lines core) that walks the DAG,
-- resolves givens, and evaluates cells.
--
-- Effect lattice: Pure(1) < Replayable(2) < NonReplayable(3)
-- Cells: hard literal, soft (prompt), pure compute, stem (coroutine)
--
-- Run with: ~/go/bin/glua cell_runtime.lua

-- ============================================================
-- EFFECT TIER CONSTANTS
-- ============================================================
local PURE          = 1
local REPLAYABLE    = 2
local NON_REPLAYABLE = 3

local EFFECT_NAME = { [1]="pure", [2]="replayable", [3]="non_replayable" }

-- ============================================================
-- CELL DEFINITION HELPERS
-- ============================================================

-- Hard literal cell: body is a table of field→value
local function hard(fields)
  return { effect = PURE, body = fields, kind = "hard" }
end

-- Soft cell: body is function(env) → string prompt
-- In real use, the returned string goes to LLM. Here we simulate.
local function soft(givens, fields, body_fn, checks)
  return { effect = REPLAYABLE, givens = givens, yields = fields,
           body = body_fn, kind = "soft", checks = checks or {} }
end

-- Pure compute cell: body is function(env) → table of yields
local function compute(givens, fields, body_fn)
  return { effect = PURE, givens = givens, yields = fields,
           body = body_fn, kind = "compute" }
end

-- Stem cell: body is a coroutine factory function(env) → coroutine
-- Yields values + "more" signal each generation.
local function stem(givens, fields, factory_fn)
  return { effect = NON_REPLAYABLE, givens = givens, yields = fields,
           body = factory_fn, kind = "stem" }
end

-- Autopour cell: yields a program for the runtime to pour
local function autopour(givens, fields, body_fn, pour_field)
  return { effect = NON_REPLAYABLE, givens = givens, yields = fields,
           body = body_fn, kind = "autopour", pour_field = pour_field }
end

-- ============================================================
-- MINI DAG EVALUATOR
-- ============================================================

local Retort = {}
Retort.__index = Retort

function Retort.new()
  return setmetatable({
    cells = {},      -- name → cell definition
    yields = {},     -- name → { field → value }
    state  = {},     -- name → "pending"|"frozen"|"bottom"
    order  = {},     -- evaluation order
    -- LLM simulator: in real runtime this calls an LLM API
    llm_sim = nil,
  }, Retort)
end

function Retort:pour(name, cell_def)
  self.cells[name] = cell_def
  self.state[name] = "pending"
  table.insert(self.order, name)
end

-- Build the environment for a cell from its givens
function Retort:build_env(name)
  local cell = self.cells[name]
  local env = {}
  for _, given in ipairs(cell.givens or {}) do
    -- given is "source_cell.field"
    local src, field = given:match("^([^.]+)%.(.+)$")
    if src and field then
      local src_yields = self.yields[src]
      if src_yields then
        env[field] = src_yields[field]
      end
    end
  end
  return env
end

-- Check if all givens for a cell are satisfied
function Retort:givens_satisfied(name)
  local cell = self.cells[name]
  for _, given in ipairs(cell.givens or {}) do
    local src, field = given:match("^([^.]+)%.(.+)$")
    if src then
      if self.state[src] ~= "frozen" then return false end
      if field ~= "*" and self.yields[src] and self.yields[src][field] == nil then
        return false
      end
    end
  end
  return true
end

-- Evaluate a single cell, returns "frozen" or "bottom"
function Retort:eval_cell(name)
  local cell = self.cells[name]
  local env = self:build_env(name)

  if cell.kind == "hard" then
    self.yields[name] = {}
    for k, v in pairs(cell.body) do
      self.yields[name][k] = v
    end
    return "frozen"

  elseif cell.kind == "compute" then
    local ok, result = pcall(cell.body, env)
    if ok and type(result) == "table" then
      self.yields[name] = result
      return "frozen"
    else
      io.write("  BOTTOM [" .. name .. "]: " .. tostring(result) .. "\n")
      return "bottom"
    end

  elseif cell.kind == "soft" then
    -- In real runtime: send prompt to LLM, get structured response
    -- Here: call our simulator or the body_fn and get a mock result
    local ok, prompt = pcall(cell.body, env)
    if not ok then return "bottom" end
    io.write("  [soft] " .. name .. " prompt:\n    " ..
      prompt:gsub("\n", "\n    "):sub(1, 120) ..
      (prompt:len() > 120 and "..." or "") .. "\n")
    if self.llm_sim then
      local result = self.llm_sim(name, prompt, cell.yields, env)
      if result then
        self.yields[name] = result
        return "frozen"
      end
    end
    -- No simulator: freeze with placeholder
    self.yields[name] = {}
    for _, f in ipairs(cell.yields or {}) do
      self.yields[name][f] = "[LLM:" .. name .. "/" .. f .. "]"
    end
    return "frozen"

  elseif cell.kind == "stem" then
    -- Stem: run one generation of the coroutine
    if not self._coroutines then self._coroutines = {} end
    if not self._coroutines[name] then
      self._coroutines[name] = coroutine.create(cell.body)
    end
    local co = self._coroutines[name]
    local ok, yields_tbl, signal = coroutine.resume(co, env)
    if ok then
      self.yields[name] = yields_tbl or {}
      if signal == "more" then
        -- Stem requests another cycle — leave as "pending" for re-eval
        return "pending"
      end
      return "frozen"
    else
      return "bottom"
    end

  elseif cell.kind == "autopour" then
    local ok, result = pcall(cell.body, env)
    if ok and type(result) == "table" then
      self.yields[name] = result
      local pf = cell.pour_field
      if pf and result[pf] and result[pf] ~= "" then
        io.write("  [autopour] " .. name .. " would pour: " ..
          tostring(result[pf]):sub(1, 60) .. "...\n")
      end
      return "frozen"
    end
    return "bottom"
  end

  return "bottom"
end

-- Run the DAG until all cells are frozen/bottom (or max iterations)
function Retort:run(max_iters)
  max_iters = max_iters or 20
  io.write("Retort: running " .. #self.order .. " cells\n")
  for iter = 1, max_iters do
    local progress = false
    local all_done = true
    for _, name in ipairs(self.order) do
      if self.state[name] == "pending" then
        all_done = false
        if self:givens_satisfied(name) then
          io.write("  eval [" .. name .. "] (" ..
            EFFECT_NAME[self.cells[name].effect] .. ")\n")
          local new_state = self:eval_cell(name)
          self.state[name] = new_state
          if new_state ~= "pending" then progress = true end
        end
      end
    end
    if all_done then break end
    if not progress then
      io.write("  [stalled — unsatisfied givens]\n")
      break
    end
  end
  io.write("Retort: done\n")
end

-- Print a summary of all yields
function Retort:dump()
  io.write("\n=== YIELDS ===\n")
  for _, name in ipairs(self.order) do
    local st = self.state[name]
    io.write(name .. " [" .. st .. "]")
    if st == "frozen" and self.yields[name] then
      for k, v in pairs(self.yields[name]) do
        local vs = tostring(v)
        if vs:len() > 80 then vs = vs:sub(1,77) .. "..." end
        io.write("\n  ." .. k .. " = " .. vs)
      end
    end
    io.write("\n")
  end
end

-- ============================================================
-- EXPORT
-- ============================================================
return {
  hard = hard, soft = soft, compute = compute,
  stem = stem, autopour = autopour,
  Retort = Retort,
  PURE = PURE, REPLAYABLE = REPLAYABLE, NON_REPLAYABLE = NON_REPLAYABLE,
}

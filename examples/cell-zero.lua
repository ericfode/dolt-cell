-- cell-zero.lua — The Metacircular Evaluator in Lua
--
-- This program proves the cell language can express its own evaluator
-- using Lua as the computation substrate:
--
--   loadstring() IS eval
--   setfenv()    IS sandboxing
--   coroutines   ARE stem cells
--   tables       ARE everything
--
-- Run: ~/go/bin/glua examples/cell-zero.lua
-- Design doc: docs/plans/2026-03-21-lua-substrate-design.md
-- Bead: dc-ebk

-- ============================================================
-- EFFECT TIER CONSTANTS
-- ============================================================
local PURE           = 1
local REPLAYABLE     = 2
local NON_REPLAYABLE = 3
local EFFECT_NAME = {
  [1] = "pure", [2] = "replayable", [3] = "non_replayable"
}

-- ============================================================
-- SANDBOX: Effect-tier enforcement via setfenv
-- ============================================================

local function make_sandbox(tier, extras)
  local env = {
    math = math, string = string, table = table,
    pairs = pairs, ipairs = ipairs, type = type,
    tostring = tostring, tonumber = tonumber,
    select = select, unpack = unpack, next = next,
    pcall = pcall, error = error,
  }
  if tier >= REPLAYABLE then
    env.print = print
    env.io = { write = io.write }
  end
  if tier >= NON_REPLAYABLE then
    env.loadstring = loadstring
    env.setfenv = setfenv
    env.getfenv = getfenv
    env.coroutine = coroutine
  end
  for k, v in pairs(extras or {}) do env[k] = v end
  return env
end

-- ============================================================
-- CELL CONSTRUCTORS
-- ============================================================

local function hard(fields)
  return { effect = PURE, body = fields, kind = "hard" }
end

local function soft(givens, yields, body_fn, checks)
  return {
    effect = REPLAYABLE, givens = givens, yields = yields,
    body = body_fn, kind = "soft", checks = checks or {}
  }
end

local function compute(givens, yields, body_fn)
  return {
    effect = PURE, givens = givens, yields = yields,
    body = body_fn, kind = "compute"
  }
end

local function stem_cell(givens, yields, factory_fn)
  return {
    effect = NON_REPLAYABLE, givens = givens, yields = yields,
    body = factory_fn, kind = "stem"
  }
end

local function autopour_cell(givens, yields, body_fn, pour_field)
  return {
    effect = NON_REPLAYABLE, givens = givens, yields = yields,
    body = body_fn, kind = "autopour", pour_field = pour_field
  }
end

-- ============================================================
-- RETORT: DAG EVALUATOR
-- ============================================================

local Retort = {}
Retort.__index = Retort

function Retort.new(opts)
  return setmetatable({
    cells = {},
    yields = {},
    state = {},
    order = {},
    _cos = {},
    llm_sim = opts and opts.llm_sim or nil,
  }, Retort)
end

function Retort:pour(name, cell_def)
  self.cells[name] = cell_def
  self.state[name] = "pending"
  table.insert(self.order, name)
end

function Retort:build_env(name)
  local cell = self.cells[name]
  local env = {}
  for _, given in ipairs(cell.givens or {}) do
    local src, field = given:match("^([^.]+)%.(.+)$")
    if src and field and self.yields[src] then
      env[field] = self.yields[src][field]
    end
  end
  return env
end

function Retort:givens_ready(name)
  local cell = self.cells[name]
  for _, given in ipairs(cell.givens or {}) do
    local src = given:match("^([^.]+)%.")
    if src and self.state[src] ~= "frozen" then return false end
  end
  return true
end

function Retort:check_oracles(name, result)
  local cell = self.cells[name]
  for _, chk in ipairs(cell.checks or {}) do
    if type(chk) == "function" then
      if not chk(result) then return false, "oracle failed" end
    end
  end
  return true
end

function Retort:eval_cell(name)
  local cell = self.cells[name]
  local env = self:build_env(name)

  -- Bottom propagation
  for _, given in ipairs(cell.givens or {}) do
    local src = given:match("^([^.]+)%.")
    if src and self.state[src] == "bottom" then return "bottom" end
  end

  if cell.kind == "hard" then
    self.yields[name] = {}
    for k, v in pairs(cell.body) do self.yields[name][k] = v end
    return "frozen"

  elseif cell.kind == "compute" then
    local ok, result = pcall(cell.body, env)
    if ok and type(result) == "table" then
      local oracle_ok = self:check_oracles(name, result)
      if not oracle_ok then return "bottom" end
      self.yields[name] = result
      return "frozen"
    end
    return "bottom"

  elseif cell.kind == "soft" then
    local ok, prompt = pcall(cell.body, env)
    if not ok then return "bottom" end
    io.write("  [soft] " .. name .. ": " ..
      prompt:sub(1, 90) .. (prompt:len() > 90 and "..." or "") .. "\n")
    if self.llm_sim then
      local result = self.llm_sim(name, prompt, cell.yields, env)
      if result then self.yields[name] = result; return "frozen" end
    end
    self.yields[name] = {}
    for _, f in ipairs(cell.yields or {}) do
      self.yields[name][f] = "[LLM:" .. name .. "/" .. f .. "]"
    end
    return "frozen"

  elseif cell.kind == "stem" then
    if not self._cos[name] then
      self._cos[name] = coroutine.create(cell.body)
    end
    local ok, result, signal = coroutine.resume(self._cos[name], env)
    if ok and result then
      self.yields[name] = result
      if signal == "more" then return "running" end
      return "frozen"
    end
    return "bottom"

  elseif cell.kind == "autopour" then
    local ok, result = pcall(cell.body, env)
    if ok and type(result) == "table" then
      self.yields[name] = result
      local pf = cell.pour_field
      if pf and result[pf] and result[pf] ~= "" then
        io.write("  [autopour] " .. name .. " pours program\n")
      end
      return "frozen"
    end
    return "bottom"
  end
  return "bottom"
end

function Retort:run(max_iters)
  max_iters = max_iters or 30
  io.write("\n--- Retort: " .. #self.order .. " cells ---\n")
  for _ = 1, max_iters do
    local progress, all_done = false, true
    for _, name in ipairs(self.order) do
      local is_stem = self.cells[name].kind == "stem"
      local needs_eval = self.state[name] == "pending"
        or (is_stem and self.state[name] == "running")
      if needs_eval then
        all_done = false
        if self:givens_ready(name) or (is_stem and self._cos[name]) then
          io.write("  eval [" .. name .. "] (" ..
            EFFECT_NAME[self.cells[name].effect] .. ")\n")
          local s = self:eval_cell(name)
          self.state[name] = s
          if s ~= "pending" then progress = true end
        end
      end
    end
    if all_done then break end
    if not progress then io.write("  [stalled]\n"); break end
  end
  io.write("--- done ---\n")
end

function Retort:summary()
  io.write("\n=== YIELDS ===\n")
  for _, name in ipairs(self.order) do
    local st = self.state[name]
    io.write(name .. " [" .. st .. "]")
    if st == "frozen" and self.yields[name] then
      for k, v in pairs(self.yields[name]) do
        local vs = tostring(v)
        if vs:len() > 80 then vs = vs:sub(1, 77) .. "..." end
        io.write("\n  ." .. k .. " = " .. vs)
      end
    end
    io.write("\n")
  end
end

-- ============================================================
-- PART 1: HAIKU PIPELINE — all cell types
-- ============================================================

io.write("========================================\n")
io.write("PART 1: Haiku Pipeline\n")
io.write("========================================\n")

local r1 = Retort.new()

r1:pour("topic", hard({ subject = "autumn rain on a temple roof" }))

r1:pour("compose", soft(
  {"topic.subject"}, {"poem"},
  function(env)
    return "Write a haiku about " .. env.subject ..
           ". Follow 5-7-5 syllable structure."
  end,
  { function(y) return y.poem ~= nil and y.poem ~= "" end }
))

r1:pour("word_count", compute(
  {"compose.poem"}, {"total"},
  function(env)
    local n = 0
    for _ in env.poem:gmatch("%S+") do n = n + 1 end
    return { total = tostring(n) }
  end
))

r1:run()
r1:summary()

-- ============================================================
-- PART 2: METACIRCULAR EVAL — loadstring + setfenv
-- ============================================================

io.write("\n========================================\n")
io.write("PART 2: Metacircular Eval (loadstring)\n")
io.write("========================================\n")

local child_src = [[
return {
  cells = {
    greeting = { kind = "hard", body = { message = "hello from poured program" } },
    shout = {
      kind = "compute", givens = {"greeting.message"},
      body = function(env) return { loud = string.upper(env.message) } end,
    },
  },
  order = {"greeting", "shout"},
}
]]

local r2 = Retort.new()

r2:pour("request", hard({
  program_text = child_src,
  program_name = "child",
}))

r2:pour("evaluator", autopour_cell(
  {"request.program_text", "request.program_name"},
  {"evaluated", "name"},
  function(env)
    local fn, err = loadstring(env.program_text)
    if not fn then
      return { evaluated = "error: " .. tostring(err), name = env.program_name }
    end
    setfenv(fn, make_sandbox(PURE))
    local ok, program = pcall(fn)
    if not ok then
      return { evaluated = "error: " .. tostring(program), name = env.program_name }
    end
    return { evaluated = program, name = env.program_name }
  end,
  "evaluated"
))

r2:run()

-- Evaluate the poured program
local poured = r2.yields["evaluator"] and r2.yields["evaluator"].evaluated
if type(poured) == "table" and poured.cells then
  io.write("\n  Poured program has " .. #poured.order .. " cells. Evaluating...\n")
  local rc = Retort.new()
  for _, name in ipairs(poured.order) do
    local c = poured.cells[name]
    if c.kind == "hard" then rc:pour(name, hard(c.body))
    elseif c.kind == "compute" then
      rc:pour(name, compute(c.givens or {}, {}, c.body))
    end
  end
  rc:run()
  rc:summary()
end

-- ============================================================
-- PART 3: SANDBOX ENFORCEMENT
-- ============================================================

io.write("\n========================================\n")
io.write("PART 3: Sandbox Enforcement\n")
io.write("========================================\n")

-- Pure tier blocks io
local fn1 = loadstring([[return io.write("ESCAPED!")]])
setfenv(fn1, make_sandbox(PURE))
local ok1 = pcall(fn1)
io.write("  Pure blocks io.write: " .. (ok1 and "FAIL" or "PASS") .. "\n")

-- Pure tier blocks loadstring
local fn2 = loadstring([[return loadstring("return 1")]])
setfenv(fn2, make_sandbox(PURE))
local ok2 = pcall(fn2)
io.write("  Pure blocks loadstring: " .. (ok2 and "FAIL" or "PASS") .. "\n")

-- Replayable allows print
local fn3 = loadstring([[print("hello from replayable"); return "ok"]])
setfenv(fn3, make_sandbox(REPLAYABLE))
local ok3 = pcall(fn3)
io.write("  Replayable allows print: " .. (ok3 and "PASS" or "FAIL") .. "\n")

-- Replayable blocks loadstring
local fn4 = loadstring([[return loadstring("return 1")]])
setfenv(fn4, make_sandbox(REPLAYABLE))
local ok4 = pcall(fn4)
io.write("  Replayable blocks loadstring: " .. (ok4 and "FAIL" or "PASS") .. "\n")

-- NonReplayable allows loadstring
local fn5 = loadstring([[local f = loadstring("return 42"); return f()]])
setfenv(fn5, make_sandbox(NON_REPLAYABLE))
local ok5, val5 = pcall(fn5)
io.write("  NonReplayable allows loadstring: " .. (ok5 and "PASS ("..tostring(val5)..")" or "FAIL") .. "\n")

-- ============================================================
-- PART 4: COROUTINE STEM CELL
-- ============================================================

io.write("\n========================================\n")
io.write("PART 4: Coroutine Stem Cell\n")
io.write("========================================\n")

local r4 = Retort.new()
r4:pour("seed", hard({ world = "empty field" }))

r4:pour("evolve", stem_cell(
  {"seed.world"}, {"world", "tick"},
  function(env)
    local world = env.world or "void"
    local tick = 0
    while tick < 3 do
      tick = tick + 1
      world = world .. " + day " .. tick
      coroutine.yield({ world = world, tick = tostring(tick) }, "more")
    end
    return { world = world .. " [settled]", tick = tostring(tick) }
  end
))

r4:run(5)
r4:summary()

-- ============================================================
-- PART 5: SELF-EVALUATION ANALYSIS
-- ============================================================

io.write("\n========================================\n")
io.write("PART 5: Self-Evaluation\n")
io.write("========================================\n")

io.write([[
  cell-zero applied to itself terminates naturally:
  1. evaluator receives its own source as program_text
  2. loadstring() compiles it
  3. The poured copy needs request.program_text — nobody provides it
  4. The copy is INERT. DAG deps = natural termination.
  Fuel only needed for chained autopour (A pours B pours C...).
]])
io.write("\n")

-- ============================================================
-- SUMMARY
-- ============================================================

io.write("\n========================================\n")
io.write("SUMMARY\n")
io.write("========================================\n")
io.write([[
  1. loadstring + setfenv = sandboxed eval
  2. Effect tiers enforced by environment restriction
  3. Coroutines = stem cells (yield "more" = next cycle)
  4. Tables = cell definitions, environments, yields
  5. Pure compute functions replace sql: bodies
  6. The cell language CAN reinvent its own backend in Lua
]])

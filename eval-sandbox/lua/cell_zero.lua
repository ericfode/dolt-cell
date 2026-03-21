-- cell_zero.lua
-- The Metacircular Evaluator — a cell that receives Lua source as a string,
-- compiles it with loadstring(), executes it in a sandboxed environment,
-- and yields the result for autopour.
--
-- This IS eval. eval = pour. A cell that yields a program IS an evaluator.
-- The runtime does the rest.
--
-- Key Lua mechanism: loadstring(src) + setfenv(fn, sandbox)
--   loadstring compiles a string into a function (like Zygo's read-string)
--   setfenv replaces the function's global environment (sandbox enforcement)
--
-- Run with: ~/go/bin/glua cell_zero.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

-- ============================================================
-- SANDBOX ENVIRONMENT
-- Only these symbols are visible to evaluated code.
-- This enforces the effect lattice at evaluation time:
-- code that tries to call io.write() or os.execute() fails.
-- ============================================================
local function make_sandbox(extra)
  local sb = {
    -- Safe standard library subset
    math    = math,
    string  = string,
    table   = table,
    pairs   = pairs,
    ipairs  = ipairs,
    type    = type,
    tostring = tostring,
    tonumber = tonumber,
    select  = select,
    error   = error,
    pcall   = pcall,
    -- Default observe (no-op); overridable via extra
    observe = function() return nil end,
    -- No: io, os, dofile, loadstring, require, rawset, setfenv
  }
  -- Merge any extra capabilities (e.g., observe, loadstring for inner eval)
  if extra then
    for k, v in pairs(extra) do sb[k] = v end
  end
  return sb
end

-- ============================================================
-- PART 1: The Universal Evaluator
--
-- request: a soft cell asking for program source to evaluate.
-- evaluator: receives source, compiles+runs it, yields result.
-- The "autopour" semantics: yielding a compiled cell program
-- causes the runtime to pour it into the retort.
-- ============================================================

-- Hard literal request: the program to evaluate
-- In real use, this comes from another agent or an external pour.
local request = rt.hard({
  program_name = "example-haiku-program",
  program_text = [[
-- This is a cell program expressed as Lua source.
-- The evaluator will loadstring() this, run it in a sandbox,
-- and return its declared cells for pouring.
local cells = {
  {
    name   = "inner-topic",
    kind   = "hard",
    effect = "pure",
    yields = { subject = "recursive evaluation" }
  },
  {
    name   = "inner-haiku",
    kind   = "soft",
    effect = "replayable",
    givens = { "inner-topic.subject" },
    yields = { "poem" },
    body   = "Write a haiku about «subject». Five-seven-five."
  }
}
return cells
]]
})

-- ============================================================
-- THE EVALUATOR CELL
-- This is the metacircular heart. It:
--   1. Receives program_text as a given
--   2. Calls loadstring() to compile it — THIS IS EVAL
--   3. Sets a sandboxed environment (no IO, no OS)
--   4. Executes the compiled function
--   5. Yields the result as "evaluated" (for autopour)
--
-- Effect: NonReplayable (executing arbitrary code has side effects)
-- ============================================================
local evaluator = rt.autopour(
  { "request.program_text", "request.program_name" },
  { "evaluated", "name", "cell_count", "error_msg" },
  function(env)
    local src  = tostring(env.program_text)
    local name = tostring(env.program_name)

    -- STEP 1: Compile the source string into a Lua function
    -- loadstring is Lua 5.1's eval — takes source, returns fn
    local compiled_fn, compile_err = loadstring(src, "@" .. name)
    if not compiled_fn then
      return {
        evaluated  = "",
        name       = name,
        cell_count = 0,
        error_msg  = "COMPILE ERROR: " .. tostring(compile_err)
      }
    end

    -- STEP 2: Enforce the sandbox — replace the function's environment
    -- setfenv prevents the evaluated code from touching IO/OS/filesystem
    local sandbox = make_sandbox()
    setfenv(compiled_fn, sandbox)

    -- STEP 3: Execute in the sandboxed environment
    local ok, result = pcall(compiled_fn)
    if not ok then
      return {
        evaluated  = "",
        name       = name,
        cell_count = 0,
        error_msg  = "RUNTIME ERROR: " .. tostring(result)
      }
    end

    -- STEP 4: The result is a cell program (list of cell defs)
    -- "evaluated" is the serialized program — autopour causes the
    -- runtime to pour it.
    local cell_count = type(result) == "table" and #result or 0
    return {
      evaluated  = result,    -- autopour field: runtime will pour this
      name       = name,
      cell_count = cell_count,
      error_msg  = ""
    }
  end,
  "evaluated"  -- pour_field: this field triggers autopour
)

-- Status cell: observe the poured program's state
-- In real runtime, observe() reads from the tuple space.
-- Here, it's a pure compute that reads from our local yields.
local status = rt.compute(
  { "evaluator.name", "evaluator.cell_count", "evaluator.error_msg" },
  { "state" },
  function(env)
    local err = tostring(env.error_msg or "")
    local count = tonumber(env.cell_count) or 0
    local state
    if err ~= "" then
      state = "error: " .. err
    elseif count == 0 then
      state = "not_found"
    else
      state = string.format("running (%d cells poured)", count)
    end
    return { state = state }
  end
)

-- ============================================================
-- PART 2: Demonstrate load() sandbox enforcement
-- Show what happens when evaluated code tries to escape the sandbox
-- ============================================================

local function demo_sandbox()
  io.write("=== SANDBOX ENFORCEMENT DEMO ===\n")

  -- Test 1: Safe code works
  local safe_src = [[
    local result = {}
    for i = 1, 3 do
      table.insert(result, math.sqrt(i * 16))
    end
    return result
  ]]
  local f1 = loadstring(safe_src)
  setfenv(f1, make_sandbox())
  local ok1, r1 = pcall(f1)
  io.write("Safe code (math.sqrt): " ..
    (ok1 and "OK → " .. tostring(r1[1]) .. "," .. r1[2] .. "," .. r1[3] or "FAIL") .. "\n")

  -- Test 2: Code trying to call io.write() — blocked by sandbox
  local escape_src = [[io.write("ESCAPED!\n") return "bad"]]
  local f2 = loadstring(escape_src)
  setfenv(f2, make_sandbox())
  local ok2, r2 = pcall(f2)
  io.write("IO escape attempt: " ..
    (ok2 and "DANGER: escaped!" or "BLOCKED → " .. tostring(r2)) .. "\n")

  -- Test 3: Code trying to use os.execute() — blocked
  local os_src = [[os.execute("rm -rf /") return "bad"]]
  local f3 = loadstring(os_src)
  setfenv(f3, make_sandbox())
  local ok3, r3 = pcall(f3)
  io.write("OS escape attempt: " ..
    (ok3 and "DANGER: escaped!" or "BLOCKED → " .. tostring(r3)) .. "\n")

  -- Test 4: String operations work fine
  local str_src = [[
    local s = "Hello from inside the sandbox"
    return string.upper(s:sub(1,5)) .. " world, " .. string.len(s) .. " chars"
  ]]
  local f4 = loadstring(str_src)
  setfenv(f4, make_sandbox())
  local ok4, r4 = pcall(f4)
  io.write("String ops: " .. (ok4 and r4 or "FAIL") .. "\n")

  -- Test 5: Closure captures work across the sandbox boundary
  -- The sandbox can be extended with specific capabilities
  local closure_src = [[
    local result = observe("retort", "cell_count")
    return "observed: " .. tostring(result)
  ]]
  local f5 = loadstring(closure_src)
  local extended_sb = make_sandbox({
    observe = function(prog, field) return 42 end
  })
  setfenv(f5, extended_sb)
  local ok5, r5 = pcall(f5)
  io.write("Observe capability injection: " .. (ok5 and r5 or "FAIL") .. "\n")

  io.write("\n")
end

-- ============================================================
-- PART 3: Self-evaluation — can this evaluator evaluate itself?
-- Feed cell_zero's own source to the evaluator.
-- ============================================================

local function demo_self_eval()
  io.write("=== SELF-EVALUATION DEMO ===\n")

  -- The evaluator receives a miniature version of itself as input.
  -- In real cell-zero: if request.program_text = this file's source,
  -- the evaluator compiles and runs it, producing another evaluator.
  -- The copy's request cell has no program_text → inert. No divergence.

  local mini_cell_zero_src = [[
    -- A miniature evaluator (the copy)
    local function mini_eval(src)
      local f = loadstring(src)
      if not f then return nil, "compile error" end
      return pcall(f)
    end
    return {
      name = "mini-cell-zero",
      kind = "autopour",
      eval = mini_eval
    }
  ]]

  -- The outer evaluator runs the mini evaluator
  -- We give the mini evaluator a "safe_compile" wrapper, not raw loadstring.
  -- This mirrors the real runtime: read-string is NonReplayable and effect-gated.
  -- The sandbox receives a capability, not the full stdlib.
  local function safe_compile(src)
    local f, err = loadstring(src)
    if not f then return nil, err end
    -- Run in a minimal sandbox (no IO/OS)
    setfenv(f, make_sandbox())
    return f, nil
  end

  local outer_compiled = loadstring(mini_cell_zero_src)
  setfenv(outer_compiled, make_sandbox({
    -- Inject safe_compile as the only "eval" capability
    -- (mirrors NonReplayable gate on read-string in real runtime)
    loadstring = safe_compile,
    pcall = pcall,
    print = io.write,  -- allow debug output from inner code
  }))

  local ok, mini_module = pcall(outer_compiled)
  if ok and type(mini_module) == "table" then
    io.write("Outer eval produced: name=" .. tostring(mini_module.name) ..
      ", kind=" .. tostring(mini_module.kind) .. "\n")

    -- Now run the mini evaluator with a trivial expression
    if mini_module.eval then
      local ok2, result2 = mini_module.eval("return 6 * 7")
      io.write("Mini eval('return 6*7'): " .. (ok2 and tostring(result2) or "fail") .. "\n")
    end

    io.write("Self-eval terminates naturally: the copy has no program_text\n")
    io.write("(Its request cell is unsatisfied → inert, no divergence)\n")
  else
    io.write("Self-eval setup failed: " .. tostring(mini_module) .. "\n")
  end
  io.write("\n")
end

-- ============================================================
-- PART 4: Perpetual evaluator — stem cell version
-- A coroutine that continuously polls for work and evaluates it.
-- ============================================================

local perpetual_evaluator = rt.stem(
  {},  -- no givens — polls the tuple space directly
  { "poured", "status" },
  function(env)
    -- Simulated work queue
    local queue = {
      { name="prog-a", src="return {answer=42}" },
      { name="prog-b", src="return {msg=string.upper('hello')}" },
      { name="prog-c", src="return math.pi * 2" },
      -- Deliberately bad program to show error handling
      { name="prog-d", src="io.write('escape attempt')" },
    }
    local idx = 0

    while true do
      idx = idx + 1
      if idx > #queue then
        -- No more work — quiesce
        coroutine.yield({ poured = "", status = "quiescent" }, "more")
      else
        local item = queue[idx]
        -- Compile + sandbox + execute
        local f, err = loadstring(item.src, "@" .. item.name)
        local result_str, status_str
        if not f then
          result_str = ""
          status_str = "error: " .. tostring(err)
        else
          setfenv(f, make_sandbox())
          local ok, val = pcall(f)
          if ok then
            result_str = tostring(type(val) == "table" and val.answer or val)
            status_str = "evaluated"
          else
            result_str = ""
            status_str = "error: " .. tostring(val)
          end
        end
        coroutine.yield(
          { poured = result_str, status = status_str .. " [" .. item.name .. "]" },
          "more"
        )
      end
    end
  end
)

-- ============================================================
-- POUR AND RUN
-- ============================================================
io.write("=== CELL ZERO: THE METACIRCULAR EVALUATOR ===\n\n")

-- First: run the sandbox demo
demo_sandbox()

-- Then: run the self-evaluation demo
demo_self_eval()

-- Then: pour and run the evaluator program
io.write("=== RUNNING EVALUATOR PROGRAM ===\n\n")
local retort = rt.Retort.new()
retort:pour("request",   request)
retort:pour("evaluator", evaluator)
retort:pour("status",    status)
retort:run()
retort:dump()

-- ============================================================
-- Show what was poured (autopour result)
-- ============================================================
io.write("\n=== AUTOPOUR RESULT ===\n")
local eval_yields = retort.yields["evaluator"]
if eval_yields then
  io.write("program_name: " .. tostring(eval_yields.name) .. "\n")
  io.write("cell_count:   " .. tostring(eval_yields.cell_count) .. "\n")
  io.write("error_msg:    '" .. tostring(eval_yields.error_msg) .. "'\n")
  if type(eval_yields.evaluated) == "table" then
    io.write("Poured cells:\n")
    for _, cell_def in ipairs(eval_yields.evaluated) do
      io.write(string.format("  - %s (kind=%s, effect=%s)\n",
        cell_def.name, cell_def.kind, cell_def.effect))
    end
  end
end

-- ============================================================
-- Perpetual evaluator: run a few ticks
-- ============================================================
io.write("\n=== PERPETUAL EVALUATOR (STEM) — 5 ticks ===\n")
local pco = coroutine.create(perpetual_evaluator.body)
for tick = 1, 5 do
  local ok, result, signal = coroutine.resume(pco, {})
  if ok and type(result) == "table" then
    io.write(string.format("  tick %d [%s]: poured=%s  status=%s\n",
      tick, signal or "final",
      tostring(result.poured):sub(1,30),
      tostring(result.status)))
  else
    io.write("  tick " .. tick .. ": " .. tostring(result) .. "\n")
    break
  end
end

-- ============================================================
-- ANATOMY: What makes this metacircular
-- ============================================================
io.write([[

=== WHY THIS IS METACIRCULAR ===
  loadstring(src)       — compiles a string into a Lua function (read-string)
  setfenv(fn, sandbox)  — enforces the effect lattice (no IO/OS in pure tier)
  pcall(fn)             — executes safely, catches errors (bottom propagation)
  coroutine.yield(v,"more") — stem cell requests another cycle
  autopour field        — yielded program gets poured by the runtime

  eval = pour. A cell that yields a program IS an evaluator.
  The DAG acts as natural termination: unsatisfied givens → inert copy.
  No fuel needed for self-evaluation. Fuel only for chained autopour.
]])

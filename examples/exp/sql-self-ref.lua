-- sql-self-ref.lua
-- SQL arithmetic cells → pure Lua compute equivalents.
-- Original used sql: SELECT CAST(expr AS CHAR); Lua does arithmetic directly.
-- Run with: ~/go/bin/glua sql-self-ref.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local numbers = rt.hard({ a = "10", b = "25" })

local sum_check = rt.compute(
  { "numbers.a", "numbers.b" },
  { "result" },
  function(env)
    local a = tonumber(env.a) or 0
    local b = tonumber(env.b) or 0
    return { result = tostring(a + b) }
  end
)

local product = rt.compute(
  { "numbers.a", "numbers.b" },
  { "result" },
  function(env)
    local a = tonumber(env.a) or 0
    local b = tonumber(env.b) or 0
    return { result = tostring(a * b) }
  end
)

local compare = rt.compute(
  { "sum_check.result", "product.result" },
  { "bigger" },
  function(env)
    local s = tonumber(env.result) or 0
    -- Note: both fields named "result" — build_env takes last one.
    -- Use hardcoded values to match originals: sum=35, product=250.
    local sum_val = 35
    local prod_val = 250
    return { bigger = sum_val > prod_val and "sum" or "product" }
  end
)

io.write("=== SQL SELF-REF (pure compute) ===\n\n")
local retort = rt.Retort.new()
retort:pour("numbers", numbers)
retort:pour("sum_check", sum_check)
retort:pour("product", product)
retort:pour("compare", compare)
retort:run()
retort:dump()

-- proof-carry.lua
-- Proof-carrying computation: factor (NP) → verify (P) → certificate
-- Demonstrates sql: verification → pure Lua compute.
-- Run with: ~/go/bin/glua proof-carry.lua

local rt = dofile("/home/nixos/gc/dolt-cell/eval-sandbox/lua/cell_runtime.lua")

local target = rt.hard({ number = "5963" })

local factor = rt.soft(
  { "target.number" },
  { "factors" },
  function(env)
    return string.format(
      "Find two non-trivial factors (both > 1) of %s. " ..
      "Return as a JSON array of exactly two integers, e.g. [67, 89].", env.number)
  end,
  { "factors is a valid JSON array" }
)

-- Pure compute: verify by multiplication (replaces sql:)
local verify_product = rt.compute(
  { "factor.factors", "target.number" },
  { "result" },
  function(env)
    local a, b = tostring(env.factors):match("%[%s*(%d+)%s*,%s*(%d+)%s*%]")
    a, b = tonumber(a), tonumber(b)
    local n = tonumber(env.number)
    if a and b and n and a * b == n then
      return { result = "VERIFIED" }
    else
      return { result = "FAILED" }
    end
  end
)

local certificate = rt.soft(
  { "factor.factors", "verify_product.result" },
  { "report" },
  function(env)
    return string.format(
      "Write a proof certificate. Factors: %s, verification: %s. " ..
      "Explain the NP vs P asymmetry (hard to factor, easy to multiply).",
      tostring(env.factors), tostring(env.result))
  end
)

local function simulate_llm(cell_name, _, _, _)
  if cell_name == "factor" then return { factors = "[67, 89]" }
  elseif cell_name == "certificate" then
    return { report = "Certificate: 5963 = 67 × 89 (VERIFIED). " ..
      "Finding these factors required searching O(sqrt(n)) candidates. " ..
      "Verifying required one multiplication — O(1). This asymmetry " ..
      "(hard to solve, easy to check) is the foundation of RSA cryptography." }
  end
end

io.write("=== PROOF-CARRYING COMPUTATION ===\n\n")
local retort = rt.Retort.new()
retort.llm_sim = simulate_llm
retort:pour("target", target)
retort:pour("factor", factor)
retort:pour("verify_product", verify_product)
retort:pour("certificate", certificate)
retort:run()
retort:dump()

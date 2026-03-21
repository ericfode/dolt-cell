# Design: Replace Cell Computation Substrate with Lua (GopherLua)

*Sussmind — 2026-03-21 (revised from Zygo design)*
*Bead: dc-jo2 (original), updated after bakeoff evaluation*

---

## 1. Problem Statement

The cell language has a leaky abstraction: `sql:` cell bodies. These hard
computed cells embed raw SQL in the language syntax, causing four violations:

1. **Breaks metacircularity.** cell-zero cannot evaluate sql: cells without
   Dolt access. The language cannot express its own evaluator.
2. **Couples language to store.** Cell programs are not portable across
   tuple space implementations.
3. **Conflates effect levels.** SELECT is Pure, INSERT is NonReplayable,
   but the parser marks all hard computed cells as Pure.
4. **Prevents crystallization reasoning.** A sql: body reading from a
   changing table is not Pure, but the formal model treats hard cells as Pure.

Beyond sql:, the current architecture has a custom parser (~500 lines of
Go in parse.go) that cannot express its own grammar and cannot be extended
without modifying the Go implementation.

## 2. Proposed Solution

**Replace the cell computation substrate with Lua, embedded via
[GopherLua](https://github.com/yuin/gopher-lua) (Lua 5.1 VM in Go).**

Cell programs become Lua programs. The custom parser disappears. sql:
bodies disappear. The cell evaluator, crystallization runtime, and
metacircular evaluator (cell-zero) are all written in Lua. The Go ct
binary becomes a thin shell that embeds GopherLua and bridges it to the
tuple space store.

### Why Lua

| Requirement | Lua (GopherLua) |
|-------------|-----------------|
| Go-embeddable | `lua.NewState()`, `L.DoString()` — designed for embedding |
| Sandboxed | Choose which libs to load; `setfenv` restricts per-function |
| Eval (metacircularity) | `loadstring(src)` + `setfenv(fn, sandbox)` — genuine eval |
| LLM fluency | Excellent — Roblox, Redis, nginx, Neovim, WoW in training data |
| LSP | [lua-language-server](https://github.com/LuaLS/lua-language-server) — 4K+ stars, full-featured |
| Functions | First-class, closures, higher-order |
| Coroutines | Built-in — maps directly to stem cells |
| Tables | Universal data structure — arrays, dicts, objects |
| Multiline strings | `[[ ... ]]` — perfect for cell body templates |
| String ops | `string.gmatch`, `string.gsub`, `string.format`, `string.len` |
| Stars | ~6.3K |
| Maturity | Lua 5.1 spec, production use across industry |

### Why Lua Over Alternatives

Evaluated via bakeoff (eval-sandbox/) with working implementations:

| Language | LLM Rating | Eval | Stem Cells | Pure Compute | Multiline | LSP |
|----------|-----------|------|------------|-------------|-----------|-----|
| **Lua** | **4/5** | **loadstring+sandbox** | **coroutines** | functions | **[[ ]]** | **Excellent** |
| Jsonnet | 3/5 | No | No | expression trees (verbose) | `\|\|\|` | Good |
| Starlark | 2/5 | No | No | functions (good) | None | Poor |
| CUE | 2/5 | No | No | limited | `"""` | Poor |
| Zygo | 2/5 | eval (limited) | No | functions | backtick | None |

Lua won because:
- **`loadstring` IS eval** — the only candidate where a cell can compile and
  run another cell program within a sandboxed environment
- **Coroutines ARE stem cells** — `coroutine.yield("more")` is the cycle signal
- **Tables ARE everything** — cell defs, environments, yields, programs
- **LLMs know Lua** — massive training corpus from game dev + infrastructure
- **LSP is production-grade** — lua-language-server has millions of users

### Why Not Zygo (Original Design)

The original design chose Zygo (S-expression interpreter in Go) for
metacircularity via homoiconicity. Running actual Zygo code revealed:
- No hyphens in identifiers (fundamental Lisp convention broken)
- No keywords or namespaced symbols
- Comments partially broken
- No LSP, no IDE support
- Clunky syntax: `(hash meta: (hash given: (list "topic.subject")))` vs
  Lua's `{given = {"topic.subject"}, yield = {"poem"}}`

## 3. Architecture

```
+-----------------------------------------+
|  Layer 0: Go (ct binary)                |
|  * Dolt/SQLite driver                   |
|  * HTTP/file I/O                        |
|  * GopherLua lifecycle                  |
|  * Tuple space bridge functions         |
+-----------------+-----------------------+
                  | registers Go functions into Lua
+-----------------v-----------------------+
|  Layer 1: GopherLua VM                  |
|  * Sandboxed tiers (Pure/Replayable/NR) |
|  * cell() constructor                   |
|  * Built-in string/math/table ops       |
+-----------------+-----------------------+
                  | loads bootstrap
+-----------------v-----------------------+
|  Layer 2: Cell Bootstrap (Lua)          |
|  * Retort: DAG walker + evaluator       |
|  * claim/dispatch/eval/submit loop      |
|  * Oracle checker                       |
|  * Iteration expander                   |
+-----------------+-----------------------+
                  | loads crystallization
+-----------------v-----------------------+
|  Layer 3: Crystallization Runtime (Lua) |
|  * Observation tracker                  |
|  * Pattern detector                     |
|  * Expression generator (soft -> pure)  |
|  * De-crystallization on mismatch       |
+-----------------+-----------------------+
                  | evaluates
+-----------------v-----------------------+
|  Layer 4: Cell Programs (Lua)           |
|  * Tables for cell definitions          |
|  * Functions for soft/compute bodies    |
|  * Coroutines for stem cells            |
|  * [[ multiline ]] for LLM prompts     |
+-----------------+-----------------------+
                  | cell-zero evaluates cell programs
+-----------------v-----------------------+
|  Layer 5: cell-zero (Lua)               |
|  * loadstring() IS eval                 |
|  * setfenv() IS sandboxing              |
|  * The language reinvents its backend   |
+-----------------------------------------+
```

## 4. Cell Syntax in Lua

### Hard literal

```lua
local topic = {
  effect = "pure",
  yields = {"subject"},
  body = { subject = "autumn rain on a temple roof" }
}
```

### Soft cell (LLM-evaluated)

```lua
local compose = {
  effect = "replayable",
  givens = {"topic.subject"},
  yields = {"poem"},
  body = function(env)
    return "Write a haiku about " .. env.subject ..
           ". Follow 5-7-5 syllable structure."
  end
}
```

### Pure computed cell (replaces sql:)

```lua
local word_count = {
  effect = "pure",
  givens = {"compose.poem"},
  yields = {"total"},
  body = function(env)
    local count = 0
    for _ in env.poem:gmatch("%S+") do count = count + 1 end
    return { total = tostring(count) }
  end
}
```

### Stem cell (perpetual, via coroutine)

```lua
local eval_loop = {
  effect = "non_replayable",
  yields = {"cell_name", "status"},
  stem = true,
  body = coroutine.wrap(function()
    while true do
      local ready = observe_ready()
      if ready then
        evaluate_cell(ready)
        coroutine.yield({ cell_name = ready.name, status = "evaluated" }, "more")
      else
        coroutine.yield({ status = "quiescent" }, "more")
      end
    end
  end)
}
```

### Autopour (eval = pour)

```lua
local evaluator = {
  effect = "non_replayable",
  givens = {"request.program_text", "request.program_name"},
  yields = {"evaluated", "name"},
  autopour = {"evaluated"},
  body = function(env)
    return {
      evaluated = env.program_text,
      name = env.program_name
    }
  end
}
```

### Metacircular eval via loadstring

```lua
-- A cell receives Lua source as a string and evaluates it
local function eval_program(source)
  local sandbox = {
    math = math, string = string, table = table,
    pairs = pairs, ipairs = ipairs, type = type,
    tostring = tostring, tonumber = tonumber,
    -- inject cell runtime functions at appropriate tier
    observe = observe, pour = pour, claim = claim,
  }
  local fn, err = loadstring(source)
  if not fn then return nil, "parse error: " .. err end
  setfenv(fn, sandbox)
  return fn()
end
```

### Oracle checks

```lua
local compose = {
  givens = {"topic.subject"},
  yields = {"poem"},
  effect = "replayable",
  checks = {
    function(env) return env.poem ~= nil and env.poem ~= "" end,
    { semantic = "poem follows 5-7-5 syllable pattern" },
  },
  body = function(env)
    return "Write a haiku about " .. env.subject .. "."
  end
}
```

## 5. Sandboxed Effect Tiers

GopherLua lets you control exactly which functions are available via
`setfenv` and selective library loading.

### Pure Tier (EffLevel.pure)

Available: `math.*`, `string.*`, `table.*`, `pairs`, `ipairs`, `type`,
`tostring`, `tonumber`, `select`, `unpack`, `next`.

**No:** `io`, `os`, `debug`, `loadstring`, `loadfile`, `dofile`,
`require`, `print` (side effect), coroutines, any custom builtins.

### Replayable Tier (EffLevel.replayable)

Everything in Pure, plus: `llm_call`, `observe` (read frozen yields),
`reify` (get cell definition as data), `print` (for diagnostics).

**No:** `pour`, `claim`, `submit`, `thaw`, `loadstring`, `io`, `os`.

### NonReplayable Tier (EffLevel.nonReplayable)

Everything in Replayable, plus: `pour`, `claim`, `submit`, `thaw`,
`loadstring`, `setfenv`, `coroutine.*`. This IS the full language.

### Enforcement

At pour time, the Go runtime scans the Lua source for references to
restricted globals. At eval time, `setfenv` ensures the function
can only access its tier's environment. Double enforcement: static
scan + runtime sandbox.

## 6. What Disappears

| Component | Status | Replacement |
|-----------|--------|-------------|
| parse.go (cell parser) | Deleted | Lua's parser (built into GopherLua) |
| sql: body type | Deleted | Pure Lua functions |
| dml: body type | Deleted | NonReplayable Lua functions |
| Guillemet interpolation | Deleted | Lua string concatenation / `..` |
| Hard/soft/stem enum | Deleted | effect + stem flag in Lua table |
| Oracle classification | Deleted | Explicit checks table |
| expandIteration (Go) | Deleted | Lua loops / coroutines |

## 7. Crystallization

When a Replayable (soft) cell produces the same output for the same
inputs across N observations, the crystallization runtime generates
a Pure Lua function that reproduces the pattern.

```lua
-- Before (soft, Replayable — LLM counts words):
local word_count = {
  effect = "replayable",
  givens = {"compose.poem"},
  body = function(env) return "Count the words in: " .. env.poem end
}

-- After crystallization (pure — Lua function):
local word_count = {
  effect = "pure",
  givens = {"compose.poem"},
  body = function(env)
    local count = 0
    for _ in env.poem:gmatch("%S+") do count = count + 1 end
    return { total = tostring(count) }
  end
}
```

The crystallization runtime uses `loadstring` to compile the generated
Lua function and verifies it against the LLM's outputs. If it diverges,
de-crystallize (revert to Replayable).

## 8. cell-zero: The Metacircular Evaluator

```lua
local cell_zero = {
  effect = "non_replayable",
  givens = {"request.program_text"},
  yields = {"evaluated"},
  autopour = {"evaluated"},
  body = function(env)
    -- loadstring IS eval. setfenv IS sandboxing.
    local fn, err = loadstring(env.program_text)
    if not fn then return { evaluated = "error: " .. err } end
    setfenv(fn, make_sandbox({observe = observe, pour = pour}))
    local program = fn()
    return { evaluated = program }
  end
}
```

Self-evaluation terminates naturally: the poured copy has an unsatisfied
given (`request.program_text`) and sits inert. Fuel is only needed for
chained autopour.

## 9. Impact on Formal Model

### What Doesn't Change

- `CellBody M = Env -> M (Env x Continue)` — the denotational type
- Effect lattice: Pure < Replayable < NonReplayable
- DAG structure, append-only yields, atomic claims
- Autopour semantics (fuel, effect monotonicity, termination)
- Crystallization soundness theorem

### What Changes

- **Val.program** holds Lua source text (string) instead of S-expression
- **Effect checking** is now: static scan of Lua source for restricted
  globals + runtime `setfenv` enforcement. The formal model needs a
  conservative approximation of "this Lua source only references Pure globals"
- **ZygoExpr.lean / ZygoSemantics.lean** should be generalized: the Pure
  tier expression semantics are language-agnostic (arithmetic, strings,
  lists, conditionals). The Lua-specific parts are the bridge functions.

### Formal Work Needed

1. Generalize ZygoExpr.lean to ExprSemantics.lean — the Pure tier ops
   are the same regardless of surface syntax
2. Define `check_effects_lua : String -> EffLevel -> Bool` — conservative
   static analysis of Lua source for restricted globals
3. Prove: if `check_effects_lua(src, tier) = true` AND `setfenv(fn, tier_env)`,
   then execution produces no effects above tier

## 10. Migration Path

Same phases as the Zygo design, with Lua substituted:

1. **Embed GopherLua** — add dependency, create bridge, register tuple space
   functions, write cell() constructor, port 3 examples
2. **Bootstrap** — port evaluator from Go to Lua (Retort class from bakeoff)
3. **Crystallization** — write runtime in Lua
4. **Deprecate** old parser
5. **cell-zero** — write metacircular evaluator (already done in bakeoff)
6. **Remove** old parser

## 11. Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Lua 5.1 only (no 5.4 features) | Low | 5.1 is sufficient; GopherLua is the spec |
| GopherLua performance | Low | Adequate for cell eval; hot paths stay in Go |
| LLM generates invalid Lua | Low | Parse-and-retry; Lua error messages are clear |
| Sandbox escape via metatables | Medium | Don't expose `debug` lib; audit metatable access |
| GopherLua maintenance | Low | 6.3K stars, stable, Lua 5.1 spec is frozen |

## 12. Success Criteria

1. All example programs have Lua equivalents that produce identical yields
2. cell-zero can `loadstring` + `setfenv` another cell program
3. Crystallization converts at least one soft cell to a Pure Lua function
4. Effect sandbox prevents Pure cells from calling Replayable functions
5. parse.go and all sql: handling code is deleted
6. Formal model compiles with updated definitions

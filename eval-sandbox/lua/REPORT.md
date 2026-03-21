# Lua Bakeoff Report

**Language**: Lua 5.1 (GopherLua 0.1)
**Date**: 2026-03-21
**Author**: Sussmind

---

## Files

| File | Purpose |
|------|---------|
| `cell_runtime.lua` | Mini DAG evaluator (~130 lines) — the core runtime |
| `cell_zero.lua` | Metacircular evaluator using `loadstring` + `setfenv` |
| `haiku.lua` | Hard literal + soft + pure compute + oracle |
| `code_review.lua` | Chained soft cells with pure compute in the middle |
| `village_sim.lua` | Simulation using coroutines for the `iterate` pattern |
| `word_count.lua` | Pure compute cells replacing `sql:` bodies |

---

## What Worked Well

### 1. `loadstring` + `setfenv` for Metacircularity — WORKS (rating: excellent)

This is the key differentiator. Lua has genuine eval:

```lua
local compiled_fn, err = loadstring(src, "@program-name")
setfenv(compiled_fn, sandbox)  -- replace global env with sandbox
local ok, result = pcall(compiled_fn)
```

This maps directly onto cell-zero semantics:
- `loadstring` = `read-string` (compile source → function)
- `setfenv` = effect lattice enforcement (sandbox prevents IO/OS access)
- `pcall` = bottom propagation (errors become bottom, not crashes)

The sandbox demonstrated in `cell_zero.lua` successfully:
- Blocks `io.write()` — `attempt to index a non-table object(nil) with key 'write'`
- Blocks `os.execute()` — same pattern
- Allows `math`, `string`, `table` — the pure tier
- Allows injected capabilities (e.g., `observe`) — capability-based effect gating

**Gotcha**: In Lua 5.1, `make_sandbox(extra)` must use a full `pairs` loop to merge extras. A single field check (`extra and extra.field`) silently drops other injected capabilities. Burned time on this.

**GopherLua note**: `load(string)` does NOT work — `load` expects a function (reader). Use `loadstring(string)` instead. This is a Lua 5.1 vs 5.2+ difference.

### 2. Coroutines for Stem Cells — WORKS (rating: excellent)

The mapping is almost 1:1:

```lua
-- Cell definition
local day = stem({}, {"world_state","narrative"}, function(env)
  while true do
    -- ... simulate one tick ...
    local signal = coroutine.yield(result, "more")
    if signal == "stop" then break end
  end
  return final_result
end)

-- Runtime
local co = coroutine.create(cell.body)
local ok, result, signal = coroutine.resume(co, env)
-- signal == "more" → cell stays "pending", request next cycle
-- signal == nil (return) → cell becomes "frozen"
```

`coroutine.status` gives the cell state for free:
- `"suspended"` = pending (yielded with "more")
- `"dead"` = frozen (returned)

The multi-value yield (`coroutine.yield(values, signal)`) is clean. The runtime passes through `"more"` vs. `nil` to decide whether to re-queue.

### 3. Tables as Universal Data Structure — WORKS (rating: excellent)

Cell definitions are plain Lua tables:

```lua
local topic = hard({ subject = "autumn rain on a temple roof" })
-- becomes: { kind="hard", effect=1, body={subject="..."} }

local compose = soft({"topic.subject"}, {"poem"}, function(env)
  return string.format("Write a haiku about %s...", env.subject)
end)
```

The `Retort` object is a table with `__index` metatable. Cell definitions, environments, yield values — all tables. No special data types needed.

### 4. Closures for Cell Bodies — WORKS (rating: excellent)

Soft cell bodies capture local state naturally:

```lua
local MAX_DAYS = 5
local day = stem(..., function(env)
  -- MAX_DAYS captured from enclosing scope
  while day_num < MAX_DAYS do ...
end)
```

The LLM simulator is injected via `retort.llm_sim = fn` — a clean dependency injection pattern without any framework overhead.

### 5. String Patterns for Pure Compute — WORKS (rating: good)

`string.gmatch` replaces `sql: SELECT COUNT(...)` cleanly:

```lua
-- Count bullet points (replaces: sql: SELECT COUNT(*) WHERE ... LIKE '- %')
for _ in string.gmatch(text, "\n%- ") do n = n + 1 end

-- Count words (replaces: sql: ... LENGTH - LENGTH(REPLACE(...)))
for _ in string.gmatch(text, "%S+") do total = total + 1 end
```

Pattern syntax is less readable than regex but functional. No `string.pack`, no bitwise ops in Lua 5.1 — not needed for this domain.

---

## What Was Awkward or Impossible

### 1. Module Imports — Awkward

`dofile(absolute_path)` works but requires absolute paths. There's no module system in GopherLua without `require` setup. Every file must `dofile("/full/path/cell_runtime.lua")`. This is fine for a bakeoff but annoying in practice.

### 2. Multiline String Template Interpolation — Missing

Lua `[[...]]` strings don't interpolate. You can't write:

```lua
local body = [[Write a haiku about «subject»]]
-- subject is NOT substituted
```

You must use `string.format` or concatenation:

```lua
local body = function(env)
  return string.format("Write a haiku about %s", env.subject)
end
```

This adds noise compared to the reference `.cell` syntax where `«field»` just works. The function wrapper is not burdensome but LLMs authoring cell bodies have to remember the pattern.

### 3. Effect Tier Enforcement — Manual

The runtime enforces effects via convention, not the type system. A `compute` cell with `effect = PURE` can still call `io.write` if it wants — the runtime doesn't prevent it. Metatables could enforce this:

```lua
local mt = { __newindex = function(t,k,v)
  if k == "effect" and v > PURE then error("pure cell cannot have side effects") end
  rawset(t,k,v)
end}
```

But this only catches construction-time violations. Runtime enforcement requires sandboxing the body functions, which means running every `compute` body through `loadstring`+`setfenv`. That's a significant overhead and we chose not to do it for the pure tier.

### 4. `load()` vs `loadstring()` — Gotcha

GopherLua 0.1 implements Lua 5.1 semantics. `load(str)` does not work — it expects a reader function. `loadstring(str)` works. This is a silent API difference that wasted investigation time. The report documents it so future bakeoffs don't repeat it.

### 5. No `string.pack`/`string.unpack` — Minor Gap

Not needed for cell programs, but worth noting: Lua 5.1 (GopherLua) has no `string.pack`. Binary serialization requires a library. Irrelevant for LLM-authored cell programs but matters for the runtime itself.

---

## LLM Authoring Rating: 4/5

**Why 4 and not 5:**
- Cell body functions need a `function(env) ... end` wrapper that doesn't appear in the `.cell` reference syntax
- `string.format` with `%s` is a minor tax vs. `«field»` interpolation
- Effect declaration is a table field (`effect = PURE`) that LLMs must remember

**Why 4 and not 3:**
- Table syntax for cell defs is extremely natural — it reads like a spec
- Closures capture context automatically — no explicit dependency threading
- `loadstring`/`setfenv` is conceptually simple and works reliably
- Coroutines for stems are intuitive once explained

An LLM prompted with the cell DSL helpers (`hard()`, `soft()`, `compute()`, `stem()`) would write correct cell programs with high reliability. The helpers abstract the boilerplate. The body function wrapper is the only real syntactic tax.

---

## Metacircularity: Does `loadstring` + Sandboxed Env Actually Work?

**Yes. Verified in `cell_zero.lua`.**

```
=== AUTOPOUR RESULT ===
program_name: example-haiku-program
cell_count:   2
Poured cells:
  - inner-topic (kind=hard, effect=pure)
  - inner-haiku (kind=soft, effect=replayable)
```

The evaluator cell:
1. Received Lua source in `program_text`
2. Called `loadstring(src)` to compile it
3. Called `setfenv(fn, sandbox)` to restrict its environment
4. Called `pcall(fn)` to execute safely
5. Returned a table of cell definitions for autopour

The sandbox successfully blocked IO and OS access while allowing math/string/table. The `observe` capability was injected as an extra key.

Self-evaluation terminates naturally: the poured copy's `request` cell has no `program_text` given → it sits unsatisfied → the copy is inert. No fuel needed. The DAG is the termination condition, exactly as described in `cell-zero-reference.zygo`.

The perpetual evaluator (stem cell) processed 4 programs in 5 ticks:
- `prog-a`: `return {answer=42}` → evaluated, result 42
- `prog-b`: `return {msg=string.upper('hello')}` → evaluated
- `prog-c`: `return math.pi * 2` → evaluated, result 6.28...
- `prog-d`: `io.write('escape attempt')` → BLOCKED by sandbox
- `tick-5`: quiescent (no more work)

---

## Coroutines Map to Stem Cells

| Coroutine | Stem Cell |
|-----------|-----------|
| `coroutine.create(fn)` | Cell instantiation |
| `coroutine.resume(co, env)` | Claim + execute one generation |
| `coroutine.yield(vals, "more")` | Yield + request next cycle |
| `coroutine.yield(vals)` | Yield without requesting more |
| `return vals` | Final yield, cell becomes frozen |
| `coroutine.status == "suspended"` | Cell state: pending |
| `coroutine.status == "dead"` | Cell state: frozen |

The mapping is clean. The only mismatch: in real cell runtime, the "more" signal triggers re-queuing by the scheduler. In Lua, this is handled by checking the second return value from `coroutine.yield`. The convention must be documented but isn't enforced by the type system.

---

## Comparison with Other Languages

| Language | Rating | `eval` | Coroutines | Tables/DAG | LLM Authoring |
|----------|--------|--------|------------|------------|---------------|
| **Lua 5.1** | **4/5** | `loadstring`+`setfenv` — works, sandboxable | `coroutine.create/resume/yield` — 1:1 stem mapping | Tables are universal — clean cell DSL | Natural, minor function wrapper tax |
| Jsonnet | 3/5 | No eval | No coroutines | Objects clean, imports awkward | Good for static defs, poor for dynamic |
| Starlark | 2/5 | No eval | No coroutines | Dicts work, no closures | Restricted syntax fights LLMs |
| CUE | 2/5 | No eval | No coroutines | Constraints elegant, no mutation | Great for schemas, wrong model for cells |

### Why Lua beats Jsonnet here

Jsonnet (3/5) loses because:
- No `eval` — metacircular evaluator is impossible without escaping to Go
- No coroutines — stems require a different representation
- Lazy evaluation is elegant for static programs but confusing for dynamic DAGs

Lua (4/5) wins specifically because `loadstring`+`setfenv` provides genuine eval with sandbox enforcement. This is exactly what the `evaluator` cell needs. No other pure scripting language in this bakeoff offers this combination.

### Why Lua beats Starlark

Starlark (2/5) is deterministic but deliberately restricted: no closures, no `load`, no coroutines, no mutation after freeze. These restrictions, intended for build system correctness, make it unsuitable for dynamic cell programs with LLM bodies.

---

## Best Syntax (Lua)

Cell definition — clean, reads like a spec:

```lua
local compose = soft(
  { "topic.subject" },           -- givens: source.field
  { "poem" },                    -- yields
  function(env)                  -- body: returns prompt string
    return string.format(
      "Write a haiku about %s. Follow 5-7-5.",
      env.subject
    )
  end
)
```

Stem cell with coroutine — maps directly to `iterate`:

```lua
local day = stem({}, {"world_state","narrative"}, function(env)
  local state = env.initial_state
  for tick = 1, MAX_DAYS do
    state = advance(state, tick)
    coroutine.yield({ world_state=state, narrative=narrate(state) }, "more")
  end
  return { world_state=state, narrative="done" }
end)
```

Eval with sandbox enforcement:

```lua
local f, err = loadstring(program_text, "@" .. program_name)
setfenv(f, make_sandbox())         -- enforce effect lattice
local ok, result = pcall(f)        -- bottom = error, not crash
```

---

## Worst Syntax (Lua)

Effect tier enforcement is invisible at definition time. Nothing stops this:

```lua
local bad = compute({"source.text"}, {"result"}, function(env)
  io.write("side effect!\n")        -- runtime doesn't block this
  os.execute("rm -rf /")            -- very bad, no enforcement
  return { result = "done" }
end)
```

The sandbox only applies to code evaluated via `loadstring`. Direct function bodies run with full privileges unless the runtime also sandboxes them. Fixing this requires running ALL cell bodies through `loadstring`+`setfenv`, which changes the authoring model significantly.

The other awkward piece — stem cells need the "more" signal to be a convention:

```lua
-- The "more" signal is a string by convention, not a type
coroutine.yield(result, "more")    -- "more" is magic string
coroutine.yield(result)            -- nil signal = done
```

A typed signal (an enum or tagged value) would be safer. In Lua 5.1 this requires either a metatable trick or discipline in the runtime.

---

## Summary

Lua 5.1 is the strongest of the four bakeoff languages for expressing the cell runtime. The combination of:
- `loadstring`+`setfenv` for genuine metacircularity with sandboxed evaluation
- Coroutines for stem cells with near-perfect semantic alignment
- Tables as a universal data structure for cell defs, environments, and yields
- Closures for capturing cell body context

...makes it a credible substrate for the cell language. The mini evaluator in `cell_runtime.lua` (~130 lines) walks the DAG, resolves givens, handles all cell kinds, and demonstrates that Lua can express the full cell runtime without any special machinery.

The main weaknesses are: no built-in template interpolation (LLMs must write `string.format`), and effect enforcement requires explicit sandboxing of all cell bodies (not just `loadstring`-evaluated code) to be sound.

**Final rating: 4/5** — ahead of Jsonnet (3/5), well ahead of Starlark (2/5) and CUE (2/5).

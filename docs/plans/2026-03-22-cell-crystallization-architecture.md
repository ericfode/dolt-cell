# Cell Architecture: LLMs Compile Themselves Into Programs

*Sussmind — 2026-03-22*

---

## The Goal

LLMs incrementally compile themselves into deterministic programs.

A soft cell does work via an LLM. The runtime observes the work. When
parts of that work are deterministic — counting, parsing, formatting,
filtering, transforming — crystallization pulls those parts out into
pure Lua functions. The LLM call shrinks or disappears.

Over time, the system gets faster, cheaper, and more reliable. Not
because someone hand-optimized it, but because the runtime learned
from observing LLM behavior.

**Everything else is in service of this.**

---

## The Cell Model

A cell is a function that takes an environment and returns yields.
When it needs an LLM, it calls `soft(prompt)` which suspends the
function, dispatches the prompt, and resumes with the answer.

```lua
return {
  cells = {
    topic = {
      body = function()
        return { subject = "autumn rain" }
      end,
    },

    compose = {
      givens = { "topic.subject" },
      body = function(env)
        local poem = soft("Write a haiku about " .. env.subject)
        return { poem = poem }
      end,
    },

    word_count = {
      givens = { "compose.poem" },
      body = function(env)
        local n = 0
        for _ in env.poem:gmatch("%S+") do n = n + 1 end
        return { total = tostring(n) }
      end,
    },
  },
}
```

A cell is just `{givens, body}`. Everything else is inferred:
- **Effect level**: did the body call `soft()`? Replayable. Didn't? Pure.
- **Yields**: the keys of the returned table.
- **Cell type**: there is no cell type. A cell is a function.

---

## The Sandbox

The body function runs in a sandbox controlled by `setfenv`. The
sandbox determines what capabilities are available:

| Sandbox | Available | When |
|---------|-----------|------|
| Pure | math, string, table | Default. No soft(), no I/O. |
| Replayable | Pure + `soft()` | When the cell needs LLM calls. Safe to replay. |
| NonReplayable | Replayable + fs, network, exec | Side effects. Not safe to replay. |

The user declares the sandbox if they need more than Pure:

```lua
cells.deploy = {
  givens = { "build.artifact" },
  sandbox = "unrestricted",
  body = function(env)
    local result = exec("kubectl apply -f " .. env.artifact)
    return { status = result }
  end,
}
```

If `sandbox` is omitted, the runtime infers it: if the body calls
`soft()`, it's Replayable. Otherwise, Pure.

---

## The Runtime

```
ct pour <name> <file.lua>
  Go reads file → loadstring in throwaway Lua VM → extract cell names + givens
  Store source text in programs table
  Store structure in cells/givens/yields tables

ct piston <name>
  Loop:
    Find ready cell (all givens have frozen yields)
    Load program source from programs table into fresh Lua VM
    Find cell body function
    Run as coroutine with resolved env

    Body runs pure Lua...
    Body calls soft(prompt) → coroutine yields
    Dispatch prompt to LLM piston → get answer
    Resume coroutine with answer
    Body continues... maybe more soft() calls... returns yields

    Freeze yields in retort DB
    Next cell
```

Each cell gets a fresh Lua VM loaded from the stored source. VMs
don't share state. The retort DB is the shared state. Frozen yields
flow between cells via the givens/yields tables.

---

## Crystallization: The Whole Point

### Observation

Every time a Replayable cell evaluates, the runtime logs:
- Input: the env (resolved givens)
- Each `soft(prompt)` call and its answer
- Output: the returned yields

### Detection

The crystallization runtime watches for patterns:
- Same inputs → same soft() prompts → same answers → same outputs
- More specifically: same inputs → the soft() call was unnecessary
  because the answer was deterministic

### Splitting

The interesting case: a cell body does BOTH deterministic and
creative work.

Before crystallization:
```lua
cells.analyze = {
  givens = { "state.data" },
  body = function(env)
    local result = soft(
      "Parse this JSON: " .. env.data ..
      "\nCount items where status='active'." ..
      "\nThen describe the overall trend.")
    return { count = result.count, trend = result.trend }
  end,
}
```

The runtime observes that `count` is always deterministic (same data →
same count) but `trend` varies (creative). Crystallization splits:

```lua
cells.count_active = {
  givens = { "state.data" },
  body = function(env)
    local items = json.decode(env.data)
    local n = 0
    for _, item in ipairs(items) do
      if item.status == "active" then n = n + 1 end
    end
    return { count = tostring(n) }
  end,
}

cells.describe_trend = {
  givens = { "state.data", "count_active.count" },
  body = function(env)
    local trend = soft(
      "There are " .. env.count .. " active items in: " .. env.data ..
      "\nDescribe the overall trend.")
    return { trend = trend }
  end,
}
```

The LLM used to do counting AND narrating. Now it only narrates.
The counting is a pure Lua function that runs instantly.

### Generation

How does the crystallization runtime generate the Lua function?
It asks an LLM:

```
"This cell was called 10 times with these input/output pairs:
  input: {data: '[{status:"active"},{status:"inactive"}]'} → output: {count: "1"}
  input: {data: '[{status:"active"},{status:"active"}]'} → output: {count: "2"}
  ...

Write a pure Lua function that produces the same outputs.
The function takes env and returns a table. No soft() calls."
```

The LLM writes the Lua function. The runtime verifies it against
the cached I/O pairs. If it matches, the cell crystallizes.

### Verification

The crystallized function is tested against new inputs:
1. Run the pure Lua function → get result
2. Run the original soft() cell → get LLM result
3. Compare. If they match: crystallization holds.
4. If they diverge: de-crystallize. Revert to soft().

### The Flywheel

Crystallization feeds itself:
1. LLM evaluates a cell (expensive, slow)
2. Runtime observes I/O pattern
3. Runtime asks LLM to write a pure function (one more LLM call)
4. Function verified → crystallized (now free, instant)
5. Future evaluations skip the LLM entirely
6. Savings compound as more cells crystallize
7. The remaining LLM calls are smaller (deterministic parts factored out)

---

## Why Cells, Not Formulas

A formula step is a blob of text dispatched to an LLM. You can't:
- Observe that half the blob is deterministic
- Split it into pure + creative parts
- Replace the deterministic part with a function
- Verify the function against the original

A cell body is a Lua function with `soft()` calls. You can:
- Observe each `soft()` call separately
- Identify which ones are deterministic
- Factor deterministic parts into pure Lua
- Verify and replace

**The cell abstraction exists to make crystallization possible.**
Formulas are opaque. Cells are transparent.

---

## Why Lua

| Need | Lua Feature |
|------|-------------|
| Cell bodies are functions | First-class functions, closures |
| Soft calls suspend/resume | Coroutines (`coroutine.yield`) |
| Crystallized code runs sandboxed | `setfenv` per function |
| Source stored in DB, re-evaluated | `loadstring(source)` |
| LLMs can write cell programs | Lua is well-represented in training data |
| Deterministic pure computation | No implicit state, `setfenv` blocks I/O |

---

## Why the Retort DB

The retort stores:
- **programs**: source text (the Lua file, consumed once)
- **cells**: structure (names, givens — the DAG)
- **yields**: frozen values (the data flowing between cells)
- **observations**: I/O pairs for crystallization
- **crystallized**: pure Lua functions generated from observations

The DB is the observation log. Without it, crystallization can't see
patterns across evaluations. The DB is not just coordination — it's
the learning substrate.

---

## What Serves The Goal

| Component | Serves crystallization? | How |
|-----------|------------------------|-----|
| Lua substrate | Yes | Functions can be split, observed, replaced |
| Effect lattice | Yes | Pure/Replayable distinction = crystallization boundary |
| Retort DB | Yes | Observation log for I/O pairs |
| Replay | Yes | Verify crystallized functions match original |
| Coroutines | Yes | Each soft() call is an observable unit |
| Sandboxing | Yes | Crystallized functions provably can't have side effects |
| Formal model | Supports | Proves crystallization preserves program semantics |
| Metacircularity | Tangential | Nice but not the point |
| Autopour | Supports | Crystallized programs can be generated dynamically |
| Gas City events | Supports | Dispatch pistons when soft() needs evaluation |

# Lua Integration Status & Next Phase Plan

*Sussmind — 2026-03-21*

---

## Current State

### What's Done

| Component | Status | Evidence |
|-----------|--------|----------|
| **GopherLua embedded in ct** | Done | `luavm.go`, `go build` clean |
| **ct run <name> <file.lua>** | Done | Boots Lua VM, runs program |
| **ct pour <name> <file.lua>** | Done | LoadLuaProgram → SQL → retort |
| **ct lint <file.lua>** | Done | Validates Lua cell structure |
| **Old .cell parser deleted** | Done | parse.go removed (844 lines) |
| **Old SQL sandbox deleted** | Done | sandbox.go removed (94 lines) |
| **cell-zero.lua** | Done | Metacircular evaluator, 5-part demo |
| **22 main examples ported** | Done | All .lua files in examples/ |
| **Tests converted to Lua** | Done | 19 tests, 13 pass (6 need live Dolt) |
| **Design doc** | Done | lua-substrate-design.md |
| **Formal model generalized** | Done | PureExprSemantics.lean |
| **CLAUDE.md updated** | Done | Lua syntax reference |
| **Research docs annotated** | Done | 8 files with deprecation headers |

### What's Not Done

| Component | Status | Bead | Blocking? |
|-----------|--------|------|-----------|
| **27 exp/ test files** | Not started | dc-0wq | No |
| **5 corpus/ files** | Not started | dc-up8 | No |
| **54 old .cell files** | Still in repo | dc-zu7 | Blocked by conversions |
| **Piston system prompt** | Old guillemets | dc-3sa | No |
| **Formal BodyType comments** | References SQL | dc-twb | No |
| **Documentation rewrite** | cell-v2-syntax.md outdated | dc-jaz | No |
| **eval.go legacy cleanup** | 1959 lines, still has guillemets | — | No (piston path) |
| **Phase 2: Lua evaluator** | Lua Retort exists but not wired to DB | dc-9ri | Blocked by dc-8ga |
| **Phase 3: Crystallization** | Not started | dc-k3u | Blocked by dc-9ri |
| **dc-8ga not closed** | Work is done but bead is open | dc-8ga | — |

### Codebase Metrics

- ct Go source: 6,133 lines across 14 files
- eval.go: 1,959 lines (largest — piston protocol + legacy eval loop)
- Lua examples: 22 files
- Old .cell files: 54 remaining (27 exp/ + 5 corpus/ + 22 main examples)
- Go tests: 19 (13 pass, 6 need live Dolt)

---

## The Key Architectural Question

**The piston protocol (cmdPiston, cmdNext, cmdSubmit) still uses Go.**

This is eval.go — 1,959 lines of Go that:
1. Claims cells from the retort DB (atomic via UNIQUE constraint)
2. Resolves inputs (joins givens to frozen yields)
3. Interpolates guillemets in soft cell bodies
4. Prints prompts for LLM pistons
5. Accepts submitted yields
6. Checks oracles
7. Records bindings (formal invariants I6, I10, I11)

The question: **Should this move to Lua too?**

### Option A: Keep the piston protocol in Go

The piston protocol is DB-heavy (SQL queries, atomic claims, formal
invariants). It's stable, tested, and correct. Moving it to Lua gains
nothing — it would just be Lua code calling db_query/db_exec, which
is what the Go code already does.

**Pros:** No rewrite risk. Formal invariants preserved. Tested.
**Cons:** eval.go stays large. Guillemets stay in Go. Two eval paths.

### Option B: Move everything to Lua

The Lua Retort class (cell_runtime.lua) already has the eval loop.
Wire it to the real DB via db_query/db_exec functions. The Go piston
commands become thin wrappers that call into Lua.

**Pros:** One eval path. Everything is Lua. Guillemets gone from Go.
**Cons:** Rewrite risk. Must preserve formal invariants. Large effort.

### Option C: Hybrid — new programs use Lua, old programs keep Go

New programs loaded via `ct pour <name> <file.lua>` use the Lua eval
path. Old programs already in the retort (loaded via .cell) continue
using the Go eval path. No migration needed.

**Pros:** Pragmatic. No risk to existing programs. Incremental.
**Cons:** Two eval paths forever. Maintenance burden.

**Recommendation: Option A for now, Option B as Phase 2 (dc-9ri).**

The piston protocol works. Don't rewrite what works. Focus on:
1. Closing out the mechanical cleanup (exp/, corpus/, .cell deletion)
2. Updating documentation
3. Getting the Lua examples actually running end-to-end against a live retort

---

## Seven Sages Review

### Sussman (Language Philosophy)

**Question:** Is the system metacircular?

**Assessment:** Yes. cell-zero.lua demonstrates all five cell types
and loadstring+setfenv eval. The Lua substrate achieves what the old
cell syntax couldn't: a program that compiles and runs another program
within the same language, sandboxed by effect tiers.

**Concern:** The piston protocol still uses Go with guillemets. This
means the *operational* eval loop is not in Lua — only the cell body
evaluation is. True metacircularity would require the piston protocol
in Lua too (Option B).

**Resolution:** The piston protocol is infrastructure, not language.
The cell LANGUAGE is Lua. The cell RUNTIME is Go+Lua. This is like
saying Python isn't metacircular because CPython is written in C.
The eval loop's implementation language doesn't affect the language's
expressive power. cell-zero.lua proves the language can express its
own evaluator — that's Sussman's criterion.

**Grade: A**

### Dijkstra (Formal Correctness)

**Question:** Are the formal model properties preserved?

**Assessment:** PureExprSemantics.lean compiles with zero sorries.
ZygoSemantics.lean (glassblower) has effect_safety proven. The Lua
substrate doesn't change the denotational semantics — CellBody M =
Env → M (Env × Continue) is still the type.

**Concern:** The bridge between Lua cell bodies and Go formal
invariants (I6 claimMutex, I10 generationOrdered, I11
bindingsPointToFrozen) is not formally verified. The Go code
enforces these; the Lua code trusts Go to do so. If Lua code
bypasses Go (direct DB calls), invariants could break.

**Resolution:** The Lua sandbox does NOT include raw DB access.
The db_query/db_exec functions are registered by Go and enforce
the formal invariants at the Go level. Lua can't bypass them.
This is correct by construction.

**Grade: A-** (bridge not formally verified, but correct by design)

### Hoare (Engineering Correctness)

**Question:** Is the codebase clean and testable?

**Assessment:** The old parser (844 lines) and sandbox (94 lines)
are deleted. Tests converted to Lua. Build is clean.

**Concern:** 54 old .cell files still in the repo. eval.go is 1,959
lines of legacy code. The test suite only has 13 passing tests (6
need live Dolt). Test coverage is low.

**Resolution:** The .cell files are tracked by dc-zu7 (blocked by
conversions). eval.go stays for the piston protocol — it's not dead
code, it's the piston path. Test coverage should increase as Lua
examples are validated against a live retort.

**Second concern:** dc-8ga is still open even though the work is done.
Close it.

**Grade: B+** (cleanup incomplete, test coverage low)

### Wadler (Type Theory)

**Question:** Does the type system work?

**Assessment:** Lua is dynamically typed. The formal model uses typed
interfaces (CellInterface, Dep, Oracle). The bridge (LoadLuaProgram →
parsedCell) performs runtime type checking when extracting Lua tables.

**Concern:** No compile-time checking of Lua cell programs. A typo in
a given name ("topic.suject" instead of "topic.subject") is caught at
runtime (dangling given), not at load time.

**Resolution:** ct lint catches dangling givens. The lintCells function
performs the same structural checks that the old parser did. This is
adequate — dynamic languages rely on linting + testing, not type checking.

**Grade: A-** (dynamic typing is a known tradeoff, mitigated by lint)

### Iverson (Notation)

**Question:** Is the notation an improvement?

**Assessment:** Lua cell definitions are more readable than the old
cell syntax for programmers:

```lua
-- Clear, familiar, works in any editor
local compose = {
  givens = {"topic.subject"},
  yields = {"poem"},
  body = function(env)
    return "Write a haiku about " .. env.subject
  end
}
```

vs the old:
```
cell compose
  given topic.subject
  yield poem
  ---
  Write a haiku about «subject».
  ---
```

**Concern:** The old syntax was more readable for non-programmers and
for LLM prompt authoring. The `---` fenced block was natural for
multiline text. Lua requires `[[...]]` or string concatenation.

**Resolution:** The trade is correct. Cell programs are authored by
programmers and LLMs, both of whom know Lua better than custom DSLs.
Lua's `[[multiline strings]]` are adequate for prompts. The gain in
expressiveness (functions, coroutines, loadstring) vastly outweighs
the loss in prompt prettiness.

**Grade: A**

### Round 1 Summary

| Reviewer | Grade | Key Issue |
|----------|-------|-----------|
| Sussman | A | Metacircular — piston is infra, not language |
| Dijkstra | A- | Bridge not formally verified |
| Hoare | B+ | 54 .cell files, low test coverage |
| Wadler | A- | Dynamic typing mitigated by lint |
| Iverson | A | Notation is better for the target audience |

**Overall: A-**

### Fixes Needed for A+

1. **Close dc-8ga** — work is done
2. **Delete the 54 .cell files** — they're converted, remove originals
3. **Convert exp/ and corpus/** — 32 files, mechanical
4. **Update piston system prompt** — remove guillemets
5. **Increase test coverage** — add glua validation of all .lua examples

---

## Immediate Action Plan

### Phase 1: Close Out (mechanical, parallelize)

| Task | Effort | Who |
|------|--------|-----|
| Close dc-8ga (done) | 1 min | sussmind |
| Delete .cell originals for 22 converted examples | 5 min | sussmind |
| Convert 27 exp/ test files to Lua | 30 min | agent (sonnet) |
| Convert 5 corpus/ files to Lua | 10 min | agent (sonnet) |
| Add glua validation test for all .lua examples | 15 min | sussmind |
| Update piston system prompt (dc-3sa) | 10 min | agent (sonnet) |
| Update formal BodyType comments (dc-twb) | 5 min | agent (sonnet) |

### Phase 2: Piston Lua Migration (dc-9ri, future)

Port cmdPiston/cmdNext/cmdSubmit to use Lua VM for cell body
evaluation (not the claiming protocol — that stays in Go).

### Phase 3: Crystallization (dc-k3u, future)

Implement observation → detection → generation → de-crystallization
in Lua. Depends on Phase 2.

### Phase 4: Documentation (dc-jaz)

Rewrite cell-v2-syntax.md as Lua cell programming guide.

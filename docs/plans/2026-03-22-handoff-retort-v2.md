# Handoff: The Retort — A Shared Thinking Space for LLMs

*Sussmind — 2026-03-22*

---

## What We Learned (and What We're Throwing Away)

We built a cell language runtime in Go + Lua. Along the way we
discovered what the system is actually for. Most of what we built
was in service of the wrong framing. Here's what survives:

**Survives (ideas):**
- Cells as the unit of thought
- The tuple space as shared medium
- Crystallization: soft thoughts hardening into programs
- The effect lattice: what's safe to replay, what's safe to crystallize
- `soft()` as the boundary between deterministic and creative work
- Code-as-data for programmatic crystallization
- Formal types as a thinking tool (Lean proofs are cheap with LLM agents)

**Thrown away (implementation):**
- The Go ct tool (6000+ lines)
- The Lua substrate (GopherLua, luavm.go)
- The Dolt retort database
- The custom cell parser (already deleted)
- The piston dispatch protocol

**Thrown away (framing):**
- "The system drives the LLM" — wrong direction
- Metacircularity as the goal — it's a means, not the end
- The cell language as a programming language for humans
- Proofs as a heavy verification step — proofs are cheap, use them
  as a thinking tool continuously, not as a gate at the end

---

## The Real Goal

**LLMs cooperate with each other in a shared thinking space,
and collaboratively crystallize their repeated work into programs.**

The retort is not a runtime that dispatches prompts to LLMs.
The retort is a place where LLMs THINK. They pour thoughts,
read each other's thoughts, and notice when parts of their
thinking are always the same. Those parts become programs.

The system provides the medium and the mechanisms. The LLMs
provide the intelligence.

---

## The Three Layers

```
┌──────────────────────────────────────────────────────────┐
│  Gas City                                                │
│  WHO is working                                          │
│                                                          │
│  Agents, sessions, lifecycle, reconciler, sling, orders  │
│  "Agent A is awake on rig dolt-cell"                     │
│  "Agent B was slung bead dc-42"                          │
│                                                          │
│  Gas City does NOT think. It orchestrates.               │
└───────────────────────┬──────────────────────────────────┘
                        │ agents have sessions, work on beads
┌───────────────────────▼──────────────────────────────────┐
│  Beads                                                   │
│  WHAT work exists                                        │
│                                                          │
│  Tasks, bugs, decisions, molecules, messages             │
│  "Review PR #42 — assigned to Agent A — priority P1"     │
│  "Research topic X — 3 leg beads — in progress"          │
│                                                          │
│  Beads do NOT think. They track.                         │
└───────────────────────┬──────────────────────────────────┘
                        │ agents think about their work in
┌───────────────────────▼──────────────────────────────────┐
│  Retort (NEW)                                            │
│  HOW agents think together                               │
│                                                          │
│  Tuple space: pour, observe, claim, freeze               │
│  Cells: functions that may call soft() for LLM work      │
│  Crystallization: soft patterns harden into pure code     │
│                                                          │
│  "Agent A poured analysis. Agent B read it.              │
│   The counting pattern crystallized. Agent C used it."   │
│                                                          │
│  The retort outlives any bead or session.                │
│  It is the accumulated intelligence of all agents.       │
└──────────────────────────────────────────────────────────┘
```

**How they connect:**

```
1. A bead is created: "Review PR #42"
2. Gas City slings it to Agent A
3. Agent A wakes, reads the bead, starts thinking
4. Agent A pours cells into the retort:
   - parse_diff (pure: extract changed files from git)
   - analyze_changes (soft: LLM reviews each file)
   - count_issues (crystallized: regex count from prior reviews)
   - synthesize (soft: LLM writes the review summary)
5. Agent A observes: count_issues was already crystallized
   by Agent B last week during a different review.
   Uses it directly. No LLM call.
6. Agent A updates the bead with the review summary
7. Gas City marks the bead closed
8. The retort keeps the crystallized count_issues forever
9. Next week, Agent C reviews a different PR and
   count_issues fires instantly — the community got smarter
```

**The event bridge:**

```
retort.cell.poured        → Gas City knows an agent is thinking
retort.cell.frozen         → Other agents can observe new yields
retort.crystal.proposed    → Agents can verify the proposal
retort.crystal.accepted    → All agents get the new pure function
bead.assigned              → Agent can start pouring into retort
agent.session.stopped      → Retort freezes partial work
```

Events flow between systems. Each reacts to the others. No tight coupling.

---

## How LLMs Use the Retort

### Visualizing an Agent Thinking

An LLM agent is an Elixir process. It connects to the retort,
pours cells, and evaluates them. Here's what it looks like from
the agent's perspective:

```
┌─────────────────────────────────────────────────┐
│  Agent A (Elixir process on BEAM node)          │
│                                                 │
│  "I've been assigned bead dc-42: Review PR #42" │
│                                                 │
│  1. I'll break this into steps:                 │
│     parse_diff → analyze → count → synthesize   │
│                                                 │
│  2. Pour my plan into the retort as cells:      │
│     Retort.pour("parse_diff", %{...})           │
│     Retort.pour("analyze", %{...})              │
│     Retort.pour("count_issues", %{...})         │
│     Retort.pour("synthesize", %{...})           │
│                                                 │
│  3. The retort evaluates my cells:              │
│     parse_diff runs (pure) → frozen             │
│     analyze runs → soft("Review this...") →     │
│       I think about the code → answer → frozen  │
│     count_issues → ALREADY CRYSTALLIZED → frozen│
│     synthesize runs → soft("Summarize...") →    │
│       I think about the findings → answer       │
│                                                 │
│  4. My yields are frozen. I update the bead.    │
└─────────────────────────────────────────────────┘
```

Key: when the agent's cell body calls `soft(prompt)`, the agent
itself IS the LLM that evaluates the prompt. The agent pours the
cell, the retort runs the body as a coroutine, the coroutine
yields a prompt, and the agent's own LLM session answers it.

The agent is both the author of the cell AND the evaluator.
It's thinking out loud in a structured way.

### Visualizing Multiple Agents

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  Agent A     │  │  Agent B     │  │  Agent C     │
│  Reviewing   │  │  Reviewing   │  │  Reviewing   │
│  PR #42      │  │  PR #57      │  │  PR #63      │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       │ pour            │ pour            │ pour
       │ analyze         │ analyze         │ analyze
       │ count_issues    │ count_issues    │ count_issues
       │ synthesize      │ synthesize      │ synthesize
       ▼                 ▼                 ▼
┌──────────────────────────────────────────────────┐
│                    RETORT                         │
│                                                  │
│  analyze/A: "Found null pointer on line 42..."   │
│  analyze/B: "Missing error handling in handler"  │
│  analyze/C: "Race condition in goroutine..."     │
│                                                  │
│  count_issues: ┌─────────────────────────────┐   │
│                │  CRYSTALLIZED (week 2)       │   │
│                │  fn: count lines matching    │   │
│                │  /BUG:|WARN:|ERROR:|RACE:/   │   │
│                │  proposed by A, verified by B│   │
│                │  used by C (no LLM call)     │   │
│                └─────────────────────────────┘   │
│                                                  │
│  Observation log:                                │
│    count_issues called 47 times                  │
│    always deterministic → crystallized week 2    │
│    analyze called 47 times                       │
│    varies by input → still soft                  │
│    synthesize called 47 times                    │
│    varies → still soft, but prompt shrinking     │
│    (because count_issues is now pre-computed)    │
└──────────────────────────────────────────────────┘
```

Each agent's work is visible to the others. Crystallizations
compound: Agent A's insight becomes Agent C's free function.
The retort gets smarter with every review.

### Visualizing Crystallization

```
Week 1:  Agent A reviews PR. count_issues takes 3 seconds (LLM).
         Retort logs: input="..." output="3"

Week 1:  Agent B reviews PR. count_issues takes 3 seconds (LLM).
         Retort logs: input="..." output="5"

Week 2:  10 observations. Pattern detected:
         "count_issues always counts regex matches"

         Crystallization engine (itself a soft() call):
         "Here are 10 I/O pairs. Here's the AST with soft() calls.
          Write a pure function that produces the same outputs."

         LLM writes:
           fn env ->
             env.findings
             |> String.split("\n")
             |> Enum.count(&String.match?(&1, ~r/BUG:|WARN:|ERROR:/))
             |> then(&%{count: to_string(&1)})
           end

         Verification: run pure fn on all 10 inputs → all match.
         CRYSTALLIZED.

Week 2:  Agent C reviews PR. count_issues takes 0.001 seconds.
         No LLM call. Pure function. Free.

Week 3:  Agent D reviews PR. count_issues → free.
         analyze prompt is SHORTER now (count is pre-computed).
         synthesize prompt is SHORTER now (count is pre-computed).
         Total LLM cost per review: down 30%.

Week 8:  More patterns crystallize. parse_diff crystallizes.
         Some common analyze patterns crystallize.
         Total LLM cost per review: down 70%.

         The agents taught the system to do most of their job.
```

---

## Cell Model

A cell is a function that takes an environment and returns yields.
When it needs an LLM, it calls `soft(prompt)` which suspends the
function, gets an answer, and resumes.

```elixir
# Hard literal (pure — no soft call)
%{body: fn _env -> %{subject: "autumn rain"} end}

# Soft cell (calls LLM)
%{
  givens: ["topic.subject"],
  body: fn env ->
    poem = soft("Write a haiku about #{env.subject}")
    %{poem: poem}
  end
}

# Mixed (pure computation + LLM)
%{
  givens: ["source.code"],
  body: fn env ->
    bugs = soft("Find bugs in:\n#{env.code}")
    count = bugs |> String.split("\n") |> Enum.count(&(&1 != ""))
    priority = if count > 5, do: soft("Prioritize: #{bugs}"), else: "low"
    %{bugs: bugs, count: to_string(count), priority: priority}
  end
}
```

There is no cell type declaration. No `kind = "hard"` or
`effect = "pure"`. The runtime discovers the effect level from
what the body DOES: called `soft()`? Replayable. Didn't? Pure.
Called `exec()`? NonReplayable.

Givens are the only metadata. Everything else is the function.

### Sandboxing

The body runs in a sandbox controlled by what's available:

| Sandbox | Available | Crystallizable? |
|---------|-----------|-----------------|
| Pure | Elixir stdlib, no soft/exec | Yes — always |
| Replayable | Pure + `soft()` | Yes — if pattern detected |
| NonReplayable | Replayable + `exec()`, fs, net | No — side effects |

If a cell's sandbox is omitted, the retort infers it from usage.

### Persistence

The entire `.ex` source file is stored in the retort when poured.
At eval time, the source is re-evaluated in a fresh environment to
reconstruct the cell bodies with closures intact. No bytecode
serialization. No function extraction. Just: store source, re-eval.

---

## Why Elixir / BEAM

The BEAM VM is a tuple space runtime:

| Need | BEAM Provides |
|------|---------------|
| Shared tuple store | **ETS/Mnesia** — atomic ops, pattern matching |
| Distribution | **Native** — connect nodes, share tables |
| Concurrent agents | **Processes** — millions, supervised |
| Fault tolerance | **OTP** — crash and restart, replay from cache |
| Hot code swap | **Native** — crystallize without restarting |
| AST manipulation | **Macro.postwalk** — walk code as data |
| Notification | **Process monitoring** — watch for changes |

No Dolt, no NATS, no Redis. ETS is the tuple space. Mnesia is the
distributed persistent tuple space. OTP is the runtime.

Why Elixir over Erlang: both compile to BEAM. Elixir has
`Macro.postwalk` for AST walking (crystallization's core operation),
better string handling for prompt construction, and more LLM training
data (agents generate fewer syntax errors).

---

## Why Homoiconic

Crystallization = walk code, find `soft()` calls, gather evidence,
ask an LLM to split the cell into pure + creative parts.

The crystallization split is ITSELF a `soft()` call:

```elixir
defmodule Crystallizer do
  def attempt_split(cell_name, ast, observations) do
    # 1. MECHANICAL: walk AST, find soft() calls
    {_, soft_calls} = Macro.postwalk(ast, [], fn
      {:soft, _meta, [prompt]} = node, acc -> {node, [prompt | acc]}
      node, acc -> {node, acc}
    end)

    # 2. CREATIVE: ask an LLM to do the refactoring
    soft("""
    Here is a cell body with #{length(soft_calls)} soft() calls:
    #{Macro.to_string(ast)}

    Here are the last 10 evaluations:
    #{format_observations(observations)}

    Some outputs are deterministic given the inputs.
    Rewrite as TWO cells:
    1. A pure cell for the deterministic parts
    2. A soft cell for the creative parts
    Return valid Elixir.
    """)
  end
end
```

The flow:
1. **System** walks AST, finds `soft()` calls (mechanical)
2. **System** gathers I/O observations (mechanical)
3. **LLM** proposes the split (creative — this IS a `soft()` call)
4. **System** verifies the split produces same outputs (mechanical)
5. **System** hot-swaps the cell bodies (mechanical)

Homoiconicity lets the system do steps 1, 4, and 5 mechanically.
Without code-as-data, ALL steps would need an LLM.

---

## Formalism: Cheap Proofs as a Thinking Tool

Lean proofs are cheap with LLM agents. The sorry-filler proved
`effect_safety` in one session. Use formalism continuously as a
thinking tool, not as a heavy verification gate.

**What to formalize:**
- Core types: Cell, Yield, Observation, Crystal
- The effect lattice: Pure < Replayable < NonReplayable
- Crystallization correctness: if `crystal(cell, obs) = pure_fn`,
  then `∀ input ∈ obs, pure_fn(input) = cell(input)`
- Replay safety: Replayable cells produce same `soft()` prompts
  when replayed with cached answers

**When to formalize:**
- At SPEC time, before building. Types first.
- Agent fills proofs (cheap). Human reviews types (valuable).
- If the types reveal confusion → fix the spec, not the proof.

**Why it works now:**
- The v1 formal model changed three times because the design changed
- With the team structure (spec → type → review → build), the design
  stabilizes before types are written
- Proof agents fill sorries automatically
- The types are the spec. The proofs are the tests.

---

## Team Structure

```
┌─────────────────────────────────────────┐
│  Architect (sussmind)                   │
│  Writes specs as rigorous paragraphs    │
│  Defines types in English + Lean        │
│  Reviews all designs before build       │
│  Owns: "what does this MEAN"            │
└─────────────┬───────────────────────────┘
              │ spec
┌─────────────▼───────────────────────────┐
│  Prover (glassblower)                   │
│  Takes specs, writes Lean types + props │
│  LLM agents fill the proofs (cheap)     │
│  Gate: nothing builds until types pass  │
│  Owns: "is this precise enough"         │
└─────────────┬───────────────────────────┘
              │ typed spec
┌─────────────▼───────────────────────────┐
│  Builder (scribe + helix)               │
│  Writes Elixir from the typed spec      │
│  TDD: tests first, implementation after │
│  Owns: "does this work"                 │
└─────────────┬───────────────────────────┘
              │ working code
┌─────────────▼───────────────────────────┐
│  Integrator (witness)                   │
│  Bridges retort <-> Gas City <-> beads  │
│  End-to-end testing                     │
│  Owns: "does this fit"                  │
└─────────────┬───────────────────────────┘
              │ integrated
┌─────────────▼───────────────────────────┐
│  User (alchemist)                       │
│  Writes cell programs, first real user  │
│  Finds rough edges, files bugs          │
│  Owns: "is this usable"                 │
└─────────────────────────────────────────┘
```

## Work Flow

Every piece of work follows this pipeline:

```
SPEC     Architect writes a rigorous paragraph + examples.
         Goes into a bead with type=decision.

TYPE     Prover writes Lean types from the spec.
         Agent fills proofs. If types reveal confusion → back to SPEC.
         Gate: types compile, no sorry.

REVIEW   Architect reviews types against intent.
         "Is this what I meant?"
         Gate: architect approves.

BUILD    Builder implements in Elixir from the typed spec.
         Tests written FIRST (from the spec's examples).
         Implementation makes tests pass.
         Gate: tests pass, dialyzer clean.

VERIFY   Prover checks: does the implementation match the types?
         Not formal verification — just "do the shapes match?"
         Gate: prover approves.

INTEGRATE Integrator wires into the running system.
         End-to-end test with real agents.
         Gate: two agents can pour + observe + crystallize.

USE      User writes real cell programs.
         Finds rough edges. Files bugs as beads.
         Gate: user can do their work without pain.
```

### What Went Wrong Last Time

| Problem | Cause | Fix |
|---------|-------|-----|
| Built the parser three times | No spec review gate | SPEC → TYPE → REVIEW before BUILD |
| Proofs disconnected from code | Written after design changed | Types first, proofs continuous |
| No end-to-end test until late | Builder worked in isolation | INTEGRATE after every component |
| 22 examples before 1 worked | No USE gate | User tests each component first |
| Everyone touching same files | Ad-hoc ownership | Clear ownership per agent |
| Scope creep | No phase discipline | Each phase has explicit deliverables |

---

## Build Phases

### Phase 1: Core Tuple Space

```
SPEC:    "A GenServer wrapping ETS. Four operations:
          pour, observe, claim, freeze."
TYPE:    Lean types for TupleSpace, Cell, Yield
BUILD:   retort/lib/retort/tuple_space.ex (~100 lines)
VERIFY:  Two processes pour and observe
USE:     Alchemist pours a hard cell, observes it
```

### Phase 2: soft() and LLM Integration

```
SPEC:    "soft(prompt) calls an LLM API, returns the answer,
          logs the I/O pair to the observation table."
TYPE:    soft : String → Replayable String
BUILD:   retort/lib/retort/soft.ex + observation log
VERIFY:  A cell with soft() calls Claude, gets answer, logs it
USE:     Alchemist writes haiku program with soft()
```

### Phase 3: Crystallization

```
SPEC 3a: "Detect when a soft() call always returns the same
          output for the same input pattern."
TYPE:    Observation, Pattern, Crystal
BUILD:   retort/lib/retort/crystallizer.ex
VERIFY:  Run haiku 10 times, detect word_count is deterministic

SPEC 3b: "Split a cell: walk AST, gather evidence, ask LLM
          to refactor, verify, hot-swap."
TYPE:    split : AST → [Observation] → Replayable (AST × AST)
BUILD:   retort/lib/retort/crystallizer/split.ex
VERIFY:  A mixed cell splits into pure + soft
USE:     Alchemist sees crystallized function used automatically
```

### Phase 4: Persistence + Distribution

```
SPEC:    "Mnesia backing. Cells and yields survive restarts.
          Multi-node replication."
BUILD:   retort/lib/retort/persistence.ex
VERIFY:  Kill node, restart, state intact. Two nodes share retort.
```

### Phase 5: Gas City Bridge

```
SPEC:    "Events connecting retort <-> Gas City. Agents pour
          as part of bead work. Crystallizations announced."
BUILD:   retort/lib/retort/gas_city_bridge.ex
VERIFY:  Agent wakes from bead, pours, crystallizes, event fires
USE:     Two agents doing reviews share crystallized count_issues
```

---

## What We're NOT Building

- A programming language (cells are data, not a language)
- A CLI tool (agents interact via Elixir API)
- A custom database (ETS/Mnesia are the database)
- A piston dispatch protocol (agents call soft() directly)
- A parser (Elixir parses Elixir)

---

## The Measure of Success

The retort is working when:

1. Two agents pour thoughts about the same kind of work
2. A pattern is detected: "both did the same deterministic step"
3. That step crystallizes into a pure function
4. A third agent does the same kind of work and the crystallized
   function fires automatically — no LLM call
5. The third agent's work is faster and cheaper
6. This compounds: each crystallization makes all future work cheaper

**The retort makes agents smarter by making the system remember
what they've already figured out.**

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

**Thrown away (implementation):**
- The Go ct tool (6000+ lines)
- The Lua substrate (GopherLua, luavm.go)
- The Dolt retort database
- The custom cell parser (already deleted)
- The piston dispatch protocol
- The Lean formal model (ideas survive, code doesn't)

**Thrown away (framing):**
- "The system drives the LLM" — wrong direction
- Metacircularity as the goal — it's a means, not the end
- The cell language as a programming language for humans

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

## How LLMs Use the Retort

An LLM agent is working on a task (assigned via a bead in Gas City).
The agent thinks by pouring cells into the retort:

```
Agent A is reviewing code. It pours:
  - analyze: "Here's what I found in this Go file..."
  - count_issues: "There are 3 critical bugs..."
  - recommendation: "The main fix should be..."

Agent B is reviewing different code. It pours:
  - analyze: "Here's what I found in this Python file..."
  - count_issues: "There are 5 warnings..."
  - recommendation: "Consider refactoring..."
```

Both agents can OBSERVE each other's frozen yields. Agent B can
read Agent A's analysis. Agent A can read Agent B's recommendations.
They think in public.

Over time, the retort accumulates observations:

```
Observation: every time ANY agent runs "count_issues",
the answer is always: count the lines matching /BUG:|WARN:|ERROR:/.
This is deterministic. It doesn't need an LLM.
```

An agent (or the crystallization engine) notices and proposes:

```
"I've seen count_issues evaluated 50 times. It's always a regex
count. Here's a pure function that does the same thing."
```

Another agent verifies:

```
"I ran the proposed function on 10 new inputs. It matches the
LLM output every time. Crystallizing."
```

Now `count_issues` is a program. Every future agent that needs
to count issues uses the crystallized function. No LLM call.
The community of agents taught the system to do their job.

---

## The Three Layers

```
┌─────────────────────────────────────────────┐
│  Gas City                                   │
│  WHO is working                             │
│  Agents, sessions, lifecycle, reconciler    │
│  "Agent A is awake on rig dolt-cell"        │
└──────────────────┬──────────────────────────┘
                   │ agents have sessions
┌──────────────────▼──────────────────────────┐
│  Beads                                      │
│  WHAT work exists                           │
│  Tasks, messages, molecules, status         │
│  "Review PR #42 — assigned to Agent A"      │
└──────────────────┬──────────────────────────┘
                   │ agents think about their work in
┌──────────────────▼──────────────────────────┐
│  Retort (NEW)                               │
│  HOW agents think together                  │
│  Tuple space, cells, crystallization        │
│  "Agent A poured analysis. Agent B read it. │
│   The pattern crystallized into a function." │
└─────────────────────────────────────────────┘
```

Gas City manages agents. Beads track work. The retort is where
the actual cognition happens. All three are complementary:

- A **bead** says "review this code"
- **Gas City** wakes an agent and assigns the bead
- The agent **thinks in the retort** — pours analysis cells,
  observes other agents' prior work, uses crystallized functions
- The agent updates the **bead** with its findings
- **Gas City** closes the session when the work is done
- The **retort** keeps the crystallized knowledge forever

The retort outlives any individual bead or agent session. It's
the accumulated intelligence of all agents who've ever thought
in this space.

---

## What Agents Do in the Retort

### Pour

An agent writes a thought — a cell with a body and dependencies.

```elixir
Retort.pour("analyze", %{
  givens: ["source.code"],
  body: fn env ->
    result = soft("Review this code:\n#{env.code}\nFind bugs.")
    %{findings: result}
  end
})
```

The agent wrote a soft cell. It needs an LLM to evaluate. But
the AGENT chose to pour this — the system didn't assign it.
The agent is thinking out loud.

### Observe

An agent reads another agent's frozen yields.

```elixir
prior_analysis = Retort.observe("analyze", "findings")
# "There are 3 critical bugs: null pointer on line 42..."
```

Agent B can see what Agent A found. Thinking is shared. This
is how agents build on each other's work.

### Crystallize (Propose)

An agent notices a pattern and proposes a crystallization.

```elixir
Retort.propose_crystal("count_issues", %{
  observation: "Always counts lines matching BUG:|WARN:|ERROR:",
  pure_body: fn env ->
    env.findings
    |> String.split("\n")
    |> Enum.count(&String.match?(&1, ~r/BUG:|WARN:|ERROR:/))
    |> to_string()
    |> then(&%{count: &1})
  end,
  evidence: [...list of 10 input/output pairs...]
})
```

This is the agent PROPOSING that a thought can become a program.
The agent is doing the crystallization, not the system.

### Verify

Another agent tests the proposal.

```elixir
Retort.verify_crystal("count_issues", %{
  test_inputs: [...5 new inputs...],
  results: "all match",
  verdict: :accept
})
```

Crystallization is a social process among agents. One proposes,
others verify. The retort records the consensus.

### Use

Future agents use the crystallized function automatically.

```elixir
# Agent C pours a cell that depends on count_issues.
# The retort evaluates count_issues using the crystallized
# pure function — no LLM call needed.
Retort.pour("prioritize", %{
  givens: ["count_issues.count", "analyze.findings"],
  body: fn env ->
    soft("There are #{env.count} issues:\n#{env.findings}\nPrioritize.")
  end
})
```

Agent C didn't write `count_issues`. Agent A discovered the
pattern. Agent B verified it. Agent C benefits from it. The
community's intelligence compounds.

---

## Why Elixir / BEAM

The BEAM VM is a tuple space runtime. It was built for this:

| Need | BEAM Provides |
|------|---------------|
| Shared tuple store | **ETS/Mnesia** — in-memory + disk, atomic ops, pattern matching |
| Distribution | **Native** — connect nodes, share tables, send messages |
| Concurrent agents | **Processes** — millions, cheap, isolated, supervised |
| Fault tolerance | **OTP supervisors** — crash and restart, replay from cache |
| Hot code swap | **Native** — crystallize a cell body without restarting |
| Observation | **Process tracing** — built-in, low overhead |
| Notification | **Process monitoring** — watch for changes, receive messages |
| AST manipulation | **Macro.postwalk** — walk code as data, find soft() calls |

The retort doesn't need Dolt, or NATS, or Redis, or Kafka.
ETS is the tuple space. Mnesia is the persistent distributed
tuple space. OTP is the runtime. Macro.postwalk is the
crystallization engine's core operation. It's all built in.

Why Elixir over Erlang: both compile to BEAM (same runtime).
Elixir has `Macro.postwalk` for AST walking (vs manual recursion
over `erl_syntax`), better string handling for prompt construction,
and more LLM training data (agents generate fewer syntax errors).

---

## Why Homoiconic

Crystallization needs to walk code, find `soft()` calls, identify
pure subtrees, and extract them. This is a tree transformation.

If code is data (Elixir AST = tuples), the crystallization engine
walks the tree with `Macro.postwalk`:

```elixir
defmodule Crystallizer do
  def attempt_split(cell_name, ast, observations) do
    # Walk the AST to find soft() calls and their surrounding context
    {_, soft_calls} = Macro.postwalk(ast, [], fn
      {:soft, _meta, [prompt]} = node, acc -> {node, [prompt | acc]}
      node, acc -> {node, acc}
    end)

    # Ask an LLM to do the actual refactoring
    # The system provides: the code (as data) + the I/O evidence
    # The LLM provides: the intelligence to factor it
    soft("""
    Here is a cell body that calls soft() #{length(soft_calls)} times:

    #{Macro.to_string(ast)}

    Here are the last 10 evaluations:
    #{format_observations(observations)}

    The pattern shows that some outputs are always deterministic
    given the inputs (e.g., counting, parsing, formatting).

    Rewrite this as TWO cells:
    1. A pure cell (no soft calls) for the deterministic parts
    2. A soft cell that uses the pure cell's output and only
       calls soft() for the parts that genuinely need creativity

    Return valid Elixir. The pure cell must produce identical
    outputs to what the original produced for the deterministic parts.
    """)
  end
end
```

The crystallization split is ITSELF a `soft()` call. The system
walks the AST to gather context (which parts call `soft()`, what
the I/O patterns look like), then asks an LLM to do the actual
refactoring. The LLM writes the split. The system verifies it.

Homoiconicity matters because the system can SHOW the LLM the
code as structured data, point to specific `soft()` call sites,
and provide the evidence (observations) in context. If code were
opaque strings, the system couldn't even identify where the
`soft()` calls are — it would have to ask the LLM to find them
too, which is less reliable.

The flow:
1. **System** walks AST, finds `soft()` calls (mechanical)
2. **System** gathers I/O observations (mechanical)
3. **LLM** proposes the split (creative — this IS a `soft()` call)
4. **System** verifies the split produces same outputs (mechanical)
5. **System** hot-swaps the cell bodies (mechanical)

The LLM does the hard part (figuring out the refactoring). The
system does the boring parts (finding call sites, gathering
evidence, verifying, deploying). Code-as-data makes steps 1, 4,
and 5 possible without LLM involvement.

---

## How It Complements Gas City

### Gas City's Job

Gas City manages the **lifecycle** of agents:
- Which agents exist (city.toml)
- When they wake and sleep (reconciler)
- Which beads they're assigned (sling)
- How they communicate (nudge, mail)
- Formulas for dispatching work (orders)

Gas City does NOT think. It orchestrates.

### Beads' Job

Beads track **work items**:
- What needs to be done (tasks, bugs, decisions)
- Who's assigned (assignee)
- What state it's in (open, in_progress, closed)
- Dependencies between work items (parent/child)

Beads do NOT think. They track.

### The Retort's Job

The retort is where **thinking happens**:
- Agents pour thoughts (cells)
- Agents read each other's thoughts (observe)
- Patterns crystallize into programs
- Knowledge accumulates across agents and time

The retort does NOT orchestrate or track. It thinks.

### The Integration

```
1. A bead is created: "Review PR #42"
2. Gas City slings it to Agent A
3. Agent A wakes, reads the bead, starts thinking
4. Agent A pours cells into the retort:
   - parse_diff (pure: extract changed files)
   - analyze_changes (soft: LLM reviews each file)
   - count_issues (crystallized: regex count from prior reviews)
   - synthesize (soft: LLM writes the review summary)
5. Agent A observes: count_issues was already crystallized
   by Agent B last week. Uses it directly. No LLM call.
6. Agent A updates the bead with the review summary
7. Gas City marks the bead closed
8. The retort keeps the crystallized count_issues forever
```

Gas City doesn't know about cells or crystallization. Beads
don't know about the tuple space. The retort doesn't know about
agent lifecycle. Each system does one thing well. Together they
make agents that get smarter over time.

### The Event Bridge

Gas City's event bus connects the systems:

```
retort.cell.poured      → Gas City knows an agent is thinking
retort.cell.crystallized → Gas City can notify other agents
bead.assigned            → Agent can start pouring into retort
agent.session.stopped    → Retort knows to freeze partial work
```

Events flow between systems. Each system reacts to events from
the others. No tight coupling.

---

## What To Build (In Order)

### Phase 1: The Tuple Space

An Elixir GenServer wrapping ETS. Four operations:

```elixir
Retort.pour(name, cell_def)       # write a cell
Retort.observe(name, field)       # read a frozen yield
Retort.claim(name)                # atomic exclusive access
Retort.freeze(name, yields)       # write yields, release claim
```

Plus `soft/1` — a function that calls an LLM API and returns
the answer. This is just an HTTP call.

One file. ~100 lines. Test it with two processes pouring and
observing.

### Phase 2: Persistence

Add Mnesia backing. Cells and yields survive restarts.
Observation log: every `soft()` call recorded with inputs/outputs.

### Phase 3: Crystallization

The engine that watches the observation log, detects patterns,
walks ASTs, splits cells, proposes crystallizations. This is
the core value.

### Phase 4: Multi-Agent

Multiple BEAM nodes. Mnesia replication. Agents on different
machines share the retort. Crystallizations propagate.

### Phase 5: Gas City Bridge

Events connecting the retort to Gas City. Agents pour into the
retort as part of their bead work. Crystallizations are announced
via the event bus.

---

## What We're NOT Building

- A programming language (cells are data, not a language)
- A CLI tool (agents interact via Elixir API, not shell commands)
- A formal model (correctness via verification, not proofs)
- A custom database (ETS/Mnesia are the database)
- A piston dispatch protocol (agents call soft() directly)
- A parser (Elixir parses Elixir)

---

## The Measure of Success

The retort is working when:

1. Two agents pour thoughts about the same kind of work
2. A pattern is detected: "both agents did the same deterministic step"
3. That step crystallizes into a pure function
4. A third agent does the same kind of work and the crystallized
   function fires automatically — no LLM call
5. The third agent's work is faster and cheaper than the first two's
6. This compounds: each new crystallization makes all future work
   in that area cheaper

**The retort makes agents smarter by making the system remember
what they've already figured out.**

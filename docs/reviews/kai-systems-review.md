# Adversarial Review: Cell REPL Design (Runtime Formulas on Beads)

**Reviewer**: Kai (Systems Architect, Gas Town)
**Document**: `docs/plans/2026-03-14-cell-repl-design.md`
**Date**: 2026-03-14
**Verdict**: The design has promising instincts but conflates Gas Town
abstractions with a fundamentally different execution model. Several
mechanical assumptions do not survive contact with the actual system.

---

## 1. Formula Type Mismatch: "Formula" Does Not Mean What You Think It Means

The design proposes 10 "runtime formulas" (`mol-cell-pour`, `mol-cell-ready`,
etc.) and calls them "calculator buttons the LLM invokes." This betrays a
fundamental misunderstanding of what a Gas Town formula is.

A formula is a TOML workflow definition. It has a `description`, `version`,
`[[steps]]` with `id`, `title`, `needs`, and `description` fields, and `[vars]`.
Look at any actual formula — `mol-polecat-work` (v9, 9 steps),
`mol-witness-patrol` (v10, 9 steps), `mol-dep-propagate` (v1, 5 steps). These
are multi-step sequential/parallel workflows executed by an agent over minutes
to hours. They are not functions. They are not callable. They do not return
values.

The execution model for a formula is:

```
formula.toml --bd cook--> proto --bd mol pour--> molecule (beads) --> agent works steps --> squash --> digest
```

There is no `gt formula invoke mol-cell-ready --args '{"molecule_id": "mol-abc"}'`.
That API does not exist. To "run" a formula, you pour it as a molecule, and an
agent (polecat, witness, dog, crew member) works through its steps. Each step
is a bead. The agent closes beads as it completes steps.

**What the design actually wants** is a set of CLI commands or library functions
that perform mechanical Cell operations. That is fine. But calling them
"formulas" imports a massive amount of incorrect baggage:

- Formulas have lifecycle (pour, squash, digest)
- Formulas create molecules with N beads (one per step)
- Formulas require an agent to execute
- Formulas have vars that are bound at pour time
- Formulas have `[squash]` configuration

If `mol-cell-ready` is a formula, pouring it creates a molecule with its own
beads. Running it means an agent works through its steps. To "invoke" it as a
calculator button, you would pour a molecule, assign it to an agent, wait for
the agent to work the steps, extract the result from bead metadata, and then
continue. For a query that should take milliseconds.

**Concrete alternative**: These should be `bd` subcommands or `gt cell`
subcommands — imperative CLI tools, not declarative workflow templates.

```bash
bd cell pour <source.cell>           # Parse and create beads
bd cell ready <molecule-id>          # Query frontier
bd cell resolve <cell-bead-id>       # Resolve inputs
bd cell eval <cell-bead-id>          # Dispatch evaluation
bd cell oracle <cell-bead-id>        # Run oracle checks
bd cell freeze <cell-bead-id>        # Freeze yields and close
bd cell bottom <cell-bead-id>        # Mark bottom, propagate
bd cell status <molecule-id>         # Render machine state
bd cell step <molecule-id>           # One eval cycle
bd cell run <molecule-id>            # Loop to quiescence
```

These are commands. They run, do a thing, print output, exit. The LLM invokes
them as tools. No molecules-within-molecules. No agents-spawning-agents-to-run-
a-query.

---

## 2. Who Drives the Loop: You Are Describing a Workflow Formula

The design says "the LLM drives the eval loop" and "the LLM IS the runtime."
But then it says the LLM follows cell-zero. And cell-zero describes "read
frontier, pick a cell, evaluate it, check oracles, freeze or retry." That is
a workflow. A multi-step sequential workflow with conditional branching. Which
is exactly what a Gas Town formula already is.

Here is what the design is actually proposing, stripped of novelty:

1. An agent (the LLM) receives a molecule (the Cell program)
2. The agent works through a loop: check readiness, dispatch work, verify results
3. The agent uses `bd` commands to manage bead state

That is `mol-polecat-work` with different step descriptions. The "Cell runtime"
is a formula. The "eval loop" is a workflow. The LLM is a crew member following
a checklist.

This is not necessarily bad. The question is: what does calling it "Cell" buy
you that a well-designed formula does not already provide? The design needs to
answer this directly. If the answer is "dependency-driven DAG evaluation with
oracle verification," then the value is in the `bd cell *` commands (the
mechanical toolkit), not in the meta-narrative about LLMs driving eval loops.

**The design should separate**:

- **The toolkit** (`bd cell *` commands): the actual new capability. Dependency
  resolution, yield freezing, oracle dispatch, DAG status rendering. This is
  real engineering work.

- **The workflow** (a formula for running Cell programs): a formula whose steps
  invoke the toolkit. `mol-cell-eval` as a formula that an agent follows.
  Step 1: pour the program. Step 2: loop `bd cell step` until quiescent.
  Step 3: report results.

- **The meta-circular bootstrap** (cell-zero): a Cell program that describes
  the eval loop. This is a demonstration, not an architecture.

Conflating these three makes it impossible to evaluate each on its own merits.

---

## 3. Polecat Dispatch: The Synchronization Problem

The design says soft cells dispatch to polecats via `gt sling`. This glosses
over a critical synchronization problem.

Here is how `gt sling` actually works:

1. `gt sling <issue-id> <rig>` assigns a bead to a polecat pool
2. The sling process spawns a polecat (tmux session, git worktree)
3. The polecat runs `gt prime`, reads its hook, follows `mol-polecat-work`
4. The polecat works for minutes to hours
5. The polecat calls `gt done`, which:
   - Pushes the branch
   - Submits an MR to the merge queue
   - Sets `exit_type` metadata on its agent bead
   - Enters `awaiting_verdict` state

The polecat lifecycle is asynchronous and long-lived. There is no "return
tentative output." There is no callback. There is no future/promise. The
result of polecat work is:

- Code committed to a git branch
- Metadata written to the polecat's agent bead
- A POLECAT_DONE mail sent to the Witness

The orchestrating LLM has exactly two options for detecting completion:

**Option A: Poll**. Run `bd show <polecat-agent-bead> --json` in a loop,
checking for `exit_type` metadata. The Witness already does this in
`survey-workers` with exponential backoff via `gt mol step await-signal`.
Latency: 30 seconds to 5 minutes depending on backoff phase.

**Option B: Mail**. Wait for a POLECAT_DONE mail. The orchestrating LLM
would need `gt mail inbox` polling. Same latency characteristics.

Neither option gives you sub-second tool invocation semantics. If a Cell
program has 20 soft cells, and each takes 2 minutes of polecat work plus
1 minute of polling overhead, you are looking at 60 minutes of wall clock
time for a serial chain. Parallel dispatch helps but adds Dolt write
contention (see below).

**The design does not address**:

- How the polecat's output (which is code/text in a git branch) gets
  translated back into yield values in bead metadata
- Who does this translation — the polecat? The orchestrator? A dog?
- What happens if the polecat crashes mid-evaluation (zombies are a known
  problem — see the Witness patrol's zombie detection, which is ~200 lines
  of formula for good reason)
- How retry-with-feedback works when the polecat is a separate agent with
  its own context window that knows nothing about oracle failure reasons

**Concrete alternative for soft cell dispatch**: Instead of `gt sling` (full
polecat lifecycle), consider a lighter-weight dispatch mechanism:

- **Agent tool**: The orchestrating LLM uses Claude's Agent/Task tool to
  spawn a sub-agent within its own session. No tmux, no worktree, no
  polecat lifecycle. Result returns inline. The beads-substrate-design doc
  already mentions this as "Agent mode."
- **Polecat mode**: Reserved for cells that genuinely need isolation (file
  system access, long-running builds, untrusted code). Accept the latency
  cost. Design the Cell program so these are leaves, not inner nodes.

---

## 4. Molecule Lifecycle: The Non-Termination Problem

The design acknowledges this as an open question but does not treat it with
the seriousness it deserves.

Gas Town molecules have a defined lifecycle:

```
Proto --pour--> Molecule --execute--> all beads closed --squash--> Digest
```

A molecule is "done" when all its beads are closed. At that point it gets
squashed into a digest — a compressed, immutable record. This is not optional.
The molecule lifecycle is load-bearing infrastructure:

- `bd mol wisp gc` garbage-collects closed wisps
- `mol-dog-reaper` cleans up stale molecules
- The Deacon monitors molecule health
- Dolt branches may be tied to molecule lifetime

Cell programs, by design, have a frontier that "grows monotonically." The
design says this explicitly. A Cell program does not terminate — new cells
can be added, the frontier expands. This means:

1. The molecule never reaches "all beads closed" (new beads keep appearing)
2. Squash never triggers
3. The molecule lives forever
4. The reaper cannot clean it up
5. Dolt accumulates unbounded state

The design hand-waves this as "quiescence (no ready cells) is the natural
endpoint." But quiescence is not termination. A quiescent Cell program can
become non-quiescent when new cells are added or external inputs change.
You cannot squash at quiescence because the program might resume.

**This is a resource leak**. In a workspace running 5 Cell programs, you have
5 permanent molecules with growing bead counts, never squashing, never
digesting. The reaper sees them as stuck. The Deacon sees them as unhealthy.
The Dolt database grows monotonically.

**Concrete alternatives**:

- **Generation model**: Borrow from the Gas City vision doc (which already
  solved this). A Cell program runs as a molecule. When it reaches quiescence,
  squash it into a digest. If the program resumes, distill the digest into a
  new proto, pour a new molecule (generation 2). Each generation is a clean
  molecule with proper lifecycle. Cross-generation state is carried via the
  digest's content-addressed record. This is exactly what `evolve` and
  `EvolutionHistory` in the Lean formalization describe.

- **Wisp mode**: Cell molecules are wisps (ephemeral molecules). They get
  garbage-collected aggressively. Use `bd mol wisp gc --age 1h --force`
  like the Witness and Refinery patrols already do. Accept that Cell programs
  are ephemeral computations, not persistent services.

---

## 5. Beads Namespace Pollution

The design says "each cell becomes a bead." For a program with N cells,
that is N beads. But it is actually worse than that:

- N cell beads
- Oracle assertions as "child beads" of cell beads (design says this
  explicitly) — potentially 2-3 per cell
- Retry beads (oracle failure triggers retry, which is a new evaluation)
- The molecule bead itself
- The agent bead for the orchestrating LLM

A 20-cell program with 2 oracles each and 1 retry on average generates:

```
20 cell beads + 40 oracle beads + 10 retry-related beads + 1 molecule + 1 agent = 72 beads
```

In a workspace with 3 active Cell programs, that is 216 mechanical beads.
These appear in `bd list`, `bd ready`, `bd graph`. They are mixed in with
actual work items (issues, MRs, patrol wisps, cleanup wisps). Every `bd`
command that scans beads now processes Cell machinery alongside real work.

The Witness patrol runs `bd list --status=in_progress --json --limit=0`
every cycle to detect orphans. It already struggles with bead volume in
busy workspaces. Adding 200+ mechanical beads makes this worse.

**The label system helps but does not solve this**. You can label Cell beads
with `cell`, `oracle`, etc., and filter with `--label cell`. But every
command that does NOT explicitly filter now returns polluted results. And
the labels themselves are stored in Dolt rows — more data, more commit
overhead.

**Concrete alternatives**:

- **Separate Dolt database**: This is exactly what Retort was. A dedicated
  database (`retort.db`) for Cell computation state, separate from the
  workspace beads database. Cell beads never pollute workspace beads.
  Cross-referencing via the `bead_bridge` table (which Retort already
  designed). This was not an accident — it was a deliberate architectural
  decision that this design discards without adequate justification.

- **Hierarchical namespacing**: If you insist on one database, use bead
  prefixes or a `namespace` column. All Cell beads live under
  `cell/<program-name>/`. The `bd` commands gain a `--namespace` filter
  that defaults to excluding `cell/*`. Cell-specific commands always
  scope to `cell/*`.

- **Ephemeral beads with aggressive GC**: Cell beads are created as wisps
  and garbage-collected after the program reaches quiescence. Only the
  final yields survive as regular beads. This keeps the mechanical
  scaffolding transient.

---

## 6. The Retort Question: Why Throw Away a Carefully Designed Schema?

The Retort schema (`schema.go`) was not an arbitrary prototype. It was a
carefully designed relational schema with:

**Dedicated tables with proper columns and types**:
- `cells`: `body_type ENUM('soft','hard','script','passthrough','spawner','evolution')`, `state ENUM('declared','computing','tentative','frozen','bottom','skipped')`, `retry_count`, `max_retries`, `spawned_by`, `spawn_order`, `iteration`
- `givens`: `source_cell`, `source_field`, `is_optional`, `is_quotation`, `default_value`, `guard_expr`, `resolved`, `resolved_value_id`
- `yields`: `value_text`, `value_json`, `is_frozen`, `is_bottom`, `tentative_value`, `value_hash`, `frozen_at`
- `oracles`: `oracle_type ENUM('deterministic','structural','semantic','conditional')`, `assertion`, `condition_expr`, `ordinal`
- `recovery_policies`: `max_retries`, `exhaustion_action ENUM('bottom','escalate','partial_accept')`, `recovery_directive`
- `evolution_loops`: `until_expr`, `max_iterations`, `current_iteration`, `status`
- `trace`: step-level execution audit trail (with `DoltIgnoreTrace` for performance)

**Purpose-built query infrastructure**:
- `ready_cells VIEW`: A SQL view with correlated subqueries that efficiently
  computes Cell readiness. It checks that all required givens have frozen
  upstream yields AND no required upstream yields are bottom. This is a
  single SQL query, not "scan all beads, read JSON metadata, filter in
  application code."

**Proper indices**:
- `idx_state` on cells (filter by declared/frozen/computing)
- `idx_cell_id` on givens, oracles, recovery_policies
- `idx_program_step` on trace
- `idx_target_cell` on evolution_loops

**The bead_bridge table**: Explicitly designed for the Cell-beads integration
point. Cell computations reference beads when dispatching to polecats. Beads
reference cells when receiving results. This is the boundary, not a merger.

The design's justification for abandoning Retort is five bullet points:

> 1. Cell programs ARE work
> 2. Beads already handles dependencies, readiness, metadata, and dispatch
> 3. `bd ready` already computes the frontier
> 4. `gt sling` already dispatches to polecats
> 5. One system to reason about, not two

Point by point:

1. Cell programs are computation, not work items. A cell computing
   `sort([4,1,7,3])` is not a task to be assigned and tracked. It is a
   computation step in a program. The bead abstraction (which is designed
   for work items with assignees, statuses, PRs, merge queues) adds friction
   to this use case.

2. `bd ready` computes readiness based on bead dependencies (blocker closed
   = ready). Cell readiness is more complex: all required givens must have
   frozen upstream yields, no required upstream is bottom, guard expressions
   must evaluate to true. `bd ready` cannot express this without the
   `ready_cells` view's SQL logic being reimplemented in application code
   that reads JSON metadata.

3. See above. `bd ready` is not `ready_cells`.

4. `gt sling` dispatches to polecats. Agreed. But `bead_bridge` already
   handles this integration. You do not need Cell beads to be workspace beads
   to dispatch polecats — you need a bridge row mapping cell-id to bead-id.

5. "One system to reason about" is appealing in theory. In practice it means
   one system doing two very different jobs, with neither job done well. The
   beads system is optimized for work tracking. The Retort schema is optimized
   for computation state. Merging them produces a system optimized for neither.

**Recommendation**: Keep Retort. Use `bead_bridge` for the integration
boundary. Cell computations live in the Retort database with proper schema,
indices, and views. When a Cell dispatches to a polecat, a `bead_bridge`
row maps the cell to its dispatch bead. When the polecat completes, the
result flows back through the bridge. This is the architecture Retort was
designed for.

---

## 7. Formula as Runtime Primitive: The Engine Cannot Support This

Even if we set aside the "formulas are not functions" problem from section 1,
the formula engine has concrete limitations that prevent the proposed usage:

**No parameterized return values**. Formulas produce side effects (beads
created, steps closed, metadata written). They do not return structured data.
`mol-cell-ready` needs to return a list of bead IDs. There is no mechanism for
a formula to return `["bd-a1b2", "bd-c3d4"]` to its caller. The caller would
have to read the side effects (query beads after the formula runs), introducing
a race condition.

**No composition**. The formula engine does not support formula A calling
formula B as a subroutine. `mol-cell-step` (which the design defines as
ready-pick-eval-oracle-freeze) cannot invoke `mol-cell-ready` then
`mol-cell-eval` then `mol-cell-oracle` then `mol-cell-freeze` as sub-formulas.
Each formula is a top-level workflow. To compose them, you would need to
inline all sub-formula steps into the parent formula — which defeats the
purpose of decomposition.

**No conditional branching in the step graph**. Formula steps have `needs`
(DAG dependencies) but no `if/else`. `mol-cell-step` needs to branch: if
oracle passes, freeze; if oracle fails and retries remain, re-eval; if oracle
fails and retries exhausted, bottom. The step graph cannot express this.
The agent implements the branching by reading the step description and using
judgment. Which means the "deterministic mechanical toolkit" is not actually
deterministic — it depends on the agent correctly interpreting branching
instructions in natural language.

**No looping**. `mol-cell-run` is defined as "loop mol-cell-step until
quiescent." The formula engine has no loop construct. The agent implements
the loop by... not closing the final step and re-executing from an earlier
step? By pouring a new molecule each iteration? Neither is a clean pattern.

**The formula engine would need extension to support this**:
- Return values from formula execution
- Sub-formula invocation (formula composition)
- Conditional step routing
- Loop constructs

These are all features in the Gas City Formula Engine vision doc's "longer-term
vision" (Formula Language v2). They do not exist today. Building the Cell REPL
on hypothetical future formula engine capabilities is risky.

**Concrete alternative**: Build the Cell toolkit as `bd cell *` commands (CLI
tools). These are ordinary Go functions compiled into the `bd` binary. They
read and write Retort tables. They compose naturally (a shell script can call
`bd cell ready` then loop over the results calling `bd cell eval`). They
return structured output (JSON). They do not require formula engine extensions.

The workflow layer (how an agent uses these commands) IS a formula — a simple
one:

```toml
formula = "mol-cell-eval-loop"
version = 1

[[steps]]
id = "pour"
title = "Load Cell program into Retort"
description = "Run bd cell pour <source>"

[[steps]]
id = "run"
title = "Evaluate to quiescence"
needs = ["pour"]
description = "Run bd cell run <molecule-id>"

[[steps]]
id = "report"
title = "Report results"
needs = ["run"]
description = "Run bd cell status <molecule-id>"
```

Three steps. The complexity lives in `bd cell *`, not in the formula.

---

## 8. Additional Systems Architecture Concerns

### 8a. Dolt Commit Overhead

The design says `mol-cell-freeze` does a "Dolt commit (the eval step is now in
version history)." Every cell freeze is a Dolt commit. For a 50-cell program,
that is 50 Dolt commits during a single execution.

Dolt commits are not free. Each commit:
- Writes a new root hash
- Updates the commit graph
- Flushes buffers
- Takes a write lock

In a workspace where the Witness patrols every 30 seconds, the Refinery
processes MRs, and Dogs run maintenance molecules, adding 50 commits per Cell
program execution creates write contention. The `trace` table in Retort was
deliberately excluded from Dolt versioning (`DoltIgnoreTrace`) because the
Retort designers knew commit-per-step was too expensive for high-frequency
operations.

**Alternative**: Batch commits. Commit after each "round" (all currently-ready
cells evaluated), not after each individual cell freeze. Or use Dolt's working
set for in-progress state and only commit at quiescence.

### 8b. Concurrent Cell Evaluation and Write Conflicts

The design's open question #2 asks "when multiple cells are ready, does the LLM
dispatch them in parallel?" If yes, multiple polecats write to the same Dolt
database concurrently. Dolt uses optimistic concurrency — concurrent writers to
the same table get merge conflicts.

If two polecats both write yield metadata to the same `beads` table (or Retort
`yields` table) simultaneously, one of them will hit a conflict on commit. Gas
Town already deals with this for workspace beads (polecats write to their own
worktree branches, the Refinery serializes merges). But Cell evaluation wants
sub-second write latency, not minutes-long merge queue processing.

**Alternative**: The orchestrating LLM is the single writer. Polecats return
results via mail or agent bead metadata. The orchestrator reads results and
writes Cell state. Single-writer eliminates conflicts.

### 8c. The "Everything Starts as Text" Assumption

Phase 2 says the first Cell programs are "just text — natural language
descriptions." The LLM reads prose and creates beads. This means `mol-cell-pour`
is not a deterministic parser — it is an LLM interpreting natural language.

Two risks:

1. **Non-reproducibility**: The same text input produces different bead
   structures on different runs. Cell programs are supposed to be precise
   specifications of computation. If the parser is non-deterministic, the
   computation is non-deterministic before any soft cell even evaluates.

2. **Error compounding**: If the LLM misinterprets a dependency ("B depends
   on A" parsed as "A depends on B"), the entire program evaluates incorrectly.
   There is no syntax check because there is no syntax. There is no parse
   error because the LLM always produces *something*.

The design acknowledges this will crystallize toward deterministic parsing.
But in the meantime, every Cell program execution starts with an unreliable
parsing step. The oracle mechanism could catch downstream errors, but it
cannot catch parse errors (the oracles are defined by the same parse step
that might be wrong).

**Alternative**: Start with the turnstile syntax. It exists. It has a parser
(`cell-to-beads.py` from the beads-substrate-design doc). The crystallization
narrative is intellectually appealing but operationally hazardous. Ship the
deterministic parser first. Let "text first" be a demo feature, not the
bootstrap path.

### 8d. Missing: How Does the Orchestrating LLM Get Its Tools?

The design assumes the LLM "invokes runtime formulas as tools." How? In Gas
Town, LLM tool invocation happens through Claude Code's MCP (Model Context
Protocol) or bash tool. The LLM runs `bd` commands via bash.

If the Cell toolkit is `bd cell *` commands, this works naturally — the LLM
runs bash commands. If the toolkit is "formulas," the LLM cannot invoke them
as tools because formulas are not tool-invocable (see section 1).

This is another argument for `bd cell *` as the implementation surface.

### 8e. Missing: Session Death and Recovery

The orchestrating LLM is a Claude Code session. Sessions die: context limits,
crashes, SIGKILL, machine restarts. `mol-polecat-work` handles this with
`gt handoff` for state preservation. The Witness handles it with session restart
and respawn.

If the Cell eval loop is in-flight when the orchestrating session dies:
- Which cells were in-flight? (polecats dispatched but not returned)
- What was the frontier state? (partially frozen yields)
- Can a new session resume? (needs to reconstruct loop state)

If Cell state is in Retort, a new session runs `SELECT * FROM cells WHERE
state = 'computing'` and knows exactly what is in flight. If Cell state is in
bead metadata JSON, a new session runs... `bd list --label cell --status=open
--json | jq '.[] | select(.metadata.state == "computing")'`? Maybe. If the
metadata schema is consistent. If the JSON is not corrupted by a partial write.

The Retort schema was designed for crash recovery. Bead metadata was not.

---

## Summary of Recommendations

| Design Choice | Problem | Alternative |
|---------------|---------|-------------|
| Runtime formulas | Formulas are workflows, not functions | `bd cell *` CLI commands |
| LLM drives eval loop | This is just a workflow formula | Separate toolkit from workflow from meta-circular demo |
| Polecat dispatch for soft cells | Async, high-latency, no return channel | Agent tool for fast dispatch; polecat for heavy isolation |
| Beads as cell storage | Namespace pollution, no Cell-specific queries | Retort database with `bead_bridge` |
| Non-terminating molecules | Resource leak, reaper conflict | Generation model (squash at quiescence, distill to re-pour) |
| Text-first parsing | Non-reproducible, error-compounding | Ship deterministic parser first, text-mode as demo feature |
| Commit per freeze | Write contention, overhead | Batch commits per eval round |
| Abandon Retort schema | Loses indices, views, typed columns, crash recovery | Keep Retort, it was designed for exactly this |

The core insight of the design — that Cell's mechanical operations should be a
deterministic toolkit the LLM invokes, not something the LLM hand-waves through
— is correct and valuable. The implementation path is wrong. Build the toolkit
as `bd cell *` commands backed by Retort. Wrap it in a simple workflow formula.
Do not try to make the formula engine into something it is not.

--- Kai

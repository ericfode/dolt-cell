# Cell-Zero in Unison: A Design Exploration

**Date**: 2026-03-14
**Status**: Research / Speculative Design
**Context**: Could Unison resolve the philosophical tension between cell-zero (the
specification) and stored procedures (the implementation)?

---

## The Tension

The v2 Cell runtime design makes a pragmatic choice: Dolt stored procedures are
the real evaluator. Cell-zero -- the metacircular evaluator described in the
v0.2 spec -- is, as Mara put it, "a specification document that describes what
the formulas do, expressed in Cell syntax. It is not self-hosting."

This works. But it leaves a gap. The computational model says cell-zero IS the
real implementation, running on the semantic substrate. The v2 design says stored
procedures are the real implementation, and cell-zero is documentation. These
cannot both be true. The v2 design chose correctly for getting something built,
but the philosophical claim -- that Cell is expressive enough to describe its
own evaluator, and that description IS the evaluator -- remains unfulfilled.

Unison might close this gap. Not because it is a better database than Dolt, but
because it is a language where code IS data by construction, where effects are
first-class and swappable, and where a program that evaluates other programs is
not a philosophical curiosity but a natural thing to write.

This document explores what cell-zero would look like as a Unison program, what
Unison's properties buy us, and what we would lose by moving away from Dolt.

---

## 1. Cell-Zero as a Unison Program

Cell-zero describes an eval loop over a dependency graph. It does the following,
forever:

1. Scan the frontier (find cells whose inputs are all frozen).
2. Pick a cell to evaluate.
3. Dispatch: soft cells go to an LLM, hard cells go to a deterministic evaluator.
4. Receive tentative output.
5. Spawn oracle claim cells.
6. Evaluate oracles (deterministic or semantic).
7. If oracles pass: freeze the cell's yields.
8. If oracles fail: retry with feedback, or mark bottom.
9. Loop.

In the Dolt design, this loop is split across stored procedures
(`cell_eval_step`, `cell_submit`) and an external LLM piston. The procedure
handles steps 1-2 and 5-8. The LLM handles steps 3-4. The loop is not a loop
in any single program -- it is an interaction protocol between two systems.

In Unison, this could be a single function:

```
cellZero : CellGraph -> {Semantic, Storage, Remote, Clock} ()
```

The function takes a cell graph and runs the eval loop. The loop IS a loop --
a recursive function that calls itself after each step. The `Semantic` ability
handles LLM dispatch. The `Storage` ability handles reading and writing cell
state. The `Remote` ability handles distribution. The `Clock` ability handles
timeouts and heartbeats.

### What the eval loop looks like structurally

The core is a function that finds ready cells, dispatches them, checks oracles,
and freezes or retries. In Unison's terms:

- **Scanning the frontier**: A pure function over the cell graph. Given a
  `CellGraph` (a value representing all cells, their dependencies, and their
  yield states), compute which cells have all inputs frozen and are in the
  `declared` state. This is `List.filter` over cells with a readiness predicate.
  No effects needed. Pure computation.

- **Picking a cell**: A pure function that selects from the ready list. Could be
  first-available, priority-based, or affinity-filtered. No effects.

- **Dispatching**: This is where abilities enter. A soft cell dispatch requires
  the `Semantic` ability -- it sends a prompt and receives a response. A hard
  cell dispatch is pure computation -- evaluate the deterministic body against
  resolved inputs. The dispatch is a pattern match on the cell's body type.

- **Oracle checking**: Deterministic oracles are pure functions. Semantic oracles
  require the `Semantic` ability. The oracle checker pattern-matches on oracle
  type and either computes locally or asks the LLM.

- **Freezing**: Requires the `Storage` ability. Update the cell graph: mark the
  cell as frozen, write its yield values.

- **Retrying**: Update the cell graph: increment retry count, append failure
  context. Recursive call back into the dispatch step.

- **Looping**: Recursive call to `cellZero` with the updated graph. The frontier
  has changed (the frozen cell's dependents may now be ready). The loop
  continues until the frontier is empty (quiescence).

### Why this is different from the Dolt version

In the Dolt design, the eval loop is implicit -- it emerges from the piston
calling `cell_eval_step` in a loop. The "loop" is in the piston's instructions,
not in any code. The state lives in database tables. The dispatch protocol is
a call-and-response between the LLM and a stored procedure.

In Unison, the eval loop is explicit. It is a function. It has a type signature.
It can be tested, composed, and distributed. The state is a value (the
`CellGraph`), not scattered across database tables. The dispatch is a function
call through an ability, not an interaction protocol.

The Unison version is closer to what the computational model claims cell-zero
IS: a program that evaluates programs. The Dolt version is an implementation
that achieves the same result through a different mechanism (interaction
protocol + database state).

---

## 2. The Semantic Ability as the LLM Bridge

Cell's dual-substrate model has a clean boundary: soft cells need semantic
evaluation (LLM), hard cells need deterministic evaluation (computation). In
Unison, this boundary is an ability.

### Declaring the ability

The `Semantic` ability would declare operations for LLM interaction:

```
structural ability Semantic where
  evaluate : Prompt -> {Semantic} Response
  judge    : Assertion -> Value -> {Semantic} OracleResult
```

`evaluate` takes a prompt (the soft cell's body with resolved inputs) and
returns a response. `judge` takes an oracle assertion and a tentative value and
returns pass/fail with explanation.

These two operations cover cell-zero's entire LLM surface. Every soft cell
dispatch goes through `evaluate`. Every semantic oracle goes through `judge`.

### The power of swappable handlers

Different handlers for `Semantic` give different execution strategies, with
zero changes to cell-zero's code:

**Production handler**: Calls an LLM API (Claude, GPT, etc.). The handler
manages API keys, rate limits, retries, token counting. Cell-zero does not know
or care which model is called.

**Local model handler**: Calls a local model (Ollama, llama.cpp). Same
interface. Different performance characteristics. Useful for development or
air-gapped environments.

**Human-in-the-loop handler**: Prints the prompt to a terminal and waits for
human input. Cell-zero becomes an interactive system where a human plays the
role of the LLM. Useful for debugging, teaching, or high-stakes evaluation
where human judgment is required.

**Cached/memoized handler**: Wraps another handler but caches responses keyed
by prompt hash. If the same prompt has been evaluated before, return the cached
result. This is crystallization at the handler level -- repeated identical
prompts get instant deterministic responses.

**Mock handler**: Returns predetermined responses for testing. Cell-zero can be
unit-tested without any LLM calls. The test provides expected responses; the
handler returns them. Oracle checking runs against the mock responses. The full
eval loop executes deterministically.

**Recording handler**: Wraps another handler, forwards requests to the real LLM,
but records all prompt/response pairs. The recording can later be replayed as a
mock handler. This enables golden-file testing of cell programs: run once with
a real LLM, record, replay forever.

### Model routing through handler composition

The v2 design uses `model_hint` on cells to route different cells to different
models. In Unison, this is handler composition. The `Semantic` handler can
inspect the prompt metadata (which cell it came from, what model hint it
carries) and dispatch to different underlying LLM clients.

Or, more interestingly: the handler can be a composite that tries a cheap model
first, checks confidence, and falls back to an expensive model. This is a
handler-level concern, invisible to cell-zero.

### What this resolves from the v2 design

The v2 design's piston model has the LLM as an external actor that follows a
protocol. The protocol is fragile -- the piston instructions are natural
language, the LLM might deviate, the interaction requires careful prompt
engineering.

With the `Semantic` ability, the boundary is typed. Cell-zero calls
`Semantic.evaluate prompt` and gets back a `Response`. The handler is
responsible for actually talking to the LLM. The types enforce the contract.
The handler can be tested independently. There is no "piston instruction
document" -- there is a function type.

---

## 3. Self-Hosting and the Fixed-Point Question

### The metacircular claim

Cell-zero in Unison evaluates Cell programs. Cell-zero is itself a Unison
definition. Can cell-zero evaluate itself?

In Scheme, the metacircular evaluator can evaluate its own source code because
Scheme's `eval` takes an S-expression (data) and produces a value. The
evaluator's source code is an S-expression. Therefore the evaluator can
evaluate its own source.

In Unison, the analog would be: cell-zero is a Unison function stored by hash.
Cell programs are Unison data structures (a `CellGraph` value). Can cell-zero
be expressed as a `CellGraph` that, when evaluated by cell-zero, produces...
cell-zero?

### Content addressing changes the game

In most languages, "self-hosting" means the compiler/interpreter can process its
own source code. The source code is text. The compiler reads text and produces
an executable.

In Unison, there is no "source code" in the traditional sense. There are
definitions stored by hash in the codebase. The "source" of cell-zero is its
AST, identified by a hash like `#a7f3b2c9...`. The definition is immutable.
Its hash is deterministic.

Cell-zero-as-data means encoding cell-zero's logic as a `CellGraph` value: a
graph of cells where each cell describes one step of the eval loop. The cells
reference each other via dependency edges. Some cells are hard (deterministic
steps like frontier scanning). Some cells are soft (steps that require judgment,
like deciding how to handle an ambiguous oracle result).

### Three levels of self-reference

**Level 1: Cell-zero evaluates a Cell program that describes cell-zero.**

Write a `.cell` file whose cells describe the eval loop. Load it as a
`CellGraph`. Run cell-zero on it. The output is... a description of what
cell-zero does. This is metacircular in the Scheme sense: the evaluator
processes a description of itself. But the output is a description, not a
running evaluator.

**Level 2: Cell-zero evaluates a Cell program whose frozen yields ARE cell-zero.**

Write a Cell program where the final yield is a `CellGraph` value representing
cell-zero itself. Running this program through cell-zero produces, as output,
the data structure that IS cell-zero's input format. You could then feed that
output back into cell-zero and get... the same output. This is a fixed point:
`cellZero(encode(cellZero)) = encode(cellZero)`.

Whether this fixed point exists depends on whether the encoding is faithful --
whether a Cell program can fully describe cell-zero's behavior. Given that
Cell is Turing-complete (soft cells can compute anything) and cell-zero is a
computable function, the encoding exists in principle. Whether it is practical
depends on how naturally cell-zero's logic maps to Cell's programming model.

**Level 3: Cell-zero IS a Cell program that runs on itself.**

This is the computational model's claim: cell-zero is a `.cell` file, and it
IS the evaluator. In Unison, this would mean cell-zero is stored as a
`CellGraph` value, and there is a bootstrap function that takes a `CellGraph`
(representing cell-zero) and produces a `CellGraph -> {Semantic, Storage} ()`
function (cell-zero as executable). The bootstrap function is the only
non-Cell code. Everything else is Cell programs evaluated by cell-zero.

This is the deepest form of self-hosting. It requires that the Cell language
is expressive enough to encode its own evaluator, and that the encoding is
executable. In Unison, the content-addressed nature helps: the `CellGraph`
encoding of cell-zero has a hash; cell-zero can reference its own hash; the
fixed-point is structural, not incidental.

### The quotation operator in Unison

The Cell spec defines `§name` as the quotation operator: it returns the
definition of `name` as data. In the Dolt design, this is `SELECT FROM cells
WHERE name = 'name'` or `SELECT FROM INFORMATION_SCHEMA.VIEWS WHERE ...`.

In Unison, quotation is more natural. Every definition is stored by hash.
Fetching a definition means looking up a hash in the codebase. The codebase is
a persistent data structure that Unison programs can query (via the Codebase
API or through abilities that expose it).

`§sort` in Unison-Cell would mean: retrieve the `CellGraph` node for the cell
named `sort`, including its body, its dependencies, its yield types, and its
oracle assertions. Since the cell graph is a Unison value, this is field
access. Since Unison definitions are stored by hash, the retrieved definition
is guaranteed to be the exact version that was referenced -- no stale reads, no
version drift.

For self-reference: `§cell-zero` returns cell-zero's own definition as data.
Cell-zero can inspect its own structure. This is reflection, enabled by
content addressing rather than by runtime introspection hacks.

---

## 4. The Eval Loop as a Unison Cloud Service

### From function to service

Cell-zero as a Unison function runs locally. Cell-zero as a Unison Cloud
service runs persistently, handles multiple programs, and distributes work
across nodes.

Unison Cloud provides the primitives:

- **Services**: Typed, versioned, content-addressed functions deployed to the
  cloud. Cell-zero becomes a service identified by its hash. Deploying a new
  version of cell-zero creates a new service with a new hash. Old and new
  versions can run simultaneously.

- **Remote ability**: Fork computations to other nodes. When cell-zero finds
  multiple ready cells, it can fork their evaluation to different workers using
  `Remote.fork`. Each worker runs the dispatch logic (soft or hard) and returns
  the result. Cell-zero collects results and continues.

- **Storage (Cell primitive in Unison Cloud)**: Durable single-value containers.
  The cell graph can be stored in a Unison Cloud `Cell` (confusing naming -- this
  is Unison Cloud's storage primitive, not a Cell-language cell). Each program's
  state persists across service restarts.

- **OrderedTable**: Typed key-value storage with transactional semantics. Cell
  yields could be stored in an OrderedTable keyed by `(program_id, cell_name,
  field_name)`. Oracle results in another. Execution traces in another.

- **Transactions**: The `Transaction` ability ensures atomic updates. Freezing a
  cell (marking it frozen, writing its yield values, updating dependent cells'
  readiness) can be wrapped in a transaction. Either all updates succeed or none
  do.

### The distributed eval loop

With Unison Cloud, cell-zero's eval loop gains natural parallelism:

1. Scan the frontier. Find N ready cells.
2. For each ready cell, fork a worker via `Remote.fork`.
3. Each worker runs dispatch (call `Semantic.evaluate` for soft cells, compute
   for hard cells).
4. Each worker runs oracle checking.
5. Each worker returns `(cell_id, result, oracle_outcomes)`.
6. Cell-zero collects results, freezes successful cells, retries failed ones.
7. Loop with updated graph.

The `Remote` ability handles node selection, failure detection, and retry. If a
worker dies mid-evaluation, `Remote` can detect the failure (via heartbeats or
timeouts) and re-fork the work. This is the same problem the v2 design solves
with `cell_reap_stale()` and the `pistons` table, but handled by the language
runtime rather than custom SQL infrastructure.

### Persistent long-running service

Cell-zero as a Unison Cloud daemon runs continuously. Programs are submitted to
it. It maintains a queue of active programs, each with its own cell graph
stored in durable Cloud storage. The daemon:

- Accepts new programs (via a typed service endpoint).
- Runs eval loops for active programs.
- Reports status (via another typed endpoint).
- Handles program completion (quiescence detection).

The daemon IS cell-zero. It is not a wrapper around cell-zero, not a stored
procedure that implements cell-zero's logic, not an LLM following cell-zero's
instructions. It is the function `cellZero`, deployed as a service, running the
eval loop.

### What this resolves

The v2 design has a three-layer architecture: stored procedures (runtime), LLM
pistons (semantic substrate), SQL (data). These three layers interact via a
protocol.

The Unison Cloud version collapses this to one layer: a Unison program with
abilities. The program IS the runtime. The `Semantic` ability IS the LLM
bridge. The `Storage` ability IS the data layer. There is no protocol between
layers because there are no layers -- there are abilities and their handlers.

---

## 5. Metacircularity via Content Addressing

### Code IS data in Unison

Unison's defining property is that definitions are identified by the hash of
their syntax tree. A definition is not a file on disk -- it is a node in a
persistent data structure (the codebase). The codebase can be queried
programmatically. Definitions can be retrieved, inspected, and manipulated as
values.

This is exactly what Cell's `§` operator requires. The `§` operator is
quotation: it lifts a definition from the code level to the data level. In most
languages, this requires runtime reflection (Java), eval/quote (Lisp), or
special-purpose introspection APIs. In Unison, it is structural: definitions
ARE data. There is no gap between "the code" and "the data representation of
the code."

### What this means for Cell

In the Dolt design, `§sort` means `SELECT * FROM cells WHERE name = 'sort'`.
The cell definition is stored as a row in a table. To inspect it, you query
the table. To reference it from another cell, you join on the cells table.
The relational model is the quotation mechanism.

In Unison, `§sort` means: look up the definition of `sort` in the cell graph
(which is a Unison value) by name, or by hash. The definition is a value of
type `CellDef` or similar -- a structured representation of the cell's body,
dependencies, yields, and oracles. Since the cell graph is a Unison value,
quotation is field access. Since definitions are content-addressed, the
quotation is stable: `§sort` always refers to the exact definition that was
present when the reference was created.

### The metacircular structure

Consider what cell-zero needs to do when it encounters `§cell-zero` -- a
reference to its own definition:

1. Look up `cell-zero` in the cell graph.
2. Retrieve its definition (body, dependencies, yields, oracles).
3. Return the definition as data.

In Unison, step 2 is guaranteed to succeed and to return the exact definition
that was hashed. There is no version drift. There is no stale cache. The hash
IS the identity. If cell-zero's definition changes, it gets a new hash, and
`§cell-zero` refers to the new version by default (or the old version if the
hash is pinned).

This means the metacircular structure is not a philosophical aspiration -- it
is a mechanical property of the system. Cell-zero can inspect its own
definition because definitions are data. Cell-zero can evaluate a program that
references cell-zero because that reference is just a hash lookup. The fixed
point (cell-zero evaluating a description of itself) is stable because content
addressing pins the identity.

### Deeper: definitions as cell bodies

What if hard cell bodies were not SQL views or expression-language strings, but
Unison functions? A hard cell's body could be a `Value -> Value` function
identified by its hash. Cell-zero dispatches a hard cell by looking up its body
hash in the codebase, retrieving the function, and applying it to the resolved
inputs.

This eliminates the `exec:` escape hatch problem from the v2 design. There is
no shelling out. There are no external executables. Hard cell bodies are Unison
functions, stored by hash, type-checked, and executed in the same runtime as
cell-zero. The security concern Kai raised (arbitrary shell commands from
database rows) vanishes: hard cell bodies run in Unison's sandbox, with only
the abilities that cell-zero grants them (which, for hard cells, should be
none -- pure computation only).

For soft cells, the body remains natural language (a `Text` value). Cell-zero
dispatches soft cells through the `Semantic` ability. The handler calls an LLM.
The dual-substrate model is preserved: soft cells use the semantic ability,
hard cells are pure Unison functions.

---

## 6. What Unison Adds That Dolt Cannot

### A real programming language for the eval loop

Dolt stored procedures are written in a subset of MySQL's procedural SQL. This
is a programming language, but a limited one. It has variables, conditionals,
loops, and cursors. It does not have:

- **Algebraic data types.** Cell state (`declared | computing | frozen | bottom`)
  is an ENUM string column, not a sum type. Pattern matching is `IF/ELSEIF`
  chains, not exhaustive match expressions.

- **First-class functions.** The dispatch logic (soft vs. hard) cannot be
  abstracted as a function passed to the eval loop. It must be inlined as
  conditional branches in the procedure body.

- **Recursive data structures.** The cell graph is not a value the procedure
  operates on -- it is scattered across tables. Traversing the graph requires
  JOINs. Building a subgraph requires temporary tables or cursors. There is no
  recursive type representing the graph.

- **Type safety.** Stored procedure variables are untyped. A variable that
  should hold a cell ID can accidentally hold a yield value. The type errors
  manifest at runtime as wrong query results, not at compile time as type
  mismatches.

- **Effect abstraction.** There is no way to abstract over "what happens when
  we need an LLM call." The procedure either calls an LLM (via some external
  mechanism) or it does not. There is no handler swap, no mock, no alternative
  execution strategy.

Unison has all of these. Cell-zero in Unison is a well-typed function with
pattern matching, recursive graph traversal, and swappable effect handlers.
The eval loop reads like what it IS -- an eval loop -- not like SQL that
happens to implement an eval loop.

### Composition and modularity

In the Dolt design, extending cell-zero means modifying stored procedures.
Adding a new cell body type (e.g., `wasm:` for WebAssembly evaluation) means
adding a branch to `cell_eval_step`. Adding a new oracle type means modifying
`cell_submit`. The procedures are monolithic.

In Unison, cell-zero is composed from smaller functions. The dispatcher is a
function from `CellBodyType -> Inputs -> {Semantic} Output`. Adding a new body
type means adding a case to the dispatcher function -- or, more elegantly,
providing a different dispatcher as a parameter. The oracle checker is a
separate function. The frontier scanner is a separate function. They compose.

### Testability

The Dolt design is tested by running stored procedures against a Dolt server
with test data. This is integration testing. You cannot unit-test
`cell_eval_step` without a running database.

In Unison, cell-zero is a pure function with abilities. You can test the
frontier scanner in isolation (it is pure). You can test the dispatcher with a
mock `Semantic` handler. You can test oracle checking with predetermined values.
You can test the full eval loop with a mock handler that returns scripted
responses. All without a database, an LLM, or a network connection.

### Distribution as a first-class concern

The v2 design handles multiple pistons through SQL-level locking (`SELECT ...
FOR UPDATE`). This works but is a concurrency mechanism bolted onto a sequential
eval loop. Scaling requires careful thought about lock contention, commit
strategies, and dead-piston recovery.

In Unison, distribution is a language-level concern. The `Remote` ability
expresses "run this computation somewhere else." The handler decides where.
Cell-zero can fork evaluations to remote workers without changing its logic.
The runtime handles failure detection, retry, and result collection.

---

## 7. What You Lose

### Dolt's relational query interface

The single most powerful property of the Dolt design is that cell state is
relational data in a SQL database. Any question about cell state can be
answered with a SQL query:

```sql
-- What is the current state of all cells in program X?
SELECT * FROM cell_program_status WHERE program_id = 'sort-proof';

-- What changed in the last 3 eval steps?
SELECT * FROM dolt_diff('HEAD~3', 'HEAD', 'yields');

-- How many cells are frozen vs. blocked vs. computing?
SELECT state, COUNT(*) FROM cells WHERE program_id = ? GROUP BY state;

-- What are the yields of cell Y at commit Z?
SELECT * FROM yields AS OF 'abc123' WHERE cell_id = 'sort';
```

In Unison, the cell graph is a value in memory (or in Cloud storage). Querying
it means writing Unison functions. There is no ad-hoc query interface. You
cannot fire up a SQL client and poke around. You must write code to answer
questions about state.

This is a significant loss for debugging, observability, and operator
experience. The Dolt design's strongest feature is that DBA tools ARE
debugging tools. `dolt sql` IS the debugger.

### Version history as commits

Dolt gives you free execution traces: each freeze is a commit, and `dolt log`
shows the history. `dolt diff` shows what changed. `AS OF` queries give you
time travel. The execution history is a first-class Git-like artifact.

Unison Cloud has durable storage but not Git-like version history on every
write. You would need to build execution tracing explicitly: log each eval
step to an append-only store, build a history query API, implement diff
functionality. This is all doable in Unison, but it is work that Dolt gives
you for free.

### The relational model for cell state

The Retort schema is normalized: cells, givens, yields, oracles each have their
own table with proper indices and foreign keys. Readiness is computed by a VIEW
with indexed JOINs. This is a well-understood, high-performance data model.

In Unison, the cell graph is likely a tree or map data structure. Readiness
computation is a traversal. Index-like performance requires careful data
structure choice (hash maps, balanced trees). This is standard functional
programming, but the relational model's query planner gives you performance
optimization that you must implement manually in Unison.

### SQL familiarity

SQL is the lingua franca of data. Operators, DBAs, analysts, and most
developers can read SQL. Unison is a niche functional language with a small
community. The operational burden of "understanding the Cell runtime" shifts
from "know SQL" to "know Unison."

### Dolt's diff/merge for execution comparison

The v2 design proposes using Dolt branches for parallel execution: fork a
program onto two branches, run with different strategies, `dolt diff` the
results. This is a powerful comparison mechanism that has no Unison analog.
Unison Cloud storage does not support branching and diffing.

---

## 8. A Hybrid Architecture

The analysis above suggests that neither pure-Dolt nor pure-Unison is optimal.
Dolt excels at storage, queryability, and version history. Unison excels at
expressing the eval loop, handling effects, and distributing computation.

A hybrid architecture might work:

### Unison for the eval loop, Dolt for state storage

Cell-zero is a Unison program. It reads cell state from Dolt (via SQL queries
through a `DoltStorage` ability handler). It writes results back to Dolt. The
eval loop logic lives in Unison. The state lives in Dolt.

The `Storage` ability handler for this configuration:

- `readGraph` issues `SELECT` queries against the Retort schema and constructs
  a `CellGraph` value.
- `freezeCell` issues `UPDATE` and `INSERT` statements to freeze yields and
  update cell state.
- `commitStep` calls `DOLT_COMMIT` to record the eval step.

Cell-zero does not know it is talking to Dolt. It uses the `Storage` ability.
The handler translates. A test handler uses in-memory state. A production
handler uses Dolt.

This preserves Dolt's queryability (SQL still works, `dolt diff` still works,
time travel still works) while gaining Unison's expressiveness for the eval
loop.

### Unison for soft cell dispatch, Dolt for everything else

A lighter integration: the eval loop stays in Dolt stored procedures, but soft
cell dispatch goes through a Unison service. The Unison service exposes a typed
endpoint:

```
evaluateSoftCell : Prompt -> {Semantic, Remote} Response
```

The stored procedure calls this endpoint instead of relying on an LLM piston
to call back. The Unison service handles model selection, caching, retry,
and distribution.

This keeps the Dolt design intact but replaces the fragile piston protocol
with a typed service call. The `Semantic` ability and its swappable handlers
become available without rewriting the eval loop.

### Unison Cloud as the runtime, Dolt as the audit log

Cell-zero runs as a Unison Cloud service. It uses Unison Cloud storage for
operational state (the cell graph, the frontier, in-flight evaluations). After
each eval step, it writes a summary to Dolt for queryability and version
history. Dolt becomes the audit log, not the runtime database.

Operators query Dolt to understand what happened. Cell-zero queries Unison Cloud
storage to know what to do next. The two are eventually consistent (the Dolt
write happens after the eval step completes).

---

## 9. The Crystallization Angle

### Abilities as the crystallization boundary

In Cell's model, crystallization converts soft cells to hard cells. The oracle
on the soft cell becomes a test for the hard cell. The LLM's judgment is
replaced by deterministic computation.

In Unison, crystallization has a natural expression through abilities. A soft
cell is dispatched through the `Semantic` ability. A crystallized (hard) cell
is a pure function -- it requires no abilities. Crystallization is the process
of replacing a `{Semantic} Output` computation with a `{} Output` computation
(pure, no effects).

The oracle that validates crystallization checks whether the pure function
produces the same output as the semantic evaluation did, for all known inputs.
This is a property-based test -- and Unison has built-in support for
property-based testing.

### Content addressing enables crystallization tracking

When a soft cell crystallizes, its hash changes (it went from a `Semantic`-
requiring computation to a pure computation). The old hash (soft) and new hash
(hard) are both permanent entries in the codebase. The crystallization event
is recorded as a relationship between two hashes: "definition #abc (soft) was
replaced by definition #def (hard), validated by oracle #ghi."

This is a permanent, content-addressed record of crystallization. You can
always look up the soft version by its hash. You can verify that the hard
version passes the oracle. The crystallization is auditable forever because
content addressing makes definitions immutable.

---

## 10. Assessment

### When the Unison path makes sense

- If the primary goal is to make cell-zero a real, runnable, testable program
  rather than a specification document.
- If the philosophical claim of metacircularity matters -- if "cell-zero IS the
  evaluator" is a design requirement, not an aspiration.
- If swappable execution strategies (different LLM providers, human-in-the-loop,
  mock testing) are important.
- If distribution (multiple workers evaluating cells in parallel) is a priority.
- If the team is willing to invest in a less-familiar language for the benefits
  of typed effects and content addressing.

### When the Dolt path makes sense

- If ad-hoc queryability of cell state is essential (and it is, for early
  debugging and operator experience).
- If version history / time travel / diffing of execution is a core feature.
- If SQL familiarity of operators and contributors matters.
- If the team wants to minimize the technology stack (Dolt is already in use
  for beads).
- If the pragmatic "just build it" priority outweighs the philosophical
  elegance of metacircularity.

### The honest answer

The Dolt design is the right choice for building Cell today. It is pragmatic,
uses existing infrastructure, and its limitations (SQL stored procedures are
not a great programming language) are manageable at the current scale.

The Unison design is the right choice for what Cell wants to become. If Cell is
to be a language whose evaluator is a program in the language, that program
should be written in something that treats code as data, effects as types, and
distribution as a first-class concern. Unison is that something.

The hybrid path -- Unison for the eval loop, Dolt for state storage -- offers
the possibility of getting both. Cell-zero as a Unison program gains
type safety, testability, and metacircularity. Dolt as the storage backend
retains queryability, version history, and operational familiarity.

Whether the hybrid path is worth the complexity of bridging two systems is an
engineering judgment that depends on where Cell's development goes after the
Rule of Five bootstrap.

# Hybrid Architecture: Unison + Dolt for Cell

## Premise

Cell is a reactive computation graph language where programs are DAGs of cells.
Soft cells are evaluated by LLMs, hard cells are deterministic computation,
oracles verify outputs, and yields flow between cells via dependencies. The
current design uses Dolt for everything: stored procedures as the runtime, SQL
views as hard cell implementations, SQL tables as state.

This document explores a hybrid where Dolt handles DATA (cell state, yields,
execution history, the relational model) while Unison handles CODE (hard cell
implementations, typed functions, content-addressed definitions).

The thesis: these two systems share a deep structural alignment around
content-addressed storage, but apply it to complementary domains -- data and
code respectively. Together they may produce something neither achieves alone.

---

## 1. Dolt for State, Unison for Computation

### The Division

Dolt owns the execution model: the `cells` table, `yields` table, `ready_cells`
view, `cell_eval_step()` procedure, `cell_reap_stale()` procedure, the
`pistons` registry, the `trace` table. Everything about what state the program
is in, what cells are ready, what yields have been produced, what is frozen vs.
tentative -- this lives in SQL.

Unison owns computation: the actual functions that hard cells execute. When
`cell_eval_step()` finds a hard cell (cell_type = 'hard'), instead of executing
a SQL view or stored procedure, it calls out to a Unison function identified by
its content hash.

### How Unison Functions Are Invoked

Unison provides several invocation paths, each with different trade-offs for
Cell integration:

**Path 1: Compiled executables via `run.compiled`**

Unison can compile programs into portable bytecode files (`.uc` suffix) via the
UCM `compile` command. These contain all Unison code and dependencies in a
single lightweight file. They are executed via `ucm run.compiled myProgram.uc`
from any terminal. This is the most straightforward bridge: `cell_eval_step()`
shells out to `ucm run.compiled <hash>.uc <args>`, reads stdout as the yield
value.

Advantages: Simple. No long-running process. Each hard cell invocation is
isolated.

Disadvantages: Process startup overhead per cell evaluation. Requires the UCM
binary on the system. Serialization of inputs/outputs through command-line
arguments and stdout.

**Path 2: Unison HTTP service**

Unison has mature HTTP server capabilities via the `@unison/httpserver` and
`@unison/routes` libraries. A Unison service can expose each hard cell function
as an HTTP endpoint. The Routes library provides `Route.route` for path
parameters, `ok.json` for response formatting, and the `<|>` operator for
combining routes. JSON serialization/deserialization is built in via the `Json`
library.

A persistent Unison HTTP service would:
- Listen on a local port
- Accept POST requests like `/eval/<function-hash>` with yield inputs as JSON
- Execute the Unison function
- Return the result as JSON

`cell_eval_step()` in Dolt would make an HTTP call to this service. This is the
most practical bridge.

Advantages: Amortized startup cost. Clean JSON interface. Unison's type system
validates inputs before execution. The service can cache compiled functions.

Disadvantages: Requires a long-running Unison process alongside Dolt. Network
serialization overhead (minimal for local calls).

**Path 3: UCM transcript scripting**

Unison's transcript system allows scripting complex UCM interactions in markdown
files. The `ucm transcript` command processes these in batch mode. This could be
used for one-off evaluations or testing, but is too heavy for per-cell-evaluation
use.

**Path 4: Direct FFI (future)**

Unison does not currently have a stable FFI. The team has held off FFI work
while the JIT compiler was in development. With the JIT now stable (announced as
part of the 1.0 release in November 2025, delivering approximately 60x speed
improvement over the interpreter), FFI work is planned. The design direction is:
foreign APIs exposed through top-level abilities, with an extensible binding
mechanism for defining new abilities and forwarding their operations to external
APIs. FFI will only be available during IO programs.

If FFI materializes, a Go program (Dolt is written in Go) could potentially call
Unison functions directly, or Unison could call Go functions. This would
eliminate the serialization boundary entirely but is not available today.

### Recommended Bridge: HTTP Service

The HTTP service path is the strongest option for Cell. It maps cleanly to the
existing architecture:

```
cell_eval_step() claims a ready hard cell
  -> reads yield inputs from Dolt (SQL SELECT)
  -> POST /eval/{unison_hash} with inputs as JSON body
  -> Unison service looks up function by hash in its codebase
  -> Unison executes function, returns result as JSON
  -> cell_eval_step() writes result to yields table (SQL UPDATE)
  -> cell frozen
```

The Unison service is stateless with respect to Cell -- it is a pure function
server. All state coordination happens in Dolt. This is a clean separation.

---

## 2. Content Addressing Alignment

### Two Content-Addressed Worlds

Dolt and Unison both use content-addressed storage, but for different things:

**Dolt's content addressing** operates on data. Dolt stores its dataset as a
Merkle tree of component blocks. Table data and schema are stored in Prolly Trees
(Probabilistic B-Trees, invented by the Noms team). The roots of those Prolly
Trees, along with metadata, are stored in a commit graph (Merkle DAG) providing
Git-style version control. A Dolt commit hash (e.g., `9shmcqu3q4o6ke8807pedlad2cfakvl7`)
identifies the complete state of all tables at that point. Subtrees with the
same root hash share storage via structural sharing -- changes only store the
diff.

**Unison's content addressing** operates on code. Every function and type
definition is stored as its abstract syntax tree, keyed by a 512-bit SHA3 hash
of the AST structure. The hash depends only on the structure of the code, not on
variable names, formatting, or file location. The Unison codebase is a SQLite
database mapping hashes to definitions. Names are just pointers to hashes -- a
single hash can have many names, and renaming a function does not change its
hash.

### How They Compose

A Cell program in the hybrid model has a composite identity:

```
program_identity = (dolt_commit_hash, unison_code_manifest)
```

The **dolt_commit_hash** pins the data state: which cells exist, their types,
their current states, all yield values, the full execution history. This is a
single hash that captures the entire relational state.

The **unison_code_manifest** is the set of Unison function hashes referenced by
hard cells. Each hard cell row in the `cells` table would have an
`executor_hash` column containing the Unison definition hash. The manifest is
the set of all such hashes across the program.

This decomposition is natural because it mirrors the dual-substrate nature of
Cell itself:

- **Data substrate**: The document-is-state principle means the program IS its
  data. Dolt captures this with a single content hash per version.
- **Code substrate**: Hard cell implementations are deterministic functions.
  Unison captures these with per-function content hashes.

### Reproducibility Guarantee

Given the same `(dolt_commit_hash, unison_code_manifest)` pair, you can
reproduce the exact program state and re-execute any hard cell with identical
results. Dolt provides data reproducibility (any commit can be checked out).
Unison provides code reproducibility (any function hash resolves to the same
implementation forever -- definitions are immutable and append-only).

This is stronger than either system alone:

- Pure Dolt: SQL views as hard cells are mutable. Changing a view changes
  behavior without changing the data commit hash. The code is not
  content-addressed.
- Pure Unison: Functions are immutable but there is no versioned relational
  state layer.

### The Cell-as-Document Hash

Cell's core principle is `hash(document) = hash(state)`. In the hybrid model:

```
hash(cell_document) = hash(dolt_commit, unison_manifest)
```

This could be computed as a simple hash of the pair, or more elegantly, the
`unison_manifest` could be stored as a row in Dolt itself (a `code_manifest`
table mapping cell_id to executor_hash), in which case the Dolt commit hash
alone captures both data and code references. The actual Unison function bodies
live outside Dolt, but their identity hashes are inside Dolt. This is analogous
to how Git stores tree objects that reference blob hashes -- the tree hash
transitively captures everything.

---

## 3. The Type Bridge

### The Boundary

Yields in Dolt are SQL values: TEXT, JSON, INTEGER, etc. The `yields` table
stores values as SQL types. When these values flow into a Unison function, they
enter a statically typed functional language with type inference, algebraic data
types, and an ability system.

The type bridge must handle:
- SQL TEXT -> Unison Text
- SQL JSON -> Unison structured types (records, algebraic types)
- SQL INTEGER -> Unison Nat or Int
- SQL BOOLEAN -> Unison Boolean
- SQL NULL -> Unison Optional

### Serialization Format: JSON as the Bridge

JSON is the natural wire format because:
1. Dolt supports JSON columns and the `JSON_EXTRACT` family of functions
2. Unison has built-in JSON serialization via the `Json` library
3. JSON is human-readable (important for debugging the Cell evaluation loop)

Unison's JSON handling uses a `Decoder` ability for deserialization. Basic types
decode via functions like `Decoder.text`, `Decoder.nat`. Structured types decode
via pattern matching on the JSON tree. Serialization uses `Json.text`,
`Json.object` for constructing output. The JSON library is mature enough that
Unison Cloud uses it for service-to-service communication.

### Schema Contract

Each hard cell function in Unison declares a type signature that constitutes a
schema contract:

```
-- Unison function type (conceptual)
myHardCell : {inputs: Map Text Json} -> Json
```

Or more typed:

```
-- Strongly typed variant
myHardCell : {x: Nat, y: Text} -> {result: Nat, confidence: Float}
```

The bridge layer would:

1. **On registration**: When a Unison function is registered as a hard cell
   executor, extract its type signature. Store the input/output schema alongside
   the executor_hash in the Dolt `cells` table (e.g., as a JSON schema in a
   `type_contract` column).

2. **On invocation**: Before calling the Unison function, validate that the
   yield inputs match the expected types. This can happen either in the Dolt
   stored procedure (SQL-level validation) or in the Unison service (type-level
   validation). Unison's static type system makes the latter essentially free --
   a type mismatch is a compile-time error within Unison, and a deserialization
   failure at the JSON boundary.

3. **On return**: The Unison function's return value is serialized to JSON and
   written back to the Dolt yields table.

### Gradual Typing Across the Boundary

An interesting property: soft cells (LLM-evaluated) produce untyped yields (free
text, JSON blobs). Hard cells (Unison functions) consume and produce typed
values. The type boundary is exactly the crystallization boundary. As cells
crystallize from soft to hard, their yields move from untyped to typed. The
Unison type system acts as a ratchet: once a cell is hard, its inputs and
outputs have guaranteed types.

---

## 4. The Crystallization Path in Hybrid

### The Current Crystallization Model

In Cell, crystallization is the process by which a soft cell (LLM-evaluated,
non-deterministic) becomes a hard cell (deterministic, reproducible). This
happens under oracle pressure: the oracle verifies that the LLM's output matches
a deterministic specification, and once proven, the cell can be replaced with a
deterministic implementation.

### Crystallization with Unison

The hybrid crystallization flow:

```
Step 1: Soft cell exists in Dolt
  cells row: {id: "c1", cell_type: "soft", state: "frozen", ...}
  The LLM has been producing correct yields for this cell.

Step 2: Oracle observes pattern
  Oracle checks accumulate in oracle_checks table.
  Pattern emerges: this cell's output is a deterministic function of its inputs.

Step 3: LLM writes Unison function
  The LLM piston, prompted with the cell's input/output history from Dolt,
  writes a Unison function that captures the deterministic logic.

  Example:
    myCell : Nat -> Nat -> Nat
    myCell x y = x + y * 2

Step 4: Function stored in Unison codebase
  The function is added to the Unison codebase via UCM.
  Unison assigns it a content hash: #af39dk28...
  The function is immutable from this point forward.

Step 5: Oracle verifies the Unison function
  Run the Unison function against the historical input/output pairs from Dolt.
  If all outputs match, the crystallization is valid.
  This verification is recorded in the oracle_checks table.

Step 6: Cell updated in Dolt
  UPDATE cells
  SET cell_type = 'hard',
      executor_hash = '#af39dk28...',
      executor_type = 'unison'
  WHERE id = 'c1';

Step 7: Future evaluations use Unison
  cell_eval_step() sees cell_type='hard', executor_type='unison'.
  Calls the Unison HTTP service with the hash.
  No LLM needed. Deterministic. Reproducible.
```

### How Clean Is This?

Very clean. Each system does what it is best at:

- **Dolt** records the fact of crystallization (the cell row changes type and
  gains an executor_hash), preserves the history (old soft evaluations are in
  the trace table), and continues to manage the state machine (ready, computing,
  frozen).
- **Unison** stores the crystallized code immutably by its content hash. The
  function never changes. The hash is a permanent reference.
- **The LLM** writes the Unison function during crystallization. This is a
  natural fit: LLMs are good at writing small, well-specified functions,
  especially when given concrete input/output examples from the execution
  history.

The crystallized cell is literally a Dolt row pointing to a Unison hash. The row
says "this cell is hard, and its computation is Unison function #af39dk28". The
pointer is a content hash, so it is unforgeable and permanent. This is as clean
as a Git tree entry pointing to a blob hash.

### Reversibility

If the oracle later discovers the crystallized function is wrong (new inputs
produce wrong outputs), the cell can be de-crystallized:

```sql
UPDATE cells
SET cell_type = 'soft',
    executor_hash = NULL,
    executor_type = NULL
WHERE id = 'c1';
```

The Unison function remains in the codebase (append-only, never deleted) but the
cell no longer references it. Dolt's version control preserves the entire history
of this transition. You can diff the commit where crystallization happened and
the commit where it was reversed.

---

## 5. Unison as MCP Server

### The Architecture

Model Context Protocol (MCP) is Anthropic's open standard for connecting LLMs
to external tools and data sources. An MCP server exposes tools that a model can
call during a conversation. In the Cell context:

```
LLM Piston (Claude)
  |
  |-- MCP connection
  |
  v
Unison MCP Server
  |-- Tool: eval_hard_cell(hash, inputs) -> result
  |-- Tool: lookup_function(hash) -> type signature
  |-- Tool: list_available_functions() -> [hash, name, type]
  |-- Tool: crystallize(cell_id, function_code) -> hash
  |
  |-- Internal: calls Dolt for state queries
  |
  v
Dolt (state layer)
  |-- ready_cells view
  |-- yields table
  |-- trace table
```

### An Existing Starting Point

A `unison-mcp-server` project already exists that enables AI assistants to
operate the Unison Codebase Manager (UCM). This demonstrates that the MCP-Unison
integration pattern is viable. For Cell, the MCP server would be more
specialized -- exposing Cell-specific tools rather than general UCM operations.

### What the MCP Tools Would Do

**`eval_hard_cell(executor_hash, inputs_json)`**: The core tool. Given a Unison
function hash and JSON inputs, execute the function and return the result. The
LLM piston calls this when `cell_eval_step()` encounters a hard cell. The tool
handles the JSON-to-Unison-type bridge internally.

**`query_state(sql)`**: Proxy SQL queries to Dolt. The LLM piston uses this to
read the `ready_cells` view, check yield values, examine dependencies. This
keeps the piston's interface uniform -- everything goes through MCP.

**`crystallize(cell_id, unison_code)`**: The LLM writes a Unison function,
submits it through this tool. The tool adds the function to the Unison codebase,
gets its hash, runs oracle verification against historical data in Dolt, and if
verification passes, updates the cell row in Dolt.

**`inspect_function(hash)`**: Returns the type signature, documentation, and
dependency graph of a Unison function. Useful when the LLM piston is deciding
whether to reuse an existing crystallized function for a new cell.

### The Three-Layer Stack

This produces a clear three-layer architecture:

| Layer | System | Role |
|-------|--------|------|
| Interface | MCP | LLM pistons connect here. Uniform tool API. |
| Compute | Unison | Executes hard cell functions. Type-safe. Content-addressed. |
| Data | Dolt | Stores all state. Version-controlled. SQL-queryable. |

The LLM piston never talks to Dolt or Unison directly. It talks to MCP tools.
The MCP server orchestrates between Unison (for computation) and Dolt (for
state). This is a clean inversion of control: the piston declares what it wants
(evaluate this cell, query this state), and the MCP server handles the how.

---

## 6. What Each System Contributes

### Dolt Contributions

| Capability | How Cell Uses It |
|------------|-----------------|
| **SQL queries** | `ready_cells` view identifies evaluable cells. Yield lookups via SELECT. Dependency resolution via JOINs. |
| **Version control** | Every eval step is a committable state change. Diff between commits shows exactly what a piston did. Branch for speculative evaluation. Merge to reconcile parallel pistons. |
| **Relational model** | cells, yields, givens, oracles, oracle_checks, trace, pistons -- all normalized tables with foreign keys and indexes. Complex queries are natural. |
| **Stored procedures** | `cell_eval_step()`, `cell_reap_stale()`, `piston_register()`, `piston_heartbeat()` -- the state machine logic lives in SQL. |
| **Execution history** | The trace table records every event. Combined with Dolt's commit graph, you get a complete audit trail of program evolution. |
| **Structural sharing** | Multiple versions of a Cell program share storage for unchanged cells. Efficient for programs that evolve incrementally. |

### Unison Contributions

| Capability | How Cell Uses It |
|------------|-----------------|
| **Typed functions** | Hard cell implementations are statically typed. Type errors are caught before execution, not at runtime. The type system serves as documentation and verification. |
| **Content-addressed code** | Functions identified by 512-bit SHA3 hash of their AST. A cell's executor_hash is a permanent, unforgeable reference to exact computation. No "works on my machine" problems. |
| **Algebraic effects (abilities)** | Cell-specific abilities could model the yield/dependency system. A `CellEval` ability could abstract over state access, making hard cell functions testable in isolation with mock handlers. |
| **Immutable definitions** | Once a function is in the Unison codebase, its hash-to-definition mapping never changes. Crystallized cells have permanent computation references. |
| **The codebase as code database** | Unison's codebase is a SQLite database with indices for type-based search, dependency tracking, and compilation caching. You can ask "what functions take Nat -> Nat -> Nat?" or "what depends on function #abc123?". |
| **Unison Cloud / distributed execution** | If Cell programs grow large, hard cell evaluation could be distributed across Unison Cloud nodes. The content-addressed functions can be moved to remote nodes with dependencies deployed on the fly via `forkAt`. |
| **JIT compiler** | The Unison 1.0 JIT provides approximately 60x speedup over the interpreter. Hard cell functions benefit from native-speed execution without leaving the content-addressed model. |

### What Neither Provides Alone

| Need | Dolt Alone | Unison Alone | Hybrid |
|------|-----------|--------------|--------|
| Versioned state + typed code | State versioned, code (SQL views) not content-addressed | Code content-addressed, no relational state | Both |
| Reproducible evaluation | SQL views can change silently | No persistent state layer | dolt_commit + unison_hash = full reproducibility |
| Crystallization with verification | Can store the fact, but hard cells as SQL views are untyped | Can verify types, but nowhere to record the crystallization history | Dolt records the history, Unison guarantees the types |
| LLM integration | SQL is awkward for LLM output parsing | Unison alone does not model the soft->hard spectrum | Dolt for the soft cell state machine, Unison for the hard cell target |

---

## 7. Migration Path

### Phase 0: Pure Dolt (Current State)

Everything lives in Dolt. The cells table, yields table, stored procedures,
views. Hard cells are SQL views or stored procedures. This is the PoC.

```
cells.executor_type = 'sql_view'
cells.executor_ref = 'hard_cell_add_numbers'
```

The system works but hard cells are limited to what SQL can express, and
computation is not content-addressed.

### Phase 1: Add Unison as Optional Executor

Introduce `executor_type = 'unison'` alongside the existing `'sql_view'` type.
Modify `cell_eval_step()` to check executor_type:

```sql
-- In cell_eval_step():
IF v_executor_type = 'sql_view' THEN
  -- existing SQL evaluation path
ELSEIF v_executor_type = 'unison' THEN
  -- call Unison HTTP service
  -- (initially via a helper script or UDF that makes HTTP calls)
END IF;
```

Stand up a Unison HTTP service alongside Dolt. Start with a few hand-written
Unison functions as proof of concept. The majority of hard cells remain SQL
views.

Schema addition:
```sql
ALTER TABLE cells
  ADD COLUMN executor_type ENUM('sql_view', 'unison', 'soft') DEFAULT 'soft',
  ADD COLUMN executor_hash VARCHAR(128) DEFAULT NULL
    COMMENT 'Unison function hash when executor_type=unison';
```

### Phase 2: Crystallization Pipeline

Build the crystallization flow: LLM writes Unison function, oracle verifies,
cell updated. This requires:

1. A way for the LLM to submit Unison code (MCP tool or direct API)
2. The Unison service to accept and compile new functions
3. Oracle verification against historical data
4. Automated cell update on successful crystallization

At this phase, new hard cells are created as Unison functions rather than SQL
views. Old SQL views continue to work.

### Phase 3: MCP Integration

Replace direct Dolt SQL calls from LLM pistons with MCP tools. The MCP server
wraps both Dolt queries and Unison function calls. The LLM piston's interface
simplifies to a set of MCP tools.

### Phase 4: Unison Abilities for Cell Semantics

Define Cell-specific Unison abilities:

```
-- Conceptual Unison ability
ability CellEval where
  readYield : CellId -> YieldName -> Json
  writeYield : CellId -> YieldName -> Json -> ()
  queryDependencies : CellId -> [CellId]
  log : Text -> ()
```

Hard cell functions use these abilities instead of raw I/O. This makes them
testable: provide a mock `CellEval` handler for unit testing, a real handler
that talks to Dolt for production. The ability system ensures hard cell
functions cannot perform arbitrary side effects.

### Phase 5: Distributed Execution (Future)

If Cell programs grow to thousands of cells, Unison Cloud's distributed
execution could parallelize hard cell evaluation across nodes. Since functions
are content-addressed, they can be deployed on the fly to remote nodes. Dolt
remains the central state coordinator.

### Throughout All Phases

Dolt stays as the state layer. The cells table, yields table, trace table, stored
procedures, ready_cells view -- none of this changes. The migration is purely
additive: new executor types, new columns, new integration points. Nothing is
removed or replaced in Dolt.

---

## 8. Risks and Open Questions

### Technical Risks

**Unison maturity**: Unison reached 1.0 in November 2025. The ecosystem is
young. Libraries may be limited. The community is small compared to mainstream
languages. However, the core language and tooling are stable, and the
content-addressed model is exactly what Cell needs.

**FFI gap**: Without FFI, the Dolt-Unison bridge must go through HTTP or
subprocess calls. This adds latency and serialization overhead. For Cell's
use case (LLM-speed evaluation), this overhead is negligible -- LLM calls
take seconds, HTTP calls take milliseconds. But for programs with thousands
of fine-grained hard cells, it could matter.

**Operational complexity**: Running two systems (Dolt + Unison service) is
more complex than running one. However, the Unison service is stateless (the
codebase is append-only and can be treated as a read-mostly store), so
operational burden is modest.

### Design Questions

**Where does the eval loop live?** Currently `cell_eval_step()` is a Dolt
stored procedure. Should the orchestration move to the Unison service? Or to
the MCP server? The simplest answer: keep it in Dolt. The eval loop is state
manipulation (claim cell, read inputs, write outputs, update state). That is
Dolt's job. Only the computation step -- the actual function execution --
moves to Unison.

**How are Unison functions registered?** The LLM writes Unison code, but who
compiles it and adds it to the codebase? Options: (a) the MCP server wraps
UCM commands, (b) a separate registration service accepts code and returns
hashes, (c) the Unison service watches a directory for new `.u` files. Option
(b) is cleanest.

**What about soft cell state in Unison?** Should the Unison service know
about soft cells at all? Probably not. Soft cells are the LLM's domain. The
Unison service only handles hard cell execution. Clean separation.

**Version correspondence**: When you branch in Dolt, should the Unison
codebase also branch? Since Unison definitions are immutable (a hash always
points to the same function), branching is unnecessary for code. Different
Dolt branches can reference different Unison hashes, and that is sufficient.
The Unison codebase is a flat, append-only store shared across all branches.

---

## 9. Alignment with Cell's Philosophy

### Document-Is-State

Cell's core principle is that the program document IS the execution state.
In the hybrid model, the "document" is the Dolt database state. Every cell,
yield, dependency, and execution trace is a row in a table. The Dolt commit
hash captures the entire document state in a single content hash.

### Dual-Substrate Fusion

Cell is a dual-substrate language: soft cells (LLM, non-deterministic) and
hard cells (deterministic, reproducible). The hybrid architecture makes this
literal at the infrastructure level: LLM pistons interact with Dolt (the
data substrate), and hard cell functions live in Unison (the code substrate).
The crystallization boundary between soft and hard is the boundary between
Dolt-managed and Unison-managed computation.

### Progressive Crystallization

The migration path (Phase 0 through Phase 5) mirrors the crystallization
model within Cell itself. The system starts soft (pure Dolt, SQL views as
hard cells -- flexible but untyped). Over time, it crystallizes (hard cells
migrate to Unison -- typed, immutable, content-addressed). The infrastructure
evolves the same way the programs do.

### Content Address Everything

The deepest alignment: Cell wants `hash(document) = hash(state)`. Dolt
content-addresses data. Unison content-addresses code. Together, they
content-address everything. A Cell program's complete identity -- its data
state, its code, its execution history -- is captured by a pair of content
hashes. This is not an approximation or a convention. It is structural.

---

## Sources

- [Unison Language - At a Glance](https://www.unison-lang.org/docs/at-a-glance/)
- [Unison FFI Discussions - GitHub Issue #1404](https://github.com/unisonweb/unison/issues/1404)
- [Unison - Running Programs](https://www.unison-lang.org/docs/usage-topics/running-programs/)
- [Unison - run.compiled](https://www.unison-lang.org/docs/ucm-commands/run/compiled/)
- [Unison - General FAQs](https://www.unison-lang.org/docs/usage-topics/general-faqs/)
- [Unison - The Big Idea](https://www.unison-lang.org/docs/the-big-idea/)
- [Unison - UCM Command Reference](https://www.unison-lang.org/docs/ucm-commands/)
- [Unison - Abilities (Algebraic Effects)](https://www.unison-lang.org/docs/fundamentals/abilities/)
- [Unison - Abilities and Ability Handlers](https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/)
- [Unison - Transcripts](https://www.unison-lang.org/docs/tooling/transcripts/)
- [Unison - Unison Share](https://www.unison-lang.org/docs/tooling/unison-share/)
- [Unison - Where Unison is Headed](https://www.unison-lang.org/blog/where-unison-is-headed/)
- [Unison 1.0 Announcement](https://www.unison-lang.org/unison-1-0/)
- [Unison JIT Compiler Announcement](https://www.unison-lang.org/blog/jit-announce/)
- [Unison HTTP Service Tutorial](https://www.unison.cloud/docs/tutorials/http-service-tutorial/)
- [Unison Routes Library](https://share.unison-lang.org/@unison/routes)
- [Unison HTTP Server Library](https://share.unison-lang.org/@unison/httpserver)
- [Unison Cloud - JSON Serialization](https://www.unison.cloud/learn/microblogging/part-2/)
- [Unison MCP Server](https://lobehub.com/mcp/yourusername-unison-mcp-server)
- [Trying Out Unison: Code as Hashes](https://softwaremill.com/trying-out-unison-part-1-code-as-hashes/)
- [Trying Out Unison: Effects Through Abilities](https://softwaremill.com/trying-out-unison-part-3-effects-through-abilities/)
- [Trying Out Unison: From Edge to Cloud](https://softwaremill.com/trying-out-unison-part-4-from-the-edge-to-the-cloud/)
- [Unison in Production](https://www.unison-lang.org/blog/experience-report-unison-in-production/)
- [Visualizing Remote Computations in Unison](https://www.unison-lang.org/blog/visualizing-remote/)
- [Dolt Architecture Overview](https://docs.dolthub.com/architecture/architecture)
- [Dolt Storage Engine](https://docs.dolthub.com/architecture/storage-engine)
- [Dolt Block Store](https://docs.dolthub.com/architecture/storage-engine/block-store)
- [Dolt Commit Graph](https://docs.dolthub.com/architecture/storage-engine/commit-graph)
- [Dolt Storage Engine Blog Post](https://www.dolthub.com/blog/2024-02-29-storage-engine/)
- [Dolt Commit Graph and Structural Sharing](https://www.dolthub.com/blog/2020-05-13-dolt-commit-graph-and-structural-sharing/)
- [Dolt Structural Sharing Deep Dive](https://www.dolthub.com/blog/2024-04-12-study-in-structural-sharing/)
- [Dolt Stored Procedures](https://docs.dolthub.com/concepts/dolt/sql/procedures)
- [Go-MySQL-Server](https://docs.dolthub.com/architecture/sql/go-mysql-server)
- [Dolt Stored Procedures Introduction](https://www.dolthub.com/blog/2021-03-10-introducing-stored-procedures/)
- [Programming in Unison - LWN.net](https://lwn.net/Articles/978955/)
- [Unison Abilities - Unofficial Tutorial](https://gist.github.com/atacratic/7a91901d5535391910a2d34a2636a93c)
- [What's Cool About Unison](https://jaredforsyth.com/posts/whats-cool-about-unison/)

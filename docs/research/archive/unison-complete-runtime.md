# Unison as Complete Runtime Substrate for Cell

Research exploration: could Unison replace Dolt as the runtime foundation for Cell?

Date: 2026-03-14

---

## Executive Summary

Unison is a content-addressed functional programming language where every definition is identified by the SHA3-512 hash of its syntax tree. Its codebase is a typed database of immutable definitions. Unison Cloud provides typed durable storage and transparent distributed computation. These properties create a genuinely deep alignment with Cell's architecture -- deeper than "just use it as a database." But the alignment comes with significant practical costs that make a full replacement of Dolt premature today. A hybrid architecture may be the most productive path.

---

## 1. Unison's Codebase as Cell State Store

### How the codebase works

The Unison codebase is backed by SQLite (the `codebase2/codebase-sqlite` module in the repository). It stores parsed, typechecked ASTs -- not source text. Every definition receives a 512-bit SHA3 hash computed over its syntax tree, with all named arguments converted to positional references and all dependencies replaced by their hashes. Names are separately stored metadata that point to hashes; they can be reassigned without changing any definition.

This means the codebase is already a content-addressed database of typed, immutable definitions with:
- Perfect knowledge of all dependencies (what depends on what)
- A persistent compilation cache that never invalidates
- Type-based search indices
- Hyperlinked browsable code (via Unison Share)

### Could Cell programs be Unison definitions?

In principle, yes. A Cell DAG could be represented as Unison types and terms:

- Each cell becomes a Unison term (or type) identified by its content hash
- Dependencies between cells become Unison's native dependency tracking
- Yields become typed values stored at specific hashes
- The `dependencies` and `dependents` UCM commands already give you the DAG traversal for free

The codebase already tracks exactly the kind of relationships Cell needs: "this definition depends on these other definitions." The type system guarantees that dependencies are well-typed. The immutability guarantee means a cell's definition, once crystallized, is permanent.

### Programmatic access

The codebase can be queried through several interfaces:

- **UCM commands**: `view` (show source by name or hash), `dependencies` (list what a definition depends on), `dependents` (list what uses a definition), `find` (search by name or type signature), `display`, `ls`
- **UCM API**: The `api` UCM command exposes a codebase server (configurable via `UCM_PORT`, `UCM_HOST`, `UCM_TOKEN` environment variables), providing HTTP access to the codebase
- **MCP (Model Context Protocol)**: Unison recently added MCP integration exposing tools to AI agents: `view-definitions`, `search-definitions-by-name`, `search-by-type`, `list-definition-dependencies`, `list-definition-dependents`, `typecheck-code`, `list-project-definitions`, and more. This is directly relevant -- an LLM evaluating a soft cell could use MCP to inspect the codebase

The MCP integration is particularly significant. It means an LLM already has a protocol for inspecting Unison code, searching by type, checking dependencies, and validating new code. This is exactly the kind of access a soft cell evaluator needs.

### Assessment

**Strong fit.** The codebase-as-database model is more semantically rich than SQL rows. You get typed, immutable, content-addressed definitions with automatic dependency tracking, type-based search, and LLM-accessible MCP integration. The main limitation is that this is a code database, not a general-purpose data store -- you cannot run arbitrary SQL queries against it.

---

## 2. Unison Cloud Storage as Yield Storage

### Available storage primitives

Unison Cloud provides typed durable storage with these primitives:

- **Cell**: Stores a single typed value in a database with transactional access. This is the exact semantic match for a Cell yield -- a named, typed, durable value
- **Table**: General-purpose structured storage with typed, transactional access (keyed by type, valued by type)
- **OrderedTable**: Ordered variant of Table (referenced in documentation but less detailed)
- **Blob**: Binary large object storage
- **Storage.Batch**: Bulk database read API (added in Cloud 20.1.0) using a fork-await pattern for heterogeneous typed batch reads across multiple tables in a single round-trip

The Cloud documentation states: "Any value may be saved in our transactional storage layer. Your access to storage is statically typed and checked by Unison's typechecker."

### The Cell-to-Cell mapping

Unison Cloud's `Cell` type stores "a single typed value in a database with transactional access." A Cell language yield is "a single typed value produced by a cell." These are the same abstraction. A Unison Cloud Cell *is* a Cell yield.

This means:
- Each cell's yield is a Unison Cloud Cell with the appropriate type
- Reading a dependency's yield is reading a Unison Cloud Cell
- The type system statically verifies that yields are consumed with the correct type
- Transactions ensure consistent reads across multiple yields

### Transaction semantics

Unison Cloud's transactional storage requires DynamoDB as a backend (in BYOC deployments), providing transactional guarantees. The `Storage.Batch` API enables reading multiple values across multiple tables in a single round trip, which maps to reading multiple cell yields atomically.

### Assessment

**Very strong fit.** The naming coincidence (Unison Cloud Cell / Cell language cell) reflects a genuine conceptual alignment. Typed, durable, transactional single-value storage is exactly what yields need. The main concern is that this ties yields to the Unison Cloud platform rather than a self-hosted database.

---

## 3. Hard Cells as Unison Functions

### The crystallization mapping

A crystallized hard cell is a deterministic function: given inputs, produce outputs. In Unison, this becomes a pure function identified by its content hash. The mapping is:

- A hard cell `f` with inputs `(a, b)` and yield type `c` becomes: `f : a -> b -> c`
- Its identity is its hash, e.g., `#a8s6df921a`
- It is immutable -- the same hash always produces the same function
- It is pure -- no abilities required (type `a -> b ->{} c`)
- It is typed -- the typechecker guarantees the yield type is correct

This is exactly the "programs are data" property Cell requires. A Unison function identified by hash is both code (you can run it) and data (you can inspect its AST, query its dependencies, find it by type signature).

### Referencing by hash

Unison supports literal hash references in code:
- Term references: `#a0v829` (short hashes that are minimally disambiguating)
- Built-in references: `##Nat`
- Cyclic references: `#x.n` (for mutually recursive definitions)
- Constructor references: `#x#c`

Short hashes can be used anywhere a name would be used. The system resolves them to full 512-bit hashes during compilation. This means you can literally write Cell programs that reference other cells by hash.

### The quotation operator mapping

Cell's quotation operator `section` quotes a cell as data. In Unison, every definition is already "quoted" -- it is stored as an AST, inspectable, and addressable by hash. The codebase *is* the quotation. You do not need a special operator because Unison's default storage format is the quoted form.

### FFI: calling Unison functions from external systems

Unison recently (November 2025) gained dynamic FFI support for calling native C libraries from Unison, via `libffi`:
- `openDLL : Text ->{IO, Exception} DLL` loads a shared library
- `getDLLSym : DLL -> Text -> Spec a ->{IO, Exception} a` imports a function by name
- Supported types: `int64`, `uint64`, `double`, `void` (with more being added)

However, this is FFI *from* Unison *to* C, not the reverse. There is no documented mechanism for calling a Unison function from Go, Python, or Rust by its hash. The intended interop path is:
1. Expose Unison logic as an HTTP service (Unison Cloud service)
2. Call that service from any language via HTTP
3. Or use the UCM codebase server API

This is a significant limitation for a system where Go orchestration code needs to invoke hard cells. You would need to go through HTTP, not direct function calls.

### The JIT compiler

Unison's JIT compiles to Chez Scheme (not LLVM/native code). Early benchmarks show ~470x speedup over the Haskell interpreter for numeric workloads. The JIT uses delimited continuations to implement algebraic effects efficiently. Compiled programs can be packaged as `.uc` files and run in Docker containers.

### Assessment

**Strong conceptual fit, moderate practical fit.** The content-addressed pure function model is ideal for hard cells. The lack of easy invocation from external languages is the main obstacle. You would need to route all hard cell evaluation through Unison's own runtime (HTTP service or UCM API) rather than calling functions directly from Go.

---

## 4. Unison's Ability System for Soft Cells

### How abilities work

Unison's abilities are algebraic effects -- a type-level mechanism for tracking and handling computational effects. The syntax:

```
structural ability Store a where
  get : {Store a} a
  put : a ->{Store a} ()
```

Functions that use abilities declare them in their type signature:

```
myFunction : Text ->{IO, Exception} Nat
```

Handlers implement the ability by pattern-matching on requests and providing a continuation:

```
storeHandler : v -> Request (Store v) a -> a
storeHandler storedValue = cases
  {Store.get -> k} ->
    handle k storedValue with storeHandler storedValue
  {Store.put v -> k} ->
    handle k () with storeHandler v
  {a} -> a
```

The typechecker enforces that all abilities used by a function are either handled or propagated in the type signature. Pure functions have type `A ->{} B` (empty ability set).

### Modeling the soft/hard boundary

This is where things get genuinely exciting. The soft/hard distinction in Cell could be a type-level distinction in Unison:

```
-- The Oracle ability: semantic evaluation by LLM
structural ability Oracle where
  evaluate : CellSpec -> {Oracle} Yield
  verify : Yield -> {Oracle} Bool

-- The Soft ability: marks a cell as requiring LLM evaluation
structural ability Soft where
  infer : Context -> {Soft} Yield

-- A hard cell is a pure function
hardCell : Input ->{} Output

-- A soft cell requires the Oracle ability
softCell : Input ->{Oracle} Output

-- Crystallization = providing a handler that eliminates Oracle
crystallize : (Input ->{Oracle} Output) -> (Input ->{} Output)
```

This makes the soft/hard boundary visible in the type system. A soft cell *cannot* be used where a hard cell is expected without going through crystallization (providing a handler that eliminates the `Oracle` ability). The typechecker enforces this.

### Multiple abilities compose naturally

A cell that needs both LLM evaluation and database access would have type:

```
complexCell : Input ->{Oracle, Store State} Output
```

As it crystallizes, abilities are peeled off one at a time. First you might provide a concrete `Store` handler (hardening the state management), then eventually provide an `Oracle` handler (hardening the semantic computation). Each step is a type-level transformation.

### Handler-based evaluation strategy

Different handlers for `Oracle` could implement different evaluation strategies:
- `llmHandler`: sends the cell spec to an LLM API
- `cachedHandler`: checks a cache first, falls back to LLM
- `testHandler`: returns deterministic test values
- `crystalHandler`: uses previously crystallized pure code

This is exactly the evaluator architecture Cell needs, expressed as a language feature rather than external infrastructure.

### Assessment

**Exceptional fit.** This is arguably the strongest alignment point. The ability system gives you the soft/hard boundary as a type-level distinction, crystallization as ability elimination, composable evaluation strategies as handlers, and compile-time enforcement that soft cells cannot masquerade as hard cells. No other approach considered for Cell provides this level of type-theoretic precision.

---

## 5. Distributed Computing for Multi-Piston Evaluation

### Unison Cloud's distribution model

Unison Cloud distributes computation through the `Remote` ability:

```
fork : Location g -> '{g, Remote} t ->{Remote} Task t
```

This sends a delayed computation to a remote location, returning a `Task` handle. The `await` function blocks until the remote computation completes. The key insight: because code is content-addressed, "arbitrary computations can just be moved from one location to another, with missing dependencies deployed on the fly."

The protocol:
1. Sender ships the bytecode tree to the recipient
2. Recipient inspects for any hashes it is missing
3. Missing dependencies are requested and cached
4. Execution proceeds

### Mapping to multi-piston evaluation

In Cell's multi-piston model, multiple evaluators (pistons) work on different cells concurrently. In Unison Cloud:

- Each piston becomes a remote computation via `fork`
- The Cell DAG determines which computations can run in parallel
- Dependencies between cells become `await` calls on upstream `Task` handles
- The content-addressed model ensures pistons can relocate dynamically

Unison Cloud's "Adaptive Service Graph Compression" could dynamically co-locate cells that frequently communicate, reducing latency. The typed RPC model eliminates serialization boilerplate between pistons.

### The Volturno precedent

Unison Cloud's Volturno streaming engine demonstrates the viability of this approach for real-world distributed systems:
- Exactly-once state-message consistency
- Stateful stream processing via `KOps` ability
- Scaling across multiple nodes without external coordination (no Zookeeper)
- Fault tolerance through view changes (new worker sets take over on failure)

### Comparison to the current model

Currently, multi-piston evaluation means multiple Claude Code sessions hitting a Dolt database. With Unison Cloud:
- No shared mutable database -- cells communicate through typed yields
- No serialization code -- Unison handles marshaling transparently
- No external coordination -- the runtime manages distribution
- Stronger guarantees -- exactly-once semantics, typed communication

### Assessment

**Strong fit with caveats.** The distribution model is elegant and eliminates much infrastructure complexity. The caveats: (1) you are coupled to the Unison Cloud platform, (2) soft cell evaluation still requires calling out to LLM APIs, which introduces latency and side effects that the pure model does not capture, and (3) the Unison Cloud free tier limits (5 services, 50MB storage, 5000 requests/month) are restrictive for serious evaluation workloads.

---

## 6. What You Lose vs. Dolt

### SQL queries

Dolt gives you full MySQL-compatible SQL. You can `SELECT * FROM cells WHERE status = 'pending'`, join across tables, aggregate yields, filter by metadata. Unison's codebase supports search by name and search by type signature, but not arbitrary relational queries. You lose the ability to ask ad-hoc questions about your cell population using SQL.

**Severity: High.** Debugging, monitoring, and operational introspection of Cell programs rely heavily on being able to query state relationally. "Show me all soft cells that have been evaluated more than 3 times" is trivial in SQL, non-trivial in Unison.

### dolt diff

Dolt's `dolt diff` shows you exactly what changed between two versions of a table -- row-level diffs. This is essential for understanding what a cell evaluation changed. Unison's codebase tracks changes at the definition level (you can see what was added/updated), but the diff granularity is different. You do not get "this row changed from X to Y."

**Severity: Medium.** Content-addressed definitions are individually immutable (a change creates a new hash), so the diff model is "new hash appeared, old hash still exists" rather than "this value mutated."

### Branching and merging

Dolt's Git-like branching lets you create speculative branches, evaluate cells differently, and merge results. This maps directly to Cell's need for speculative execution and alternative evaluation paths. Unison projects have branches, but they are for code organization, not data branching. You cannot "branch the yields" in the same way.

**Severity: High.** Speculative evaluation is a core Cell capability. Dolt branches provide this at the data level. Unison would require building a branching mechanism on top of its storage primitives.

### The relational model

Dolt's relational model (tables, rows, columns, joins, foreign keys) provides a natural way to represent the Cell schema: cells table, yields table, dependencies table, evaluations table. Unison replaces this with a typed functional model. You lose the ability to normalize data across tables and the decades of tooling built for relational databases.

**Severity: Medium.** The functional model is arguably more natural for Cell (cells are functions, not rows), but you lose the operational tooling ecosystem.

### Stored procedures

The current Retort architecture uses Dolt stored procedures to implement cell evaluation logic inside the database. Unison has no equivalent -- logic lives in Unison code, not in the storage layer. This is arguably better (code should not live in the database), but it changes the architecture.

**Severity: Low.** Stored procedures are a pragmatic choice, not an essential one. Unison's approach (logic as typed functions) is arguably cleaner.

### The existing Retort schema

Any migration means rewriting the Retort schema and all code that interacts with it. The current implementation has working SQL tables, stored procedures, and Go code that talks to Dolt. Moving to Unison means rebuilding this in a new language.

**Severity: High** (in terms of effort), **Low** (in terms of design quality). The work is significant, but the resulting system would likely be better.

---

## 7. Practical Concerns

### Ecosystem maturity

Unison has:
- ~6,600 GitHub stars, 122 contributors, ~20,000 commits
- 97 releases (latest: February 2026)
- Active development with frequent releases
- Discord community (size not publicly documented)
- Unison Share for library discovery

The ecosystem is small but active. The standard library (`@unison/base`) is reasonably complete. Third-party libraries are sparse. You will likely need to write libraries for any domain-specific functionality.

**Assessment: Early-stage but viable.** You will be an early adopter, with the benefits and risks that entails.

### Can LLMs write Unison?

This is a critical question for Cell, where soft cells are evaluated by LLMs that may need to produce Unison code during crystallization.

Factors working against LLM fluency:
- Unison's syntax is unusual (abilities, handlers, `cases`, `handle...with`, structural vs. unique types)
- Training data is extremely limited compared to Python, JavaScript, Go, or even Haskell
- The content-addressed model means code organization differs from any mainstream language
- Library documentation is sparse, limiting an LLM's ability to use the ecosystem

Factors working for LLM fluency:
- Unison's MCP integration means LLMs can inspect the codebase, search by type, and typecheck generated code
- The typechecker catches errors immediately, enabling iterative correction
- Unison's syntax is regular and consistent once learned
- The `typecheck-code` MCP tool lets an LLM validate its output before committing

**Assessment: Significant risk.** Current LLMs (including frontier models) have limited Unison training data. They can likely handle simple functions but will struggle with complex ability declarations, handlers, and the codebase interaction model. The MCP integration partially compensates by giving LLMs tools to validate and explore, but fluency is not guaranteed. This is the single largest practical risk of the Unison approach.

### Deployment complexity

Unison can be deployed via:
- Docker containers with the `unisonlang/unison` image
- Compiled `.uc` files in minimal containers
- Unison Cloud (managed or BYOC)

BYOC requires:
- A pool of machines
- S3-compatible storage (mandatory)
- DynamoDB table (optional, for transactional storage)
- Setup via `tofu init && tofu apply` (~20 minutes)

**Assessment: Moderate complexity.** Simpler than Kubernetes, more complex than a single Dolt server. The BYOC model is well-designed but adds infrastructure requirements.

### Unison Cloud pricing and availability

Free tier:
- Unlimited private projects
- Up to 5 services (deactivated every 3 weeks)
- 50MB storage
- 5,000 service requests/month

BYOC free tier:
- Personal usage up to 10-node clusters (160 cores)
- Free for open source, nonprofits, education

Commercial pricing is not publicly documented in detail ("fits on a notecard" per their blog, but the notecard is not published).

**Assessment: Viable for development, unclear for production scale.** The free tiers are generous for prototyping. Production costs are opaque. BYOC provides a self-hosted escape hatch.

### Community size

The community is small. Discord is the primary hub. The project is backed by Unison Computing, PBC (a public benefit corporation). The bus factor is real -- this is a VC-backed language company, not a community-driven open-source project. If Unison Computing fails, the ecosystem's future is uncertain.

**Assessment: Real risk.** Betting Cell's entire runtime on a small-company language is a strategic gamble.

---

## 8. Synthesis: Three Possible Architectures

### Option A: Full Unison (replace Dolt entirely)

Cell programs are Unison definitions. Yields are Unison Cloud Cells. Hard cells are pure Unison functions. Soft cells use the Oracle ability. Distribution uses Cloud.run. The Dolt database is eliminated.

**Gains:** Type-level soft/hard distinction, content-addressed everything, native distribution, no impedance mismatch between code and data.

**Losses:** SQL queries, dolt diff, data branching, relational model, LLM fluency in Unison, ecosystem risk.

**Verdict:** Architecturally beautiful. Practically risky today.

### Option B: Hybrid (Unison for computation, Dolt for state)

Hard cells crystallize into Unison functions. The ability system models the soft/hard boundary. But yields, cell metadata, evaluation history, and operational state stay in Dolt. Unison functions are invoked via HTTP services. Dolt remains the source of truth for DAG state.

**Gains:** Type-level soft/hard distinction for crystallized cells, SQL for everything operational, gradual migration path.

**Losses:** Two systems to operate, serialization boundary between Unison and Dolt, incomplete content-addressing story.

**Verdict:** Pragmatic. Gets the highest-value Unison features (abilities, content-addressing for hard cells) while keeping operational tooling.

### Option C: Unison-inspired design in Dolt (keep Dolt, steal ideas)

Do not adopt Unison at all. Instead, implement content-addressed functions, an ability-like soft/hard type distinction, and evaluation strategies in Go/SQL. Use Dolt's existing strengths.

**Gains:** No new dependencies, full SQL, full dolt diff, existing code works.

**Losses:** Manual implementation of everything Unison provides natively. The type-level soft/hard boundary becomes a convention rather than a compiler-enforced invariant.

**Verdict:** Safe. Misses the deepest insights Unison offers.

---

## 9. Key Insight: The Ability System Is the Prize

The research reveals an asymmetry. Most of Unison's features (content-addressing, typed storage, distribution) are nice-to-have improvements over Dolt. They make things cleaner but do not fundamentally change what is possible. The ability system is different. It transforms the soft/hard boundary from a runtime property into a compile-time type distinction.

With abilities:
- A soft cell *cannot* accidentally be treated as deterministic -- the type forbids it
- Crystallization is ability elimination -- a well-understood type-theoretic operation
- Evaluation strategies are handlers -- composable, testable, swappable
- The compiler proves that a fully crystallized cell has no remaining soft dependencies

This is not something you can "steal" and implement in Go. Algebraic effects require a language that supports them. If Cell wants this property, it needs a language with abilities (Unison, OCaml 5, Koka, Eff) or it needs to build a type checker for Cell's own language.

---

## 10. Recommendations

1. **Do not attempt full Unison migration now.** The LLM fluency gap and ecosystem risk are too high for Cell's near-term needs.

2. **Prototype the ability system mapping.** Write a small proof-of-concept that models soft cells, hard cells, and crystallization using Unison abilities. This validates the type-theoretic argument without committing to full migration.

3. **Explore Unison as a crystallization target.** When a soft cell crystallizes into a hard cell, the resulting deterministic function could be stored as a Unison definition. This gets content-addressing and type safety for the most important artifacts (crystallized cells) without replacing the entire runtime.

4. **Use Unison's MCP integration for LLM-codebase interaction.** Even without full adoption, the MCP tools (`view-definitions`, `search-by-type`, `typecheck-code`) provide a model for how LLM evaluators should interact with a typed codebase.

5. **Watch the FFI story.** Unison's FFI is actively developing (DLL support landed November 2025). If they add the ability to call Unison functions from external languages (reverse FFI), the hybrid architecture becomes much more attractive.

6. **Monitor LLM fluency.** As Unison grows, LLM training data will increase. The MCP integration accelerates this by providing tools that compensate for limited training data. Reassess in 6-12 months.

---

## Appendix A: Unison Ability Syntax Reference

### Declaring an ability

```unison
structural ability Oracle where
  evaluate : CellSpec ->{Oracle} Yield
  verify : Yield ->{Oracle} Bool
```

### Function type with abilities

```unison
-- Pure function (no abilities)
hardCell : Input ->{} Output

-- Function requiring Oracle
softCell : Input ->{Oracle} Output

-- Function requiring multiple abilities
complexCell : Input ->{Oracle, Store State, Remote} Output
```

### Writing a handler

```unison
oracleHandler : Request {Oracle} a -> {IO, Exception} a
oracleHandler = cases
  {Oracle.evaluate spec -> k} ->
    result = callLLM spec  -- IO effect
    handle k result with oracleHandler
  {Oracle.verify yield -> k} ->
    valid = checkYield yield  -- IO effect
    handle k valid with oracleHandler
  {a} -> a
```

### Using a handler

```unison
result = handle softCell input with oracleHandler
```

### Crystallization as handler replacement

```unison
-- Before: soft cell needs Oracle
soft : Input ->{Oracle} Output

-- After: crystallized handler provides deterministic implementation
crystalHandler : Request {Oracle} a -> a
crystalHandler = cases
  {Oracle.evaluate spec -> k} ->
    result = deterministicCompute spec  -- no IO!
    handle k result with crystalHandler
  {Oracle.verify yield -> k} ->
    handle k True with crystalHandler
  {a} -> a

-- Usage produces a pure computation
hard : Input ->{} Output
hard input = handle soft input with crystalHandler
```

## Appendix B: Unison Hash Reference Syntax

```
#a0v829        -- term reference (short hash)
##Nat          -- built-in reference
#x.2           -- 2nd element of a cyclic definition group
#x#0           -- first constructor of type #x
```

Hashes are 512-bit SHA3 digests. Short hashes are the minimal prefix needed for disambiguation in the current codebase. The compiler resolves them to full hashes during compilation.

## Appendix C: Unison Cloud Storage Types

| Type | Description | Cell Mapping |
|------|-------------|--------------|
| Cell | Single typed value, transactional | Cell yield |
| Table | Keyed typed values, transactional | Yield lookup table |
| OrderedTable | Ordered keyed values | Sorted cell indices |
| Blob | Binary large objects | Artifact storage |
| Storage.Batch | Bulk reads across tables | Multi-yield resolution |

## Appendix D: Key URLs

- Unison language: https://www.unison-lang.org
- Unison GitHub (6.6k stars, 122 contributors): https://github.com/unisonweb/unison
- Unison Cloud: https://unison.cloud
- Unison Share (library ecosystem): https://share.unison-lang.org
- MCP integration docs: https://github.com/unisonweb/unison/blob/trunk/docs/mcp.md
- Abilities reference: https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/
- Cloud BYOC: https://www.unison-lang.org/blog/cloud-byoc/
- Volturno (distributed streaming): https://www.unison-lang.org/blog/volturno-design/

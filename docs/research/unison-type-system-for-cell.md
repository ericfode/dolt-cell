# Unison's Type System and Ability System as a Model for Cell

**Date**: 2026-03-14
**Status**: Research exploration (no code)

---

## Overview

Unison is a statically-typed functional language built on a radical premise: code is
content-addressed. Every definition is identified by a 512-bit SHA3 hash of its syntax
tree, stored as an AST in a database rather than as text files. The language includes a
system of algebraic effects called "abilities" that track computational effects in the
type system. This document explores how Unison's type system and ability system could
model Cell's computational concepts -- the soft/hard boundary, oracles, crystallization,
quotation, bottom propagation, and the DAG structure.

The central thesis: Cell's fundamental invariant -- the soft/hard boundary -- maps
naturally onto the distinction between effectful and pure computations in Unison's ability
system. A soft cell is a computation that requires the `Semantic` ability; a hard cell is
a pure function with no ability requirements. The type signature alone tells you which
substrate a cell needs.

---

## 1. The Soft/Hard Boundary as an Ability

### How Unison Abilities Work

In Unison, every function type has the form `A ->{e} B`, where `e` is a set of abilities
(effects) the function may perform. A pure function with no effects has the type
`A ->{} B`. When you write `A -> B` in a signature you provide, Unison infers the
abilities; when Unison reports it back, `->` means pure.

An ability is declared with its operations:

```
structural ability Store v where
  get : {Store v} v
  put : v ->{Store v} ()
```

A handler provides an interpretation for those operations, pattern-matching on each
request constructor and deciding what to do with the continuation:

```
storeHandler : v -> Request (Store v) a -> a
storeHandler storedValue = cases
  {Store.get -> k} ->
    handle k storedValue with storeHandler storedValue
  {Store.put v -> k} ->
    handle k () with storeHandler v
  {a} -> a
```

Key property: abilities are visible in the type signature. A function cannot secretly
perform an effect -- the type checker enforces this. And handlers *eliminate* abilities:
a handler converts a computation requiring `{Store v}` into one that does not.

### Modeling the Soft/Hard Boundary

The LLM substrate can be modeled as a custom ability:

```
unique ability Semantic where
  evaluate : Prompt -> {Semantic} Output
```

With this in place, Cell's soft/hard distinction becomes a type-level property:

- **Hard cells** are pure functions: `Nat -> Nat`, `Text -> [Text]`, `Input ->{} Output`.
  No ability requirements. Deterministic. The empty ability set `{}` is the hard
  guarantee.

- **Soft cells** require the `Semantic` ability: `Input ->{Semantic} Output`. The type
  signature declares that this computation needs an LLM to evaluate. It cannot be run
  without a handler that provides `Semantic` interpretation.

The soft/hard boundary is no longer a runtime convention or a naming scheme (the
current approach uses sigils like `hard:` and `soft:`). It is a compile-time invariant
enforced by the type checker. You literally cannot call a soft cell from a hard cell
without the type checker refusing to compile.

### What a Semantic Handler Looks Like

A handler for the `Semantic` ability would bridge to an actual LLM:

```
llmHandler : Request Semantic a ->{IO} a
llmHandler = cases
  {Semantic.evaluate prompt -> k} ->
    response = callLLMAPI prompt  -- IO effect
    handle k response with llmHandler
  {a} -> a
```

This handler translates `Semantic` requests into `IO` operations (HTTP calls to an LLM
API). For testing, a mock handler could provide deterministic responses:

```
mockSemantic : Map Prompt Output -> Request Semantic a -> a
mockSemantic responses = cases
  {Semantic.evaluate prompt -> k} ->
    response = Map.get prompt responses |> Optional.getOrElse defaultOutput
    handle k response with mockSemantic responses
  {a} -> a
```

This is exactly the dependency injection pattern that abilities enable. The same soft
cell code runs against the real LLM in production and against a mock in tests, without
changing the cell's implementation.

### Ability Polymorphism for Mixed Computations

Unison supports ability polymorphism through type variables. A function like
`List.map : (a ->{e} b) -> [a] ->{e} [b]` works with any ability set `e`. This means
utility functions that operate over cells don't need to know whether they're handling
soft or hard cells -- the ability requirement propagates automatically.

A cell combinator could be polymorphic:

```
sequence : [() ->{e} a] ->{e} [a]
```

When applied to hard cells, `e` is empty. When applied to soft cells, `e` includes
`Semantic`. When applied to a mix, `e` includes `Semantic` and the result requires
the `Semantic` ability -- which is exactly right: a pipeline containing even one soft
cell is semantically soft.

---

## 2. Oracles as Abilities

### The Oracle Ability

Oracles in Cell verify outputs. They can be deterministic (checking a property
algorithmically) or semantic (asking an LLM to judge quality). This maps to another
ability:

```
unique ability Oracle where
  check : Assertion -> {Oracle} Verdict
```

Where `Verdict` might be:

```
unique type Verdict = Pass | Fail Text | Uncertain Float
```

### Deterministic vs. Semantic Oracles

A deterministic oracle handler eliminates the `Oracle` ability without introducing
`Semantic`:

```
deterministicOracle : Request Oracle a ->{} a
deterministicOracle = cases
  {Oracle.check assertion -> k} ->
    verdict = runPropertyCheck assertion  -- pure computation
    handle k verdict with deterministicOracle
  {a} -> a
```

A semantic oracle handler translates `Oracle` into `Semantic`:

```
semanticOracle : Request Oracle a ->{Semantic} a
semanticOracle = cases
  {Oracle.check assertion -> k} ->
    prompt = formatAssertionAsPrompt assertion
    response = Semantic.evaluate prompt
    verdict = parseVerdict response
    handle k verdict with semanticOracle
  {a} -> a
```

The type signatures tell the whole story: `deterministicOracle` produces a pure result
(no abilities remain), while `semanticOracle` still requires `Semantic`. The type system
tracks the distinction between deterministic and semantic verification at compile time.

### Composing Cells with Oracles

A cell that uses both LLM evaluation and oracle verification would have the signature:

```
verifiedSoftCell : Input ->{Semantic, Oracle} Output
```

The handler stacking pattern -- nesting multiple handlers -- lets you peel off
abilities one at a time:

```
handle
  (handle (verifiedSoftCell input) with semanticOracle)
with llmHandler
```

Each handler eliminates one ability, ultimately producing an `{IO}` computation that
can be executed.

---

## 3. Yields as Typed Values

### The Problem with Untyped Yields

In the current Dolt-based implementation, yields are TEXT or JSON strings. The
contract between a cell and its consumers is enforced at runtime by parsing, not at
compile time by types. A cell that yields `{name: "Alice", age: 30}` and a consumer
that expects `{name: Text, score: Float}` will fail at runtime with a parse error.

### Unison's Type System for Yields

Unison has a rich type system that includes:

- **Built-in types**: `Nat`, `Int`, `Float`, `Boolean`, `Text`, `Char`, `Bytes`
- **Algebraic data types**: sum types with multiple constructors
- **Record types**: named fields with auto-generated accessors
- **Polymorphic types**: `forall a. [a]`, parameterized types
- **Type constructors**: `List`, `Map`, `Optional`, `Either`

Record types provide named fields:

```
unique type PersonRecord = {
  name : Text,
  age : Nat,
  scores : [Float]
}
```

Unison auto-generates getters (`PersonRecord.name : PersonRecord -> Text`), setters
(`PersonRecord.name.set : Text -> PersonRecord -> PersonRecord`), and modifiers
(`PersonRecord.name.modify : (Text ->{g} Text) -> PersonRecord ->{g} PersonRecord`).

### Typed Cell Signatures

With Unison types, cell signatures become precise:

```
-- A hard cell that sorts a list of numbers
sortCell : [Nat] ->{} [Nat]

-- A soft cell that extracts entities from text
extractEntities : Text ->{Semantic} [Entity]

-- A soft cell that summarizes with a score
summarize : Text ->{Semantic} {summary: Text, confidence: Float}
```

The type checker catches mismatches at compile time. If a downstream cell expects
`[Entity]` but the upstream cell yields `Text`, compilation fails. No runtime parsing
needed.

### Structural Types for Schema Flexibility

Unison's structural type system adds an interesting dimension. A `structural type`
is identified by its structure, not its name. Two structurally identical types declared
independently are interchangeable:

```
structural type PersonA = { name : Text, age : Nat }
structural type PersonB = { name : Text, age : Nat }
-- PersonA and PersonB are the SAME type
```

This could model the case where two independently developed cells happen to produce
compatible output. They don't need to share a type definition -- structural
compatibility is enough.

Conversely, `unique type` declarations (the default) are identified by name. A
`unique type Age = Age Nat` is not the same as `unique type Count = Count Nat` even
though they have identical structure. This models semantic distinctions: an age is not
a count.

### Limitations

Unison does not currently support GADTs (Generalized Algebraic Data Types) or
existential types, though these are planned for a future version based on the
Dunfield-Krishnaswami bidirectional typechecking framework. This limits some advanced
type-level programming patterns -- for instance, you cannot have a heterogeneous
collection of cells with type-level constraints on their connections without
existentials.

---

## 4. Quotation in Unison

### Cell's Quotation Operator

In Cell, the `section` operator (`\S`) quotes a cell definition, turning it from something
that *executes* into something that can be *inspected as data*. `\Ssort` doesn't run the
sort cell -- it produces a data representation of what the sort cell *is*.

### Unison's Content-Addressed Code

Unison's architecture is remarkably close to what quotation needs. Every definition in
the codebase is:

1. **Hashed**: identified by a 512-bit SHA3 hash of its syntax tree
2. **Stored as AST**: the codebase holds abstract syntax trees, not text
3. **Immutable**: the definition associated with a hash never changes
4. **Content-addressed**: the hash depends only on the structure of the code, not on
   names

Two functions with different variable names but identical structure produce the same
hash. All dependencies are replaced by their hashes, so the hash uniquely identifies
the exact implementation and pins down all dependencies.

### Link.Term and Link.Type

Unison provides first-class references to definitions:

- `Link.Term`: a reference (hash) to a term in the codebase
- `Link.Type`: a reference (hash) to a type in the codebase

The `termLink` and `typeLink` syntax creates these references. You can pass them around,
store them, compare them -- they're ordinary values.

### How Quotation Could Work

Quotation in Cell maps to obtaining a `Link.Term` for a definition:

```
-- Pseudo-Unison: quoting the sort cell
quotedSort : Link.Term
quotedSort = termLink sortCell
```

This gives you a content-addressed reference to the sort cell's definition. The hash
is stable -- it doesn't change when you rename the function, and it uniquely identifies
the exact implementation.

### The Limitation: No Term Inspection

Here is the critical gap. Unison's current Codebase API intentionally excludes direct
access to term and type implementations. As the API documentation states: "We can ask
the codebase for links, but not for the actual terms or types." The API supports:

- `Codebase.termNamesAt`: get names for a term link in a namespace
- `Codebase.typeNamesAt`: get names for a type link in a namespace
- `Codebase.constructorsOf`: get constructors of a type
- `Codebase.list`: list namespace contents
- Patch operations for refactoring

But you cannot programmatically inspect the AST of a definition. You can reference it,
name it, link to it, but not decompose it into its constituent parts from within
Unison code.

This means Cell's quotation -- which needs to make cell definitions inspectable for
crystallization and metaprogramming -- would require extending Unison's reflection
capabilities. The architecture supports it (the AST is right there in the database),
but the API does not expose it yet.

### Documentation as Partial Reflection

Unison's documentation system offers a partial form of reflection. Documentation is a
first-class `Doc` type that can embed code:

- `@source{myTerm}` displays a function's full implementation
- `@signature{myTerm}` shows type signatures
- Inline code references with double backticks are typechecked

These doc elements reference terms by their content-addressed hash and update
automatically on rename. This is closer to quotation than most languages offer, but
it's presentation-oriented rather than computation-oriented -- you can display code
but not manipulate it programmatically.

### The Opportunity

Unison is the language closest to supporting Cell-style quotation natively. The
infrastructure exists: code is already data (ASTs in a database, identified by hash).
What's missing is the programmatic API to access that data from within Unison programs.
If the Codebase API were extended with something like:

```
Codebase.termAST : Link.Term ->{Codebase} Term
Codebase.typeAST : Link.Type ->{Codebase} Type
```

...then quotation would be a natural feature, not a bolted-on macro system.

---

## 5. The Crystallization Type

### What Crystallization Means

Crystallization is the process of converting a soft cell into a hard cell. An LLM
evaluates a soft cell repeatedly, an oracle verifies the outputs, and eventually the
soft cell is replaced by a deterministic function that produces the same results.

### Typing Crystallization

In Unison's ability system, crystallization has a natural type:

```
crystallize : (Input ->{Semantic} Output) -> (Input ->{} Output)
```

This says: take a function that requires the `Semantic` ability and produce a function
that requires no abilities. The input and output types are preserved. The type system
guarantees interface compatibility -- the crystallized cell accepts the same input and
produces the same output type.

A more realistic signature would account for the possibility of failure:

```
crystallize : (Input ->{Semantic} Output)
           -> {Semantic, Oracle} (Input ->{} Output)
```

Crystallization itself requires the `Semantic` ability (to evaluate the soft cell and
observe its behavior) and the `Oracle` ability (to verify that the generated hard cell
matches the soft cell's behavior). The result is a pure function.

### The Crystallization Process as an Ability Handler

Conceptually, crystallization is a special kind of ability handler. Normal handlers
interpret an ability at runtime -- they execute the LLM call when `Semantic.evaluate`
is requested. A crystallizing handler would:

1. Run the soft cell with many inputs, collecting input-output pairs
2. Synthesize a deterministic function that matches the observed behavior
3. Verify the synthesized function against the oracle
4. Return the synthesized function

The handler doesn't just eliminate the `Semantic` ability at runtime -- it produces a
new function that *statically* lacks the ability requirement. This is a compile-time
transformation, not a runtime interpretation.

### Content-Addressed Crystallization

Unison's content-addressing makes crystallization particularly clean:

- The soft cell has hash `#abc123` with type `Input ->{Semantic} Output`
- The crystallized hard cell has hash `#def456` with type `Input ->{} Output`
- The crystallization record can store both hashes, creating an auditable link
  between the soft and hard versions

Since definitions are immutable, the soft cell's hash never changes. The
crystallization is a permanent relationship between two immutable definitions.

### Type-Level Guarantees

The type system provides three guarantees for crystallization:

1. **Interface preservation**: the input and output types must match
2. **Ability elimination**: the result must be pure (no `Semantic` requirement)
3. **Oracle verification**: the crystallization process must use verification

These are not runtime checks -- they are compile-time constraints enforced by the
type checker.

---

## 6. Bottom in Unison

### Cell's Bottom

In Cell, bottom (`_|_`) represents evaluation failure. When a cell fails, bottom
propagates through the DAG -- any cell that depends on a failed cell also produces
bottom. This is Cell's error propagation mechanism.

### Unison's Error Handling Abilities

Unison provides a graduated set of error-handling abilities:

**Abort**: terminates computation with no information.

```
structural ability Abort where
  abort : {Abort} a
```

**Throw**: terminates with a typed error value.

```
-- Throw is parameterized by the error type
divByThrow : Nat -> Nat ->{Throw Text} Nat
divByThrow a b = match b with
  0 -> throw "Cannot divide by zero"
  n -> a Nat./ b
```

**Exception**: terminates with a `Failure` value (a structured error type).

```
divByException : Nat -> Nat ->{Exception} Nat
divByException a b = match b with
  0 -> Exception.raise (Generic.failure "Cannot divide by zero" b)
  n -> a Nat./ b
```

### Converting Between Abilities and Data Types

Handlers convert between ability-based and data-based error representations:

- `toOptional!` converts `{Abort}` to `Optional a` -- abort becomes `None`
- `toEither` converts `{Throw e}` to `Either e a` -- throw becomes `Left`
- `catch` converts `{Exception}` to `Either Failure a`

And vice versa:
- `Optional.toAbort` converts `None` to `Abort.abort`

This bidirectional conversion is idiomatic in Unison -- you choose the representation
that best fits the current context.

### Modeling Cell's Bottom

Cell's bottom propagation maps most naturally to the `Abort` ability:

```
unique ability CellAbort where
  bottom : {CellAbort} a
```

When a cell fails, it calls `CellAbort.bottom`, which halts the computation. The
return type `a` means bottom can appear anywhere (it never actually returns, so it's
compatible with any expected type).

### Bottom Propagation Through the DAG

In a cell DAG, each cell depends on upstream cells. If we model cell evaluation as a
function that requires `CellAbort`:

```
evaluateCell : CellId -> {CellAbort, Semantic} Output
```

Then bottom propagation is automatic. If an upstream cell aborts, the downstream cell
-- which calls the upstream cell -- also aborts, because the unhandled `CellAbort`
propagates up the call stack.

A handler at the DAG level can convert individual cell failures into bottom values:

```
withBottomPropagation : Request CellAbort a -> Optional a
withBottomPropagation = cases
  {CellAbort.bottom -> _k} -> None  -- continuation is discarded
  {a} -> Some a
```

The handler for the bottom case discards the continuation `k` -- it doesn't resume the
computation. This models the fact that bottom is terminal: once a cell fails, no
further computation happens in that branch.

### Richer Bottom with Throw

For debugging, `Throw` provides more information than `Abort`:

```
unique type CellFailure
  = EvaluationTimeout CellId
  | OracleRejection CellId Verdict
  | DependencyFailed CellId CellId
  | SubstrateMissing CellId

evaluateCell : CellId -> {Throw CellFailure, Semantic} Output
```

The `DependencyFailed` constructor explicitly records which upstream cell caused the
failure, making the propagation path traceable. A handler can collect the full failure
chain:

```
toEither : Request (Throw CellFailure) a -> Either CellFailure a
```

---

## 7. The DAG as a Unison Data Structure

### Cell Programs as DAGs

A Cell program is a directed acyclic graph where nodes are cells and edges represent
data dependencies. The question is whether this DAG can be represented as a first-class
Unison data structure with typed edges.

### Basic DAG Representation

Unison's base library includes `Map` and `Set` types, plus a `Graph` type in
`lib.base.data.Graph`. A cell DAG could be modeled as:

```
unique type CellId = CellId Nat

unique type CellNode = {
  id : CellId,
  definition : Link.Term,
  dependencies : [CellId]
}

unique type CellGraph = CellGraph (Map CellId CellNode)
```

This captures the structure but loses type information about edges. The `definition`
field is a `Link.Term` -- a hash reference to the cell's implementation in the
codebase.

### Typed Edges

A more expressive representation would encode the types of data flowing along edges.
Without GADTs (which Unison doesn't yet support), this is challenging. A pragmatic
approach uses existential-style wrapping:

```
unique type TypedEdge = {
  source : CellId,
  target : CellId,
  edgeType : Link.Type  -- hash reference to the type flowing on this edge
}
```

The `Link.Type` reference captures what type flows along the edge, but the type
checker cannot enforce that the source cell's output type matches the target cell's
input type at the graph construction level. That verification would need to happen
through a validation function rather than through the type system directly.

### Functional DAG Evaluation

The evaluation pattern for a cell DAG follows the standard topological-sort approach,
but with abilities tracking the computational substrate:

```
evaluateGraph : CellGraph ->{Semantic, CellAbort} Map CellId Output

-- Or, more precisely, with ability polymorphism:
evaluateNode : CellNode -> Map CellId Output ->{e, CellAbort} Output
```

The ability variable `e` captures whether the node is soft (`{Semantic}`) or hard
(`{}`). In practice, since the graph mixes soft and hard cells, the overall evaluation
requires `{Semantic}` -- the union of all ability requirements.

### Distributed DAG Evaluation

Unison's distributed computing model is particularly relevant here. Unison can
serialize arbitrary values, including functions, and ship them to different locations.
The protocol is hash-based: the sender ships bytecode; the recipient checks for missing
hashes and requests only what it needs.

A distributed cell DAG evaluation could ship individual cell computations to different
nodes:

```
evaluateRemote : CellNode ->{Remote, Semantic} Output
```

The `Remote` ability handles distribution; `Semantic` handles LLM access. Unison's
content-addressed architecture means cells are automatically deduplicated across
nodes -- if two nodes have the same cell (same hash), the code doesn't need to be
transferred.

### Lazy Distributed Evaluation

Unison's `Remote.Value` type enables lazy distributed evaluation. Instead of
eagerly fetching results, you wrap values as remote references:

```
structural type DistributedCell a
  = Evaluated (Remote.Value a)
  | Pending (Remote.Value (() ->{Semantic} a))
```

The `Value.map` operation applies functions at remote locations without fetching data
locally, enabling "move the computation to the data" patterns. This could model a
cell DAG where cells are evaluated where their dependencies reside, minimizing data
movement.

---

## 8. Can LLMs Write Unison?

### Why This Matters

Crystallization requires an LLM to produce a hard cell -- a deterministic function --
from observed soft cell behavior. If the target language is Unison, the LLM must be
able to write valid Unison code. If LLMs cannot write Unison, crystallization cannot
produce Unison functions, and the type system benefits described above are moot for
crystallized cells.

### The Training Data Problem

LLM code generation quality correlates strongly with training data volume. Research
findings:

- **High-resource languages** (Python, JavaScript, Java) have abundant training data
  and LLMs perform well on them.
- **Low-resource languages** (OCaml, Racket, Haskell) have limited training data and
  LLMs struggle. A 2024 study on Haskell code completion found that "most datasets
  contain little to no functional code, leading to poor performance."
- **Knowledge transfer is limited**: familiarity with imperative languages does not
  transfer well to functional languages in LLM training.
- Developers on Hacker News report being "generally disappointed" with LLM output for
  Haskell.

### Unison's Position

Unison is significantly more niche than Haskell:

- Haskell has decades of academic papers, tutorials, Stack Overflow answers, and
  open-source projects for LLMs to train on.
- Unison has a small community, 53 exercises on Exercism, and a focused documentation
  site. The total volume of Unison code available for training is orders of magnitude
  smaller than Haskell's.
- Unison's syntax, while similar to Haskell in some respects, has unique features
  (abilities syntax, content-addressed references, structural/unique type modifiers)
  that would not transfer from Haskell training data.

No published research specifically evaluates LLM performance on Unison. Based on the
general pattern that LLM performance degrades with training data scarcity, and that
Unison is among the least represented languages in training corpora, the prognosis is
poor.

### Mitigating Factors

Several factors partially offset the training data problem:

1. **Unison's similarity to Haskell**: Core syntax (pattern matching, algebraic data
   types, higher-order functions) is familiar. An LLM trained on Haskell could produce
   plausible Unison with relatively few corrections.

2. **Type-directed generation**: Unison's type system could guide LLM output. Given a
   target type signature `[Nat] ->{} [Nat]` for a sort function, the LLM's output is
   heavily constrained. The type checker can validate the result.

3. **Content-addressed correction**: Since Unison stores code as ASTs, generated code
   can be parsed, typechecked, and rejected or accepted programmatically. Failed
   attempts don't pollute the codebase.

4. **Few-shot learning**: Providing Unison examples in the prompt can bootstrap LLM
   performance. Crystallization could include Unison examples as part of the
   crystallization prompt.

5. **Semi-synthetic training data**: Research on low-resource languages suggests that
   translating solutions from high-resource languages can create training data for
   fine-tuning. Unison's Exercism track provides 53 exercises with solutions that
   could seed this process.

### Practical Implications for Cell

For crystallization to work with Unison as the target:

- **Short-term**: LLMs will produce Unison code that is approximately correct but
  needs compilation and type-checking as a verification step. The oracle system can
  catch semantic errors. Expect higher iteration counts than with Python.

- **Medium-term**: Fine-tuning a model on Unison code (the base library, Unison Share
  projects, Exercism solutions) could substantially improve generation quality. The
  type system means even imperfect generation can be guided toward correctness.

- **Alternative**: Crystallization could target a higher-resource language (Python,
  TypeScript) and use Unison as the coordination layer. Soft cells crystallize into
  Python functions; the Unison DAG orchestrates them through FFI or RPC. This loses
  the type-level guarantees for crystallized cells but gains LLM fluency.

---

## Synthesis: How the Pieces Fit Together

### The Full Picture

Assembling all eight aspects, here is what Cell-in-Unison would look like as a type
system:

```
-- The fundamental abilities
unique ability Semantic where
  evaluate : Prompt ->{Semantic} Output

unique ability Oracle where
  check : Assertion ->{Oracle} Verdict

unique ability CellAbort where
  bottom : {CellAbort} a

-- Cell types
unique type Cell e a = Cell (Input ->{e} a)
-- When e = {}, it's a hard cell
-- When e = {Semantic}, it's a soft cell

-- Crystallization
crystallize : (Input ->{Semantic} Output)
           -> {Semantic, Oracle}
              (Input ->{} Output)

-- Oracle variants
unique type OracleMode
  = Deterministic   -- Oracle handler is pure
  | SemanticOracle  -- Oracle handler uses Semantic

-- DAG structure
unique type CellGraph = CellGraph (Map CellId CellNode)

-- Bottom propagation via Abort
evaluateGraph : CellGraph
             -> {Semantic, CellAbort}
                Map CellId Output

-- Quotation via content-addressed references
quote : Link.Term  -- hash of a cell definition
```

### What the Type System Enforces

1. **Soft/hard boundary**: A hard cell cannot call `Semantic.evaluate`. The type
   checker prevents it. This is Cell's fundamental invariant, enforced at compile
   time.

2. **Oracle mode tracking**: The type signature of an oracle handler reveals whether
   it's deterministic or semantic. You cannot accidentally treat a semantic oracle as
   deterministic.

3. **Yield type safety**: Cell inputs and outputs are typed. Mismatches between
   producer and consumer are compile-time errors.

4. **Bottom propagation**: The `CellAbort` ability propagates through the call graph
   automatically. No special runtime mechanism needed.

5. **Crystallization interface preservation**: The type signature of `crystallize`
   guarantees that the hard cell has the same input/output types as the soft cell.

### What the Type System Does Not Enforce

1. **Semantic correctness of crystallization**: The type system ensures interface
   compatibility but cannot verify that the crystallized function *behaves the same*
   as the soft cell. That remains the oracle's job.

2. **DAG well-formedness**: Without GADTs, the type system cannot enforce that edges
   in the cell graph connect compatible types. Graph validation is a runtime check.

3. **Quotation/inspection**: The current Codebase API does not expose ASTs for
   programmatic inspection. Quotation is limited to hash references without
   structural access.

4. **Non-determinism tracking**: While `Semantic` marks a cell as LLM-dependent, the
   type system doesn't track *degrees* of non-determinism or confidence levels. A
   cell that returns the same answer 99% of the time and one that's truly random both
   have the same type.

### The Key Insight

Unison's ability system provides exactly the right abstraction for Cell's soft/hard
boundary. The boundary is not a tag, not a naming convention, not a runtime check --
it's a type-level property tracked by the compiler. Abilities compose (a pipeline
with one soft cell is a soft pipeline), handlers are swappable (test with mocks,
run with real LLM), and the type signature is documentation that cannot lie.

The deeper alignment is between Unison's content-addressed architecture and Cell's
quotation/crystallization model. Both treat code as data. Both identify code by its
content rather than by its name. Both assume that the same hash always means the same
computation. Unison's infrastructure is Cell's quotation system waiting to be
activated -- it just needs the API to expose what's already there.

---

## Sources

- [Introduction to Abilities](https://www.unison-lang.org/docs/fundamentals/abilities/)
- [Abilities and Ability Handlers (language reference)](https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/)
- [Writing Your Own Abilities](https://www.unison-lang.org/docs/fundamentals/abilities/writing-abilities/)
- [Abilities for the Monadically Inclined](https://www.unison-lang.org/docs/fundamentals/abilities/for-monadically-inclined/)
- [Error Handling with Abilities](https://www.unison-lang.org/docs/fundamentals/abilities/error-handling/)
- [Unofficial Abilities Tutorial](https://gist.github.com/atacratic/7a91901d5535391910a2d34a2636a93c)
- [Trying Out Unison, Part 3: Effects Through Abilities](https://softwaremill.com/trying-out-unison-part-3-effects-through-abilities/)
- [The Big Idea (content-addressed code)](https://www.unison-lang.org/docs/the-big-idea/)
- [Types (language reference)](https://www.unison-lang.org/docs/language-reference/types/)
- [Unique and Structural Types](https://www.unison-lang.org/docs/fundamentals/data-types/unique-and-structural-types/)
- [Record Types](https://www.unison-lang.org/docs/fundamentals/data-types/record-types/)
- [Documenting Unison Code](https://www.unison-lang.org/docs/usage-topics/documentation/)
- [Distributed Datasets in Unison](https://www.unison-lang.org/articles/distributed-datasets/core-idea/)
- [Codebase API Proposal (GitHub Issue #922)](https://github.com/unisonweb/unison/issues/922)
- [Using Abilities Part 1](https://www.unison-lang.org/docs/fundamentals/abilities/using-abilities-pt1/)
- [Using Abilities Part 2](https://www.unison-lang.org/docs/fundamentals/abilities/using-abilities-pt2/)
- [Common Collection Types](https://www.unison-lang.org/docs/fundamentals/values-and-functions/common-collection-types/)
- [Unison on Exercism](https://exercism.org/tracks/unison)
- [LLM Performance on Haskell (Hacker News discussion)](https://news.ycombinator.com/item?id=42194461)
- [Investigating LLM Performance for Functional Languages: Haskell Case Study](https://arxiv.org/html/2403.15185v1)
- [Survey on LLM Code Generation for Low-Resource Languages](https://arxiv.org/abs/2410.03981)
- [Knowledge Transfer for Low-Resource Programming Languages](https://dl.acm.org/doi/10.1145/3689735)
- [ALGO: Synthesizing Programs with LLM-Generated Oracle Verifiers](https://arxiv.org/abs/2305.14591)

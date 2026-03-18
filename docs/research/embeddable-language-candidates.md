# Embeddable Language Candidates for Cell

**Author**: obsidian (polecat)
**Date**: 2026-03-18
**Bead**: do-ov6l
**Status**: Draft — breadth-first survey, not final recommendation

---

## Context

Cell's `.cell` DSL is a bespoke domain-specific language for declaring dataflow
graphs of LLM-powered computations. The runtime is in Go. The question: could an
existing embeddable language replace the bespoke parser while preserving Cell's
semantics?

### What the DSL must express

| Construct | Purpose | Example |
|-----------|---------|---------|
| `cell NAME [(stem)]` | Declare a computation node, optionally perpetual | `cell compose (stem)` |
| `yield FIELD [= VALUE]` | Declare output fields, optionally pre-frozen | `yield topic = "rain"` |
| `given SOURCE.FIELD` | Declare input dependency | `given compose.poem` |
| `given? SOURCE.FIELD` | Optional dependency | `given? config.mode` |
| `given SOURCE[*].FIELD` | Fan-in gather (all iterations) | `given reflect[*].poem` |
| `recur until GUARD (max N)` | Guarded iterative refinement | `recur until settled = "DONE" (max 5)` |
| `check COND` / `check~ ASSERT` | Deterministic / semantic validation | `check result is valid JSON` |
| `---` body block | Freeform prompt or SQL body | Natural language with `«field»` interpolation |

Key properties:
- **Declarative DAG**: cells form a dependency graph, execution order is derived
- **Monotonic**: once a yield is frozen, it never changes
- **Effect lattice**: Pure < Semantic < Divergent (hard → soft → stem)
- **Append-only**: all state changes are inserts, never updates
- **Body is opaque text**: the body of a soft cell is a prompt, not code

### What "embed in Go" means

The Go runtime (`cmd/ct/`) needs to:
1. Parse `.cell` files into an AST of cells, yields, givens, checks, recur, bodies
2. Convert that AST into SQL inserts (the "pour" operation)
3. Drive the DAG evaluation loop (the "piston" operation)

The parser is ~400 lines of Go. The question is whether replacing it with an
existing language gives us enough to justify the dependency.

---

## Evaluation Criteria

For each candidate:
1. **Expressiveness**: Can it naturally encode cell/given/yield/check/recur?
2. **Go embedding**: Is there a mature Go library? (not a subprocess/FFI hack)
3. **Gains**: What do we get that the bespoke parser doesn't provide?
4. **Losses**: What do we give up vs. the current approach?
5. **Fit**: How natural does Cell semantics feel in this language?

---

## Tier 1: Strong Go Embedding Story

### Lua (via GopherLua / golua)

**Go embedding**: Excellent. [GopherLua](https://github.com/yuin/gopher-lua) is
a pure-Go Lua 5.1 implementation, battle-tested, actively maintained. Also
[golua](https://github.com/aarzilli/golua) for C-binding approach. GopherLua is
the clear choice for pure-Go.

**Expressiveness**: Lua's tables can represent cells naturally:

```lua
cell "compose" {
  given = { "topic.subject" },
  yield = { "poem" },
  body = [[
    Write a haiku about «subject». Follow 5-7-5 syllable structure.
  ]],
  check = { "poem is not empty" },
}
```

Lua's `[[...]]` long strings are perfect for multi-line prompt bodies. Tables
are flexible enough for all cell constructs. Metatables could provide validation.
`recur` and `stem` are representable as table fields.

**Gains**:
- Computed cell definitions (loops, conditionals, parameterized cell factories)
- User-defined functions for complex check expressions
- REPL for interactive cell development
- Lua's `require` for modular cell libraries
- Battle-tested parser — no maintenance burden on us

**Losses**:
- Readability for non-programmers. Lua syntax (braces, commas, quotes around
  everything) is noisier than `cell compose / given topic.subject / yield poem`
- Must handle Lua's eager evaluation vs Cell's declarative DAG
- Lua has mutable state — must discipline users to only use it declaratively
- Error messages from Lua runtime may be confusing in Cell context
- Dependency (~15k LOC for GopherLua)

**Fit**: Medium. Lua is a natural "config language that can also compute" but
Cell's value proposition is that `.cell` files read like English, not code. Moving
to Lua trades readability for power. The prompt body (the most important part) is
still opaque text either way.

**Verdict**: Best Go embedding story. Worth considering if we want computed cell
definitions. But Cell programs are typically <50 lines — the power/readability
tradeoff may not pay off.

---

### Starlark (Google's Python Dialect)

**Go embedding**: Excellent. [go.starlark.net](https://github.com/google/starlark-go)
is the canonical implementation, pure Go, maintained by Google. Used in Bazel,
Buck2, Tilt, Skycfg. Very mature.

**Expressiveness**:

```python
cell(
    name = "compose",
    given = ["topic.subject"],
    yield_ = ["poem"],
    body = """
    Write a haiku about «subject». Follow 5-7-5 syllable structure.
    """,
    check = ["poem is not empty"],
)
```

Starlark is deliberately limited: no classes, no exceptions, no import of
arbitrary packages, deterministic execution, hermetic. This aligns well with
Cell's philosophy — programs are data declarations, not general computation.

**Gains**:
- Deterministic by design — no I/O, no threads, no randomness
- Frozen values (Starlark values are immutable after construction — mirrors Cell's monotonicity)
- `load()` for modular composition
- Well-defined subset of Python — familiar syntax
- Battle-tested in build systems that need reproducibility

**Losses**:
- Still noisier than bespoke DSL (parentheses, commas, `yield_` to avoid keyword)
- Starlark's immutability is deep — but Cell's "frozen" is a runtime concept, not a language concept
- No Starlark REPL (minor)
- Slightly more complex than Lua for the Go embedding API

**Fit**: High. Starlark's "hermetic, deterministic config language" philosophy
closely matches Cell's "declarative DAG of computations" philosophy. The
immutability alignment is compelling. The Python-like syntax is more accessible
than Lua to most developers.

**Verdict**: Strongest philosophical alignment. If we want a replacement
language, Starlark is the most natural fit. The determinism and immutability
guarantees overlap heavily with Cell's own invariants.

---

### CUE

**Go embedding**: Good. [cuelang.org/go](https://pkg.go.dev/cuelang.org/go) is
the canonical Go SDK, maintained by the CUE team (Marcel van Lohuizen, ex-Go
team). Pure Go. However, the API has been evolving and breaking — not yet at 1.0.

**Expressiveness**:

```cue
compose: {
    kind: "cell"
    given: ["topic.subject"]
    yield: ["poem"]
    body: """
        Write a haiku about «subject». Follow 5-7-5 syllable structure.
        """
    check: ["poem is not empty"]
}
```

CUE's value proposition is constraints and types. You could define a schema for
cells and get validation for free:

```cue
#Cell: {
    kind: "cell"
    given: [...string]
    yield: [...string]
    body?: string
    check?: [...string]
    recur?: {max: int, until?: string}
    stem?: bool
}
compose: #Cell & { ... }
```

**Gains**:
- Built-in constraint system — `check` expressions could become CUE constraints
- Type-safe cell definitions with schema validation at parse time
- Lattice-based evaluation (CUE unifies values via a lattice — conceptually
  similar to Cell's effect lattice, though the lattices are different)
- Can generate JSON Schema, OpenAPI, etc. from cell definitions
- Hermetic, deterministic, no side effects

**Losses**:
- CUE's learning curve is steep — the lattice-based type system is powerful but unusual
- Pre-1.0 API instability
- CUE is more complex than needed — we'd use 20% of its features
- Error messages can be cryptic ("conflicting values" from lattice failures)
- CUE wants to be the top-level configuration language; embedding it as a
  sub-parser feels awkward

**Fit**: Medium-high. CUE's constraint system maps elegantly to Cell's checks
and validation. But CUE is trying to solve a much bigger problem (configuration
unification) and Cell is trying to solve a smaller, weirder problem (LLM-powered
DAGs). The impedance mismatch is in the bodies — CUE has no concept of "opaque
prompt text that gets sent to an LLM."

**Verdict**: Intellectually compelling but practically over-engineered for Cell's
needs. The constraint system is the standout feature. Worth revisiting if Cell
grows a richer type system.

---

### Jsonnet

**Go embedding**: Good. [google/go-jsonnet](https://github.com/google/go-jsonnet)
is the canonical pure-Go implementation. Maintained, used in production (Grafana,
Tanka, Databricks). Also [jsonnet-go](https://github.com/google/go-jsonnet) — same thing.

**Expressiveness**:

```jsonnet
{
  compose: {
    kind: "cell",
    given: ["topic.subject"],
    yield: ["poem"],
    body: |||
      Write a haiku about «subject». Follow 5-7-5 syllable structure.
    |||,
    check: ["poem is not empty"],
  },
}
```

Jsonnet's `|||` text blocks work well for prompt bodies. It's "JSON + functions +
imports + conditionals."

**Gains**:
- `|||` text blocks for multi-line prompts
- Functions and `local` for parameterized cell templates
- `import` for modular composition
- Outputs pure JSON — trivial to consume in Go
- Well-understood by infra/DevOps community

**Losses**:
- Everything is JSON in the end — the cell abstraction must be convention, not
  enforced by the language
- No built-in type/constraint system (unlike CUE)
- Jsonnet's lazy evaluation can produce confusing errors
- Less readable than the bespoke DSL for simple programs

**Fit**: Medium. Jsonnet is a good "structured data with computation" language,
but Cell programs are more than structured data — they have execution semantics
(DAG, recur, checks). Jsonnet can represent the static structure but can't
enforce the semantics.

**Verdict**: Fine but uninspiring. If the main need is "parameterized cell
templates," Jsonnet works. But it doesn't bring anything that Starlark doesn't do
better for this use case.

---

## Tier 2: Viable But Weaker Go Story

### Nickel

**Go embedding**: Weak. Nickel is written in Rust. No native Go library. Would
require CGo bindings or subprocess execution. The [nickel-lang](https://nickel-lang.org/)
project has no Go SDK.

**Expressiveness**: Nickel's contract system is purpose-built for "validated
configuration" which maps well to Cell's checks:

```nickel
let Cell = {
  given | Array String,
  yield | Array String,
  body | String | optional,
  check | Array String | default = [],
} in
{
  compose = {
    given = ["topic.subject"],
    yield = ["poem"],
    body = m%"Write a haiku about «subject»"%,
  }
}
```

**Gains**:
- Contracts (runtime type checking) align with Cell's check/check~ system
- Merge system for composing configurations
- Designed specifically for "programmable configuration"

**Losses**:
- No Go embedding — dealbreaker for the current architecture
- Small community, less battle-tested than Starlark/Lua
- Rust dependency would complicate the build

**Fit**: High conceptually, low practically. If Cell's runtime were in Rust,
Nickel would be a strong contender.

**Verdict**: Skip for now. Revisit only if Cell moves to a Rust runtime.

---

### Dhall

**Go embedding**: Weak. Dhall is written in Haskell. There's a
[dhall-golang](https://github.com/philandstuff/dhall-golang) but it's
unmaintained (last commit 2022, doesn't support latest Dhall spec). Would need
the Haskell binary as a subprocess.

**Expressiveness**: Dhall's selling point is total, terminating, typed
configuration:

```dhall
let Cell = { given : List Text, yield : List Text, body : Optional Text }
in
{ compose = {
    given = ["topic.subject"],
    yield = ["poem"],
    body = Some ''
      Write a haiku about «subject».
    ''
  }
}
```

**Gains**:
- Guaranteed termination (total language) — interesting parallel with Cell's max bounds on recur
- Strong type system with imports
- Immutable by design

**Losses**:
- Dead Go library. Subprocess execution adds latency and complexity.
- Dhall's type system is more powerful than needed
- Small community, niche adoption
- Haskell runtime dependency

**Fit**: Medium. The totality guarantee is philosophically aligned with Cell's
bounded recursion. But the practical embedding story is too weak.

**Verdict**: Skip. The Go story is dead.

---

### HCL (HashiCorp Configuration Language)

**Go embedding**: Excellent. [hashicorp/hcl](https://github.com/hashicorp/hcl) is
the canonical pure-Go implementation. Used in Terraform, Packer, Vault, Consul.
Extremely mature and battle-tested.

**Expressiveness**:

```hcl
cell "compose" {
  given = ["topic.subject"]
  yield = ["poem"]

  body = <<-EOT
    Write a haiku about «subject». Follow 5-7-5 syllable structure.
  EOT

  check = ["poem is not empty"]
}
```

HCL's block syntax is actually quite close to Cell's current syntax! The
`cell "compose" { ... }` pattern mirrors `cell compose` + indented body.

**Gains**:
- Heredoc strings (`<<-EOT`) for prompt bodies
- Block-structured syntax familiar from Terraform
- Variable interpolation (`${var.name}`) — could replace guillemets
- Functions for computed values
- Extremely mature Go library, used in production everywhere

**Losses**:
- HCL is designed for infrastructure, not computation graphs
- No built-in concept of DAGs, dependencies, or execution order
- HCL's `depends_on` is a Terraform concept, not an HCL concept
- Variable interpolation syntax (`${...}`) clashes with prompt text where
  `${...}` might appear literally
- BUSL license on newer HashiCorp tools (though HCL itself is MPL-2.0)

**Fit**: Medium. HCL's syntax is surprisingly close to what Cell already looks
like. But HCL is a flat key-value configuration language at heart — it has no
notion of cell kinds, effect levels, or dataflow semantics. You'd be using HCL
as a glorified parser and throwing away everything that makes HCL HCL.

**Verdict**: The syntax match is tempting, but HCL adds the least value of any
option here. If the only goal is "don't maintain a parser," HCL works. But it
brings nothing that helps with Cell's actual hard problems.

---

### Pkl (Apple)

**Go embedding**: Weak. Pkl is written in Kotlin/JVM. There's a
[pkl-go](https://github.com/apple/pkl-go) library but it works by running the
Pkl evaluator as a subprocess (requires JVM). Not a native Go library.

**Expressiveness**:

```pkl
class Cell {
  given: Listing<String>
  yield: Listing<String>
  body: String?
  check: Listing<String>?
}

compose: Cell = new {
  given { "topic.subject" }
  yield { "poem" }
  body = """
    Write a haiku about «subject».
    """
}
```

**Gains**:
- Rich type system with classes, type constraints, generics
- Multi-line string literals
- Built-in validation via type constraints
- Good IDE support (JetBrains)

**Losses**:
- JVM dependency — heavyweight for a parser replacement
- Subprocess-based Go integration adds latency
- Young language (released 2024), still evolving
- Small community

**Fit**: Low. The JVM dependency is a dealbreaker for a Go tool that needs to
start fast and run lean.

**Verdict**: Skip. JVM subprocess model is too heavy.

---

## Tier 3: Dark Horses

### Expr (antonmedv/expr)

**Go embedding**: Excellent. [expr](https://github.com/expr-lang/expr) is a pure-Go
expression evaluator — small, fast, well-maintained. Not a full language but a
Go-native expression engine.

**Expressiveness**: Expr is an expression language, not a configuration language.
It can't define cell structures. But it could replace Cell's guard expressions
and check conditions:

```go
// Instead of parsing "settled = DONE" as custom syntax:
program, _ := expr.Compile(`settled == "DONE"`)
result, _ := expr.Run(program, env)
```

**Gains**:
- Type-safe expression evaluation in Go
- Could replace the bespoke guard expression parser
- Could make `check` conditions more expressive (arithmetic, string ops, regex)
- ~3k LOC, minimal dependency

**Losses**:
- Not a replacement for the cell DSL — only for expressions within it
- Different scope than the other candidates

**Fit**: High for a specific sub-problem. Expr wouldn't replace the `.cell`
parser but could handle guard expressions and check conditions, which are
currently the weakest part of the bespoke parser.

**Verdict**: Not a DSL replacement, but a strong candidate for improving the
expression sub-language within Cell. Worth adopting independently of the DSL
question.

---

### Tengo

**Go embedding**: Good. [d5/tengo](https://github.com/d5/tengo) is a pure-Go
scripting language, ~30k LOC, actively maintained. Faster than GopherLua in
benchmarks. Go-like syntax.

**Expressiveness**: Similar to Lua but with Go-like syntax:

```tengo
cell := func(name, opts) {
  return {name: name, given: opts.given, yield: opts.yield, body: opts.body}
}

compose := cell("compose", {
  given: ["topic.subject"],
  yield: ["poem"],
  body: `Write a haiku about «subject».`,
})
```

**Gains**:
- Pure Go, fast, small
- Go-like syntax may be more natural for the Go-centric team
- Compiled to bytecode — faster than interpreted Lua for complex programs

**Losses**:
- Smaller community than GopherLua
- Less well-known — harder to onboard contributors
- No significant advantage over Lua for this use case

**Fit**: Medium. A "Lua but Go-flavored" option. No compelling reason to prefer
it over GopherLua or Starlark.

**Verdict**: Exists, works, but doesn't differentiate enough.

---

### Risor

**Go embedding**: Good. [risor-io/risor](https://github.com/risor-io/risor) is a
pure-Go scripting language designed specifically for embedding in Go applications.
Modern, actively maintained, Go-like syntax with Python influences.

**Gains**:
- Designed for Go embedding from day one
- Built-in Go interop (call Go functions directly)
- Modern stdlib (HTTP, JSON, YAML, etc.)

**Losses**:
- Young project, smaller community
- More features than needed (HTTP client, etc.) — attack surface

**Fit**: Medium. Another "embeddable scripting for Go" option. No standout
feature for Cell's specific needs.

**Verdict**: Worth watching but not a clear winner over Starlark or Lua.

---

### YAML + Custom Tags

**Go embedding**: Trivial. YAML is not a language, but YAML with custom tags
and a Go struct decoder is a zero-dependency approach:

```yaml
- cell: compose
  given: [topic.subject]
  yield: [poem]
  body: |
    Write a haiku about «subject». Follow 5-7-5 syllable structure.
  check:
    - poem is not empty
```

**Gains**:
- Zero new dependencies (Go's YAML libraries are mature)
- Universally known syntax
- Trivial to parse into Go structs

**Losses**:
- YAML's gotchas (Norway problem, implicit typing, indentation sensitivity)
- No computation — can't parameterize or compose
- Strictly less expressive than the current bespoke DSL
- No comments-in-data (YAML comments are stripped by parsers)
- Arguably worse than the current `.cell` syntax for readability

**Fit**: Low. YAML is the wrong direction — it's less readable and less
expressive than what we have. The `.cell` DSL already reads better than YAML
for this domain.

**Verdict**: Skip. Going backwards.

---

### Tree-sitter Grammar

Not a language but a parsing approach. Write a tree-sitter grammar for `.cell`
syntax, use [smacker/go-tree-sitter](https://github.com/smacker/go-tree-sitter)
for Go integration.

**Gains**:
- Keep the current `.cell` syntax exactly
- Get syntax highlighting, IDE support, incremental parsing for free
- Error recovery (tree-sitter produces partial ASTs from broken files)
- Language-agnostic — the grammar works in any editor

**Losses**:
- CGo dependency (tree-sitter is C)
- Must write and maintain the grammar (similar effort to bespoke parser)
- Overkill for ~25 production cell programs

**Fit**: Medium. Doesn't change what can be expressed — only improves tooling.
Best value if Cell programs become a common authoring format.

**Verdict**: Orthogonal to the DSL question. Worth doing independently for editor
support, but doesn't solve the "should we replace the parser" question.

---

## Comparison Matrix

| Language | Go Embed | Expressiveness | Gains vs Bespoke | Readability | Fit |
|----------|----------|---------------|-----------------|-------------|-----|
| **Starlark** | ★★★ | ★★★ | Determinism, immutability, imports | ★★ | ★★★ |
| **Lua** | ★★★ | ★★★ | Computation, REPL, ecosystem | ★★ | ★★ |
| **CUE** | ★★☆ | ★★★ | Constraints, types, lattices | ★☆ | ★★ |
| **HCL** | ★★★ | ★★ | Mature parser, heredocs | ★★☆ | ★★ |
| **Jsonnet** | ★★★ | ★★☆ | Templates, imports, JSON output | ★★ | ★★ |
| **Expr** | ★★★ | ★ (expressions only) | Guard/check expressions | ★★★ | ★★★ |
| **Nickel** | ☆ | ★★★ | Contracts | ★★ | ★★★ |
| **Dhall** | ☆ | ★★☆ | Totality, types | ★★ | ★★ |
| **Pkl** | ☆ | ★★★ | Rich types, IDE | ★★ | ★☆ |
| **Tengo** | ★★☆ | ★★☆ | Speed, Go-like | ★★ | ★★ |
| **Risor** | ★★☆ | ★★☆ | Go interop | ★★ | ★★ |
| **YAML** | ★★★ | ★ | Zero deps | ★☆ | ☆ |

---

## The Real Question

The bespoke `.cell` parser is ~400 lines of Go. It handles everything Cell needs
today. The cost of maintaining it is low. What would justify replacing it?

**Arguments for replacement:**
1. **Modular composition**: `import` / `load()` for cell libraries. Today each
   `.cell` file is standalone. If Cell programs need to share cell definitions,
   an embedded language with imports wins.
2. **Computed definitions**: If cell programs need loops, conditionals, or
   parameterized factories ("generate 10 analysis cells for each input"),
   an embedded language wins.
3. **Expression richness**: Guard expressions and check conditions are currently
   limited to a fixed grammar. An expression evaluator (even just Expr) would
   make checks more powerful.

**Arguments against replacement:**
1. **Readability is Cell's superpower**. The `.cell` syntax reads like English.
   Every replacement adds syntax noise (braces, commas, quotes). For a language
   whose bodies are natural-language prompts, readability matters more than power.
2. **~400 lines is cheap**. The parser works, is tested, and handles edge cases.
   Adding a dependency to avoid maintaining 400 lines is not obviously a win.
3. **Cell programs are small**. The largest programs are <50 lines. The
   complexity ceiling where an embedded language starts paying off hasn't been hit.
4. **The hard problems are elsewhere**. Stem completion, guard-skip bottom
   propagation, oracle atomicity — these are runtime problems, not parser problems.
   A better parser doesn't help.

---

## Recommendation

**Keep the bespoke `.cell` parser.** It's Cell's competitive advantage. The
English-like readability is a feature, not a bug. None of the replacement
languages improve on it for programs under 50 lines.

**Two targeted improvements instead:**

1. **Adopt Expr for guard/check expressions** — replace the fixed guard grammar
   with a proper expression evaluator. This is the one area where the bespoke
   parser is genuinely limiting. Expr is ~3k LOC, pure Go, and solves the real
   problem (richer guard predicates and check conditions) without touching the
   rest of the syntax.

2. **Write a tree-sitter grammar** — for editor support (syntax highlighting,
   error recovery, go-to-definition). This is orthogonal to the parser question
   but high-value if Cell programs become a common authoring format.

**If Cell programs need composition later** (imports, shared definitions), revisit
Starlark. It has the strongest philosophical alignment (deterministic, immutable,
hermetic) and the best Go embedding. But don't add it until the need is proven.

---

## Appendix: Go Embedding Library Status

| Library | Go Purity | Stars | Last Release | License |
|---------|-----------|-------|-------------|---------|
| go.starlark.net | Pure Go | 2.4k | 2024 | BSD-3 |
| yuin/gopher-lua | Pure Go | 6.2k | 2024 | MIT |
| cuelang.org/go | Pure Go | 5.1k | 2024 (pre-1.0) | Apache-2.0 |
| google/go-jsonnet | Pure Go | 1.6k | 2024 | Apache-2.0 |
| hashicorp/hcl | Pure Go | 5.3k | 2024 | MPL-2.0 |
| expr-lang/expr | Pure Go | 6.1k | 2024 | MIT |
| d5/tengo | Pure Go | 3.5k | 2024 | MIT |
| risor-io/risor | Pure Go | 1.6k | 2024 | Apache-2.0 |
| apple/pkl-go | Subprocess | 0.2k | 2024 | Apache-2.0 |
| philandstuff/dhall-golang | Stale | 0.4k | 2022 | BSD-3 |
| nickel-lang (no Go) | N/A | 2.3k | 2024 | MIT |

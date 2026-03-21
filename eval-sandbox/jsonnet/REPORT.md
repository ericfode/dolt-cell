# Jsonnet Cell Language Bakeoff — Evaluation Report

## Files

| File | Compiles | Output |
|------|----------|--------|
| `haiku.jsonnet` | yes | `haiku.json` |
| `code-review.jsonnet` | yes | `code-review.json` |
| `village-sim.jsonnet` | yes | `village-sim.json` |
| `word-count.jsonnet` | yes | `word-count.json` |
| `cell-zero.jsonnet` | yes | `cell-zero.json` |

All files run with `~/go/bin/jsonnet <file>` and produce valid JSON.

---

## Design

A cell program is a JSON object with `program` (string name) and `cells` (array). Each cell has:

```
{
  name:    string,
  effect:  "pure" | "replayable" | "non_replayable",
  givens:  ["cell.field", ...],        // dependency declarations
  yields:  ["field", ...],             // output field names
  body:    <body descriptor>,          // see below
  checks:  [<check descriptor>, ...],
  stem?:   bool,                       // stem cell flag
  autopour?: string,                   // which yield field to autopour
  iterate?: { count, seed, state_field } // iterate cell descriptor
}
```

Body types:
- `{ type: "literal", value: <JSON> }` — hard literal, pure value
- `{ type: "soft", template: "...{{var}}..." }` — LLM prompt with interpolation
- `{ type: "compute", expr: <expression tree> }` — pure compute, replaces sql:

---

## What Worked Well

### Object model for cells
Jsonnet's objects map cleanly onto the cell data model. Named fields for `givens`, `yields`, `effect`, `body` are natural. A cell descriptor is readable JSON when manifested.

### Local functions as constructors
`hardLiteral`, `softCell`, `computeCell`, `autopourCell`, `stemCell`, `iterateCell` — these are Jsonnet local functions that produce cell descriptors. LLMs write calls to these constructors rather than raw objects. The ergonomics are good: named parameters (Jsonnet supports keyword arguments), sensible defaults, consistent shape.

```jsonnet
local compose = softCell(
  name="compose",
  givens=["topic.subject"],
  yields=["poem"],
  template="Write a haiku about {{subject}}...",
  checks=[{ type: "semantic", assertion: "poem follows 5-7-5" }],
);
```

This is readable. An LLM can generate it reliably.

### Template strings
`"Write a haiku about {{subject}}"` maps naturally to Jsonnet string concatenation. Variable interpolation (`{{var}}`) is a convention in the template — the runtime substitutes resolved givens. Jsonnet's multi-line strings (`|||...|||`) or concatenation chains both work.

### Pure compute at manifest time
When all inputs to a pure compute cell are literals (known at load time), Jsonnet can collapse the computation to a value immediately — no runtime needed. `word-count.jsonnet` demonstrates this: `std.length(std.split(std.stripChars(text, " \t\n"), " "))` runs during `jsonnet` invocation and returns `9` for the literal input.

### Expression trees for pure compute (when inputs are unknown)
When inputs come from upstream cells (not literals), computation must be deferred. The expression tree representation — `{ op: "call", fn: "split", args: [...] }` — is serializable JSON that a runtime can interpret. It's verbose but complete and unambiguous.

### Effect annotations
`effect: "pure" | "replayable" | "non_replayable"` carries through cleanly. The effect lattice is just data.

### Stem and autopour as flags
`stem: true` and `autopour: "field_name"` are clean boolean/string annotations on a cell. No special syntax needed.

---

## What Was Awkward or Impossible

### Functions cannot be serialized (the central problem)
Jsonnet's native functions cannot manifest to JSON. This is the core tension:

```jsonnet
// This FAILS at manifest time:
body: { type: "compute", fn: function(bindings) { total: std.length(...) } }
// Error: couldn't manifest function as JSON
```

Pure compute cells that depend on runtime-resolved givens cannot use Jsonnet functions in their body descriptors. The workaround — expression trees — is verbose and feels like writing bytecode by hand:

```jsonnet
// Instead of:
function(bindings) std.length(std.split(bindings["poem"], " "))

// You must write:
{ op: "call", fn: "length", args: [
    { op: "call", fn: "split", args: [
        { op: "get", binding: "compose.poem" },
        { op: "lit", value: " " }
    ]}
]}
```

This defeats one of Jsonnet's strengths (expressiveness). The expression tree approach is essentially a second language embedded in JSON.

### `then` and `else` are reserved keywords
When building expression trees with conditional nodes, `then` and `else` must be quoted as string keys:

```jsonnet
// FAILS:
{ op: "cond", pred: ..., then: ..., else: ... }

// Works but ugly:
{ op: "cond", pred: ..., "then": ..., "else": ... }
```

A minor issue, but it means the expression tree constructor signatures are slightly non-uniform.

### No iteration/recursion in Jsonnet itself
Jsonnet has no looping constructs (by design — it terminates). The `iterate` cell pattern (stem-like, threading state N times) cannot be expressed as Jsonnet execution. It must be a declarative descriptor:

```jsonnet
iterate: { count: 5, seed: "assemble.initial_state", state_field: "world_state" }
```

The runtime implements the fold; Jsonnet just describes it. This is honest but means the iteration semantics are invisible in the source — they're in runtime docs, not in the program.

### No shared library / imports across programs
Each `.jsonnet` file redeclares `hardLiteral`, `softCell`, etc. In a real deployment, these would live in a shared `cell.libsonnet` that each program imports:

```jsonnet
local cell = import 'cell.libsonnet';
local topic = cell.hardLiteral("topic", { subject: "..." });
```

This works in Jsonnet (imports are supported), but wasn't done here to keep each file self-contained for the bakeoff. In production, the helper library is essential.

### `std.objectFields` ordering is alphabetical
`hardLiteral` uses `std.objectFields(yieldValues)` to extract yield names from the value object. Jsonnet returns these in alphabetical order regardless of declaration order. For cells with many yield fields, the order of `yields` in the output may not match the order they appear in the value object. Cosmetic issue, not semantic.

### No `check~` (oracle/semantic check) first-class distinction
The reference uses `check~` for semantic assertions (LLM-verified) vs `check` for deterministic. In Jsonnet, both are just objects in a `checks` array with a `type` field. The distinction is preserved (`type: "semantic"` vs `type: "deterministic"`) but the visual cue of `~` is lost. LLMs authoring checks must remember the convention.

### Metacircularity is structural, not executional
The cell-zero evaluator can be fully described in Jsonnet. The Jsonnet output is a valid cell program that — if handed to a runtime implementing the cell semantics — would evaluate programs via autopour. But Jsonnet itself cannot execute the description. The language is purely declarative; the loop, the observe primitive, the `:more` signal, and fuel tracking all live in the runtime.

This is the correct position for a data format language. It just means Jsonnet alone cannot close the metacircular loop.

---

## Rating: LLM Authoring (1–5)

**3 / 5**

### Reasons for the score

**Up (+):**
- Constructor functions (`softCell(...)`) are highly LLM-friendly. Named parameters, clear structure, no boilerplate per field.
- Templates are just strings — easy to write and read.
- The JSON output is machine-readable and matches the cell data model well.
- Effect annotations, checks, givens/yields all map naturally.

**Down (−):**
- The function-cannot-manifest limitation forces expression trees for pure compute. Expression trees are annoying to write and to read. An LLM authoring a non-trivial pure compute cell will likely make mistakes in the tree structure.
- No native iteration — the `iterate` descriptor is a convention that LLMs must remember and a runtime must implement.
- The shared library problem means each file is longer than it needs to be. LLMs tend to copy patterns; without a shared import, they copy the entire helper block.
- The distinction between "Jsonnet computes this now" (manifest-time pure cells) vs "the runtime computes this later" (deferred pure cells) is subtle and easy to confuse.

**Comparison to the reference cell syntax:** The reference `.cell` format scores ~4/5 for LLM authoring because the syntax is purpose-built (guillemets for interpolation, `given`/`yield` keywords, `iterate`, `check~`). Jsonnet is a general-purpose config language adapted to this task; the adaptation is workable but not frictionless.

---

## Metacircularity: Is It Achievable?

**Partially.** The cell-zero evaluator is fully representable as a Jsonnet program that produces a valid cell program JSON. A runtime that implements the cell semantics (pour, observe, autopour, stem, fuel) would correctly execute that JSON as a metacircular evaluator.

What Jsonnet adds beyond the reference:
- The metacircularity analysis is embedded as data in the program output (`metacircularity` field in `cell-zero.json`), making the self-evaluation termination argument machine-readable.
- Pure cells with literal inputs collapse to values at Jsonnet load time — Jsonnet is itself a partial evaluator for the pure fragment.

What Jsonnet cannot do:
- Execute the evaluator. The `observe` primitive, `:more` signal, and autopour firing are runtime semantics. Jsonnet produces a description; execution requires the ct runtime.
- Express the fuel counter or other runtime invariants as static program properties.

The self-evaluation termination argument holds in Jsonnet exactly as in the reference: if cell-zero pours itself, the copy's `request` cell has no source for `program_text`, so the dependency is unsatisfied and the copy is inert. No fuel needed for self-application; fuel is only needed for chained autopour (A pours B pours C...).

---

## Best Syntax (Jsonnet's strength)

Soft cell construction is clean and expressive:

```jsonnet
local analyze = softCell(
  name="analyze",
  givens=["source.code"],
  yields=["findings"],
  template=(
    "Review this Python function for correctness, performance, and style:\n\n" +
    "{{code}}\n\n" +
    "Identify all bugs, edge cases, and potential improvements. " +
    "Format each finding as a bullet point starting with \"- \"."
  ),
  checks=[
    { type: "deterministic", expr: "bullet_count(findings) >= 3" },
  ],
);
```

This is readable, writable by LLMs, and the output JSON is unambiguous. The program graph (`cells: [source, analyze, countFindings, prioritize]`) makes the DAG order explicit and scannable.

Manifest-time pure compute (when inputs are literals) is also clean:

```jsonnet
local wordCountNow = std.length(
  local words = std.split(std.stripChars(inputText, " \t\n"), " ");
  if inputText == "" then [] else words
);
```

This runs during `jsonnet` invocation. No runtime needed. Pure cells over literal inputs are collapsed immediately — a real strength for static analysis and validation.

---

## Worst Syntax (Jsonnet's weakness)

Deferred pure compute (expression trees) is the worst part:

```jsonnet
// The status cell's cond tree — equivalent to 8 lines of readable code:
expr=obj([
  fieldExpr("state",
    letExpr(
      [
        bindExpr("cells",    call("observe", [get("evaluator.name"), lit("cells")])),
        bindExpr("total",    call("length", [get("cells")])),
        bindExpr("bottoms",  call("length", [call("filter", [lit("is_bottom"), get("cells")])])),
        bindExpr("unfrozen", call("length", [call("filter", [lit("is_not_frozen"), get("cells")])])),
      ],
      cond(eq(get("total"), lit(0)), lit("not_found"),
        cond(gt(get("bottoms"), lit(0)), lit("error"),
          cond(eq(get("unfrozen"), lit(0)), lit("complete"),
            lit("running"))))
    )
  ),
]),
```

This is expressing a `let + cond` chain that would be 4 lines in any real language. The expression tree balloons it to 20+ lines of nested constructor calls. The Zygo reference writes this naturally:

```clojure
(let [cells (observe name :cells)
      total (len cells) ...]
  (cond (= total 0) "not_found" ...))
```

Jsonnet cannot express deferred computation as native code — only as data encoding native code. This is the right tradeoff for a data format, but it's a genuine ergonomic cost for pure compute cells.

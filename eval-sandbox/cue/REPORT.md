# CUE Language Bakeoff — Evaluation Report

**Language**: CUE v0.16.0
**Evaluator**: Sussmind
**Date**: 2026-03-21
**Files**: cell_zero.cue, haiku.cue, code_review.cue, village_sim.cue, word_count.cue

---

## What Worked Well

### 1. Dependency graph via reference model

CUE's reference model maps cleanly to the cell DAG. When `compose` references
`topic.literal.subject`, CUE evaluates the reference at constraint-solve time.
The dependency is enforced structurally — if `topic` were undefined, `compose`
would fail. This is the strongest alignment between CUE and the cell language.

```cue
// topic is a hard literal
topic: #Cell & {
    effect: "pure"
    literal: { subject: "autumn rain on a temple roof" }
}

// compose depends on topic — the reference IS the dependency edge
compose: #Cell & {
    effect: "replayable"
    body: "Write a haiku about \(topic.literal.subject). Follow 5-7-5..."
}
```

The rendered body string proves the dependency was resolved. No runtime needed.

### 2. Effect lattice as a closed enum

The effect lattice maps directly to a CUE disjunction:

```cue
#Effect: "pure" | "replayable" | "non-replayable"
```

Any cell that assigns an invalid effect (`"database"`, `"magic"`) fails at
`cue eval` time with a type error. This is static effect checking for free.

### 3. Pure compute replacing sql:

The `sql:` bodies in the reference `.cell` files were doing string arithmetic.
CUE's `strings` package handles this natively and the results are proven values
at eval time — not promises that require a database to execute.

```cue
import "strings"

_lines: strings.Split(strings.TrimSpace(text), "\n")
_bullet_lines: [for l in _lines if strings.HasPrefix(strings.TrimSpace(l), "- ") {l}]
total: len(_bullet_lines)  // evaluates to 5 — not a query, a fact
```

### 4. Schema-as-workaround for functions

CUE has no user-defined functions. The workaround — defining a `#WordCounter`
schema and instantiating it via `& {}` unification — is idiomatic CUE and
surprisingly readable:

```cue
#WordCounter: {
    input: string
    _ws: strings.Fields(input)
    result: { words: len(_ws) }
}

haiku_counts: #WordCounter & { input: "autumn rain falls soft\n..." }
code_counts:  #WordCounter & { input: "def is_prime(n): ..." }
```

This is CUE's answer to parameterized computation. It works. It's verbose.

### 5. Program-as-data for autopour

The `autopour` primitive in the cell language means "yield a program struct
that the runtime will pour." CUE can describe this as a `#Program` value:

```cue
evaluator_yields: {
    evaluated: #Program & {
        name: "haiku-autopoured"
        cells: [{ name: "topic", effect: "pure", ... }, ...]
    }
}
```

The struct IS the program. CUE validates it against `#Program`. The runtime
receives it. This is a clean split of concerns: CUE validates structure,
the runtime handles execution.

---

## What Was Awkward or Impossible

### 1. Soft cells cannot be rendered when givens are from other soft cells

CUE can interpolate hard literal values into prompt bodies. It cannot
interpolate runtime values (LLM outputs). The workaround — `_demo_*`
constants — makes the computation evaluable but requires the demo value
to be manually specified. Every soft cell with soft-cell givens needs a stub.

This is inherent: CUE is a constraint language evaluated at spec time.
LLM outputs do not exist at spec time. There is no fix.

### 2. No iteration / stem cells

The `iterate day 5` primitive — run a cell N times, threading state — is
inexpressible in CUE. CUE has no:
- loops
- recursion
- mutation
- continuation

The workaround is static unrolling (define `day_0`, `day_1`, ..., `day_N`
where each references the previous). This works for fixed N but:
- loses the `iterate` primitive's clean semantics
- doesn't generalize (N must be known at spec time)
- produces verbose, repetitive code

This is the deepest mismatch. The cell language's iterate is fundamentally
about time-stepped stateful computation. CUE is fundamentally stateless.

### 3. No user-defined functions

The lack of `def/fn` is the most concrete daily friction. Every time you
want to reuse a computation (count words, parse bullets, compute hash),
you must either repeat the code inline or use the `#Schema & {}` workaround.
The workaround works but adds conceptual overhead.

```cue
// You want: word_count(text)
// You get:
#WordCounter: { input: string; _ws: strings.Fields(input); result: { words: len(_ws) } }
my_count: (#WordCounter & { input: "hello world" }).result.words
```

### 4. Stem cells are annotation-only

`stem: true` in a CUE struct is just metadata. CUE has no way to express
"evaluate this cell repeatedly and pass the output back as input." The
perpetual evaluator pattern is completely opaque to CUE. We can document
what it does; we cannot describe what it is.

### 5. Check constraints are strings, not executable predicates

The cell language's `check` and `check~` annotations are either
deterministic assertions or semantic (LLM-evaluated) checks. CUE can list
them as strings but cannot execute them:

```cue
check: ["poem follows 5-7-5 syllable structure"]  // just a string
```

CUE does have real constraint expressions (`int & >=0`, `string & =~"^[A-Z]"`)
but these only cover structural/type constraints. Semantic checks
("the haiku has a kigo") are beyond CUE's type system.

### 6. The `»guillemet«` → `\(interpolation)` translation only works for literals

In the cell language, `«field»` in a body refers to a given at runtime.
In CUE, `\(cell.field)` works only when the value is concrete at eval time.
If `topic` is a soft cell, `compose.body` cannot interpolate `topic.poem`.

This is the key semantic gap: the cell language's body interpolation is
runtime-resolved; CUE's is compile-time-resolved.

---

## LLM Authoring Rating: 2/5

**Reasoning:**

CUE is precise and validated, but it fights the LLM authoring model at
several levels.

**Pro:**
- The schema `#Cell` gives a clear target. LLMs write valid CUE quickly.
- String interpolation for hard-literal deps is clean and natural.
- Type errors at `cue eval` give immediate feedback.
- Pure compute cells are genuinely better than `sql:` bodies.

**Con:**
- The `#Schema & {}` pattern for parameterized computation is opaque.
- An LLM writing a multi-step pipeline must manually track which givens
  are literals vs. soft-cell outputs and handle them differently.
- No functions means every reusable computation is a copy-paste affair
  or a schema instantiation with extra steps.
- Iteration (the most common pattern after simple pipelines) requires
  either annotation-only metadata or verbose static unrolling.
- The two-level model (CUE spec-time vs. cell runtime) is confusing:
  an LLM will naturally try to write `\(compose.poem)` in the critique
  body and be surprised when it fails because compose is soft.

An LLM can write correct CUE for simple programs (haiku, code review).
For programs with iteration, perpetual cells, or deep soft-cell dep chains,
CUE becomes a configuration language for describing a program rather than
a language for writing one.

---

## Metacircularity Assessment

**Can CUE express the cell language's metacircular evaluator? No, not fully.**

The cell language achieves metacircularity via `autopour`:
- A cell yields a program text
- The runtime pours it
- eval = pour

CUE can represent this as data:

```cue
evaluator: {
    autopour: true
    compute: { identity_law: "evaluated = program_text" }
}
```

But CUE cannot EXECUTE it. There is no `pour`, no `observe`, no `:more`.

**What CUE IS metacircular for**: CUE's own type system. A `#Cell`
definition is itself a CUE value. You can write CUE programs that describe
CUE programs. The `#Program: { cells: [...#CellDef] }` definition is
CUE describing itself. This is real metacircularity at the constraint level.

The gap: the cell language's metacircularity is about runtime evaluation
(a program that can pour other programs including itself). CUE's
metacircularity is about constraint description (a schema that constrains
values including other schemas). These are different kinds of metacircularity.

**Verdict**: CUE achieves schema-level metacircularity but not execution-level
metacircularity. For cell-zero specifically, CUE produces a valid, validated
description of the evaluator but cannot run it.

---

## Best Syntax: Pure Compute with Schema Reuse

```cue
import "strings"

// Define once as a schema
#WordCounter: {
    input:  string
    _words: strings.Fields(input)
    result: {
        count: len(_words)
        lines: len(strings.Split(strings.TrimSpace(input), "\n"))
        chars: len(strings.Replace(input, "\n", "", -1))
    }
}

// Instantiate for multiple inputs — the "function call" is unification
haiku_stats: (#WordCounter & { input: "autumn rain falls soft\na frog leaps" }).result
code_stats:  (#WordCounter & { input: "def is_prime(n): ..." }).result
```

This is clean, validated, and genuinely useful. The computed values (`count: 5`,
`lines: 2`) appear in `cue eval` output as proven facts, not promises.

---

## Worst Syntax: Soft Cell with Soft-Cell Givens

The core loop of a pipeline — one LLM cell feeding the next — is where CUE
breaks down. The reference syntax:

```cell
cell critique
  given compose.poem
  given count-words.total
  ---
  Critique this haiku (word count: «total»):
  «poem»
  ---
```

Becomes, in CUE, a mix of rendered and placeholder values:

```cue
// critique's body — total is rendered (from pure compute)
// but poem is a placeholder (from soft cell — not known at spec time)
critique: #Cell & {
    body: """
        Critique this haiku (word count: \(count_words.compute.total)):

        \(_demo_poem)   // <-- must provide demo value manually

        Evaluate: ...
        """
}
```

The asymmetry is confusing: `count_words.compute.total` resolves to `13` because
count_words is a pure cell. But `compose.poem` is soft — it doesn't exist at
spec time. The LLM must manually know which givens are "spec-time resolvable"
and which need `_demo_` stubs. This is a leaky abstraction.

---

## Summary Table

| Cell Feature        | CUE Status     | Notes |
|---------------------|----------------|-------|
| Hard literal cell   | Full           | Clean struct with concrete values |
| Effect annotation   | Full           | Closed enum, statically checked |
| DAG dependencies    | Full           | Reference model IS the DAG |
| Prompt rendering    | Partial        | Only works for literal-valued givens |
| Pure compute (sql:) | Full           | `strings.*` stdlib, arithmetic, list comprehensions |
| Check constraints   | Annotation only| Structural checks work; semantic checks are strings |
| Autopour (data)     | Full           | `#Program` struct is valid program-as-data |
| Autopour (execute)  | None           | No pour primitive |
| Stem / iterate      | None           | No loops, no recursion, no time |
| Observe primitive   | None           | No runtime query |
| Metacircularity     | Partial        | Schema-level yes; execution-level no |

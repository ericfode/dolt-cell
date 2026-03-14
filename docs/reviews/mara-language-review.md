# Adversarial Review: Cell REPL Design

**Reviewer**: Mara (Language Implementer -- 15 years: Racket, Tree-sitter, Clojure reader)
**Document under review**: `docs/plans/2026-03-14-cell-repl-design.md`
**Supporting specs**: `cell-v0.2-spec.md`, `cell-minimum-viable-spec.md`, `cell-computational-model.md`
**Date**: 2026-03-14
**Verdict**: The design has a compelling vision but contains at least five structural problems that will block implementation. Several are disguised as "open questions" when they are actually load-bearing gaps.

---

## 1. "Text First, Syntax Second" Is a Mirage

The design doc (lines 41-43) claims:

> The first Cell programs are just text -- natural language descriptions of cells, their dependencies, and their yields. No turnstyle operators required.

And Phase 2 (lines 128-131) illustrates:

> "Here are three cells. Cell A produces a list of numbers. Cell B sorts them. Cell C verifies the sort is correct. B depends on A, C depends on B."

This is a toy example. It works precisely because the program is trivial. Scale it to anything resembling the v0.2 spec's actual feature set and the claim collapses.

### 1.1 Ambiguity in natural language programs

The v0.2 spec defines at least 12 syntactic features in the kernel alone (spec lines 43-55). The natural language equivalent of each must be unambiguously extractable by the LLM during `mol-cell-pour`. Consider what the LLM has to recover from prose:

- **Cell boundaries**: Where does one cell end and another begin? In prose, there is no delimiter. "Cell B sorts them" -- is "them" a given reference or a pronoun?
- **Dependency direction**: "C verifies the sort is correct" -- does C depend on B, or does C depend on A and B? The word "the sort" is anaphoric. A parser resolves anaphora by asking "what is the antecedent?" An LLM guesses.
- **Yield names**: The prose says "a list of numbers." Is the yield called `list`, `numbers`, `items`, `data`? The LLM will invent a name. A second LLM invocation will invent a different name. Downstream cells that reference `A->items` will break if the name was actually `A->numbers`.
- **Oracle assertions vs. cell body**: "Cell C verifies the sort is correct" -- is C a cell with a `∴` body that does verification, or is this an oracle (`⊨`) on cell B? The ambiguity is fundamental because the v0.2 spec (lines 375-377) says oracles ARE cells. The LLM has to decide which one the author intended.
- **Optional dependencies**: How does prose express `given?` vs `given`? "C can optionally use D's output" -- is that `given?` or a guard clause?
- **Bottom propagation**: How does prose express `⊥` semantics? "If compression fails, stop" -- is that `⊥` or an exhaustion handler?

The v0.2 spec defines ~25 features (spec line 400). Each needs an unambiguous prose encoding. The claim that "syntax is the residue of crystallization" (design doc line 148) reverses the actual dependency: you need to know what you are parsing *before* you can parse it. The crystallization story assumes the LLM consistently maps diverse natural language phrasings to the same bead structures. This assumption has no evidence behind it and is falsifiable with a single counterexample: two phrasings of the same program producing different DAGs.

### 1.2 Reproducibility is dead on arrival

The design doc (line 67) says the document IS the state. The v0.2 spec (line 77) says content addressing: "Hash the document = hash the state." But if the program is prose, hashing the prose gives you a content address for the *text*, not for the *program*. Two different prose descriptions of the same program will hash differently. The same prose description parsed twice may produce different bead structures. Content addressing requires a canonical form. Prose has no canonical form.

### 1.3 What "text first" actually means

What the design is really proposing is that the LLM acts as a parser with no grammar. This is not "text first" -- it is "no parser." Every classical language went through the phase of informal specification before formal grammar, and the lesson is universal: without a grammar, you cannot test conformance, you cannot write a second implementation, and you cannot reason about what programs mean.

**Fix**: Start with a minimal formal syntax from day one. Even if it is just `cell:`, `given:`, `yield:`, `body:`, `oracle:` as YAML-like keywords. The LLM can still read prose and emit this format -- that is a fine use of the LLM. But the intermediate representation must be structured. `mol-cell-pour` should accept a structured format (even if it is JSON), not raw prose. The LLM call to *interpret* prose into that format can be a separate, explicit step that is itself testable.

---

## 2. The Parser Crystallization Chicken-and-Egg

The design doc Phase 4 (lines 143-155) describes the parser as a soft cell that crystallizes:

> A cell whose job is to read text and produce beads. Initially soft -- the LLM reads the input text and figures out what cells/deps/yields to create. As syntax patterns stabilize, this cell crystallizes.

This has a circularity the design acknowledges (line 304-306) but does not resolve:

> If the parser is a Cell program, what parses the parser? (Answer: the LLM, initially. But this needs to be made explicit in the bootstrap sequence.)

"Needs to be made explicit" is an understatement. Let me spell out the dependency chain:

1. To run any Cell program, you need `mol-cell-pour` (the loader).
2. `mol-cell-pour` needs to parse the program text into beads.
3. In Phase 4, the parser is itself a Cell program (a soft cell).
4. To run the parser cell, you need `mol-cell-pour` to load it.
5. To load it, you need a parser.
6. GOTO 4.

The bootstrap doc (line 305) says "the LLM, initially." But that just pushes the question back one level: what is the *specification* of correct parsing that the LLM should follow? If the spec is the v0.2 document, then the parser is an implementation of a formal grammar -- just a bad one (non-deterministic, untestable, unreproducible). If the spec is "whatever the LLM thinks is right," then there is no correctness criterion and crystallization toward a deterministic parser is undefined.

### 2.1 You cannot crystallize without a test oracle

Crystallization (v0.2 spec lines 288-300) replaces `∴` with `⊢=`. The oracle on the soft cell becomes a contract on the hard cell. For the parser cell, the oracle would be something like:

```
⊨ parse(text) produces the same bead structure as the LLM would
```

But "the same bead structure as the LLM would" is not a deterministic oracle -- it requires an LLM call to evaluate. You cannot crystallize a cell whose oracle is itself semantic, unless you first crystallize the oracle. For the parser, the oracle IS the grammar. You need the grammar to test the parser. You need the parser to run programs. This is not a chicken-and-egg -- it is a chicken-and-egg-and-rooster, all mutual.

### 2.2 Grammars are not optional for language implementation

I have built parsers for a living. Here is what I know: you do not discover a grammar empirically. You design it. A grammar is a contract between the language author and the language user. Without it, you have a pidgin -- mutually intelligible only through shared context, not shared rules.

The design doc's vision of syntax "emerging from usage" (line 148) is attractive as metaphor but is not how languages work. Syntax emerges from *constraints*: the parser's capabilities, the author's ergonomic choices, the interaction between precedence and associativity. These are design decisions, not observations.

**Fix**: Write a PEG or EBNF grammar for the Cell kernel syntax. It can be small -- 20-30 rules. Implement the parser as a Go function (or a Tree-sitter grammar) that `mol-cell-pour` calls. The parser is Layer 0 alongside the runtime formulas. It is hard from day one. The LLM's job is not to parse -- it is to *translate* prose into Cell syntax, which the parser then verifies. This cleanly separates concerns: translation is soft (LLM), parsing is hard (grammar).

---

## 3. The `⊢=` Evaluator Is Unimplemented and Unspecified

The v0.2 spec (lines 319-365) defines ~40 primitives for the `⊢=` expression language. The minimum-viable spec (lines 125-133) slims this to ~15. Either way, this is a non-trivial expression evaluator: arithmetic, string operations, list operations, field access, binding, conditionals, higher-order functions (`filter(list, predicate)`, `map(list, fn)`).

The design doc (line 82) says:

> Hard cells (`⊢=`): Evaluate deterministic expression locally. No LLM needed.

"Locally" where? What evaluates `⊢= count <- len(split(text, " "))`? There are exactly three options:

### 3.1 Option A: A Go function

The evaluator is a Go function that parses and evaluates the `⊢=` expression language. This requires:
- A parser for the expression language (tokenizer, AST, precedence rules)
- An interpreter or compiler for ~15-40 built-in functions
- A type system (or at least type coercion rules) for the values
- Error handling for malformed expressions

This is a real programming language implementation. It is not a formula. It is not simple. The v0.2 spec includes `filter(list, predicate)` and `map(list, fn)` (line 346) -- these take *predicates and functions as arguments*. That means the expression language has lambdas or closures, even if unnamed. The spec does not acknowledge this.

### 3.2 Option B: An LLM call

Defeats the purpose. If `⊢=` cells call the LLM, they are not deterministic. The entire crystallization story (hard vs. soft) collapses. This is not a viable option.

### 3.3 Option C: A formula

The design doc says formulas are "deterministic TOML formulas" (line 119). If the `⊢=` evaluator is a formula, then the formula engine must be able to evaluate arbitrary expressions with ~15 built-in functions, binding, conditionals, and list comprehensions. That makes the formula engine a programming language runtime. The design doc does not mention this.

### 3.4 The `map` and `filter` problem

The v0.2 spec (line 346) lists:
```
filter(list, predicate), map(list, fn)
```

What is `predicate` here? What is `fn`? If these are lambda expressions, the `⊢=` language is not "just expressions" -- it is a functional programming language with anonymous functions. The spec provides no syntax for lambdas. The minimum viable spec (line 130) drops `map` and `filter` from the kernel, which is wise, but the v0.2 spec still has them and any implementation will eventually need them.

Even the kernel's `if cond then a else b` (min-spec line 133) introduces branching into the expression language. Combined with binding (`name <- expression`), you have a Turing-complete expression language (depending on recursion availability). The spec does not address whether `⊢=` expressions can be recursive.

**Fix**: Define the `⊢=` expression language as a proper language. Write a grammar. Specify the type system (are values dynamically typed? is there coercion?). Decide whether lambdas exist. If they do, specify their syntax. Implement the evaluator as a Go function in Layer 0, alongside the parser. Call it what it is: an embedded expression language, not "deterministic evaluation."

---

## 4. Yield Type Safety Is Absent

The design doc (line 225) says yields are stored as bead metadata (JSON). The v0.2 spec says typed values flow through the graph. But nowhere does any document define what types yields can have, how type mismatches are detected, or what happens when cell A yields a string and cell B expects a list.

### 4.1 The JSON impedance mismatch

JSON has six types: string, number, boolean, null, array, object. The `⊢=` expression language operates on values with more structure: lists (with element types), field-bearing records (with named fields), and predicates. When a yield is stored as JSON:

- `yield count` -- is this `{"count": 42}` or `{"count": "42"}`? The difference matters for `⊢= count > 10`.
- `yield items` -- is this `{"items": [1,2,3]}` or `{"items": "[1,2,3]"}`? An LLM producing a string representation of a list is a common failure mode.
- `yield proof[]` -- the `[]` suffix (v0.2 spec line 483) implies a list type. But JSON has no typed arrays. `[1, "two", true]` is a valid JSON array.

### 4.2 Soft cells produce untyped output

When a soft cell (`∴`) evaluates via LLM, the output is text. `mol-cell-freeze` (design doc line 91) writes yield values to bead metadata. Who converts the LLM's text output into typed JSON? The spec says nothing about this. If the LLM produces `"42"` (a string) and the downstream `⊢=` cell does `count + 1`, does the evaluator coerce? Fail? Silently produce `"421"`?

### 4.3 The oracle typing gap

Oracles check properties of tentative output, but the v0.2 spec (line 382) shows oracles like:
```
⊨ result = 55                    -- deterministic (exact value check)
```

What type is `55`? What type is `result`? If `result` came from an LLM as the string `"55"`, does `= 55` match? This is the classic loose-vs-strict equality problem that every dynamically-typed language has had to resolve, and Cell has not even acknowledged it exists.

### 4.4 Cross-cell type contracts

The spec says `given other-cell->field` creates a dependency. But there is no mechanism to declare that cell A's `yield x` should be a number, or that cell B's `given A->x` expects a number. The `yield` syntax (v0.2 spec line 83) provides no type annotations. The `given` syntax provides no type constraints. Types are checked only if the downstream cell's body or oracles happen to fail -- which is a runtime error, not a type error.

**Fix**: Add optional type annotations to yields: `yield count : number`, `yield items : list[string]`. Make `mol-cell-freeze` validate that frozen values match declared types. When a soft cell produces output, require the LLM to emit structured JSON conforming to the yield type schema. This is a solved problem -- LLMs can output JSON schema-conforming responses when asked. Without this, every Cell program of non-trivial size will suffer from type confusion at cell boundaries.

---

## 5. The Metacircular Bootstrap Is Genuinely Circular

The design doc Phase 5 (lines 157-166) says:

> Cell-zero as a text document describing the eval loop. The LLM reads it, follows it, using runtime formulas as tools.

The computational model (lines 37-39) says:

> Cell-zero is a `.cell` file. It is a Cell program, like any other. But it provides the evaluation kernel.

And then (lines 68-71):

> In Cell, cell-zero is the real implementation. The LLM reads cell-zero.cell and follows its instructions.

This creates a genuine dependency cycle, not a philosophical one:

### 5.1 The cycle spelled out

```
cell-zero.cell  -- is a Cell program
    |
    needs: mol-cell-pour to load it into beads
    needs: mol-cell-eval to evaluate its cells
    needs: mol-cell-freeze to freeze its yields
    |
    provides: the eval loop that mol-cell-eval implements
    provides: the freeze logic that mol-cell-freeze implements
```

Cell-zero defines the evaluation kernel. The runtime formulas implement the evaluation kernel. Cell-zero is loaded and run by the runtime formulas. The formulas are supposed to be "the calculator buttons" (design doc line 37) that the LLM presses while following cell-zero. But cell-zero tells the LLM WHAT buttons to press. So:

- Without cell-zero, the LLM does not know the evaluation algorithm.
- Without the formulas, cell-zero cannot execute.
- Without the LLM, neither cell-zero nor the formulas do anything.

### 5.2 This is not like Scheme's metacircular evaluator

The design doc and computational model repeatedly invoke the Scheme analogy (comp-model lines 58-66). But there is a critical difference. In Scheme, the metacircular evaluator is a *demonstration* that Scheme is expressive enough to describe itself. The actual Scheme implementation is a C program (or assembly, or whatever). The metacircular evaluator runs ON TOP of a real evaluator.

In Cell, the claim (comp-model line 71) is that cell-zero IS the real implementation. There is no "real evaluator underneath" -- the LLM is the substrate. But the LLM needs instructions (cell-zero) to know what to do. And cell-zero needs to be parsed and loaded to be read. The design doc's answer is "the LLM just reads the text" -- but "just reads" is an eval loop. You are implementing eval by assuming eval.

### 5.3 Where the cycle actually resolves

The design doc's Phase 1-5 bootstrap sequence (lines 118-166) does gesture toward a resolution: the runtime formulas (Phase 1) are Go code, not Cell programs. They are the "real implementation underneath." Cell-zero (Phase 5) is then a description of what those formulas do, expressed in Cell syntax.

If this is the intent, then say it plainly: **the Go formulas are the real evaluator. Cell-zero is a specification document that describes what the formulas do, expressed in Cell syntax. It is metacircular in the sense that it describes itself, but it is not self-hosting in the sense that it replaces the formulas.**

But the computational model explicitly contradicts this (comp-model lines 68-71):

> In Cell, cell-zero is the real implementation. The LLM reads cell-zero.cell and follows its instructions. Cell-zero IS the evaluator, running on the semantic substrate.

You cannot have it both ways. Either the Go formulas are the real evaluator (in which case cell-zero is documentation), or cell-zero is the real evaluator (in which case you have an unresolved circularity). Pick one and state it clearly.

**Fix**: Acknowledge that the Go formula set IS the evaluator. Cell-zero is a Cell-language description of the evaluator's behavior -- useful for self-documentation, for testing formula correctness against a specification, and for the metacircular elegance of a language that can describe itself. But it is not the thing that runs. The formulas run. Cell-zero describes what they should do.

---

## 6. Additional Language Implementation Concerns

### 6.1 Guard clause evaluation order

The v0.2 spec (lines 173-178) says guards are evaluated after all `given` inputs are frozen. But guards use the `⊢=` expression language (line 213), which can reference frozen values. If guard evaluation has side effects (binding via `<-`), or if guards on different cells reference each other's skip/proceed status, the evaluation order matters. The spec says "if ANY guard is false: the cell is skipped" but does not specify whether guards are evaluated left-to-right, all-at-once, or short-circuit. For a single cell this may not matter, but consider two cells with mutually-referencing guards -- each checking the other's skip status. The spec does not address this and confluence may not hold.

### 6.2 Wildcard dependency resolution timing

The v0.2 spec (lines 117-122) says wildcard dependencies resolve against "all cells in the current graph whose names match the pattern" and "the cell becomes ready when ALL matching cells have frozen the referenced field." But the match set can change (line 147): "Under `⊢∘` evolution loops, the match set may change between iterations."

This breaks a critical assumption: readiness is supposed to be monotonic. Once a cell's inputs are bound, it stays ready. But if the wildcard match set grows (a new cell `experiment-3` is spawned), a cell that was ready (all of `experiment-0`, `experiment-1`, `experiment-2` frozen) is now NOT ready (`experiment-3` is not frozen). This violates monotonicity of the ready set. The spec does not address this.

### 6.3 The `eval()` function in proof-carrying examples

The v0.2 spec (line 490) and the computational model (line 369) both use `eval(lhs, x)` in a `⊢=` body:

```
⊢= holds <- eval(lhs, x) == eval(rhs, x)
```

But `eval` is not in the list of valid `⊢=` primitives (spec lines 330-353). This is the same "undefined function" problem that the spec identifies in programs 19, 23, 24, 25 (spec line 323). The spec's own canonical example violates its own rules. Either `eval` needs to be added to the primitive set (making `⊢=` significantly more powerful -- it can now evaluate symbolic expressions), or the proof-carrying example needs to be rewritten.

### 6.4 The `⊢=` expression language lacks a formal semantics

The spec lists primitives (lines 330-353) but provides no evaluation rules. What is the evaluation order? Is it strict or lazy? What happens on division by zero? What does `sort(list, key)` do when `key` is ambiguous? What does `matches(s, pattern)` return -- a boolean, a match object, a list of groups? What regex flavor does `matches` use?

Every one of these questions will arise during implementation. Without formal semantics, implementors will make ad hoc choices that diverge from each other. If there is ever a second implementation of Cell (which the computational model contemplates with "substrate independence," comp-model line 76), the two implementations will disagree on edge cases.

### 6.5 Oracle claim cells and graph pollution

The v0.2 spec (lines 375-377) says "every `⊨` assertion is syntactic sugar for a claim cell." The computational model (lines 106-111) says cell-zero spawns claim cells. The design doc (lines 84-88) says `mol-cell-oracle` spawns oracle claim beads. A program with 10 cells and 3 oracles each will produce 30 claim cells. Under retry (max 3 attempts), up to 90 claim cells for 10 actual cells.

These claim cells are in the graph. They have bead IDs. They consume storage. The design doc does not specify:
- Are claim cells visible to the user? (If so, they pollute the DAG visualization.)
- Are claim cells garbage-collected after oracle resolution?
- Do claim cells have their own oracles? (If so, infinite regress.)
- Can claim cells produce `⊥`? (What does it mean for an oracle check to have no value?)

### 6.6 Non-termination is underspecified

The v0.2 spec (line 71) says "Cell programs do not terminate by design." The design doc (line 299) asks "When does a Cell molecule end?" and suggests quiescence. But quiescence (no ready cells) is not the same as completion. A program might quiesce because:
- All cells are frozen (done).
- Some cells are blocked by `⊥` (partially done).
- A wildcard dependency is waiting for cells that will never be spawned (deadlock).
- A guard clause prevented cells from entering the ready set (conditional skip).

The caller needs to distinguish these cases. The design doc's `mol-cell-status` (line 98) shows states but does not define how the caller knows the program is "done enough." For a REPL, this is critical: when does the REPL return a result?

---

## Summary of Required Fixes

| # | Problem | Severity | Fix |
|---|---------|----------|-----|
| 1 | "Text first" produces ambiguous, unreproducible programs | Blocking | Define a minimal structured format for `mol-cell-pour` input. LLM translates prose to format; format is what gets loaded. |
| 2 | Parser crystallization has no correctness criterion | Blocking | Write a PEG/EBNF grammar. Parser is Layer 0 (Go code), not a soft cell. |
| 3 | `⊢=` evaluator is unspecified and non-trivial | Blocking | Specify the expression language formally. Implement as a Go evaluator. Acknowledge `map`/`filter` require lambdas. |
| 4 | No type safety at yield boundaries | High | Add optional type annotations to `yield`. Validate on freeze. |
| 5 | Metacircular bootstrap is genuinely circular | High | Clarify that Go formulas are the real evaluator; cell-zero is a specification, not the implementation. |
| 6.1 | Guard evaluation order unspecified | Medium | Specify guards are evaluated independently per-cell, no cross-cell guard references. |
| 6.2 | Wildcard deps break ready-set monotonicity | Medium | Freeze the wildcard match set at pour time, or define re-resolution semantics explicitly. |
| 6.3 | `eval()` in spec examples is an undefined primitive | Low | Add `eval` to primitives or rewrite the example. |
| 6.4 | `⊢=` has no formal semantics | Medium | Write evaluation rules (strict, left-to-right, with defined error behavior). |
| 6.5 | Oracle claim cells pollute the graph | Medium | Define claim cell lifecycle: visibility, garbage collection, nesting limits. |
| 6.6 | Quiescence vs. completion undistinguished | Medium | Define completion predicates for `mol-cell-status`. |

---

## What the Design Gets Right

To be clear: the core vision is sound. Dual-substrate fusion (soft + hard cells in the same graph), oracle verification as first-class cells, and crystallization as progressive hardening -- these are genuinely novel ideas that address a real problem (how to build reliable systems on unreliable LLM substrates).

The formula toolkit (design doc lines 49-60) is the right abstraction. The observability story (lines 189-210) is thoughtful. The separation of "LLM provides judgment, formulas provide rigor" (line 37) is the correct division of labor.

The problems above are all solvable. They are implementation gaps, not architectural flaws. But they must be solved BEFORE the bootstrap sequence begins, not discovered during it. Language implementations that start without a grammar, a type discipline, and a formal semantics always pay the cost later -- and the cost compounds with every program written against the informal spec.

Start with the grammar. Everything else follows.

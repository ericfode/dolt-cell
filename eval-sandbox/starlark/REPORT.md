# Starlark Substrate Evaluation Report

**Date:** 2026-03-21
**Evaluator:** Sussmind
**Files:** cell_zero.star, haiku.star, code_review.star, village_sim.star, word_count.star

---

## Summary

Starlark can express cell programs. The structural mapping is clean for the core
cases (hard literal, soft cell, pure compute, multi-given pipelines). It fails
on two specific constructs — stem cells and iterate — not by being incapable of
expressing the semantics, but by requiring imperative code where the cell language
is declarative. An LLM authoring cell programs in Starlark would spend cognitive
effort on boilerplate that the cell language absorbs automatically.

**Rating: 2/5 for LLM authoring** (see detailed breakdown below).

---

## Cell Type Mapping

### Hard Literal (Pure)

```starlark
# .cell:
#   cell topic
#     yield subject = "autumn rain on a temple roof"

cell_topic = {
    "name": "topic",
    "effect": "pure",
    "givens": [],
    "yields": ["subject"],
    "body": None,
    "value": {"subject": "autumn rain on a temple roof"},
    "checks": [],
}
```

**Works well.** The dict representation is verbose but unambiguous. A cell is
obviously a dict; its structure is self-documenting. The `body=None, value={...}`
pattern for hard literals is readable once learned.

**Awkwardness:** 8 lines in Starlark vs 2 lines in .cell. The boilerplate-to-signal
ratio is about 4:1 for simple cells.

---

### Soft Cell (Replayable)

```starlark
# .cell:
#   cell compose
#     given topic.subject
#     yield poem
#     ---
#     Write a haiku about «subject»...
#     ---

cell_compose = {
    "name": "compose",
    "effect": "replayable",
    "givens": ["topic.subject"],
    "yields": ["poem"],
    "body": (
        "Write a haiku about {subject}. " +
        "Follow the traditional 5-7-5 syllable structure..."
    ),
    "value": {},
    "checks": [],
}
```

**Works, with friction.** The given/yield/body split maps directly to the dict
fields. The `{field}` template substitution replaces `«field»` guillemets.

**Awkwardness:**

1. **No implicit string concatenation.** Starlark requires explicit `+` between
   string literals. Writing multiline LLM prompts requires either one long line
   or manual `+ "\n"` joins. This is the single most painful ergonomic issue.
   The .cell triple-dash block handles multi-paragraph prompts without any
   special syntax.

2. **No guillemet syntax.** `{subject}` works but is visually identical to
   Python's f-string syntax, which Starlark does NOT support. An LLM might
   write `f"...{subject}..."` and be surprised when it fails.

3. **Body is a string, not a block.** In .cell the body is a first-class
   syntactic block. In Starlark it is a string value — you cannot tell by
   looking at a dict whether its `body` is a prompt or a function until you
   check the type.

---

### Pure Compute (Replaces sql:)

```starlark
# .cell:
#   cell count-findings
#     given analyze.findings
#     yield total
#     ---
#     sql: SELECT (LENGTH(f.value_text) - LENGTH(REPLACE(f.value_text, '- ', ''))) / 2

def count_findings_body(ctx):
    findings = ctx.get("findings", "")
    lines = findings.split("\n")
    count = len([l for l in lines if l.strip().startswith("- ")])
    return {"total": count}

cell_count_findings = {
    "name": "count-findings",
    "effect": "pure",
    "givens": ["analyze.findings"],
    "yields": ["total"],
    "body": count_findings_body,
    ...
}
```

**Starlark wins here.** The sql: escape hatch was computing string statistics
via SQL — this is genuinely better as a Starlark function. Benefits:

- **Testable in isolation.** Call `count_findings_body({"findings": "- a\n- b"})`.
- **Correct behavior.** The SQL `LENGTH - REPLACE` trick breaks on multiple
  spaces and newlines (verified in word_count.star: `"  hello   world  "` gives
  4 via SQL-style, 2 via `split()`).
- **Explicitly pure.** No DB connection, no side effects, honest effect label.
- **Readable.** The intent is clear from the function body.

The sql: pattern was always a workaround for the absence of a pure compute
substrate. Starlark makes the right thing the easy thing.

---

### Stem Cell (Non-Replayable, Perpetual)

```starlark
# .cell:
#   cell perpetual-request (stem)
#     yield program_name
#     yield program_text
#     ---
#     Poll for pending requests...

def perpetual_request_body(ctx):
    if len(_pending_requests) > 0:
        req = _pending_requests[0]
        return ({"program_name": req["name"], "program_text": req["text"]}, "more")
    return ({"program_name": "", "program_text": ""}, "more")

cell_perpetual_request = {
    "name": "perpetual-request",
    "effect": "non_replayable",
    "stem": True,
    "body": perpetual_request_body,
    ...
}
```

**Works mechanically, loses the declaration.** The `(yields_dict, "more")`
return convention is expressible. But the `(stem)` annotation in .cell is a
single keyword that changes the runtime's behavior. In Starlark, `stem: True`
is just a flag in a dict — it doesn't affect the function itself, it just
labels intent for the runtime.

The bigger issue: stem cells need external state (the pending queue). In .cell,
`observe` reads from the shared tuple space — a first-class runtime primitive.
In Starlark, you have to use module-level variables (`_pending_requests`), which
breaks the functional model and can't be replicated by the real runtime.

---

### Autopour

```starlark
# .cell:
#   cell evaluator
#     given request.program_text
#     yield evaluated [autopour]

cell_evaluator = {
    "name": "evaluator",
    "effect": "non_replayable",
    "autopour": ["evaluated"],   # annotates which yield fields to pour
    "body": evaluator_body,
    ...
}
```

**Structurally representable; semantically hollow.** The `autopour` list marks
which yield fields should be poured by the runtime. The cell function itself
just passes through — the actual pouring is a runtime operation.

In Starlark, without a real runtime, `autopour` is just metadata. The semantics
(parse the yielded text as a cell program and pour it) cannot be expressed
within Starlark itself. You can describe the structure of autopour but you
cannot implement it.

---

### Iterate (Fixed-Point Iteration)

```starlark
# .cell:
#   iterate day 5
#     given assemble.initial_state
#     yield world_state
#     yield narrative
#     --- (LLM body that reads world_state and produces world_state') ---

# Starlark requires an explicit loop:
def iterate_cell(cells, seed_cell, n):
    state = cells[seed_cell]["value"]["initial_state"]
    for i in range(n):
        (state, narrative) = simulate_day_step(i, state, narrative)
    cells["day"] = {"value": {"world_state": state, "narrative": narrative}}
```

**The hardest construct.** `iterate NAME N` in .cell is a self-referential
cell that feeds its own output back as input. The runtime handles the feedback
loop; the cell author writes a single step function.

Starlark's gap:

1. **Cannot express `given self.world_state`** — self-reference in a dict
   is not possible. The feedback loop MUST be an explicit function.
2. **Structural information is lost.** The iterate cell in .cell tells you
   at a glance: "this cell runs N times; each output feeds the next input."
   In Starlark, you see a `for i in range(n)` loop — structurally identical
   to any other loop.
3. **The runtime contract is broken.** The real runtime would evaluate the
   step cell against a real LLM, threading state. The Starlark version must
   simulate this with hard-coded narratives.

---

## Ergonomic Issues by Severity

### Critical (blocks natural authoring)

**No multiline string literals.** This is the most painful issue. Cell prompts
are naturally multi-paragraph. In .cell, the triple-dash block handles this
transparently. In Starlark, every newline in a prompt requires explicit `+ "\n"`.
An LLM writing a complex world-building prompt has to mentally escape every
paragraph break.

Python has triple-quoted strings (`"""`). Starlark does not. This single
omission makes Starlark significantly worse than Python for prompt authoring.

### Major (requires workaround)

**No implicit string concatenation.** Starlark requires `+` between adjacent
string literals. Writing long prompts requires either one very long line or
explicit string joining.

**Top-level for loops require `-globalreassign` flag or wrapping in `main()`.**
A natural execution pattern (iterate over cells) cannot be written at the module
level without the flag. All execution must be inside functions. This is
non-obvious and causes real errors.

**`%-15s` format specifiers not supported.** Starlark's `%` formatting is a
subset of Python's. Alignment specifiers like `%-15s` raise runtime errors.
An LLM familiar with Python will write these and be surprised.

### Minor (style issues)

**Cell names with hyphens must be quoted as dict keys.** `"count-words"` is
fine as a string but not as a bare identifier. This is a Starlark constraint
(and Python's), not specific to cell encoding.

**`body` field has mixed types.** `None` = literal, string = soft/LLM, callable
= pure compute. Type-checking this requires `type(body) == type("")`, which
is awkward. A real substrate would use tagged unions or separate dict fields.

**Checks are data, not executable.** `"findings contains at least 3 bullet points"`
is a string. The check evaluator must parse this English-like syntax. Without
a proper check DSL or `eval()`, checks cannot call arbitrary Starlark functions.

---

## Metacircularity

**Is eval achievable in Starlark? Partially.**

The cell language's metacircular evaluator (cell-zero) says: eval = pour.
A cell that yields a program is an evaluator. The runtime pours it.

In Starlark:

```starlark
# The evaluator cell passes through its input unchanged.
# The runtime does the actual pouring.
def evaluator_body(ctx):
    return {"evaluated": ctx["program_text"], "name": ctx["program_name"]}

cell_evaluator = {
    "autopour": ["evaluated"],  # metadata: runtime pours this
    "body": evaluator_body,
    ...
}
```

The DATA representation is self-describing: programs are lists of cell dicts,
cells are dicts with known keys, the evaluator is itself a cell dict. You can
write `eval = lambda program: pour(program)` as a Starlark function.

What you CANNOT do:
- Implement `pour` in Starlark (it requires runtime access: DB writes, LLM
  dispatch, dependency resolution)
- Implement `observe` (requires tuple space access)
- Make the evaluator actually evaluate (simulation is not evaluation)

The .cell evaluator is metacircular because `pour` IS the runtime operation
and `yield evaluated [autopour]` invokes it by annotation. Starlark cannot
annotate its way into runtime behavior — it can only describe the structure.

**Verdict:** Starlark can represent the metacircular evaluator as a data
structure. It cannot implement the evaluator's operational semantics without
a host runtime written in something else.

---

## LLM Authoring Rating: 2/5

### What works for LLM authors

- Dict representation of cells is regular and predictable
- `given/yields/body/effect` as dict keys are self-documenting
- Pure compute functions are natural Python-style code
- Chain of cells as a list + topological sort is learnable

### What hurts LLM authors

- **Boilerplate ratio is high.** A 2-line hard literal in .cell is 8+ lines
  in Starlark. An LLM will often write the minimal cell and omit required keys.
- **No multiline string support.** LLM prompts are naturally multiline. The
  `+ "\n" +` pattern is error-prone and easy to forget.
- **Type ambiguity of `body`.** LLMs will sometimes write a string when a
  function is needed and vice versa.
- **No top-level execution.** The `main()` wrapping requirement is a silent
  trap — code looks correct but fails with "for loop not within a function".
- **Feature gaps vs Python.** An LLM trained on Python will write triple-quoted
  strings, implicit string concatenation, `f"..."` strings, `%-15s` format
  specifiers — all of which fail silently-to-confusingly in Starlark.

---

## Best Syntax: Pure Compute Cell

The cleanest Starlark syntax is a pure compute cell. The function body is
natural Python-style code; the dict wrapper is minimal; the semantics are
honest (effect=pure, body=callable).

```starlark
# word_count.star — count_findings_body
# This replaces a sql: SELECT LENGTH/REPLACE... body with honest pure compute.
def count_findings_body(ctx):
    findings = ctx.get("findings", "")
    lines = findings.split("\n")
    count = len([l for l in lines if l.strip().startswith("- ")])
    return {"total": count}

cell_count_findings = {
    "name": "count-findings",
    "effect": "pure",
    "givens": ["analyze.findings"],
    "yields": ["total"],
    "body": count_findings_body,
    "value": {},
    "checks": [],
}
```

This is unambiguous, testable in isolation, and more correct than the sql:
equivalent (handles multiple spaces and newlines).

---

## Worst Syntax: Multi-Paragraph Soft Cell

```starlark
# village_sim.star — world-constructor body
# A multi-paragraph LLM prompt in Starlark.
# Every paragraph break requires explicit string joining.
cell_world_constructor = {
    "name": "world-constructor",
    "effect": "replayable",
    "givens": ["params.premise"],
    "yields": ["setting", "rules", "seeds_of_conflict"],
    "body": (
        "You are a world-builder. Given this premise: " +
        "\"A world in which {premise}\"\n\n" +
        "Construct the world by returning three things as JSON:\n" +
        "SETTING: {\"name\": \"...\", \"era\": \"...\", ...}\n" +
        "RULES: {\"premise_mechanic\": \"...\", \"constraints\": [...], ...}\n" +
        "SEEDS_OF_CONFLICT: [\"...\", \"...\", \"...\"]"
    ),
    ...
}
```

Compare with .cell:

```
cell world-constructor
  given params.premise
  yield setting
  yield rules
  yield seeds_of_conflict
  ---
  You are a world-builder. Given this premise:
  "A world in which «premise»"

  Construct the world by returning three things as JSON:

  SETTING: {"name": "...", "era": "...", ...}
  RULES: {"premise_mechanic": "...", ...}
  SEEDS_OF_CONFLICT: ["...", ...]
  ---
```

The .cell version is a prose document with a small syntactic frame around it.
The Starlark version is code that assembles a string. For LLM authors, the
.cell version is composing a prompt; the Starlark version is engineering a string.

---

## Conclusion

Starlark is a capable substrate for representing cell programs structurally.
The cell-as-dict model is clean and the pure compute cell type is a genuine
improvement over sql: bodies.

The language breaks down on three fronts:

1. **Prompt ergonomics.** No multiline strings, no implicit concat, no guillemet
   substitution. Authoring LLM prompts in Starlark is engineering, not writing.

2. **Declarative iteration.** The `iterate NAME N` construct has no Starlark
   equivalent. Expressing it requires imperative code that loses structural
   information.

3. **Runtime primitives.** `observe`, `pour`, `autopour`, stem cell looping —
   these are runtime operations that cannot be implemented in Starlark itself.
   A Starlark substrate can describe them but not implement them.

For a bakeoff evaluating whether Starlark can serve as the cell language's
substrate: **it can host the data model but not the operational semantics**.
A tool that translates .cell programs to Starlark for static analysis or
documentation would work well. A tool that tries to make Starlark the
authoring surface would fight the language on every multiline prompt.

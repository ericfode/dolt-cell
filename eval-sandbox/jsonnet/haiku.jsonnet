// haiku.jsonnet — Haiku generation pipeline
//
// Demonstrates:
//   - Hard literal cell (pure value, no computation)
//   - Soft cell (LLM-evaluated, replayable)
//   - Pure compute cell (deterministic, no LLM)
//   - Oracle check (semantic assertion)
//   - Cell dependency graph via givens
//
// KEY CONSTRAINT: Jsonnet manifests to JSON. Functions cannot be serialized.
// Pure compute cells encode their logic as a structured expression tree (AST
// fragment), not a Jsonnet closure. This is verbose but survives serialization.
// The runtime would evaluate these expression trees, not Jsonnet functions.
//
// Representation:
//   Hard literal:  body.type = "literal",  body.value = <JSON value>
//   Soft cell:     body.type = "soft",     body.template = "...{{var}}..."
//   Pure compute:  body.type = "compute",  body.expr = <expression tree>

// ── Helpers ──────────────────────────────────────────────────────────────────

local program(name, cells) = {
  program: name,
  cells: cells,
};

local hardLiteral(name, yieldValues) = {
  name: name,
  effect: "pure",
  givens: [],
  yields: std.objectFields(yieldValues),
  body: { type: "literal", value: yieldValues },
  checks: [],
};

local softCell(name, givens, yields, template, checks=[]) = {
  name: name,
  effect: "replayable",
  givens: givens,
  yields: yields,
  body: { type: "soft", template: template },
  checks: checks,
};

local computeCell(name, givens, yields, expr, checks=[]) = {
  name: name,
  effect: "pure",
  givens: givens,
  yields: yields,
  body: { type: "compute", expr: expr },
  checks: checks,
};

// Expression tree constructors — pure data, serializable
local call(fn, args) = { op: "call", fn: fn, args: args };
local get(binding) = { op: "get", binding: binding };
local lit(v) = { op: "lit", value: v };
local obj(fields) = { op: "obj", fields: fields };
local fieldExpr(name, expr) = { name: name, expr: expr };

// ── Cells ────────────────────────────────────────────────────────────────────

local topic = hardLiteral("topic", {
  subject: "autumn rain on a temple roof",
});

local compose = softCell(
  name="compose",
  givens=["topic.subject"],
  yields=["poem"],
  template=(
    "Write a haiku about {{subject}}. " +
    "Follow the traditional 5-7-5 syllable structure across exactly three lines. " +
    "Return only the three lines of the haiku, separated by newlines."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(poem)" },
    { type: "semantic", assertion: "poem follows 5-7-5 syllable pattern" },
  ],
);

// Pure compute: count words by splitting on whitespace and taking the length.
// Encoded as a serializable expression tree rather than a Jsonnet function.
// Equivalent to: { total: length(split(strip(poem), " ")) }
local countWords = computeCell(
  name="count-words",
  givens=["compose.poem"],
  yields=["total"],
  expr=obj([
    fieldExpr("total",
      call("length", [
        call("split", [
          call("strip", [get("compose.poem")]),
          lit(" "),
        ]),
      ])
    ),
  ]),
  checks=[
    { type: "deterministic", expr: "total > 0" },
  ],
);

local critique = softCell(
  name="critique",
  givens=["compose.poem", "count-words.total"],
  yields=["review"],
  template=(
    "Critique this haiku (word count: {{total}}):\n\n" +
    "{{poem}}\n\n" +
    "Evaluate: Does it follow 5-7-5 syllable structure? " +
    "Does the imagery evoke the subject? " +
    "Is there a seasonal reference (kigo)? " +
    "Is there a cutting word (kireji) or pause between images? " +
    "Rate overall quality from 1-5."
  ),
  checks=[
    { type: "deterministic", expr: "sentence_count(review) >= 2" },
  ],
);

// ── Program ──────────────────────────────────────────────────────────────────

program("haiku", [topic, compose, countWords, critique])

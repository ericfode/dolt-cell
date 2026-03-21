// code-review.jsonnet — Code review pipeline
//
// Demonstrates:
//   - Hard literal cell with multi-line string value
//   - Soft cell with multi-line template and variable interpolation
//   - Pure compute cell replacing sql: (counting bullet points)
//   - Chain of dependencies: source → analyze → count-findings → prioritize

// ── Shared library (inline — Jsonnet has no stdlib import here) ──────────────

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

// Expression tree constructors
local call(fn, args) = { op: "call", fn: fn, args: args };
local get(binding) = { op: "get", binding: binding };
local lit(v) = { op: "lit", value: v };
local obj(fields) = { op: "obj", fields: fields };
local fieldExpr(name, expr) = { name: name, expr: expr };
local binop(op, left, right) = { op: op, left: left, right: right };

// ── Cells ────────────────────────────────────────────────────────────────────

local source = hardLiteral("source", {
  code: "def is_prime(n): return all(n % i != 0 for i in range(2, n))",
});

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

// Pure compute: count "- " occurrences in findings text.
// Replaces the sql: body from the reference. Encoded as expression tree.
// Equivalent to: { total: count_occurrences("- ", findings) }
local countFindings = computeCell(
  name="count-findings",
  givens=["analyze.findings"],
  yields=["total"],
  expr=obj([
    fieldExpr("total",
      call("count_occurrences", [
        lit("- "),
        get("analyze.findings"),
      ])
    ),
  ]),
  checks=[],
);

local prioritize = softCell(
  name="prioritize",
  givens=["analyze.findings", "count-findings.total"],
  yields=["summary"],
  template=(
    "Given {{total}} findings from the code review:\n\n" +
    "{{findings}}\n\n" +
    "Prioritize these findings by severity (critical first, minor last). " +
    "For each, classify as BUG, PERFORMANCE, or STYLE. " +
    "Write a one-paragraph executive summary suitable for a pull request comment."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(summary)" },
  ],
);

// ── Program ──────────────────────────────────────────────────────────────────

{
  program: "code-review",
  cells: [source, analyze, countFindings, prioritize],
}

// cell-zero.jsonnet — The Metacircular Evaluator
//
// Demonstrates:
//   - Hard literal cell (pure)
//   - Soft cell (replayable, LLM prompt)
//   - Pure compute cell (replaces sql:)
//   - Autopour cell (yields a program → runtime pours it)
//   - Stem cell (perpetual, returns :more)
//   - Self-evaluation question (handled structurally)
//
// The key question: is metacircularity achievable in Jsonnet?
//
// Short answer: Partially. The STRUCTURE of the evaluator (which cells exist,
// what their deps are, how they compose) CAN be represented. The EXECUTION
// semantics (what happens when a program is poured, what :more does,
// how autopour fires) must be delegated to the runtime.
//
// Jsonnet is a data language. It can describe the evaluator. It cannot
// BE the evaluator. This is the fundamental tension.
//
// However: the description is complete enough that a runtime implementing
// the cell semantics could execute it correctly. That's the test.

// ── Helpers ──────────────────────────────────────────────────────────────────

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

// Autopour cell: yields a field whose value the runtime pours as a new program.
// effect must be non_replayable because pouring is a side effect.
local autopourCell(name, givens, yields, autopour_field, template, checks=[]) = {
  name: name,
  effect: "non_replayable",
  givens: givens,
  yields: yields,
  autopour: autopour_field,  // the field name whose value is poured
  body: { type: "soft", template: template },
  checks: checks,
};

// Stem cell: runs perpetually, cycling until the runtime stops it.
// Each cycle can return a "more" signal to request another cycle.
// The template sees its own previous yields (if any) merged with its givens.
local stemCell(name, givens, yields, autopour_field=null, template, checks=[]) = {
  name: name,
  effect: "non_replayable",
  givens: givens,
  yields: yields,
  stem: true,
  [if autopour_field != null then "autopour"]: autopour_field,
  body: { type: "soft", template: template },
  checks: checks,
};

// Expression tree constructors
local call(fn, args) = { op: "call", fn: fn, args: args };
local get(binding) = { op: "get", binding: binding };
local lit(v) = { op: "lit", value: v };
local cond(pred, then_, else_) = { op: "cond", pred: pred, "then": then_, "else": else_ };
local obj(fields) = { op: "obj", fields: fields };
local fieldExpr(name, expr) = { name: name, expr: expr };
local letExpr(bindings, body) = { op: "let", bindings: bindings, body: body };
local bindExpr(name, expr) = { name: name, expr: expr };
local gt(a, b) = { op: ">", left: a, right: b };
local eq(a, b) = { op: "==", left: a, right: b };

// ── PART 1: The Universal Evaluator ─────────────────────────────────────────
//
// request: a pour-request — another cell or external agent fills in the
// program name and source text of the program to evaluate.

local request = softCell(
  name="request",
  givens=[],
  yields=["program_name", "program_text"],
  template=(
    "This is a pour-request. Another cell or an external agent fills in " +
    "the program name and the raw source text of the program to evaluate.\n\n" +
    "Yield program_name = the name for the new program.\n" +
    "Yield program_text = the complete source to be poured."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(program_text)" },
    { type: "deterministic", expr: "not_empty(program_name)" },
  ],
);

// evaluator: takes program_text and yields it for autopour.
// eval = pour. This IS the universal evaluator.
local evaluator = autopourCell(
  name="evaluator",
  givens=["request.program_text", "request.program_name"],
  yields=["evaluated", "name"],
  autopour_field="evaluated",
  template=(
    "The universal evaluator. Take {{program_text}} and yield it as a " +
    "program for autopour. The runtime will parse it, verify its effect " +
    "level, and pour it into the retort.\n\n" +
    "If the text doesn't parse, this yield becomes bottom (error).\n" +
    "If the effect level exceeds the bound, this yield becomes bottom.\n" +
    "Otherwise, the program enters the retort and starts evaluating.\n\n" +
    "Yield evaluated = {{program_text}}\n" +
    "Yield name = {{program_name}}"
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(evaluated)" },
  ],
);

// ── PART 2: Observing Results (Pure Compute — replaces sql:) ─────────────────
//
// Once a program is poured, we observe its cells' states.
// In the Zygo reference this uses observe(); here we encode it as a
// compute cell over an "observe" primitive call (runtime provides it).

local status = computeCell(
  name="status",
  givens=["evaluator.name"],
  yields=["state"],
  // Equivalent to the Zygo:
  //   (let [cells (observe name :cells)
  //         total (len cells)
  //         bottoms (len (filter bottom? cells))
  //         unfrozen (len (filter (not frozen?) cells))]
  //     (cond (= total 0) "not_found"
  //           (> bottoms 0) "error"
  //           (= unfrozen 0) "complete"
  //           :else "running"))
  expr=obj([
    fieldExpr("state",
      letExpr(
        [
          bindExpr("cells",   call("observe", [get("evaluator.name"), lit("cells")])),
          bindExpr("total",   call("length", [get("cells")])),
          bindExpr("bottoms", call("length", [call("filter", [lit("is_bottom"), get("cells")])])),
          bindExpr("unfrozen",call("length", [call("filter", [lit("is_not_frozen"), get("cells")])])),
        ],
        cond(
          eq(get("total"), lit(0)),
          lit("not_found"),
          cond(
            gt(get("bottoms"), lit(0)),
            lit("error"),
            cond(
              eq(get("unfrozen"), lit(0)),
              lit("complete"),
              lit("running"),
            ),
          ),
        ),
      )
    ),
  ]),
  checks=[],
);

// ── PART 3: Self-Evaluation Commentary ──────────────────────────────────────
//
// Can this evaluator evaluate itself?
//
// If request.program_text = the text of THIS program (cell-zero.jsonnet),
// then evaluator yields it with autopour → runtime pours a copy.
// The copy's request cell has no source of program_text → unsatisfied dep.
// The copy is inert. Self-evaluation terminates naturally. No fuel needed.
//
// Fuel is only needed for CHAINED autopour (A pours B pours C...).
// This is captured in the program metadata below.

// ── PART 4: The Perpetual Evaluator (Stem Version) ───────────────────────────
//
// A stem cell that continuously accepts pour-requests and evaluates them.
// stem: true signals the runtime to keep cycling.

local perpetualRequest = stemCell(
  name="perpetual-request",
  givens=[],
  yields=["program_name", "program_text"],
  template=(
    "Poll for a pending pour-request. This is a stem cell — it runs " +
    "forever, checking each generation for new work.\n\n" +
    "Use observe(\"cell-zero\", \"pending-requests\") to check for work.\n" +
    "If a request is pending: yield program_name and program_text from it, " +
    "return :more to cycle again.\n" +
    "If no request: yield empty strings, return :more (quiescent)."
  ),
  checks=[],
);

local perpetualEvaluator = stemCell(
  name="perpetual-evaluator",
  givens=["perpetual-request.program_text", "perpetual-request.program_name"],
  yields=["poured", "status"],
  autopour_field="poured",
  template=(
    "If {{program_text}} is not empty, yield it for autopour.\n" +
    "If empty, yield empty string (quiescent — no work this generation).\n\n" +
    "This is the perpetual metacircular evaluator:\n" +
    "a stem cell that continuously pours programs as they arrive.\n\n" +
    "Yield poured = {{program_text}} (or empty if quiescent)\n" +
    "Yield status = \"evaluating\" or \"quiescent\"\n" +
    "Return :more to cycle again."
  ),
  checks=[],
);

// ── PART 5: Demonstration — Hard Literal + Pure Compute ─────────────────────

local exampleTopic = hardLiteral("example-topic", {
  subject: "the metacircular evaluator",
});

local exampleHaiku = softCell(
  name="example-haiku",
  givens=["example-topic.subject"],
  yields=["poem"],
  template=(
    "Write a haiku about {{subject}}. " +
    "Follow 5-7-5 syllable structure. " +
    "Return only the three lines."
  ),
  checks=[
    { type: "deterministic", expr: "not_empty(poem)" },
    { type: "semantic", assertion: "poem follows 5-7-5 syllable pattern" },
  ],
);

// Pure compute: word count of the poem. Replaces sql:.
local exampleWordCount = computeCell(
  name="example-word-count",
  givens=["example-haiku.poem"],
  yields=["total"],
  expr=obj([
    fieldExpr("total",
      call("add", [
        lit(1),
        call("length", [
          call("split", [
            call("strip", [get("example-haiku.poem")]),
            lit(" "),
          ]),
        ]),
      ])
    ),
  ]),
  checks=[
    { type: "deterministic", expr: "total > 0" },
  ],
);

// ── Metacircularity Analysis ─────────────────────────────────────────────────
//
// Can Jsonnet express a metacircular evaluator?
//
// This section encodes the analysis as data — honest documentation
// of what Jsonnet can and cannot do here.

local metacircularityAnalysis = {
  question: "Can this evaluator evaluate itself?",
  answer: "Structurally yes, executionally no.",
  structural_metacircularity: {
    achievable: true,
    explanation: (
      "The Jsonnet program CAN describe a cell program whose cells implement " +
      "the cell evaluator. The request + evaluator + autopour chain is fully " +
      "representable as JSON data."
    ),
  },
  executional_metacircularity: {
    achievable: false,
    explanation: (
      "Jsonnet is a data language that manifests to JSON. It has no runtime " +
      "execution model for cells — no pour, no observe, no :more. The JSON " +
      "output is a DESCRIPTION of the evaluator, not an execution of it. " +
      "A separate runtime (the ct tool) must execute the description."
    ),
  },
  self_eval_termination: {
    mechanism: "unsatisfied dependency",
    explanation: (
      "If cell-zero pours itself, the copy's request cell has no source " +
      "of program_text. The unsatisfied dependency halts evaluation naturally. " +
      "No fuel counter needed for this case."
    ),
  },
  chained_autopour: {
    mechanism: "fuel counter",
    explanation: (
      "A pours B pours C... requires a fuel bound. Each pour decrements fuel. " +
      "At fuel=0, autopour yields bottom. This is a runtime invariant, not " +
      "expressible in the static program description."
    ),
  },
};

// ── Program ──────────────────────────────────────────────────────────────────

{
  program: "cell-zero",
  metacircularity: metacircularityAnalysis,
  cells: [
    // Part 1: Universal evaluator
    request,
    evaluator,
    // Part 2: Observe results
    status,
    // Part 4: Perpetual stem version
    perpetualRequest,
    perpetualEvaluator,
    // Part 5: Demonstration
    exampleTopic,
    exampleHaiku,
    exampleWordCount,
  ],
}

# cell_zero.star — The Metacircular Evaluator in Starlark
#
# Demonstrates ALL cell body types in the Starlark substrate:
#   - Hard literal  (pure, value in body field)
#   - Soft cell     (replayable, LLM-evaluated string body)
#   - Pure compute  (pure, Starlark function body — replaces sql:)
#   - Stem cell     (non-replayable, perpetual, returns "more")
#   - Autopour      (cell yields a program, runtime pours it)
#
# KEY DESIGN: A "cell" is a dict with these fields:
#   name      — string identifier
#   effect    — "pure" | "replayable" | "non_replayable"
#   yields    — list of field names this cell produces
#   givens    — list of "source.field" dependency strings
#   stem      — bool, True for perpetual cells
#   autopour  — list of yield fields to pour as programs
#   body      — None (hard literal), string (soft/LLM), or callable (pure compute / stem)
#   value     — dict of literal values (for hard literal cells only)
#   checks    — list of check strings
#
# The runtime (not implemented here) would:
#   1. Resolve givens → bind them as a context dict
#   2. Evaluate the body (call it with context, or send it to LLM)
#   3. Freeze the yields
#   4. If autopour: parse and pour any designated yield fields
#   5. For stem cells: call body repeatedly with updated context, stop when "more" not returned

# ============================================================
# RUNTIME SIMULATOR
# (A minimal interpreter so this file actually runs and shows output)
# ============================================================

def make_context(cells, cell_name):
    """Build the resolution context for a cell by resolving its givens."""
    cell = cells[cell_name]
    ctx = {}
    for given in cell.get("givens", []):
        parts = given.split(".")
        source_name = parts[0]
        field_name = parts[1]
        source_cell = cells[source_name]
        val = source_cell.get("value", {}).get(field_name, None)
        if val == None:
            val = "[unresolved: %s]" % given
        ctx[field_name] = val
    return ctx

def evaluate_cell(cells, cell_name):
    """
    Simulate evaluation of a single cell.
    Returns (yields_dict, signal) where signal is None or "more".
    """
    cell = cells[cell_name]
    body = cell.get("body", None)
    effect = cell.get("effect", "pure")
    ctx = make_context(cells, cell_name)

    # Hard literal cell: body is None, value is already set
    if body == None:
        return (cell.get("value", {}), None)

    # Soft cell: body is a string template (simulated LLM call)
    if type(body) == type(""):
        # Substitute context into the body template
        rendered = body
        for k, v in ctx.items():
            rendered = rendered.replace("{" + k + "}", str(v))
        # Simulate the LLM response with a placeholder
        simulated = "[LLM would evaluate: %s]" % rendered[:60]
        result = {}
        for field in cell["yields"]:
            result[field] = simulated
        return (result, None)

    # Pure compute / stem cell: body is a callable
    result = body(ctx)
    if type(result) == type(()):
        # Stem cells return (yields_dict, signal)
        return result
    # Pure compute returns just a dict
    return (result, None)

def run_program(cells, order):
    """Execute cells in dependency order, printing results."""
    print("=== PROGRAM EXECUTION ===")
    for cell_name in order:
        cell = cells[cell_name]
        yields_dict, signal = evaluate_cell(cells, cell_name)

        # Update the cell's value in place so downstream cells can read it
        cells[cell_name]["value"] = yields_dict

        tag = ""
        if cell.get("stem", False):
            tag = " [STEM]"
        if cell.get("autopour", []):
            tag += " [AUTOPOUR: %s]" % ", ".join(cell.get("autopour", []))

        print("")
        print("cell %s (effect=%s)%s" % (cell_name, cell.get("effect", "pure"), tag))
        for k, v in yields_dict.items():
            short_v = str(v)
            if len(short_v) > 80:
                short_v = short_v[:77] + "..."
            print("  yield %s = %s" % (k, short_v))
        if signal:
            print("  signal: %s" % signal)

    print("")
    print("=== DONE ===")

# ============================================================
# PART 1: The Universal Evaluator
# ============================================================

# Hard literal: a pure value, no computation.
cell_example_topic = {
    "name": "example-topic",
    "effect": "pure",
    "givens": [],
    "yields": ["subject"],
    "stem": False,
    "autopour": [],
    "checks": [],
    "body": None,
    "value": {"subject": "the metacircular evaluator"},
}

# Soft cell: LLM-evaluated. The piston reads the string body and produces yields.
# Context variables are referenced as {field} (Starlark string format).
# In the real language they would be «field» guillemets.
cell_example_haiku = {
    "name": "example-haiku",
    "effect": "replayable",
    "givens": ["example-topic.subject"],
    "yields": ["poem"],
    "stem": False,
    "autopour": [],
    "checks": [
        "not_empty(poem)",
        'check~("poem follows 5-7-5 syllable pattern")',
    ],
    "body": "Write a haiku about {subject}. Follow 5-7-5 syllable structure. Return only the three lines.",
}

# Pure compute cell: replaces sql: in old syntax.
# This is a Starlark function — deterministic, no LLM needed.
# Effect level is honestly "pure".
def word_count_body(ctx):
    poem = ctx.get("poem", "")
    words = poem.strip().split()
    return {"total": len(words)}

cell_example_word_count = {
    "name": "example-word-count",
    "effect": "pure",
    "givens": ["example-haiku.poem"],
    "yields": ["total"],
    "stem": False,
    "autopour": [],
    "checks": [],
    "body": word_count_body,
}

# ============================================================
# PART 2: The Universal Evaluator (autopour)
# ============================================================

# Soft cell: accepts a pour-request from an external agent.
# In a real runtime this would be filled by the piston/user.
cell_request = {
    "name": "request",
    "effect": "replayable",
    "givens": [],
    "yields": ["program_name", "program_text"],
    "stem": False,
    "autopour": [],
    "checks": [
        "not_empty(program_name)",
        "not_empty(program_text)",
    ],
    "body": "Yield the program name and S-expression source text for the program to be evaluated.",
    # Simulated: in reality the LLM/user would fill these in
    "value": {
        "program_name": "haiku-demo",
        "program_text": "(defcell demo {:yield [:x] :effect :pure} {:x 42})",
    },
}

# The universal evaluator: takes program_text and yields it for autopour.
# The runtime parses and pours the yielded program.
# eval = pour. A cell that yields a program IS an evaluator.
def evaluator_body(ctx):
    program_text = ctx.get("program_text", "")
    program_name = ctx.get("program_name", "")
    # Pure pass-through: the runtime does the actual pouring via :autopour
    return {
        "evaluated": program_text,
        "name": program_name,
    }

cell_evaluator = {
    "name": "evaluator",
    "effect": "non_replayable",
    "givens": ["request.program_text", "request.program_name"],
    "yields": ["evaluated", "name"],
    "stem": False,
    "autopour": ["evaluated"],    # Runtime pours this field's value as a program
    "checks": ["not_empty(evaluated)"],
    "body": evaluator_body,
}

# Status observer: checks the state of a poured program.
# In the old syntax this was sql:; here it's a pure compute cell
# using observe (simulated as a lookup in our in-memory state).
def status_body(ctx):
    name = ctx.get("name", "")
    # In a real runtime: cells = observe(name, "cells")
    # Simulate: assume the poured program has some cells in progress
    simulated_cells = [
        {"state": "frozen"},
        {"state": "frozen"},
        {"state": "declared"},
    ]
    total = len(simulated_cells)
    bottoms = len([c for c in simulated_cells if c["state"] == "bottom"])
    unfrozen = len([c for c in simulated_cells if c["state"] != "frozen"])
    if total == 0:
        state = "not_found"
    elif bottoms > 0:
        state = "error"
    elif unfrozen == 0:
        state = "complete"
    else:
        state = "running"
    return {"state": state}

cell_status = {
    "name": "status",
    "effect": "replayable",
    "givens": ["evaluator.name"],
    "yields": ["state"],
    "stem": False,
    "autopour": [],
    "checks": [],
    "body": status_body,
}

# ============================================================
# PART 3: Stem Cells (Perpetual Evaluator)
# ============================================================

# Stem cells return ("more",) as their second value to request another cycle.
# Here we simulate one cycle: the stem checks for pending work,
# returns work if found, and signals "more" to keep running.

_pending_requests = [
    {"name": "prog-alpha", "text": "(defcell a {:yield [:v] :effect :pure} {:v 1})"},
]

def perpetual_request_body(ctx):
    """Poll for a pending pour-request. Stem cell — runs perpetually."""
    if len(_pending_requests) > 0:
        req = _pending_requests[0]
        return ({"program_name": req["name"], "program_text": req["text"]}, "more")
    return ({"program_name": "", "program_text": ""}, "more")

cell_perpetual_request = {
    "name": "perpetual-request",
    "effect": "non_replayable",
    "givens": [],
    "yields": ["program_name", "program_text"],
    "stem": True,
    "autopour": [],
    "checks": [],
    "body": perpetual_request_body,
}

def perpetual_evaluator_body(ctx):
    """If program_text is not empty, yield it for autopour. Stem cell."""
    program_text = ctx.get("program_text", "")
    if program_text == "":
        return ({"poured": "", "status": "quiescent"}, "more")
    return ({"poured": program_text, "status": "evaluating"}, "more")

cell_perpetual_evaluator = {
    "name": "perpetual-evaluator",
    "effect": "non_replayable",
    "givens": [
        "perpetual-request.program_text",
        "perpetual-request.program_name",
    ],
    "yields": ["poured", "status"],
    "stem": True,
    "autopour": ["poured"],
    "checks": [],
    "body": perpetual_evaluator_body,
}

# ============================================================
# MAIN: Build the program and run it
# ============================================================

# Register all cells in a dict keyed by name.
# Hyphens in names require quoting as dict keys in Starlark.
cells = {
    "example-topic": cell_example_topic,
    "example-haiku": cell_example_haiku,
    "example-word-count": cell_example_word_count,
    "request": cell_request,
    "evaluator": cell_evaluator,
    "status": cell_status,
    "perpetual-request": cell_perpetual_request,
    "perpetual-evaluator": cell_perpetual_evaluator,
}

# Execution order respects the DAG (topological sort done by hand here).
# Part 1: demonstration cells
run_program(cells, [
    "example-topic",
    "example-haiku",
    "example-word-count",
])

print("")
print("--- EVALUATOR SUBSYSTEM ---")
run_program(cells, [
    "request",
    "evaluator",
    "status",
])

print("")
print("--- STEM CELLS (one cycle shown) ---")
run_program(cells, [
    "perpetual-request",
    "perpetual-evaluator",
])

# ============================================================
# SELF-EVALUATION ANALYSIS (printed, not executed)
# ============================================================
print("")
print("=== SELF-EVALUATION ANALYSIS ===")
print("Q: Can this evaluator evaluate itself?")
print("A: Yes, structurally. If request.program_text = (contents of this file),")
print("   then evaluator would yield that text with autopour=True.")
print("   The runtime would pour a copy. The copy's request cell has no")
print("   givens filled in => it sits unsatisfied => the copy is INERT.")
print("   Self-evaluation terminates naturally. No fuel needed.")
print("")
print("Q: Can Starlark express metacircularity?")
print("A: Partially. The cell STRUCTURE (dicts + functions) can represent")
print("   itself. The autopour mechanism cannot be self-hosting without a")
print("   real runtime. But the DATA REPRESENTATION is self-describing:")
print("   cells are dicts, programs are lists of cells, eval is a function.")

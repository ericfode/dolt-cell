# haiku.star — Haiku Generation Pipeline in Starlark
#
# Maps directly to haiku-reference.cell:
#   cell topic      → hard literal (pure, value already set)
#   cell compose    → soft cell (replayable, LLM body)
#   cell count-words → pure compute (replaces sql:)
#   cell critique   → soft cell (replayable, multi-given LLM body)
#
# Cell dict schema:
#   name     : string
#   effect   : "pure" | "replayable" | "non_replayable"
#   givens   : list of "source.field" strings
#   yields   : list of field name strings
#   body     : None (literal) | string (soft/LLM template) | callable (pure compute)
#   value    : dict for hard literal cells (pre-set yields)
#   checks   : list of check condition strings
#   stem     : bool
#   autopour : list of autopour field names

# ============================================================
# CELL RUNTIME (minimal simulator)
# ============================================================

def resolve_givens(cells, cell_name):
    """Resolve all givens for a cell into a context dict."""
    cell = cells[cell_name]
    ctx = {}
    for given in cell.get("givens", []):
        parts = given.split(".")
        source_name = parts[0]
        field_name = parts[1]
        src = cells.get(source_name, {})
        val = src.get("value", {}).get(field_name, None)
        ctx[field_name] = val if val != None else "[missing: %s]" % given
    return ctx

def render_template(template, ctx):
    """Substitute {field} placeholders with context values."""
    result = template
    for k, v in ctx.items():
        result = result.replace("{" + k + "}", str(v))
    return result

def simulate_llm(prompt, yields_list):
    """
    Simulate what an LLM would return for a given prompt.
    In the real runtime, the piston sends the rendered prompt to an LLM.
    Here we return descriptive placeholders.
    """
    short = prompt[:50].replace("\n", " ")
    result = {}
    for field in yields_list:
        if field == "poem":
            result[field] = "autumn rain falls soft\ntemple bells echo silence\nleaves find the water"
        elif field == "total":
            result[field] = 12
        elif field == "review":
            result[field] = ("The haiku follows the 5-7-5 structure. " +
                "The imagery effectively evokes the subject. " +
                "The kigo (seasonal reference) is present with autumn rain. " +
                "A kireji pause exists between the second and third lines. " +
                "Overall quality: 4/5.")
        else:
            result[field] = "[LLM response for '%s' given prompt: %s...]" % (field, short)
    return result

def run_cell(cells, cell_name):
    """Evaluate a single cell; update cells[cell_name]['value'] in place."""
    cell = cells[cell_name]
    body = cell.get("body", None)
    ctx = resolve_givens(cells, cell_name)

    if body == None:
        # Hard literal: value is already set at definition time
        return cell.get("value", {})

    if type(body) == type(""):
        # Soft cell: render template and simulate LLM
        prompt = render_template(body, ctx)
        result = simulate_llm(prompt, cell["yields"])
    else:
        # Pure compute: call the function with context
        result = body(ctx)

    cells[cell_name]["value"] = result
    return result

def run_checks(cell, value):
    """Evaluate check conditions and print results."""
    checks = cell.get("checks", [])
    for check in checks:
        # Evaluate simple checks against the yielded values
        passed = True
        note = ""
        if "not_empty" in check:
            field = check.split("(")[1].rstrip(")")
            val = value.get(field, "")
            passed = val != "" and val != None
            note = "value present" if passed else "EMPTY"
        elif "contains at least" in check:
            # e.g. "review contains at least 2 sentences"
            # split: ["review", "contains", "at", "least", "2", "sentences"]
            parts = check.split()
            field = parts[0]
            n = int(parts[4])
            val = str(value.get(field, ""))
            count = val.count(". ") + (1 if val.endswith(".") else 0)
            passed = count >= n
            note = "%d sentences found" % count
        elif "check~" in check:
            passed = True  # Semantic checks always pass in simulation
            note = "semantic (simulated pass)"
        else:
            note = "unevaluated"

        status = "PASS" if passed else "FAIL"
        print("    check [%s] %s  (%s)" % (status, check, note))

def print_cell_result(cell_name, cell, value):
    """Pretty-print a cell's evaluation result."""
    tag = "(%s)" % cell.get("effect", "pure")
    if cell.get("stem", False):
        tag += " [STEM]"
    print("")
    print("cell %s %s" % (cell_name, tag))
    for k, v in value.items():
        v_str = str(v)
        if len(v_str) > 100:
            v_str = v_str[:97] + "..."
        print("  yield %s = %s" % (k, v_str))
    run_checks(cell, value)

# ============================================================
# PROGRAM DEFINITION
# ============================================================

# ── Hard literal ─────────────────────────────────────────────
# cell topic
#   yield subject = "autumn rain on a temple roof"
cell_topic = {
    "name": "topic",
    "effect": "pure",
    "givens": [],
    "yields": ["subject"],
    "stem": False,
    "autopour": [],
    "body": None,
    "value": {"subject": "autumn rain on a temple roof"},
    "checks": [],
}

# ── Soft cell ─────────────────────────────────────────────────
# cell compose
#   given topic.subject
#   yield poem
#   ---
#   Write a haiku about «subject»...
#
# Note: guillemets «field» become {field} in Starlark templates.
# This is the main awkwardness: no native interpolation syntax.
cell_compose = {
    "name": "compose",
    "effect": "replayable",
    "givens": ["topic.subject"],
    "yields": ["poem"],
    "stem": False,
    "autopour": [],
    "body": (
        "Write a haiku about {subject}. " +
        "Follow the traditional 5-7-5 syllable structure across exactly three lines. " +
        "Return only the three lines of the haiku, separated by newlines."
    ),
    "value": {},
    "checks": [],
}

# ── Pure compute cell ─────────────────────────────────────────
# cell count-words
#   given compose.poem
#   yield total
#   ---
#   sql: SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(...)) + 1
#
# The sql: body is replaced by a Starlark function.
# This is HONEST: the old sql: was really deterministic computation;
# here it's explicitly pure (no LLM, no DB query).
def count_words_body(ctx):
    """Count words in the poem by splitting on whitespace."""
    poem = ctx.get("poem", "")
    if poem == "" or poem == None:
        return {"total": 0}
    words = poem.strip().split()
    return {"total": len(words)}

cell_count_words = {
    "name": "count-words",
    "effect": "pure",
    "givens": ["compose.poem"],
    "yields": ["total"],
    "stem": False,
    "autopour": [],
    "body": count_words_body,
    "value": {},
    "checks": [],
}

# ── Soft cell with multiple givens ───────────────────────────
# cell critique
#   given compose.poem
#   given count-words.total
#   yield review
#   ---
#   Critique this haiku (word count: «total»):
#   «poem»
#   ...
#
# Multiple givens are merged into a single context dict.
# Both {poem} and {total} are available in the template.
cell_critique = {
    "name": "critique",
    "effect": "replayable",
    "givens": ["compose.poem", "count-words.total"],
    "yields": ["review"],
    "stem": False,
    "autopour": [],
    "body": (
        "Critique this haiku (word count: {total}):\n\n" +
        "{poem}\n\n" +
        "Evaluate: Does it follow 5-7-5 syllable structure? " +
        "Does the imagery evoke the subject? " +
        "Is there a seasonal reference (kigo)? " +
        "Is there a cutting word (kireji) or pause between images? " +
        "Rate overall quality from 1-5."
    ),
    "value": {},
    "checks": ["review contains at least 2 sentences"],
}

# ============================================================
# PROGRAM REGISTRY AND EXECUTION
# ============================================================

cells = {
    "topic": cell_topic,
    "compose": cell_compose,
    "count-words": cell_count_words,
    "critique": cell_critique,
}

# Topological execution order (hand-sorted DAG)
order = ["topic", "compose", "count-words", "critique"]

def main():
    print("=== haiku.star — Haiku Generation Pipeline ===")
    for cell_name in order:
        cell = cells[cell_name]
        value = run_cell(cells, cell_name)
        print_cell_result(cell_name, cell, value)

    print("")
    print("=== DESIGN NOTES ===")
    print("")
    print("Mapping from .cell to .star:")
    print("  cell NAME             -> dict with 'name' key")
    print("  yield FIELD = LITERAL -> body=None, value={'FIELD': LITERAL}")
    print("  yield FIELD           -> field name in yields list")
    print("  given SOURCE.FIELD    -> 'SOURCE.FIELD' in givens list")
    print("  --- LLM body ---      -> body = string template")
    print("  sql: SELECT ...       -> body = callable function (pure compute)")
    print("  check CONDITION       -> checks list (evaluated by run_checks)")
    print("  guillemets field      -> {field} in Starlark string templates")
    print("")
    print("Awkward points:")
    print("  1. No implicit string concat: must use + between string literals")
    print("  2. No guillemet syntax: {field} works but is less visually distinct")
    print("  3. No multiline string bodies: must manually join with newlines and +")
    print("  4. Checks are data (strings), not executable - requires eval() equivalent")
    print("  5. Cell names with hyphens need quoting as dict keys")
    print("  6. Top-level for loops not allowed; must wrap in main()")

main()

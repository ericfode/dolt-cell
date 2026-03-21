# code_review.star — Code Review Pipeline in Starlark
#
# Maps directly to code-review-reference.cell:
#   cell source         → hard literal (pure)
#   cell analyze        → soft cell (replayable, LLM body)
#   cell count-findings → pure compute (replaces sql: COUNT)
#   cell prioritize     → soft cell (replayable, multi-given)
#
# This file demonstrates:
#   - Multi-field hard literal cells
#   - Chained soft cells (analyze → count-findings → prioritize)
#   - Pure compute replacing sql: arithmetic
#   - Checks on soft cell output
#   - How template rendering works with multi-paragraph LLM prompts

# ============================================================
# SHARED RUNTIME HELPERS
# ============================================================

def resolve_givens(cells, cell_name):
    """Resolve all givens into a context dict by reading frozen yields."""
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
    """Substitute {field} placeholders. Replaces «field» guillemets from .cell syntax."""
    result = template
    for k, v in ctx.items():
        result = result.replace("{" + k + "}", str(v))
    return result

def simulate_llm(prompt_rendered, yields_list, cell_name):
    """
    Simulate LLM evaluation. Returns a realistic placeholder response per field.
    In the real runtime, the piston sends the rendered prompt to an LLM and
    parses the structured response into the yield fields.
    """
    result = {}
    for field in yields_list:
        if field == "findings" and cell_name == "analyze":
            result[field] = (
                "- BUG: is_prime(0) and is_prime(1) return True; they should return False\n" +
                "- BUG: range(2, n) excludes n; is_prime(4) returns True incorrectly\n" +
                "- PERFORMANCE: O(n) trial division; use range(2, int(n**0.5)+1)\n" +
                "- PERFORMANCE: all() short-circuits but base cases bypass this\n" +
                "- STYLE: no docstring explaining parameters, return type, or behavior\n" +
                "- STYLE: single-line lambda-style definition reduces readability\n" +
                "- EDGE CASE: negative numbers are incorrectly classified as prime"
            )
        elif field == "summary" and cell_name == "prioritize":
            result[field] = (
                "CRITICAL — BUG (is_prime(0)/is_prime(1)): The function incorrectly returns True for 0 and 1, " +
                "which are not prime by definition. " +
                "CRITICAL — BUG (off-by-one in range): range(2, n) misses the divisor n itself, " +
                "causing composite numbers like 4 to be classified as prime. " +
                "HIGH — PERFORMANCE: Trial division up to n is O(n); the standard approach " +
                "checks divisors up to sqrt(n), yielding O(sqrt(n)) complexity. " +
                "MEDIUM — EDGE CASE: Negative inputs produce incorrect results. " +
                "LOW — STYLE: Missing docstring and single-line style impede readability. " +
                "Executive summary: This function has two correctness bugs that make it " +
                "unreliable for any production use. Fix the range bound and add base-case " +
                "guards for n < 2 before addressing performance or style concerns."
            )
        else:
            result[field] = "[LLM response for field '%s' in cell '%s']" % (field, cell_name)
    return result

def run_cell(cells, cell_name):
    """Evaluate a cell and store its yields in cells[cell_name]['value']."""
    cell = cells[cell_name]
    body = cell.get("body", None)
    ctx = resolve_givens(cells, cell_name)

    if body == None:
        # Hard literal — value already set
        return cell.get("value", {})

    if type(body) == type(""):
        # Soft cell — render and simulate LLM
        _rendered = render_template(body, ctx)
        result = simulate_llm(_rendered, cell["yields"], cell_name)
    else:
        # Pure compute — call function
        result = body(ctx)

    cells[cell_name]["value"] = result
    return result

def check_passes(check_str, value):
    """Evaluate a single check condition. Returns (passed, note)."""
    if "not_empty" in check_str:
        field = check_str.split("(")[1].rstrip(")")
        val = value.get(field, "")
        passed = val != "" and val != None and val != 0
        return (passed, "non-empty" if passed else "EMPTY")
    elif "contains at least" in check_str:
        # e.g. "findings contains at least 3 bullet points"
        parts = check_str.split()
        field = parts[0]
        n = int(parts[4])
        val = str(value.get(field, ""))
        # Count bullet points: lines starting with "- "
        lines = val.split("\n")
        bullets = len([l for l in lines if l.strip().startswith("- ")])
        passed = bullets >= n
        return (passed, "%d bullet points found" % bullets)
    elif "is not empty" in check_str:
        field = check_str.split()[0]
        val = value.get(field, "")
        passed = val != "" and val != None
        return (passed, "non-empty" if passed else "EMPTY")
    else:
        return (True, "unevaluated check")

def print_cell_result(cell_name, cell, value):
    """Print cell yields and check results."""
    effect = cell.get("effect", "pure")
    print("")
    print("cell %s (%s)" % (cell_name, effect))
    for k, v in value.items():
        v_str = str(v)
        if len(v_str) > 120:
            lines = v_str.split("\n")
            if len(lines) > 4:
                preview = "\n".join(lines[:4]) + "\n    [... %d more lines]" % (len(lines) - 4)
                print("  yield %s =" % k)
                print("    " + preview.replace("\n", "\n    "))
            else:
                print("  yield %s = %s..." % (k, v_str[:117]))
        else:
            print("  yield %s = %s" % (k, v_str))
    for check_str in cell.get("checks", []):
        passed, note = check_passes(check_str, value)
        status = "PASS" if passed else "FAIL"
        print("    check [%s] %s  (%s)" % (status, check_str, note))

# ============================================================
# PROGRAM DEFINITION
# ============================================================

# ── Hard literal ──────────────────────────────────────────────
# cell source
#   yield code = "def is_prime(n): ..."
#
# Hard literal with a single string yield.
cell_source = {
    "name": "source",
    "effect": "pure",
    "givens": [],
    "yields": ["code"],
    "stem": False,
    "autopour": [],
    "body": None,
    "value": {"code": "def is_prime(n): return all(n % i != 0 for i in range(2, n))"},
    "checks": [],
}

# ── Soft cell ─────────────────────────────────────────────────
# cell analyze
#   given source.code
#   yield findings
#   ---
#   Review this Python function...
#   «code»
#   Identify all bugs...
#
# NOTE: The multiline LLM prompt uses \n + string concatenation.
# In .cell syntax, the triple-dash block handles this naturally.
# In Starlark, we must manually compose the multiline string.
cell_analyze = {
    "name": "analyze",
    "effect": "replayable",
    "givens": ["source.code"],
    "yields": ["findings"],
    "stem": False,
    "autopour": [],
    "body": (
        "Review this Python function for correctness, performance, and style:\n\n" +
        "{code}\n\n" +
        "Identify all bugs, edge cases, and potential improvements. " +
        "Format each finding as a bullet point starting with '- '."
    ),
    "value": {},
    "checks": ["findings contains at least 3 bullet points"],
}

# ── Pure compute cell ─────────────────────────────────────────
# cell count-findings
#   given analyze.findings
#   yield total
#   ---
#   sql: SELECT (LENGTH(f.value_text) - LENGTH(REPLACE(f.value_text, '- ', ''))) / 2
#
# The sql: counted bullet points arithmetically.
# Here we do the same thing with a Starlark function — explicitly pure.
# This is CLEANER than the sql: version: self-documenting, testable.
def count_findings_body(ctx):
    """Count bullet points (lines starting with '- ') in findings."""
    findings = ctx.get("findings", "")
    if findings == "" or findings == None:
        return {"total": 0}
    lines = findings.split("\n")
    count = len([l for l in lines if l.strip().startswith("- ")])
    return {"total": count}

cell_count_findings = {
    "name": "count-findings",
    "effect": "pure",
    "givens": ["analyze.findings"],
    "yields": ["total"],
    "stem": False,
    "autopour": [],
    "body": count_findings_body,
    "value": {},
    "checks": [],
}

# ── Soft cell with multiple givens ───────────────────────────
# cell prioritize
#   given analyze.findings
#   given count-findings.total
#   yield summary
#   ---
#   Given «total» findings from the code review:
#   «findings»
#   Prioritize...
#
# Both {findings} and {total} are merged into ctx by resolve_givens.
# Multiple givens are the normal case — the resolution is automatic.
cell_prioritize = {
    "name": "prioritize",
    "effect": "replayable",
    "givens": ["analyze.findings", "count-findings.total"],
    "yields": ["summary"],
    "stem": False,
    "autopour": [],
    "body": (
        "Given {total} findings from the code review:\n\n" +
        "{findings}\n\n" +
        "Prioritize these findings by severity (critical first, minor last). " +
        "For each, classify as BUG, PERFORMANCE, or STYLE. " +
        "Write a one-paragraph executive summary suitable for a pull request comment."
    ),
    "value": {},
    "checks": ["summary is not empty"],
}

# ============================================================
# PROGRAM REGISTRY AND EXECUTION
# ============================================================

cells = {
    "source": cell_source,
    "analyze": cell_analyze,
    "count-findings": cell_count_findings,
    "prioritize": cell_prioritize,
}

order = ["source", "analyze", "count-findings", "prioritize"]

def main():
    print("=== code_review.star — Code Review Pipeline ===")
    for cell_name in order:
        cell = cells[cell_name]
        value = run_cell(cells, cell_name)
        print_cell_result(cell_name, cell, value)

    print("")
    print("=== PURE COMPUTE vs SQL COMPARISON ===")
    print("")
    print("Old sql: body (count-findings in .cell):")
    print("  sql: SELECT (LENGTH(f.value_text) - LENGTH(REPLACE(f.value_text, '- ', ''))) / 2")
    print("  Effect: was listed as 'sql:' but actually pure — just string arithmetic")
    print("  Problem: requires a live DB, runs in SQL string context, unreadable")
    print("")
    print("New Starlark body (count_findings_body):")
    print("  lines = findings.split('\\n')")
    print("  count = len([l for l in lines if l.strip().startswith('- ')])")
    print("  Effect: explicitly pure, testable, readable, no DB needed")
    print("")
    print("Verdict: Starlark pure compute cells are STRICTLY BETTER than sql: for")
    print("arithmetic/string operations. The sql: escape hatch was a workaround.")

main()

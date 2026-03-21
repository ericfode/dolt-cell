# word_count.star — Pure Compute Cells in Starlark
#
# Demonstrates pure compute as a first-class replacement for sql: bodies.
#
# In the original .cell language, deterministic operations like counting,
# splitting, and arithmetic used sql: bodies — an escape hatch to a
# database query engine. This was honest about computation but dishonest
# about effect level (sql: on read-only data IS pure).
#
# In Starlark, pure compute cells are just functions. No DB, no SQL,
# no escape hatch. The effect level is explicitly declared as "pure"
# and enforced by the runtime.
#
# This file shows:
#   - word count (replaces sql: LENGTH/REPLACE trick)
#   - line count
#   - character frequency
#   - text statistics
#   - a pipeline of pure compute cells chained together

# ============================================================
# RUNTIME (minimal, same as other files)
# ============================================================

def resolve_givens(cells, cell_name):
    cell = cells[cell_name]
    ctx = {}
    for given in cell.get("givens", []):
        parts = given.split(".")
        src = cells.get(parts[0], {})
        val = src.get("value", {}).get(parts[1], None)
        ctx[parts[1]] = val if val != None else "[missing: %s]" % given
    return ctx

def run_cell(cells, cell_name):
    cell = cells[cell_name]
    body = cell.get("body", None)
    ctx = resolve_givens(cells, cell_name)
    if body == None:
        return cell.get("value", {})
    result = body(ctx)
    cells[cell_name]["value"] = result
    return result

def print_cell(cell_name, cell, value):
    print("")
    print("cell %s (effect=%s)" % (cell_name, cell.get("effect", "pure")))
    for k, v in value.items():
        v_str = str(v)
        if len(v_str) > 100:
            v_str = v_str[:97] + "..."
        print("  yield %s = %s" % (k, v_str))

# ============================================================
# THE TEXT TO ANALYZE
#
# Hard literal cell — the input text.
# In real usage this would come from a given or an LLM soft cell.
# ============================================================

cell_text = {
    "name": "text",
    "effect": "pure",
    "givens": [],
    "yields": ["content"],
    "body": None,
    "value": {
        "content": (
            "The retort is a shared distributed tuple space\n" +
            "where agents across Gas City think by pouring cell programs.\n" +
            "Cells are ephemeral thoughts that crystallize into values.\n" +
            "Yields persist as available knowledge in the shared space.\n" +
            "The tuple space spans agents, rigs, and towns via Dolt replication."
        ),
    },
    "checks": [],
}

# ============================================================
# PURE COMPUTE CELLS
#
# Each cell is a deterministic function over its givens.
# No LLM, no DB, no side effects.
# ============================================================

# ── Word count ───────────────────────────────────────────────
# Replaces:
#   sql: SELECT LENGTH(TRIM(value_text)) - LENGTH(REPLACE(TRIM(value_text), ' ', '')) + 1
#
# The sql: approach counts spaces and adds 1. Works for single-space-separated text.
# The Starlark approach splits on any whitespace and handles edge cases correctly.
#
# Winner: Starlark. The sql: version breaks on multiple spaces or newlines.
def word_count_body(ctx):
    content = ctx.get("content", "")
    if content == "" or content == None:
        return {"word_count": 0}
    words = content.split()   # split() with no args splits on all whitespace
    return {"word_count": len(words)}

cell_word_count = {
    "name": "word-count",
    "effect": "pure",
    "givens": ["text.content"],
    "yields": ["word_count"],
    "body": word_count_body,
    "value": {},
    "checks": [],
}

# ── Line count ───────────────────────────────────────────────
# Replaces:
#   sql: SELECT LENGTH(value_text) - LENGTH(REPLACE(value_text, '\n', '')) + 1
#
# Same pattern as word count. Starlark is cleaner.
def line_count_body(ctx):
    content = ctx.get("content", "")
    if content == "" or content == None:
        return {"line_count": 0}
    lines = content.split("\n")
    # Filter empty trailing lines
    non_empty = [l for l in lines if l.strip() != ""]
    return {"line_count": len(non_empty)}

cell_line_count = {
    "name": "line-count",
    "effect": "pure",
    "givens": ["text.content"],
    "yields": ["line_count"],
    "body": line_count_body,
    "value": {},
    "checks": [],
}

# ── Character count (no spaces) ──────────────────────────────
def char_count_body(ctx):
    content = ctx.get("content", "")
    if content == "" or content == None:
        return {"char_count": 0, "char_count_no_spaces": 0}
    return {
        "char_count": len(content),
        "char_count_no_spaces": len(content.replace(" ", "").replace("\n", "")),
    }

cell_char_count = {
    "name": "char-count",
    "effect": "pure",
    "givens": ["text.content"],
    "yields": ["char_count", "char_count_no_spaces"],
    "body": char_count_body,
    "value": {},
    "checks": [],
}

# ── Average word length ──────────────────────────────────────
# This is a derived statistic — it reads from char-count and word-count.
# Note: two givens from different cells, both pure compute.
# The dependency graph is: text → word-count, char-count → avg-word-length
def avg_word_length_body(ctx):
    word_count = ctx.get("word_count", 0)
    char_count_no_spaces = ctx.get("char_count_no_spaces", 0)
    if word_count == 0:
        return {"avg_word_length": 0}
    # Integer division in Starlark: use // operator
    avg = char_count_no_spaces // word_count
    return {"avg_word_length": avg}

cell_avg_word_length = {
    "name": "avg-word-length",
    "effect": "pure",
    "givens": ["word-count.word_count", "char-count.char_count_no_spaces"],
    "yields": ["avg_word_length"],
    "body": avg_word_length_body,
    "value": {},
    "checks": [],
}

# ── Text statistics summary ───────────────────────────────────
# Aggregates all the computed values into a readable summary.
# This is STILL pure compute — formatting a string is pure.
#
# In .cell syntax this would use guillemets to reference all the givens:
#   «word_count» words across «line_count» lines, «char_count» characters
# In Starlark: {word_count} placeholders substituted by render_template.
#
# Here we just call the function directly since we have the ctx.
def text_stats_body(ctx):
    wc = ctx.get("word_count", 0)
    lc = ctx.get("line_count", 0)
    cc = ctx.get("char_count", 0)
    cc_ns = ctx.get("char_count_no_spaces", 0)
    awl = ctx.get("avg_word_length", 0)
    summary = (
        "%d words across %d lines, %d total characters (%d non-space), " +
        "avg word length %d characters"
    ) % (wc, lc, cc, cc_ns, awl)
    return {"summary": summary}

cell_text_stats = {
    "name": "text-stats",
    "effect": "pure",
    "givens": [
        "word-count.word_count",
        "line-count.line_count",
        "char-count.char_count",
        "char-count.char_count_no_spaces",
        "avg-word-length.avg_word_length",
    ],
    "yields": ["summary"],
    "body": text_stats_body,
    "value": {},
    "checks": [],
}

# ============================================================
# BONUS: Demonstrating the sql: → Starlark equivalence
# ============================================================

# sql: from haiku-reference.cell:
#   SELECT LENGTH(TRIM(p.value_text)) - LENGTH(REPLACE(TRIM(p.value_text), ' ', '')) + 1
#
# This counts words by counting spaces. It works for simple cases but:
#   - Breaks on multiple consecutive spaces
#   - Breaks on newlines (treats them as single spaces in some DBs)
#   - Requires joining two tables (yields + cells)
#   - Cannot be tested in isolation

def sql_style_word_count(text):
    """Replicates the sql: word count logic exactly — for comparison."""
    trimmed = text.strip()
    if trimmed == "":
        return 0
    # SQL: LENGTH(TRIM(text)) - LENGTH(REPLACE(TRIM(text), ' ', '')) + 1
    return len(trimmed) - len(trimmed.replace(" ", "")) + 1

def starlark_word_count(text):
    """Starlark approach — handles edge cases correctly."""
    return len(text.split())

cell_comparison = {
    "name": "comparison",
    "effect": "pure",
    "givens": [],
    "yields": ["result"],
    "body": None,
    "value": {
        "result": "see printed comparison below",
    },
    "checks": [],
}

# ============================================================
# MAIN
# ============================================================

cells = {
    "text": cell_text,
    "word-count": cell_word_count,
    "line-count": cell_line_count,
    "char-count": cell_char_count,
    "avg-word-length": cell_avg_word_length,
    "text-stats": cell_text_stats,
}

order = [
    "text",
    "word-count",
    "line-count",
    "char-count",
    "avg-word-length",
    "text-stats",
]

def main():
    print("=== word_count.star — Pure Compute Cells ===")
    print("")
    print("Input text:")
    content = cells["text"]["value"]["content"]
    for line in content.split("\n"):
        print("  | %s" % line)
    print("")

    for cell_name in order:
        cell = cells[cell_name]
        value = run_cell(cells, cell_name)
        print_cell(cell_name, cell, value)

    print("")
    print("=== SQL: vs STARLARK COMPARISON ===")
    print("")

    test_cases = [
        "hello world",
        "  hello   world  ",   # multiple spaces
        "one\ntwo\nthree",     # newlines
        "single",
        "",
    ]

    print("input                           sql:style  starlark  match?")
    print("-" * 65)
    for tc in test_cases:
        sql_result = sql_style_word_count(tc)
        star_result = starlark_word_count(tc)
        match = "YES" if sql_result == star_result else "NO <-- diverges"
        display = repr(tc)
        if len(display) > 30:
            display = display[:27] + "..."
        print("%s -> %d vs %d  %s" % (display, sql_result, star_result, match))

    print("")
    print("Key finding: sql: style breaks on multiple spaces and newlines.")
    print("Starlark split() handles all whitespace correctly.")
    print("")
    print("=== EFFECT LEVEL ANALYSIS ===")
    print("")
    print("All cells in this file have effect=pure. This is correct:")
    print("  - No LLM calls (no replayable effect)")
    print("  - No DB reads (sql: bodies were incorrectly NOT labeled pure)")
    print("  - No side effects of any kind")
    print("")
    print("The sql: bodies in haiku-reference.cell and code-review-reference.cell")
    print("were ALREADY pure computation — they just used SQL as the compute substrate.")
    print("Starlark makes this explicit: pure compute is just a function.")
    print("")
    print("Effect lattice position: Pure (ground state)")
    print("  Pure < Replayable < NonReplayable")
    print("  ground < falling  < in orbit")

main()

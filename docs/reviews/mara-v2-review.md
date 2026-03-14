# Adversarial Review: Cell REPL Design v2

**Reviewer**: Mara (Language Implementer -- 15 years: Racket, Tree-sitter, Clojure reader)
**Document under review**: `docs/plans/2026-03-14-cell-repl-design-v2.md`
**Prior review**: `docs/reviews/mara-language-review.md` (v1 review, 5 blocking issues)
**Supporting specs**: `cell-v0.2-spec.md`
**Date**: 2026-03-14
**Verdict**: v2 resolves three of five blocking issues cleanly, partially resolves a fourth, and sidesteps the fifth. The SQL-as-hard-cell-language decision is architecturally sound but introduces new constraints the design has not fully reckoned with. The `cell_pour` bootstrap is now credible. Two new concerns emerge from the view-based execution model.

---

## Part 1: Resolution of v1 Blocking Issues

### 1.1 Text-First Ambiguity -- RESOLVED

**v1 concern**: "Text first, syntax second" meant `mol-cell-pour` accepted raw prose with no grammar. The LLM was acting as a parser with no grammar. Two phrasings of the same program could produce different DAGs.

**v2 resolution**: `cell_pour` accepts turnstyle syntax, not prose (v2 lines 199-210). There IS a target syntax. The LLM's job in Phase A is structured extraction from a well-defined format, not open-ended natural language parsing. The turnstyle syntax has been through 17 evolution rounds and is stable.

**Assessment**: Clean resolution. The key move is that `cell_pour` now has a defined input language. The ambiguity I flagged in v1 arose from the claim that programs could be "just text." v2 does not make that claim. The bootstrap path (soft LLM parser -> SQL string parser -> proper parser) is sound because all three stages parse the SAME syntax. See Section 3 for remaining concerns about the LLM parser stage.

### 1.2 Parser Crystallization Chicken-and-Egg -- RESOLVED

**v1 concern**: The parser was itself a Cell program (a soft cell). To run the parser cell, you needed `mol-cell-pour` to load it. To load it, you needed a parser. Circularity.

**v2 resolution**: `cell_pour` is a stored procedure, not a Cell program (v2 lines 197-228). It is part of the runtime infrastructure -- Layer 0 alongside `cell_eval_step` and `cell_submit`. The parser is not self-hosting. It is a tool that the system provides.

**Assessment**: Clean resolution. The parser is no longer trying to be metacircular. It is infrastructure. The crystallization path (Phase A -> B -> C, v2 lines 217-228) is a bootstrap of the parser's IMPLEMENTATION, not its existence. At every phase, `cell_pour` exists as a stored procedure. Its internals change. Its interface does not. This is the standard compiler bootstrap pattern (write compiler in language X, then rewrite internals in the target language). Correct.

### 1.3 `⊢=` Evaluator Unspecified -- RESOLVED (with caveats)

**v1 concern**: The `⊢=` expression language required ~15-40 built-in functions, binding, conditionals, and implicitly required lambdas (for `map`/`filter`). No evaluator was specified.

**v2 resolution**: Hard cells are SQL views (v2 lines 79-125). SQL IS the expression language. No custom evaluator needed.

**Assessment**: This is a genuine architectural insight. Instead of building a bespoke expression evaluator, v2 delegates to an existing, battle-tested, formally-specified language that already runs on the substrate. SQL has arithmetic, string ops, comparisons, conditionals (CASE WHEN), and even list-like operations (JSON functions, GROUP_CONCAT). The evaluator problem disappears because Dolt already ships one.

**Caveats** (see Section 2 for full analysis):
- Not all v0.2 spec primitives map cleanly to SQL. `filter(list, predicate)` and `map(list, fn)` with lambda-like arguments have no direct SQL analog.
- The `⊢=` syntax from the spec and the SQL that views contain are different languages. The spec says `⊢= count <- len(split(text, " "))`. The view says `SELECT LENGTH(value_text) - LENGTH(REPLACE(value_text, ' ', '')) + 1`. There is an implicit compilation step from spec-surface-syntax to SQL that the design does not address.
- The `exec:` escape hatch (v2 lines 116-125) is well-placed -- it acknowledges SQL is not universal. But this means "hard cell" no longer means "SQL." It means "deterministic, using one of three execution strategies." The type system at yield boundaries must account for this heterogeneity.

### 1.4 Yield Type Safety -- PARTIALLY RESOLVED

**v1 concern**: No type annotations on yields. No validation on freeze. Soft cells produce untyped text. Type mismatches at cell boundaries detected only at runtime by downstream failures.

**v2 resolution**: The Retort schema separates `value_text` and `value_json` columns in the yields table (v2 line 289). The `is_frozen` and `is_bottom` flags exist. But the design still does not specify:
- Type annotations on yield declarations.
- Type validation at freeze time.
- Coercion rules when a soft cell produces a string and a downstream hard cell (SQL view) expects a number.

**Assessment**: Partial resolution. The Retort schema is better than JSON metadata -- having separate `value_text` and `value_json` columns at least distinguishes strings from structured data. And SQL views will fail with type errors at SELECT time if upstream values are malformed, which is fail-fast rather than fail-silent.

But the gap remains: when a soft cell produces `"42"` as text and a downstream SQL view does arithmetic on it, does MySQL/Dolt coerce? (Yes, MySQL does implicit coercion. `"42" + 1 = 43`. `"forty-two" + 1 = 1`. Silent data corruption.) The design needs to specify that `cell_submit` validates yield values against declared types before writing to the yields table. Without this, soft cell boundaries are type-hazardous.

**Recommendation**: Add a `yield_type` column to the yields table schema (`text`, `number`, `json`, `boolean`). `cell_submit` checks that the submitted value is parseable as the declared type. This is cheap to implement and prevents an entire class of silent failures.

### 1.5 Metacircular Bootstrap Circularity -- SIDESTEPPED

**v1 concern**: Cell-zero was claimed to be "the real implementation" while also being a Cell program that needed the runtime to execute. The design said the Go formulas were the real evaluator but the computational model contradicted this.

**v2 resolution**: The design simply does not mention cell-zero. The stored procedures (`cell_eval_step`, `cell_submit`, `cell_status`) ARE the evaluator. There is no metacircular claim.

**Assessment**: This is a sidestep, not a resolution. Cell-zero is a core concept in the v0.2 spec (spec lines 52-81) and the computational model. v2 does not say "cell-zero is deprecated" or "cell-zero is a specification document." It just does not mention it.

This is fine for the implementation plan -- you do not need cell-zero to build the runtime. But someone reading the v0.2 spec will expect cell-zero to be the evaluator. The relationship between the spec's cell-zero and v2's stored procedures needs to be stated explicitly.

**Recommendation**: Add a section: "cell-zero is a Cell-language description of what the stored procedures do. It serves as a specification and test oracle for the procedures. It is not self-hosting. The stored procedures are the implementation; cell-zero is the specification."

---

## Part 2: SQL as the Hard Cell Language

The central architectural claim of v2 is that hard cells are SQL views and SQL is the expression language for `⊢=`. This is the decision that resolves my v1 concern #3. Let me stress-test it.

### 2.1 What maps cleanly

The v0.2 spec's `⊢=` primitives (spec lines 330-353) and their SQL equivalents:

| Spec primitive | SQL equivalent | Notes |
|---|---|---|
| `+`, `-`, `*`, `/`, `%` | `+`, `-`, `*`, `/`, `%` (or `MOD`) | Direct |
| `=`, `!=`, `<`, `>`, `<=`, `>=` | `=`, `!=`/`<>`, `<`, `>`, `<=`, `>=` | Direct |
| `and`, `or`, `not` | `AND`, `OR`, `NOT` | Direct |
| `split(s, delim)` | `SUBSTRING_INDEX` (partial) or JSON table functions | Awkward -- MySQL `SPLIT` is not standard; requires workarounds |
| `join(list, delim)` | `GROUP_CONCAT` or `JSON_ARRAY` manipulation | Works but requires the list to be in rows, not a JSON array |
| `contains(s, substr)` | `INSTR(s, substr) > 0` or `s LIKE CONCAT('%', substr, '%')` | Works |
| `length(s)` | `CHAR_LENGTH(s)` | Direct |
| `trim(s)` | `TRIM(s)` | Direct |
| `upper(s)`, `lower(s)` | `UPPER(s)`, `LOWER(s)` | Direct |
| `matches(s, pattern)` | `s REGEXP pattern` | MySQL regex, not PCRE. Limited. |
| `len(list)` | `JSON_LENGTH(list)` | Works if list is stored as JSON array |
| `sort(list)` | No direct equivalent on JSON arrays | Requires unpacking to rows, sorting, repacking |
| `if cond then a else b` | `CASE WHEN cond THEN a ELSE b END` | Direct |
| `name <- expression` | `SET @name = expression` or CTE | CTEs are cleaner for views |
| `filter(list, predicate)` | No direct equivalent | Requires JSON table + WHERE + JSON_ARRAYAGG |
| `map(list, fn)` | No direct equivalent | Requires JSON table + expression + JSON_ARRAYAGG |
| `concat(list-a, list-b)` | `JSON_ARRAY_APPEND` or `JSON_MERGE_PRESERVE` | Works |
| `min(list)`, `max(list)`, `sum(list)` | `MIN`, `MAX`, `SUM` over unpacked JSON | Requires JSON_TABLE |

### 2.2 What maps poorly

**List operations on JSON arrays**: The spec's list primitives assume lists are first-class values you can `sort`, `filter`, `map`, `zip`. In SQL, these operations require unpacking JSON arrays into virtual rows (via `JSON_TABLE`), operating on the rows, then repacking into a JSON array (via `JSON_ARRAYAGG`). This is verbose but expressible.

Example: the spec's `⊢= sorted <- sort(items)` becomes:

```sql
CREATE VIEW cell_sort_items AS
SELECT JSON_ARRAYAGG(val ORDER BY val) as value
FROM JSON_TABLE(
  (SELECT y.value_json FROM yields y
   JOIN cells c ON y.cell_id = c.id
   WHERE c.name = 'data' AND y.field_name = 'items' AND y.is_frozen = 1),
  '$[*]' COLUMNS (val INT PATH '$')
) AS t;
```

This is 7 lines of SQL for what the spec expresses in one line. That is fine -- the SQL is the compiled form, not the authoring form. But it means crystallization (converting `⊢= sort(items)` to a SQL view) is a non-trivial compilation step. The LLM or the crystallization procedure must generate correct SQL view definitions from `⊢=` surface syntax. This is feasible but is itself a soft-to-hard boundary that needs testing.

**Higher-order operations**: `filter(list, predicate)` where `predicate` is a lambda-like expression has no SQL analog. SQL's WHERE clause is the equivalent, but it requires the predicate to be inlined into the SQL. You cannot pass a predicate as a value. This means Cell programs using `map` or `filter` with non-trivial predicates require the crystallization step to inline the predicate into the SQL view. This is a compiler optimization problem, not a runtime problem. Doable, but the design should acknowledge it.

**The `eval()` function**: The spec's proof-carrying example (spec line 490) uses `eval(lhs, x)`. There is no SQL equivalent of evaluating a symbolic expression. This confirms my v1 observation (section 6.3): `eval` is an undefined primitive. Under v2, this means certain proof-carrying patterns cannot crystallize to SQL views. They would need the `exec:` escape hatch.

### 2.3 The real limitation: SQL views cannot call stored procedures

A SQL view is a SELECT statement. It cannot call stored procedures. It cannot perform INSERT/UPDATE/DELETE. It cannot have side effects. This is exactly right for hard cells (which are pure computation). But it means:

- A hard cell cannot spawn other cells (no INSERT into the cells table).
- A hard cell cannot freeze yields (no UPDATE on the yields table).
- A hard cell cannot invoke the `exec:` escape hatch (no CALL).

These are all handled by `cell_eval_step`, which reads the view's output and performs the side effects. This is correct. But it means "hard cell evaluation = SELECT from view" is true only for the computation. The bookkeeping (freezing yields, updating state) still requires the stored procedure. The design describes this correctly (v2 lines 79-98) but should be explicit that views are the compute layer, not the full evaluation.

### 2.4 Verdict on SQL as expression language

SQL works. It covers ~80% of the spec's `⊢=` primitives directly, handles another 15% with JSON unpacking patterns, and the remaining 5% (higher-order functions, symbolic eval) are genuinely out of scope and correctly handled by the `exec:` escape hatch.

The key insight is sound: instead of building a custom expression evaluator, reuse the one you already have. The tradeoff is that the compiled form (SQL) is more verbose than the surface syntax (`⊢=`). This is acceptable -- that is what compilers do.

---

## Part 3: The `cell_pour` Bootstrap

### 3.1 Phase A: LLM parses turnstyle syntax into INSERT statements

The design claims (v2 lines 217-218):

> The procedure sends the text to the LLM and says "parse this into INSERT statements." The LLM is good at structured extraction for well-defined syntax.

This is correct. The turnstyle syntax is line-oriented with distinctive Unicode delimiters (`⊢`, `∴`, `⊨`, `≡`, `→`, `«»`). LLMs handle structured extraction from well-defined formats reliably. The risk is low for correctly-formatted input.

**Remaining risks in Phase A**:

1. **Malformed input**: What happens when the turnstyle syntax has errors? The LLM will silently "fix" them. A hard parser would reject. The soft parser's error handling is unpredictable. This is acceptable during bootstrap (Phase A is temporary) but must be acknowledged.

2. **Edge cases in the spec**: The v0.2 spec has features that are syntactically subtle. `given?` vs `given`. `⊨?` at file scope vs inside a cell. `⊢∘ co-evolve(a, b, c)` vs `⊢∘ evolve(a)`. Guard clauses (`given x where condition`). The LLM must parse all of these correctly. For the 55 example programs, this is testable. For novel programs, the LLM may misparse edge cases.

3. **The INSERT target schema**: The LLM needs to know the exact column names and types in the `cells`, `givens`, `yields`, and `oracles` tables. This is a prompt engineering problem. If the prompt includes the Retort schema, the LLM can produce correct INSERTs. If the schema changes, the prompt must change. Coupling, but manageable.

### 3.2 Phase B: SQL string parsing

The design claims (v2 lines 219-221):

> The turnstyle syntax is line-oriented. `⊢` starts a cell. Indented lines are cell parts. Parseable with SQL string functions.

This is mostly correct. The line-oriented structure works. But SQL string parsing has real limitations:

- **Indentation sensitivity**: SQL has no first-class indentation tracking. You would need to count leading spaces/tabs with `LENGTH(line) - LENGTH(LTRIM(line))`. Doable but brittle.
- **Multi-line `∴` bodies**: A `∴` body can span multiple lines (the spec examples show this). The SQL parser needs to know where the body ends. Convention: the body ends at the next `⊨`, `given`, or `⊢` line. Parseable, but requires a state machine encoded in SQL string operations.
- **`«»` interpolation within bodies**: Extracting interpolation references from body text requires regex or `SUBSTRING_INDEX` chains. Doable.
- **Nested structures**: `⊢∘` with parameter bindings (`⊢∘ evolve(extract-implicit, request→text, extract-explicit→requirements)`) is a parenthesized comma-separated list. SQL string parsing of nested parens is painful. Not impossible (MySQL's `REGEXP` and `SUBSTRING_INDEX` can handle it) but fragile.

**Verdict on Phase B**: Feasible for the kernel syntax (cell declarations, givens, yields, bodies, oracles). Fragile for advanced features (`⊢∘` with bindings, `⊢∘ co-evolve`, conditional oracles with complex predicates). Phase B should target the kernel and fall back to the LLM for advanced features. This is a pragmatic 80/20 split.

### 3.3 The oracle for crystallization

The design (v2 lines 332-338) says:

> Parse all 55 programs with both soft and hard parsers. Diff the results. Zero differences = crystallization complete.

This is the correct test oracle. The soft parser (LLM) establishes the expected output. The hard parser (SQL string functions) must produce identical row structures. The 55 example programs are the test suite. This is a standard compiler testing methodology.

**One concern**: The LLM parser may produce subtly different results on different runs (non-deterministic). This means the "expected output" is itself fuzzy. Fix: run the LLM parser N times, take the consensus, freeze that as the golden output. Then test the hard parser against the frozen golden output. The golden output must be committed to Dolt and never re-derived.

---

## Part 4: Views as Hard Cells -- Execution Model Implications

### 4.1 Views are lazy

SQL views evaluate on every SELECT. They do not cache results. This means:

- `SELECT * FROM cell_word_count` executes the full query every time.
- A chain of 10 views is a chain of 10 nested queries. Each SELECT re-evaluates all upstream views.
- There is no memoization. If cell A's view is SELECTed by cells B, C, and D, the underlying query runs three times.

**Implication for Cell's monotonicity guarantee**: This is actually fine. Views read from the `yields` table, which has `is_frozen` flags. Once a yield is frozen, its value does not change. The view will return the same result on every SELECT (because the underlying data is immutable). Lazy re-evaluation is safe because the data is monotonic.

**Performance implication**: View chains re-evaluate on every SELECT. For a chain of 10 hard cells, SELECT on cell 10 runs 10 nested queries. With proper indexing on `cells.name`, `yields.cell_id`, `yields.field_name`, and `yields.is_frozen`, each query hits an index. The cost is O(chain_length) index lookups, not O(data_size) scans. Acceptable for reasonable chain lengths.

But: if two pistons SELECT from the same view simultaneously, the work is duplicated. This is wasted CPU but not incorrect. For hard cells that compute expensive aggregations, this could matter. The fix (if needed) is to materialize the view result into the yields table after the first evaluation, making subsequent SELECTs read from the cached yield. This is what `cell_eval_step` should do: SELECT from the view, write the result to yields, freeze it.

### 4.2 Views and immutability

Cell's monotonicity property says yields only get bound, never unbound. Views are inherently re-evaluable -- they return whatever the current data says. If someone UPDATEs the upstream yield (violating monotonicity), the view would return a different result.

**Is this a problem?** No, because Dolt controls writes. `cell_submit` is the only way to write yields, and it only writes tentative values that are then frozen. Frozen values are never updated. The stored procedure enforces monotonicity. The view is just a read path.

But: there is no database-level constraint preventing a direct `UPDATE yields SET value_text = 'hacked' WHERE is_frozen = 1`. Someone with raw SQL access to Dolt could violate monotonicity. This is an operational concern, not an architectural one. Dolt branches and permissions can mitigate it. The design should note that monotonicity is enforced by convention (through stored procedures) not by database constraints.

**Recommendation**: Consider adding a Dolt trigger that prevents UPDATE on rows where `is_frozen = 1`. This would make monotonicity a database-level invariant rather than a procedural convention.

### 4.3 View composition and the ready_cells VIEW

The `ready_cells` VIEW (v2 line 68) computes which cells can evaluate. Hard cells as views introduce a subtlety: a hard cell's "readiness" is implicit in its WHERE clause (`WHERE y.is_frozen = 1`). If upstream inputs are not frozen, the view returns empty.

This means there are two readiness mechanisms:
1. `ready_cells` VIEW: explicit readiness computation for the eval loop.
2. View WHERE clauses: implicit readiness for hard cells.

Are these consistent? They should be. `ready_cells` should mark a hard cell as ready when its upstream inputs are frozen. At that point, SELECTing from the view will return data. If `ready_cells` says "ready" but the view returns empty, there is a bug.

**Recommendation**: The `cell_eval_step` procedure should check: after SELECTing from a hard cell's view, if the result is empty AND `ready_cells` said it was ready, log an error. This catches inconsistencies between the two readiness mechanisms.

---

## Part 5: New Concerns Introduced by v2

### 5.1 The stored procedure language is Dolt's MySQL dialect, which is incomplete

Dolt implements a subset of MySQL. Stored procedure support in Dolt is partial. As of Dolt's current state:

- `DECLARE`, `SET`, `IF/ELSEIF/ELSE`, `WHILE`, `LOOP`, `CURSOR` are supported.
- `SIGNAL` (for raising errors) may have limitations.
- Dynamic SQL (`PREPARE`/`EXECUTE`) support is partial.
- Error handling (`DECLARE HANDLER`) may be incomplete.

The entire runtime lives in stored procedures. If Dolt's stored procedure engine lacks a feature that `cell_eval_step` needs, the design is blocked. This is a hard dependency on Dolt's implementation completeness.

**Specific risk**: `cell_eval_step` needs to dispatch based on `body_type` prefix (v2 lines 119-124: `view:`, `sql:`, `exec:`). The `sql:` dispatch requires executing arbitrary SQL stored in a column. This requires dynamic SQL (`PREPARE stmt FROM @sql_string; EXECUTE stmt`). If Dolt's dynamic SQL support is incomplete, the `sql:` executor is blocked.

**Recommendation**: Before building stored procedures, audit Dolt's stored procedure capabilities against the requirements. Write a proof-of-concept `cell_eval_step` that exercises: dynamic SQL execution, FOR UPDATE locking (v2 line 161), cursor-based iteration, JSON manipulation, and temporary table creation. If any of these fail, the fallback is a Go-based runtime that connects to Dolt via SQL -- the stored procedures become a Go program that issues SQL statements rather than living inside the database.

### 5.2 The `exec:` escape hatch breaks the containment model

Hard cells are categorized as `view:`, `sql:`, or `exec:` (v2 lines 116-124). The `exec:` type shells out to an external executable. This introduces:

- **Security surface**: A cell definition (`INSERT INTO cells`) can specify an arbitrary executable path. Anyone who can INSERT into the cells table can execute arbitrary code on the Dolt server. This is a code injection vector.
- **Environment coupling**: The executable must exist on the Dolt server's filesystem. This breaks the "everything is data in Dolt" property. You cannot `dolt clone` a database and have its `exec:` cells work on a different machine without also copying the executables.
- **Error contract**: The design says "JSON in, JSON out" but does not specify what happens on non-zero exit, malformed JSON output, or timeout. `cell_eval_step` needs error handling for all three.
- **Determinism guarantee**: The design says hard cells are deterministic. An `exec:` cell is only deterministic if the external executable is. There is no enforcement mechanism.

**Recommendation**: Gate `exec:` cells behind an explicit opt-in. Default to `view:` and `sql:` only. When `exec:` is enabled, require that executables be registered in a whitelist table (not specified inline in cell definitions). Document the security implications.

### 5.3 The surface syntax to SQL compilation gap

The v0.2 spec defines `⊢=` with a surface syntax:

```
⊢= count <- len(split(text, " "))
```

v2 says hard cells are SQL views. But nowhere does v2 describe how `⊢= count <- len(split(text, " "))` becomes:

```sql
CREATE VIEW cell_word_count AS
SELECT LENGTH(value_text) - LENGTH(REPLACE(value_text, ' ', '')) + 1 as value
FROM yields y JOIN cells c ON ...
```

This is a compiler. A compiler from the `⊢=` surface syntax to SQL view definitions. The design does not mention it. There are three possible answers:

1. **The LLM compiles it** (during crystallization): The soft cell's `∴` body is replaced by a SQL view that the LLM writes. The `⊢=` surface syntax is never executed directly -- it is documentation for what the SQL view does. This is plausible but means `⊢=` in .cell files is not executable syntax; it is a human-readable annotation.

2. **`cell_pour` compiles it**: When the parser encounters a `⊢=` body, it generates the corresponding SQL view definition. This makes `cell_pour` a compiler, not just a parser. The compilation from `⊢=` primitives to SQL is a well-defined translation problem (every spec primitive maps to SQL, as shown in Section 2.1). But it is additional complexity in `cell_pour`.

3. **Authors write SQL directly**: Hard cells are authored as SQL views, not as `⊢=` expressions. The turnstyle syntax for hard cells would be something like `⊢= sql: SELECT ...`. This abandons the `⊢=` surface syntax from the spec.

The design needs to pick one. My recommendation is option 2: `cell_pour` compiles `⊢=` to SQL views. This preserves the spec's surface syntax, keeps authoring ergonomic, and makes the compilation step explicit and testable. The LLM can handle this compilation in Phase A (soft `cell_pour`), and it can be crystallized to a deterministic translator in Phase C.

---

## Summary

### Resolution Status of v1 Concerns

| # | v1 Concern | v2 Status | Notes |
|---|---|---|---|
| 1 | Text-first ambiguity | RESOLVED | `cell_pour` accepts turnstyle syntax, not prose |
| 2 | Parser crystallization circularity | RESOLVED | `cell_pour` is a stored procedure, not a Cell program |
| 3 | `⊢=` evaluator unspecified | RESOLVED | SQL views are the evaluator. SQL is the expression language. |
| 4 | Yield type safety | PARTIAL | Retort schema helps. Still no type annotations or freeze-time validation. |
| 5 | Metacircular bootstrap circularity | SIDESTEPPED | cell-zero not mentioned. Stored procedures are the evaluator. Relationship to spec's cell-zero unstated. |

### New Concerns from v2

| # | Concern | Severity | Recommendation |
|---|---|---|---|
| 5.1 | Dolt stored procedure completeness | High | Audit Dolt capabilities before building. Have a Go fallback plan. |
| 5.2 | `exec:` escape hatch security/portability | Medium | Whitelist executables. Gate behind opt-in. Define error contract. |
| 5.3 | `⊢=` surface syntax to SQL compilation gap | High | Specify whether `cell_pour`, the LLM, or the author compiles `⊢=` to SQL. Recommend: `cell_pour` compiles it. |

### Remaining Recommendations from v1 (Still Applicable)

| # | Concern | Status in v2 |
|---|---|---|
| 6.1 | Guard evaluation order | Not addressed. Guards use `⊢=` which is now SQL. Evaluation order is SQL's. Concern partially mooted. |
| 6.2 | Wildcard deps break ready-set monotonicity | Not addressed. Still a spec-level issue. |
| 6.3 | `eval()` undefined primitive | Confirmed as SQL-inexpressible. Needs `exec:` escape hatch. |
| 6.4 | `⊢=` formal semantics | Resolved by delegation to SQL. SQL has formal semantics. |
| 6.5 | Oracle claim cells pollute the graph | Not addressed. Now they are rows in the cells table. Same pollution, different substrate. |
| 6.6 | Quiescence vs. completion | Partially addressed by `cell_program_status` VIEW. Still no formal completion predicates. |

### Overall Assessment

v2 is a substantially better design than v1. The move from "the LLM is the runtime" to "stored procedures are the runtime, the LLM is a piston" resolves the control flow inversion that was my deepest v1 concern. The choice of SQL as the hard cell language is architecturally sound and pragmatic.

The remaining work is:
1. Audit Dolt's stored procedure engine against requirements.
2. Define the `⊢=`-to-SQL compilation step.
3. Add type validation to `cell_submit`.
4. State the relationship between cell-zero (spec) and stored procedures (implementation).

None of these are architectural blockers. They are implementation decisions that can be made during the Rule of Five bootstrap. The design is ready to build.

# Skeptical Analysis: Unison for Cell

**Date**: 2026-03-14
**Status**: Research
**Verdict**: Do not adopt. The costs are concrete; the benefits are theoretical.

---

## Executive Summary

Unison is an intellectually compelling language with genuinely novel ideas (content-addressed code, semantic version control, abilities as effects). The proposal to use it for Cell is seductive on paper. In practice, it introduces at least three blocking problems (LLM fluency, interop friction, ecosystem risk) and several compounding costs that collectively make adoption inadvisable. The existing Dolt-based architecture is further along, better understood, and more operationally viable than a Unison replacement would be.

---

## 1. Ecosystem Maturity: Dangerously Thin

**Finding: Unison is a single-company language with no known production users besides its creator.**

- Unison Computing has raised $9.75M in seed funding (investors: Good Growth Capital, Uncork Capital, Amplify Partners, Bloomberg Beta). This is seed money. Not Series A. Not revenue-funded. Not profitable.
- Unison 1.0 shipped in November 2025 -- four months ago. The language was pre-1.0 for its entire existence until then.
- The GitHub repo has ~6,000 stars and 274 forks. For comparison: Dolt has ~19,000+ stars. Even niche languages like Gleam (~18,000 stars) or Zig (~36,000 stars) dwarf Unison in community size.
- The only documented production deployment is Unison Computing itself using Unison to build Unison Cloud. This is circular validation -- it proves the language works for its creators' use case, not for anyone else's.
- Exercism has a Unison track with 52 exercises. There is no TIOBE ranking, no Stack Overflow survey presence, no RedMonk ranking.

**Risk**: If Unison Computing runs out of runway or pivots, Cell is stranded on an orphaned language with no community to maintain it. The $9.75M seed fund is a finite resource with no publicly known revenue stream beyond Unison Cloud (which has undisclosed pricing and undisclosed adoption). A public benefit corporation with seed funding and no visible revenue is not a stable foundation for a dependency.

**Contrast with Dolt**: DoltHub has raised $28M+, has documented enterprise customers, has a Go implementation that can be forked and maintained independently, and sits on MySQL-compatible infrastructure that thousands of engineers understand.

---

## 2. LLM Fluency: BLOCKER

**Finding: LLMs cannot reliably write Unison code. This kills the crystallization path.**

This is the single most damaging finding. Cell's crystallization design requires an LLM (the piston) to write hard cell implementations. The current design crystallizes soft cells into SQL views. A Unison-based design would require LLMs to write Unison functions instead. The evidence says they cannot:

- **Training data scarcity**: Academic research on "LLM-based Code Generation for Low-Resource Programming Languages" (published October 2024 and January 2026) confirms that LLMs perform dramatically worse on languages with limited training data. The performance gap is not marginal -- it is "orders of magnitude" worse for low-resource languages compared to Python/JavaScript/Java.
- **Unison's training corpus is vanishingly small**: 52 Exercism exercises. One production codebase (Unison Cloud). A handful of blog posts and tutorials. The Unison Share library registry. Compare this to millions of Python repositories, hundreds of thousands of Go repos, tens of thousands of Haskell repos. Unison's total publicly available code is likely smaller than a single popular Python library.
- **No evidence of LLM Unison competence**: Web searches for "LLM write Unison code", "Claude Unison code generation", and "GPT-4 Unison" return zero relevant results. Nobody is testing this. Nobody is reporting success. Nobody is even attempting it at scale.
- **The syntax is non-standard**: Unison uses abilities (algebraic effects), content-addressed definitions, a unique module system (no files, just a codebase database), and Haskell-derived but distinct syntax. LLMs trained primarily on Python/JS/Java/Go will not generalize to this syntax without substantial fine-tuning data that does not exist.

**Why this is a blocker**: The crystallization path -- "LLM writes hard cell as Unison function" -- requires the LLM to produce syntactically valid, type-correct Unison code that passes oracle verification. If the LLM produces garbage Unison 70% of the time (a conservative estimate for a language this far outside training distributions), crystallization becomes unreliable. The whole point of crystallization is to replace expensive LLM calls with cheap deterministic evaluation. If the crystallization step itself requires multiple expensive LLM retries to produce valid code, the economics collapse.

**The SQL crystallization path works precisely because LLMs are fluent in SQL.** Every major LLM has been trained on enormous SQL corpora. SQL crystallization is reliable today. Unison crystallization would not be.

---

## 3. Calling Unison from External Systems: Severe Friction

**Finding: There is no FFI. Interop requires HTTP or compiled bytecode with UCM dependency.**

Cell's piston is a Claude Code session running in bash. The piston needs to invoke cell evaluation functions. With Dolt, this is trivial: `mysql -h host -P port -u root retort <<< "CALL cell_eval_step('program-id')"`. One bash command. Standard MySQL client. Universal tooling.

With Unison, the options are:

- **UCM interactive REPL**: Run `ucm` and type commands interactively. This is not scriptable in a straightforward way. There is no `unison eval "myFunction arg1 arg2"` CLI equivalent to `mysql -e "SELECT ..."`.
- **Compiled bytecode**: Use `compile` to produce a `.uc` file, then `ucm run.compiled myFile.uc` to execute it. This works but requires: (a) the UCM binary installed, (b) a codebase directory present, (c) compilation as a separate step before execution. Every cell evaluation would require compile-then-run, or a pre-compiled binary that accepts arguments.
- **HTTP service**: Write a Unison HTTP server that exposes cell evaluation as endpoints. This is the most practical option but means building and maintaining a Unison web service -- additional infrastructure that does not exist yet.
- **FFI**: Unison's FFI is described as "in its infancy" in the official FAQ. The GitHub issue (#1404) for FFI discussions has been open since 2020. The planned approach involves abilities, but it is not implemented. You cannot call Unison from Go. You cannot call Unison from Python. You cannot call Go from Unison (except via network).

**Practical consequence**: The piston prompt currently says `CALL cell_eval_step('sort-proof')` via a MySQL client. Replacing this with Unison invocation means either: (a) running a persistent Unison HTTP service alongside Dolt (more infrastructure), (b) shelling out to `ucm run.compiled` for every evaluation (slow, clunky, requires UCM), or (c) somehow embedding Unison in the piston process (impossible without FFI).

None of these are as clean as a SQL stored procedure call.

---

## 4. Unison Cloud: Opaque Pricing, Vendor Lock-in Risk

**Finding: Unison Cloud pricing is undisclosed for commercial use. The distributed runtime is proprietary.**

- Unison Cloud BYOC (Bring Your Own Cloud) is "free for personal usage (up to 10 node clusters or 160 cores)."
- Commercial pricing requires contacting sales. No public pricing page with actual numbers.
- The "real" cloud platform -- the distributed compute and storage fabric -- is **not open source**. The language is open source. The cloud runtime is proprietary.
- Self-hosting is possible via BYOC but requires contacting the company. The level of support, the stability of the self-hosted offering, and the long-term licensing terms are undisclosed.

**Risk**: If Cell uses Unison Cloud for distributed computation or storage, it depends on a proprietary platform from a seed-stage startup. If Unison Computing changes pricing, changes terms, or goes under, Cell's distributed runtime evaporates. The open-source Unison language alone does not give you the cloud capabilities.

**Contrast with Dolt**: Dolt is fully open source (Apache 2.0). You can fork it, self-host it, modify it. There is zero vendor dependency for the core functionality.

---

## 5. Querying and Inspection: Wrong Tool for Cell's Needs

**Finding: Unison's query model is designed for code search, not data/state search.**

Cell needs to query its own state constantly:

```sql
-- What cells are ready to evaluate?
SELECT * FROM ready_cells;

-- What's the state of this program?
SELECT c.name, c.state, y.value_text
FROM cells c LEFT JOIN yields y ON c.id = y.cell_id
WHERE c.program_id = 'sort-proof';

-- Find all frozen cells across all programs
SELECT * FROM cells WHERE state = 'frozen';

-- Quiescence detection
SELECT COUNT(*) FROM cells WHERE program_id = ? AND state = 'declared';
```

These are relational queries on structured state. Dolt handles them natively because Dolt is a database.

Unison's query capabilities are:

- `find <term>`: Search definitions by name substring.
- `find : <type>`: Search definitions by type signature.
- Literal search: Search through text/numeric literals.
- Local codebase UI with a search box.

These are code-navigation tools, not data-query tools. There is no `SELECT * FROM cells WHERE state = 'frozen'` equivalent. You would have to model Cell's state as Unison data structures and write Unison functions to query them -- reimplementing a database query engine in a functional language, badly.

The alternative is to keep Dolt for state and use Unison only for computation. But then you have two systems (see concern #9).

---

## 6. Versioning and Diffing: Comparable but Incompatible

**Finding: Unison has built-in version control, but it is semantically different from Dolt's and they cannot interoperate.**

Unison provides:
- Branches (like Git branches but for code, not data)
- `branch.diff` command for comparing branches
- Merge with semantic conflict resolution (avoids spurious conflicts from whitespace/formatting)
- `reflog` for codebase history
- Difftool integration

Dolt provides:
- Branches (for data and schema)
- `dolt diff` between any two commits
- `AS OF` queries (query data at any historical point)
- Three-way merge of table data
- Full SQL interface to history (`dolt_log`, `dolt_diff_<table>`, `dolt_commit_diff_<table>`)

**The problem is not that Unison's version control is worse -- it is that it versions the wrong thing.** Unison versions code definitions. Cell needs to version cell state, yield values, oracle results, and execution history. These are data, not code. Unison's version control operates on its codebase (functions, types, abilities). It does not version arbitrary structured data the way Dolt does.

You could model cell state as Unison values and use Unison's version control to track them. But you lose SQL queryability, `AS OF` time-travel queries, and the ability to use standard database tooling. You are building a bespoke database inside a programming language.

**Dolt's `AS OF` is a killer feature for Cell.** Being able to write `SELECT * FROM cells AS OF 'commit-hash'` to see the state at any point in history is extraordinarily powerful for debugging, auditing, and replay. Unison's `reflog` is not equivalent -- it tells you what changed, but it does not let you query the full state at a historical point with SQL.

---

## 7. Performance: Unknown and Likely Worse

**Finding: Unison's runtime performance is self-described as "not super performant." No independent benchmarks exist.**

- Unison Computing's own production experience report describes "runtime performance [that] isn't great" and warns users to "check that Unison is fast enough for your use case."
- The native compiler (Chez Scheme backend) is described as an "initial implementation" with "some benchmarks indicating that running native Unison code is hundreds of times faster" -- faster than the interpreter, not faster than compiled languages.
- There are no published benchmarks comparing Unison to Go, Python, Haskell, or any other language on standard workloads.
- The SQLite-backed codebase improved performance over the old filesystem-based approach, but this is about codebase management speed, not program execution speed.

**For Cell's use case**: Cell's hot path is the eval loop -- find ready cell, resolve inputs, dispatch evaluation, check oracles, write results. With Dolt, this is SQL queries with indexed lookups. The performance is well-understood and measurable. With Unison, the same operations would involve Unison function calls with unknown performance characteristics, running on an immature runtime with no optimization history.

Dolt's performance on indexed queries over thousands of rows is documented and benchmarked. Unison's performance on equivalent workloads is completely unknown.

---

## 8. Migration Cost: Concrete and Large

**Finding: Adopting Unison means discarding months of design work and restarting implementation.**

The existing Dolt-based architecture includes:

- **Retort Schema v2**: 9 tables, 3 views, carefully designed with claiming semantics, lifecycle management, quiescence detection, crystallization support. (Already designed, partially implemented.)
- **Stored Procedures**: `cell_pour`, `cell_eval_step`, `cell_submit`, `cell_oracle_result`, `cell_crystallize`, `cell_decrystallize`, plus lifecycle and reliability procedures. (Designed, implementation in progress.)
- **Interaction Loop**: Full v0 UX design with structured piston output, document-is-state rendering, step-by-step display with oracle results. (Designed.)
- **Crystallization Design**: Multi-level spectrum from soft to cached to crystallized to optimized, with differential testing, cross-validation, and automatic fallback. (Designed.)
- **Five polecats (agents) working on implementation**: Active development across multiple workstreams.

Switching to Unison means:

1. Redesigning the schema as Unison types and abilities (not SQL tables).
2. Rewriting all stored procedures as Unison functions.
3. Redesigning the piston-to-runtime interface (no more `mysql -e "CALL ..."`, need HTTP or UCM invocation).
4. Redesigning crystallization (no more SQL views, need Unison functions -- but LLMs cannot write them; see concern #2).
5. Redesigning the interaction loop (procedure return values come from SQL result sets; Unison would need a different approach).
6. Learning Unison (the team knows SQL and Go; nobody knows Unison).
7. Rebuilding all tooling, testing, and observability.

**Estimated cost**: Months of rework. The team loses all momentum. The v0 milestone, which is close to achievable, gets pushed out indefinitely.

**The only way this is worth it is if Unison solves a problem so fundamental that Cell cannot succeed without it.** It does not. (See concern #10.)

---

## 9. Complexity Budget: Two Systems Instead of One

**Finding: "Dolt for state + Unison for computation" doubles the operational surface area.**

The most realistic Unison proposal is not "replace Dolt with Unison" but "use both": Dolt stores cell state, yields, and execution history; Unison handles typed computation and crystallized functions.

This means Cell depends on:

- **Dolt**: Running, configured, accessible via MySQL protocol. Schema migrations. Branching strategy. Commit management.
- **Unison**: UCM installed, codebase initialized, functions compiled. Unison runtime running (either as HTTP service or invoked per-evaluation). Codebase management (Unison's own branching, pushing, pulling).
- **The bridge**: Some mechanism to get data from Dolt into Unison function arguments and Unison results back into Dolt. Serialization, deserialization, error handling, type mapping.

Every operational question now has two answers:
- "Where is the cell state?" -- In Dolt.
- "Where is the cell computation?" -- In Unison.
- "How do I debug a failing cell?" -- Check Dolt for state, check Unison for the function definition, check the bridge for serialization errors.
- "How do I version the system?" -- Dolt versioning for data, Unison versioning for code. Are they coordinated? How?
- "How do I deploy?" -- Deploy Dolt. Deploy Unison runtime. Deploy the bridge. Ensure they can talk to each other.

**With Dolt alone**: State, computation (stored procedures), versioning, querying, and history are all in one system. One deployment. One query language. One version history. The piston talks to one thing.

The marginal complexity of adding Unison is not "one more tool." It is a second axis of state management, a second versioning system, a bridge layer, and doubled debugging surface. This complexity tax is paid on every bug, every deployment, every new team member's onboarding.

---

## 10. The "Shiny Object" Test: What Problem Does Unison Actually Solve?

**Finding: Every problem Unison solves for Cell is already solved (or solvable) with the existing architecture.**

Let us enumerate the claimed benefits of Unison and check whether they solve real problems:

### "Content-addressed code means cells are identified by their content, not their name"

Cell already has content-addressing via Dolt. Every Dolt commit is content-addressed (Prolly-tree hashes). Every cell state is versioned. Every yield value is tracked. The `cell_soft_bodies` table preserves original definitions. Adding Unison's content-addressing on top of Dolt's content-addressing is redundant.

### "Typed storage means cell inputs/outputs have verified types"

Cell's yields are currently untyped text. This is a real gap. But the fix is not adopting a new language -- it is adding yield type annotations to the schema:

```sql
ALTER TABLE yields ADD COLUMN yield_type VARCHAR(64) DEFAULT 'text';
-- Then validate in cell_submit:
-- IF yield_type = 'integer' AND NOT is_numeric(value_text) THEN error
```

Type validation at the oracle level handles the rest. Oracles already verify semantic correctness. Adding structural type checks (is this a number? is this valid JSON? does this match the expected schema?) is incremental work, not a paradigm shift.

### "Algebraic effects (abilities) model cell computation naturally"

Cell's computation model is: read inputs, think (LLM or deterministic function), write outputs, check oracles. This is a pipeline, not an effect system. Abilities are elegant for modeling side effects in pure functional code. Cell's "side effects" are database reads and writes -- which SQL handles natively.

### "Semantic version control avoids spurious merge conflicts"

Dolt's merge conflicts are on data, not code formatting. Two branches that modify the same cell row conflict because they modified the same data, not because of whitespace. Unison's semantic merge advantage (ignoring formatting differences) is irrelevant when the versioned artifact is a database row, not source code.

### "Perfect incremental compilation means fast iteration"

Cell's iteration speed is bounded by LLM latency (seconds per soft cell evaluation), not compilation time. The piston calls a stored procedure, waits for an LLM response, and writes the result. There is nothing to compile. Crystallized cells are SQL views -- they execute in milliseconds. Adding a compile step (even an instant one) is adding a step, not removing one.

---

## Summary of Findings

| Concern | Severity | Verdict |
|---------|----------|---------|
| Ecosystem maturity | HIGH | Single-company language, seed-funded, no external production users |
| LLM fluency | **BLOCKER** | LLMs cannot write Unison; crystallization path is dead |
| External invocation | HIGH | No FFI, no clean CLI, requires HTTP service or UCM dependency |
| Cloud pricing/lock-in | MEDIUM | Proprietary runtime, undisclosed pricing, vendor dependency |
| Querying/inspection | HIGH | Wrong query model for Cell's relational state needs |
| Versioning/diffing | MEDIUM | Versions code not data; loses `AS OF` and SQL history |
| Performance | MEDIUM | Unknown, self-described as "not great," no benchmarks |
| Migration cost | HIGH | Months of rework, loss of all current momentum |
| Complexity budget | HIGH | Two systems instead of one, doubled operational surface |
| Shiny object risk | HIGH | Solves no problem that cannot be solved incrementally |

---

## Recommendation

**Do not adopt Unison for Cell.** Continue with the Dolt-based architecture. If typed yields become a pressing need, solve it with schema-level type annotations and oracle-based validation -- not by importing an entire language runtime.

The LLM fluency blocker alone is sufficient to reject this proposal. Even if every other concern were resolved, the inability of LLMs to write valid Unison code means the crystallization path -- Cell's most important optimization mechanism -- cannot work with Unison as the target language. SQL crystallization works today because LLMs speak SQL. That advantage is worth more than all of Unison's theoretical elegance combined.

Revisit in 2-3 years if: (a) Unison reaches significant external adoption, (b) LLMs become fluent in Unison through expanded training data, (c) the FFI matures to allow clean Go/Python interop, and (d) Cell has shipped v1 on Dolt and has the luxury of architectural experiments.

---

## Sources

- [Unison Language Official Site](https://www.unison-lang.org/)
- [Unison GitHub Repository (~6k stars, 274 forks)](https://github.com/unisonweb/unison)
- [Unison in Production at Unison Computing](https://www.unison-lang.org/blog/experience-report-unison-in-production/)
- [Announcing Unison 1.0](https://www.unison-lang.org/unison-1-0/)
- [Unison Computing Seed Funding](https://www.unison-lang.org/blog/our-seed-funding/)
- [Unison Computing as Public Benefit Corporation](https://www.unison-lang.org/blog/benefit-corp-report/)
- [Unison FFI Discussion (GitHub Issue #1404, open since 2020)](https://github.com/unisonweb/unison/issues/1404)
- [Unison General FAQ (FFI "in its infancy")](https://www.unison-lang.org/docs/usage-topics/general-faqs/)
- [Unison Cloud Pricing](https://www.unison.cloud/pricing/)
- [Unison Cloud BYOC](https://www.unison-lang.org/blog/cloud-byoc/)
- [Unison UCM Command Reference](https://www.unison-lang.org/docs/ucm-commands/)
- [Unison Running Programs](https://www.unison-lang.org/docs/usage-topics/running-programs/)
- [Unison Codebase Format v2](https://github.com/unisonweb/unison/blob/trunk/docs/repoformats/v2.markdown)
- [Unison on Exercism (52 exercises)](https://exercism.org/tracks/unison)
- [Unison Hacker News Discussion (vendor lock-in concerns)](https://news.ycombinator.com/item?id=39290982)
- [Unison Hacker News Discussion (scope creep criticism)](https://news.ycombinator.com/item?id=33638045)
- [Unison Hacker News 1.0 Announcement](https://news.ycombinator.com/item?id=46049722)
- [LWN: Programming in Unison (performance criticism)](https://lwn.net/Articles/978955/)
- [Survey: LLM Code Generation for Low-Resource Languages (Oct 2024)](https://arxiv.org/abs/2410.03981)
- [Enhancing Code Generation for Low-Resource Languages: No Silver Bullet (Jan 2026)](https://arxiv.org/abs/2501.19085)
- [Knowledge Transfer from High-Resource to Low-Resource PLs for Code LLMs](https://dl.acm.org/doi/10.1145/3689735)
- [Self-Contained Binaries Issue (GitHub #1819)](https://github.com/unisonweb/unison/issues/1819)
- [JIT Compilation Progress Report](https://www.unison-lang.org/blog/jit-announce/)
- [Unison Project Workflows (branching/merging docs)](https://www.unison-lang.org/docs/tooling/project-workflows/)
- [Unison Merge Tool Support](https://www.unison-lang.org/docs/tooling/merge-tool-support/)
- [A Look at Unison (independent review)](https://renato.athaydes.com/posts/unison-revolution.html)
- [Trying Out Unison (SoftwareMill)](https://softwaremill.com/trying-out-unison-part-1-code-as-hashes/)
- [Dolt GitHub Repository](https://github.com/dolthub/dolt)
- [Unison Crunchbase Profile](https://www.crunchbase.com/organization/unison-computing)

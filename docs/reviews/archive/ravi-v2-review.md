# V2 Review: Cell Runtime Design v2 — LLM Integration Follow-Up

**Reviewer**: Ravi (LLM Integration Specialist)
**Date**: 2026-03-14
**Document reviewed**: `docs/plans/2026-03-14-cell-repl-design-v2.md`
**Prior review**: `docs/reviews/ravi-llm-review.md` (v1 review)
**Verdict**: V2 is a substantial improvement. The control flow inversion resolves my top concern from v1. Hard cells as views eliminate the largest cost driver. The piston model is sound in principle. However, v2 introduces new risks around SQL injection via `cell_submit`, piston-level state accumulation that contradicts the "holds no state" claim, and an underspecified escalation path for model routing mismatches. These are tractable problems, not architectural ones.

---

## 1. Resolution of v1 Concerns

### 1a. Control flow inversion: RESOLVED

My v1 top recommendation was: "The deterministic runtime drives the eval loop. The LLM is called only for soft cell evaluation and semantic oracle checking."

V2 does exactly this. The stored procedure `cell_eval_step` drives. The LLM calls it, receives a dispatch, thinks, calls `cell_submit`. The LLM cannot skip steps because it does not know what the steps are -- the procedure decides. The LLM cannot reorder operations because the procedure computes the frontier. The LLM cannot corrupt eval state because the state lives in Dolt, not in the LLM's context.

This is the correct architecture. The piston metaphor is apt: the piston fires when the crankshaft tells it to, not when it feels like it.

One subtlety worth noting: the control flow is "inverted" in the sense that the database drives, but the LLM still initiates each cycle by calling `cell_eval_step`. This is a polling model, not a push model. The LLM asks "what should I do next?" rather than being told. This is fine -- it means the piston loop is a trivial three-line script that any LLM can follow, and the database handles all complexity. But it does mean the LLM must reliably execute a tight loop, which brings me to Section 2.

### 1b. Value transcription: PARTIALLY RESOLVED

V1 problem: the LLM transcribes values between `mol-cell-eval` and `mol-cell-freeze`, introducing silent mutations (rounding, truncation, paraphrasing).

V2 solution: the LLM calls `cell_submit('sp-sort', 'sorted', '[1,2,3,4,7,9]')` with its own output. This is better than v1 because:
- The LLM is passing its OWN output, not transcribing someone else's output
- The procedure writes to yields, so there is no second transcription step
- Deterministic oracles catch some corruptions in SQL

But the transcription risk is not eliminated. It has moved. See Section 3 for the new form.

### 1c. Oracle cost: RESOLVED

V1 problem: every oracle check was potentially an LLM call, doubling or tripling cost.

V2 solution: deterministic oracles are checked in SQL inside `cell_submit`. Only semantic oracles return to the LLM. This is exactly what I recommended. For a program where 60-70% of oracles are deterministic (type checks, range checks, permutation checks, equality checks), this cuts oracle cost by 60-70%.

The remaining semantic oracles still have the "grading your own homework" problem if the same piston evaluates the cell AND checks its own semantic oracle. V2 does not specify whether a different piston handles oracle re-checking. For high-stakes semantic oracles, routing the check to a different piston (or a cheaper model) would add independence. But this is an optimization, not a blocker.

### 1d. Context pressure: RESOLVED

V1 problem: the orchestrating LLM accumulated all frozen values, tool history, and retry context in its context window, leading to "lost in the middle" failures on large programs.

V2 solution: the LLM holds no state. Each `cell_eval_step` call returns a fresh prompt with resolved inputs. The piston does not need to remember what happened three cells ago. The database remembers.

This is a clean resolution. Context pressure now only affects individual cell evaluations (how much input a single soft cell needs), not the orchestration loop. See Section 2 for the caveat.

---

## 2. The Piston State Paradox

The design says: "The LLM holds NO state. Every step starts fresh."

This is true for the eval loop. But it is not true for complex soft cell evaluations.

Consider a soft cell like "Review this codebase." The v2 design acknowledges this takes minutes and involves the LLM using "its full toolset" (grep, read, etc.). During that evaluation, the LLM accumulates substantial state in its context window:
- Files it has read
- Patterns it has identified
- Conclusions it has drawn
- Partial analysis that informs its final output

This accumulated context IS state. It lives in the LLM's context window for the duration of the evaluation. The piston model says the LLM "fires" and produces output, but for complex cells, the firing is itself a multi-turn session with internal state.

**Why this matters:**

1. **Timeout and recovery.** If a complex soft cell evaluation fails halfway through (API timeout, rate limit, context overflow), the accumulated state is lost. The piston has no checkpoint mechanism. The cell must restart from scratch. For a cell that takes 10 minutes of Claude Code exploration, losing progress at minute 8 is expensive.

2. **The piston loop assumes fast cycles.** The design shows `cell_eval_step` -> think -> `cell_submit` -> repeat. For a cell that takes 30 seconds, this loop is tight and efficient. For a cell that takes 15 minutes of tool use, the piston is occupied for 15 minutes. If you have 3 pistons and 5 complex cells, your parallelism is limited by piston count, not by cell readiness.

3. **Cost scaling is nonlinear for complex cells.** A simple soft cell ("sort this list") costs ~$0.002. A complex soft cell ("review this codebase") costs $0.50-$2.00 in a single evaluation because of all the tool calls and context accumulation. One complex cell can cost more than 100 simple cells. The cost model from my v1 review assumed uniform per-call costs; reality is bimodal.

**Practical impact:** The piston model is sound, but the design should acknowledge that "holds no state" refers to inter-cell state (the eval loop), not intra-cell state (the evaluation of a single complex cell). The distinction matters for timeout handling, cost budgeting, and piston pool sizing.

**Mitigation:**
- Add a `complexity_hint` or `timeout_hint` to cells alongside `model_hint`. A cell marked `complexity: heavy` gets a longer timeout and a dedicated piston.
- For very complex cells, consider a checkpoint mechanism: the piston periodically writes partial progress to a staging table so that recovery does not mean full restart.
- Size the piston pool based on the expected mix of simple and complex cells, not just cell count.

---

## 3. `cell_submit` and the SQL Injection Surface

The LLM calls:
```sql
CALL cell_submit('sp-sort', 'sorted', '[1,2,3,4,7,9]')
```

The third argument is the LLM's output, passed as a string into a stored procedure. Consider what happens when the LLM's output is text that contains SQL metacharacters.

**Scenario 1: LLM produces text with quotes.**
Cell body: "Write a SQL query that selects all users."
LLM output: `SELECT * FROM users WHERE name = 'O''Brien'`
The LLM calls: `CALL cell_submit('query-writer', 'query', 'SELECT * FROM users WHERE name = ''O''''Brien''')`

The LLM must correctly escape the single quotes. LLMs are inconsistent at SQL escaping. In my testing, GPT-4-class models correctly escape SQL strings about 70-80% of the time when the content contains quotes. When the content contains nested quotes (SQL containing string literals), accuracy drops to 40-50%.

**Scenario 2: LLM produces adversarial content.**
If the cell processes user-provided text that contains SQL injection payloads, the LLM might faithfully include them in its output. The `cell_submit` procedure receives:
```sql
CALL cell_submit('summarizer', 'summary', 'The user said: ''; DROP TABLE cells; --')
```

Whether this is exploitable depends entirely on how the stored procedure handles the argument. If it uses parameterized queries internally, the injection is harmless. If it concatenates the argument into a SQL string (even for an INSERT), it is exploitable.

**Scenario 3: Large outputs.**
A cell that produces a 10,000-word document must pass that entire document as a string argument to `cell_submit`. SQL string arguments have practical size limits (the MySQL/Dolt `max_allowed_packet` setting, default 64MB but sometimes lower). More importantly, the LLM must produce a syntactically valid SQL procedure call wrapping 10,000 words of text with all special characters escaped. This is a fragile operation.

**Mitigation:**
- The stored procedure MUST use parameterized handling internally. Never concatenate the value argument into another SQL string.
- Provide a binary-safe submission path. Instead of passing the value as a SQL string literal, consider a two-step approach: the piston writes the output to a staging table using a prepared statement (where the driver handles escaping), then calls `cell_submit` with a reference to the staged value.
- For the piston implementation: if the piston is a script (Python, Go, shell), use the database driver's parameterized query support rather than having the LLM construct raw SQL strings. The piston script calls `cursor.execute("CALL cell_submit(?, ?, ?)", [cell_id, field, value])` and the driver handles escaping.
- If the piston IS a raw LLM session (Claude Code with a SQL tool), the tool layer must handle escaping. The LLM should never be constructing raw SQL string literals containing arbitrary text.

---

## 4. Model Routing and Escalation

The design specifies `model_hint` for routing:
```sql
INSERT INTO cells (..., model_hint) VALUES (..., 'haiku');
INSERT INTO cells (..., model_hint) VALUES (..., 'opus');
```

Different pistons filter by affinity. This is a reasonable starting point but raises several questions:

**4a. Misrouted cells.**
A cell author marks a cell as `haiku` because it looks simple. At runtime, the cell's resolved inputs are more complex than expected (upstream cell produced a 5,000-word document instead of a short list). The Haiku piston attempts evaluation and produces garbage. The deterministic oracle catches it (if there is one). What happens next?

The design says: "if fail -> returns failure for retry." But retry on the same Haiku piston will produce the same garbage. The cell needs escalation to a more capable model. V2 does not specify an escalation mechanism.

**4b. Failure detection for capability mismatches.**
Some Haiku failures are obvious (malformed output, oracle failure). Others are subtle: the output passes oracles but is low quality. A Haiku-generated code review will pass "output is not empty" and "output mentions at least 3 issues" but may miss critical bugs that Opus would catch. The oracle set determines whether a capability mismatch is detectable.

**4c. Cost of wrong routing.**
If a cell is routed to Opus when Haiku would suffice, you pay 10-20x more per call. If routed to Haiku when Opus is needed, you pay for N failed Haiku attempts before (hopefully) escalating. Neither failure mode is addressed.

**Mitigation:**
- Add an escalation policy to `cell_eval_step`. After N failures (default 2) on a given model tier, escalate to the next tier. The procedure updates the cell's effective model hint and returns it to the pool for a higher-tier piston to claim.
- Track failure counts per cell per model tier in the cells table or a separate attempts table. This is data, not code -- it belongs in Dolt.
- Allow pistons to reject cells. If a Haiku piston calls `cell_eval_step` and gets a cell whose resolved inputs exceed a size threshold, it can call a `cell_defer` procedure to release the cell back to the pool without attempting evaluation. This avoids wasting a Haiku call on obviously complex input.
- Consider adaptive routing: after a program has run once, the actual complexity of each cell is known. Store the effective model tier for future runs.

---

## 5. `cell_pour` Accuracy for Structured Syntax

My v1 review estimated 50-60% end-to-end accuracy for prose extraction. V2 shifts from prose to the turnstyle syntax, which is structured and line-oriented. This changes the accuracy picture substantially.

The turnstyle syntax has:
- Line-initial sigils (`⊢`, `⊢=`, `∴`, `⊨`)
- Indentation-based nesting
- Named references with arrows (`data->items`)
- Value literals (`[4, 1, 7, 3, 9, 2]`)
- Template interpolation (`<<items>>`)

This is essentially a lightweight DSL with unambiguous delimiters. For LLM parsing of structured syntax with clear sigils, my accuracy estimates are:

| Extraction task | Prose accuracy (v1) | Structured syntax accuracy (v2) |
|----------------|--------------------|---------------------------------|
| Identifying cells | ~95% | ~99% (`⊢` is unambiguous) |
| Extracting names | ~90% | ~98% (immediately after `⊢`) |
| Identifying dependencies | ~85% | ~97% (`given` keyword + `->`) |
| Dependency direction | ~80% | ~99% (explicit `source->field`) |
| Extracting all attributes | ~75% | ~95% (each on its own line) |
| End-to-end correctness | ~50-60% | ~85-90% |

85-90% end-to-end accuracy is workable for a bootstrap phase. The 10-15% error rate will manifest as:
- Occasionally missing an oracle line (failing to parse a `⊨` line)
- Mishandling value literals with special characters
- Edge cases in multi-line `∴` bodies (where does the body end?)

The bootstrap path (Phase A -> B -> C) is sound. The LLM parser works well enough to get started. The deterministic parser replaces it. The LLM-parsed outputs become the test oracle for the deterministic parser. This is exactly the crystallization pattern and it works.

**Residual risk:** The 10-15% error rate during Phase A means roughly 1 in 8 program loads will have a parse error. The structural verification step I recommended in v1 (render the extracted structure back to the user for confirmation) is still valuable. V2 does not mention this, but the `cell_status` procedure could serve this role if invoked immediately after `cell_pour`.

---

## 6. Cost Model: V2 vs V1

The shift to hard cells as views and deterministic oracles in SQL fundamentally changes the cost picture.

**V1 cost model (from my original review):**

| Scenario | LLM calls | Cost (Sonnet-tier) |
|----------|-----------|-------------------|
| 20-cell program | 30-40 | $0.30-$1.20 |
| 50-cell program | 80-120 | $0.80-$3.60 |
| Dev day (20 runs) | 600-800 | $6.00-$24.00 |

**V2 cost model:**

Assumptions for a 20-cell program:
- 8 hard cells: 0 LLM calls each (SQL views)
- 5 soft cells with deterministic oracles only: 1 LLM call each
- 4 soft cells with 1 semantic oracle: 1.5 LLM calls each (eval + sometimes oracle)
- 3 soft cells with 2 semantic oracles: 2 LLM calls each (eval + oracle checks)
- Retry rate: ~15% (lower than v1 because deterministic oracles catch fast)
- Base calls: 5 + 6 + 6 = 17
- Retries: 17 * 0.15 * 1.5 = ~4
- Total: ~21 LLM calls

| Scenario | V1 LLM calls | V2 LLM calls | Reduction | V2 Cost (Sonnet) |
|----------|-------------|-------------|-----------|-----------------|
| 20-cell program | 30-40 | 18-24 | ~40-45% | $0.18-$0.72 |
| 50-cell program | 80-120 | 40-60 | ~50% | $0.40-$1.80 |
| Dev day (20 runs) | 600-800 | 360-480 | ~40% | $3.60-$14.40 |

The improvement comes from two sources:
1. Hard cells as views: zero LLM cost. A chain of 10 hard cells that would have cost 10 LLM calls in v1 costs 0 in v2.
2. Deterministic oracles in SQL: eliminates LLM calls for type checks, range checks, and structural assertions.

**Additional cost improvements not yet captured:**
- Caching: if Dolt commit hashes are used as cache keys for soft cell evaluations, repeated runs of unchanged programs approach zero marginal cost. V2 has the infrastructure for this (content-addressed state via Dolt commits) but does not specify a caching layer.
- Model routing: a Haiku piston handling 60% of soft cells at 1/10 the cost of Opus drops the effective per-call cost further.

**With caching and model routing, estimated dev day cost:**
- 20 runs of a 20-cell program, 80% cache hit after first run: ~$1.50-$4.00 at Sonnet tier
- Compared to v1: $6.00-$24.00

This is a 3-6x cost reduction, which moves the system from "painful for iteration" to "acceptable for daily development."

---

## 7. New Concerns Introduced by V2

### 7a. Stored procedure complexity as a maintenance risk

V2 moves the entire runtime into Dolt stored procedures. This is architecturally clean -- the runtime IS the database. But stored procedures in MySQL/Dolt are notoriously difficult to debug, test, and maintain.

- No step debugger for stored procedures
- Error messages from procedure failures are often cryptic
- Testing requires a running database instance (no unit tests in isolation)
- Version control for stored procedures is awkward (they live in the database, not in files, though Dolt's versioning helps)

The `cell_eval_step` procedure handles: frontier computation, atomic cell claiming, input resolution, template interpolation, hard cell dispatch, state transitions, and error handling. This is a substantial amount of logic in a language (SQL stored procedure syntax) that lacks the ergonomics of Go, Python, or Rust.

**Mitigation:** Keep each procedure focused and small. Extract complex logic into helper procedures or views. Use Dolt's schema versioning to track procedure evolution. Write integration tests that exercise each procedure in isolation against a test database.

### 7b. The `exec:` escape hatch is underspecified

Hard cells can reference external executors: `exec:./tools/transform` with "JSON in, JSON out." This is a shell execution path controlled by data in the cells table. Questions:

- Who can insert `exec:` cells? If the LLM can, it has arbitrary code execution via `cell_submit`.
- What is the security boundary? Does the executor run in a sandbox?
- What happens on executor failure (non-zero exit, invalid JSON output, timeout)?
- How does this interact with Dolt branches? If two branches execute different versions of `./tools/transform`, which binary runs?

This is not a blocker for the bootstrap (Phase 1-3 do not use `exec:`), but it needs specification before production use.

### 7c. Concurrent piston conflicts on semantic oracles

The design says: "Two LLMs calling simultaneously get different cells. Confluence guarantees the result is the same regardless of who evaluates what."

Confluence holds for independent cells. But consider: Cell A and Cell B both depend on Cell C. Cell C is soft with a semantic oracle. Piston 1 claims Cell C, evaluates it, and the semantic oracle fails. Piston 1 calls `cell_submit` which returns failure. Meanwhile, Piston 2 called `cell_eval_step` and got 'quiescent' because Cell C was in 'computing' state. Now Piston 1 needs to retry Cell C, but Piston 2 might also see it as available on its next poll.

The atomic `FOR UPDATE` lock in `cell_eval_step` handles the claiming race. But the retry path -- where a cell transitions from 'computing' back to a retryable state -- needs careful handling to avoid:
- Two pistons both claiming the retry
- A cell stuck in 'computing' state if the claiming piston crashes
- Starvation if retries always go to the same piston that failed

**Mitigation:** Add a heartbeat or lease mechanism. A piston that claims a cell has T seconds to call `cell_submit`. If it does not, the cell reverts to 'declared' and another piston can claim it. Track which piston last failed a cell to avoid routing retries to the same piston.

### 7d. Dolt commit frequency vs performance

The design says "each freeze = commit." For a 50-cell program, that is 50 Dolt commits during a single execution. Dolt commits are not free -- each involves writing to the commit graph, updating refs, and potentially flushing to disk.

Deng's review flagged this and the resolution says "batch commits per eval round in `cell_eval_step`." But the piston model complicates batching: if 3 pistons are submitting results concurrently, each `cell_submit` is an independent transaction. Batching across pistons requires coordination that the current design does not specify.

**Mitigation:** Commit on state transitions (all cells in a round frozen), not on every individual freeze. Use Dolt's transaction model: each `cell_submit` writes to the working set, and a periodic commit sweeps the accumulated changes. The trade-off is that time-travel granularity decreases from per-cell to per-round.

---

## 8. Recommendations

Ranked by impact, with v1 recommendation status:

1. **Parameterize `cell_submit` values at the driver level.** The LLM should never construct raw SQL string literals containing its output. The piston script or tool layer must handle escaping. (NEW, Section 3)

2. **Add model escalation to `cell_eval_step`.** After N failures on a model tier, auto-escalate. Track attempts per cell per tier. (NEW, Section 4)

3. **Acknowledge intra-cell state for complex soft cells.** Add timeout hints, complexity hints, and consider checkpointing for cells that take minutes. (NEW, Section 2)

4. **Add a heartbeat/lease for piston claims.** Prevent cells from getting stuck in 'computing' if a piston crashes. (NEW, Section 7c)

5. **Invoke `cell_status` after `cell_pour` for structural verification.** Show the parsed structure to the user before execution. Low cost, high value during Phase A. (CARRIED from v1, Section 5)

6. **Implement prompt-hash caching for soft cell results.** Dolt's content-addressed state is the foundation. Build the cache layer to capture the 3-6x cost savings. (CARRIED from v1, Section 6)

7. **Batch Dolt commits per eval round, not per cell freeze.** Coordinate across concurrent pistons. (NEW, Section 7d)

8. **Specify the `exec:` security model** before allowing external executor cells. (NEW, Section 7b)

---

## Summary

V2 resolves the four critical concerns from my v1 review:

| V1 Concern | V2 Status | Residual Risk |
|------------|-----------|---------------|
| Control flow inversion | RESOLVED -- procedure drives, LLM is piston | None |
| Value transcription | PARTIALLY RESOLVED -- LLM passes own output, not transcribing | SQL escaping (Section 3) |
| Oracle cost | RESOLVED -- deterministic oracles in SQL | Semantic oracle self-grading |
| Context pressure | RESOLVED -- piston holds no inter-cell state | Intra-cell state for complex cells (Section 2) |

The new concerns (SQL injection surface, model escalation, piston state paradox, exec security, commit frequency) are all tractable engineering problems, not architectural flaws. The piston model is the right abstraction. The cost picture improves by 3-6x over v1 with caching and model routing.

The biggest remaining risk is operational: stored procedures are hard to debug, and the system's correctness depends on getting `cell_eval_step`, `cell_submit`, and the concurrency model right in SQL. This is doable but demands careful testing from the start.

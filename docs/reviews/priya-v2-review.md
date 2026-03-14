# Review: Cell REPL Design v2 (UX/Observability)

**Reviewer**: Priya (UX -- JetBrains / Observable background)
**Document**: `2026-03-14-cell-repl-design-v2.md`
**Date**: 2026-03-14
**Prior review**: `priya-ux-review.md` (v1)
**Verdict**: The architecture matured significantly. The observability layer graduated from napkin sketch to blueprint -- but the blueprint describes load-bearing walls without specifying doors, windows, or how people move through the building.

---

## 1. Scorecard: v1 Concerns

| v1 Issue | v1 Severity | v2 Status | Notes |
|----------|-------------|-----------|-------|
| Status is snapshot, not live | Critical | Partially addressed | `cell_program_status` is still a snapshot. `--watch` is not mentioned. |
| "Present" is undefined | Critical | Improved | `cell_status` procedure renders document-with-yields. But the interaction surface is still SQL calls. |
| DAG visualization breaks at scale | High | Unaddressed | No table view, no collapsed-depth view, no web UI. The view returns flat rows. |
| One status for three users | High | Unaddressed | `cell_program_status` is a single view. No operator/debugger/developer modes. |
| Document-is-state violated | Critical | Addressed | `cell_status` renders `.cell` text with frozen yields filled in. This is the right answer. |
| Error/failure UX absent | Critical | Partially addressed | Oracle retry exists in the piston loop. Causal chain for bottom propagation is not shown. |
| REPL interaction model missing | High | Reframed | The REPL is "call stored procedures from a SQL client." This is honest but brutal. |
| No history navigation | Medium | Addressed (raw) | Dolt `AS OF` and `dolt_diff` exist. No user-facing abstraction over them. |
| Yield rendering unspecified | Medium | Unaddressed | `cell_program_status` does `GROUP_CONCAT` of yields. No truncation, no expansion, no type-specific rendering. |
| Multi-molecule support missing | Medium | Partially addressed | `program_id` parameter on views. No listing, no dashboard. |
| No liveness feedback | High | Unaddressed | Nothing in the design streams progress to the user. |

**Summary**: 3 of 11 concerns addressed. 4 partially addressed. 4 unaddressed. The architecture is better. The user experience remains underspecified.

---

## 2. `cell_program_status` -- A Query Is Not a UX

The design presents this view:

```sql
CREATE VIEW cell_program_status AS
SELECT c.name, c.state, c.body_type,
       GROUP_CONCAT(y.field_name, '=', COALESCE(y.value_text, '(pending)'))
       as yields
FROM cells c
LEFT JOIN yields y ON y.cell_id = c.id
WHERE c.program_id = ?
GROUP BY c.id;
```

And says: "Instant status via `SELECT * FROM cell_program_status`."

This is a database query. It returns a result set. The user gets rows and columns. That is the entire observability story for the running state of a Cell program.

**What is missing between the query and the user**:

- **Who runs this query?** The user types it into a SQL client? The piston prints it periodically? A wrapper script polls and renders?
- **What renders the result?** MySQL CLI output is a fixed-width ASCII table. That is not a status display. It is a dump.
- **How often does the user see it?** Once, when they remember to ask? Continuously? On state transitions?
- **What does `(pending)` look like in a row with 6 yields?** `GROUP_CONCAT` produces a single string: `items=(pending),sorted=(pending),count=(pending),...`. At 10 yields this is unreadable.

The `cell_status` procedure is better -- it renders the document-is-state view. But the design says "can render" not "does render" or "is invoked by." A procedure that exists but is never called is not a UX.

**Concrete ask**: Define the default interaction loop. When the user types the equivalent of "run my program," what appears on their terminal, who puts it there, and when does it update? This is not an optional detail. This is the product.

**Three options, pick one**:

1. **SQL-native**: The user is expected to use a SQL client. `cell_program_status` and `cell_status` are for them to invoke manually. The UX is "you are a DBA." This is valid for v0 but must be stated explicitly so nobody expects more.

2. **Wrapper CLI**: A thin script (bash, Go, whatever) that calls `CALL cell_status('my-program')` in a loop with `watch`-style redraw. The script is 20 lines. It turns the SQL query into a live display. This is the minimum viable UX.

3. **Piston output**: The piston itself (the Claude Code session) prints status after each `cell_eval_step` / `cell_submit` cycle. The user watches the piston's terminal. The UX is "watch the LLM work." This is the most natural for the current architecture but couples observability to the piston.

All three are defensible. None is described in v2. The design has a view and a procedure and no story for how either reaches a human eyeball.

---

## 3. Dolt Time Travel -- Power Without a Steering Wheel

The design shows:

```sql
SELECT * FROM cells AS OF 'abc123';
SELECT * FROM dolt_diff('HEAD~3', 'HEAD', 'yields');
```

This is powerful. Execution history as version control. Every freeze is a commit. You can see any past state. You can diff any two states.

But the user must know:

- **Commit hashes.** `AS OF 'abc123'` requires a hash. Where does the user get the hash? `dolt log`? That shows all commits to the database, not just the ones for this program. The user must filter mentally.
- **Relative references.** `HEAD~3` means "three commits ago" -- but three commits ago across ALL programs, not three eval steps ago for THIS program. If two programs are running concurrently, `HEAD~3` is meaningless for understanding either one.
- **What changed.** `dolt_diff` returns a table diff. Column adds/removes/changes. The user sees rows with `from_value` and `to_value` columns. That is a database diff, not an execution trace. "Cell sort froze with value [1,2,3]" is the information; "row in yields table changed from NULL to [1,2,3] between commit abc and def" is the representation. The gap is enormous.

**What a user-facing history layer looks like**:

```sql
-- Instead of raw dolt_diff, a view that translates commits to eval events:
CREATE VIEW cell_eval_history AS
SELECT
  dc.commit_hash,
  dc.message,                         -- e.g. "freeze: sort.sorted"
  dc.date,
  cd.diff_type,                       -- 'added' | 'modified'
  cd.from_value,
  cd.to_value,
  c.name as cell_name,
  y.field_name
FROM dolt_log dc
JOIN dolt_diff_yields cd ON cd.commit_hash = dc.commit_hash
JOIN cells c ON c.id = cd.cell_id
JOIN yields y ON y.id = cd.row_id
WHERE c.program_id = ?
ORDER BY dc.date DESC;
```

And a procedure:

```sql
CALL cell_history('sort-proof');          -- Show eval steps for this program
CALL cell_at_step('sort-proof', 3);      -- State after the 3rd eval step
CALL cell_diff_steps('sort-proof', 2, 5); -- What changed between steps 2 and 5
```

The raw Dolt primitives are the engine. The user-facing procedures are the steering wheel. v2 has the engine and no steering wheel. Again.

---

## 4. The Piston's Perspective -- What Does the User See?

The piston loop is:

```
CALL cell_eval_step('sort-proof')   --> returns prompt + metadata
LLM thinks, produces output
CALL cell_submit('sort-proof', 'sorted', '[1,2,3,4,7,9]')  --> returns pass/fail
Repeat
```

The piston IS a Claude Code session. The user is presumably watching this session. So what do they see?

**Option A: Raw SQL calls.** The Claude Code session shows the LLM calling `cell_eval_step`, receiving a blob of JSON, thinking, calling `cell_submit`. The user sees tool-use blocks. The actual Cell semantics (which cell is being evaluated, what the inputs are, what the oracle said) are buried in SQL result sets.

**Option B: The LLM narrates.** The piston instructions tell the LLM to print human-readable status: "Evaluating cell 'sort'. Inputs: items = [4,1,7,3,9,2]. Thinking... Result: [1,2,3,4,7,9]. Oracle 'ascending': passed. Freezing." The user reads a narrative log. This works but depends on the LLM's discipline -- it might narrate verbosely, inconsistently, or not at all.

**Option C: The procedure returns structured status.** `cell_eval_step` returns not just a prompt but a human-readable status line. `cell_submit` returns not just pass/fail but a formatted result summary. The LLM prints these as-is. The user sees structured output that comes from SQL, not from LLM whim.

**The design does not say.** The piston loop description shows the SQL calls but not what the user's terminal looks like during execution. This matters because for the initial version, the piston's terminal IS the only observability surface. There is no separate dashboard. There is no `--watch` script. The user watches the Claude Code session. If that session shows raw SQL tool calls, the user experience is watching a machine talk to a database. That is not a product.

**Concrete ask**: Define what `cell_eval_step` and `cell_submit` return, not just for the LLM's consumption, but for the user reading the piston's output. Include a human-readable status line in the return value. Make the piston instructions require printing it.

---

## 5. `cell_pour` Output -- Parse and Pray?

The bootstrap path for `cell_pour`:

> Phase A: LLM parses (soft cell_pour). The procedure sends the text to the LLM and says "parse this into INSERT statements."

The user calls `CALL cell_pour('my-program', '<cell text>')`. The LLM parses the text. INSERT statements are executed. Rows appear in `cells`, `givens`, `yields`, `oracles`.

**What the user does NOT see**:

- **What was parsed.** The LLM's interpretation of the `.cell` text. Did it correctly identify 5 cells or did it merge two? Did it parse the oracle assertion correctly? Did it get the dependency directions right?
- **Confirmation.** "I found 5 cells, 3 givens, 7 yields, 2 oracles. Proceed?" There is no review step. The LLM parses and inserts atomically.
- **Parse errors.** If the `.cell` syntax is ambiguous or malformed, the LLM guesses. There is no error channel. The user discovers the mismatch when execution produces wrong results, not when parsing produces wrong rows.

This is particularly dangerous because the LLM is parsing a novel syntax that has no formal grammar (per Mara's review). The LLM is interpreting natural-language-adjacent notation with Unicode symbols. It will sometimes get it wrong. When it does, the error is silent.

**What good parse UX looks like**:

```
CALL cell_pour('sort-proof', '...');

-- Returns:
-- Parsed 3 cells: data, sort, report
-- Parsed 4 givens: sort<-data.items, report<-sort.sorted, ...
-- Parsed 2 oracles on cell 'sort': permutation, ascending
--
-- Review: SELECT * FROM cells WHERE program_id = 'sort-proof';
-- Confirm: CALL cell_pour_confirm('sort-proof');
-- Cancel:  CALL cell_pour_cancel('sort-proof');
```

A two-phase pour: parse + stage, then confirm or cancel. The parse result is visible. The user can inspect the rows before they become the program. This is not overhead -- it is the difference between "I loaded my program" and "I think I loaded my program, I hope the LLM read my mind."

For Phase B (deterministic parser), the confirmation step becomes optional because the parser is predictable. For Phase A (LLM parser), it is essential.

---

## 6. Multiple Pistons -- The Invisible Parallelism Problem

The design handles multiple pistons elegantly at the database level:

```sql
SELECT id INTO ready_id FROM ready_cells
WHERE program_id = ? AND state = 'declared'
LIMIT 1 FOR UPDATE;
```

Two LLMs calling simultaneously get different cells. The SQL is correct. The UX is absent.

**Scenario**: Three pistons are running. Piston A is evaluating `sort` (Opus, 45 seconds in). Piston B just froze `transform` and picked up `validate`. Piston C is idle (no ready cells). The user wants to know what is happening.

**What they can do today**: Open three terminal windows, one per piston. Each shows its own Claude Code session. The user mentally multiplexes three streams of raw SQL calls to reconstruct the global state. This is what air traffic control looked like before radar.

**What they need**:

1. **A single view of all pistons.** Which piston is working on which cell. How long each has been running. Which pistons are idle.

2. **Global progress.** "Program sort-proof: 4/7 cells frozen. 2 in-flight (sort @ piston-A, validate @ piston-B). 1 blocked." This comes from `cell_program_status` but nobody is calling it and rendering it.

3. **Piston identity.** The stored procedures do not currently track WHICH piston claimed a cell. `state = 'computing'` does not record who is computing. If piston A dies, its claimed cell is stuck in `computing` forever. There is no heartbeat, no timeout, no reassignment.

**Concrete ask for the schema**:

```sql
ALTER TABLE cells ADD COLUMN claimed_by VARCHAR(64);
ALTER TABLE cells ADD COLUMN claimed_at TIMESTAMP;
```

`cell_eval_step` sets `claimed_by` to the piston's identifier. A reaper query finds cells where `state = 'computing' AND claimed_at < NOW() - INTERVAL 5 MINUTE` and resets them to `declared`. Without this, piston failure is a silent deadlock.

**Concrete ask for the UX**: Define whether multi-piston observability is in scope for v0. If it is, describe the aggregated view. If it is not, state that v0 is single-piston and parallel execution is a future concern. Do not show a multi-piston architecture and then provide single-piston observability.

---

## 7. New Concerns Introduced by v2

### 7a. SQL as the Interaction Surface

v1 had `mol-cell-status`, `mol-cell-run`, `mol-cell-pour` -- CLI commands with names that described what they did. v2 has:

```sql
CALL cell_pour('sort-proof', '...');
CALL cell_eval_step('sort-proof');
CALL cell_submit('sort-proof', 'sorted', '[1,2,3]');
SELECT * FROM cell_program_status;
```

The interaction surface is SQL. The user needs a SQL client (mysql CLI, DBeaver, a Dolt shell). They need to know SQL syntax. They need to type stored procedure calls with string-escaped Cell program text as arguments.

This is a deliberate choice and I understand the architectural reasons. But the UX implications are severe:

- **Onboarding cost**: A new user must understand SQL, Dolt, stored procedures, AND Cell semantics before they can run their first program. The v1 CLI commands had one concept each. The v2 SQL calls require three layers of knowledge.
- **Ergonomics**: Typing `CALL cell_pour('my-program', '...')` with multi-line Cell text inside SQL string quotes is painful. Escaping. Line breaks. Unicode characters in SQL strings. This is a friction factory.
- **Discoverability**: CLI commands have `--help`. SQL procedures do not (unless you query `INFORMATION_SCHEMA.ROUTINES` and read the procedure body). A new user cannot type `cell_pour --help`.

**This does not mean v2 is wrong.** SQL-as-runtime is the right architectural decision. But the design must acknowledge that SQL is the implementation layer, not the interaction layer, and that a CLI wrapper is needed:

```bash
cell pour sort-proof.cell          # Calls cell_pour internally
cell run sort-proof                # Starts a piston loop
cell status sort-proof             # Calls cell_status, renders output
cell history sort-proof            # Calls cell_eval_history
```

The CLI wrapper is trivial -- each command is one SQL call. But it transforms the UX from "you are a DBA" to "you are a Cell programmer." State this in the design: SQL is the runtime, CLI is the interface, the CLI is in scope.

### 7b. The `cell_status` Procedure -- Render Target Undefined

The design says:

> The `cell_status` procedure can render the original program text with frozen values filled in.

And shows the beautiful document-is-state output:

```
⊢ data
  yield items = [4, 1, 7, 3, 9, 2]        -- # frozen

⊢ sort
  given data->items = [4, 1, 7, 3, 9, 2]   -- check resolved
  yield sorted = [1, 2, 3, 4, 7, 9]       -- # frozen
  assert permutation check pass
  assert ascending order pass
```

But this procedure needs the original `.cell` text to reconstruct the document. Where does that text live?

- Is the original text stored in the database? (A `program_source` table?)
- Is it reconstructed from the parsed rows? (Reverse-compiling INSERT statements back to turnstyle syntax?)
- Does it read the `.cell` file from disk? (Coupling the database to the filesystem.)

If reconstructed from rows, the output will not match the user's original formatting, comments, or whitespace. The "document-is-state" promise breaks if the rendered document looks different from the authored document.

If stored, there needs to be a `program_source` column or table that `cell_pour` populates. The design does not mention this.

### 7c. Hard Cell Views and the Namespace

Hard cells become SQL views: `CREATE VIEW cell_word_count AS ...`. These views live in the Dolt database's schema namespace alongside `cell_program_status`, `ready_cells`, and the Retort tables.

At 50 hard cells, the user has 50 views named `cell_*`. At 200 hard cells across 10 programs, the view namespace is polluted. `SHOW TABLES` returns a wall of view names mixed with base tables.

**Naming convention needed**: `cell_{program}_{cellname}` at minimum. Or a separate schema per program. Or a naming prefix that makes views filterable (`hc_sort_proof_word_count`). The design does not address namespace management.

### 7d. Crystallization Is Invisible

Crystallization (soft cell becomes hard cell / SQL view) is a major event: the system just proved that an LLM operation can be replaced by deterministic SQL. This should be celebrated and surfaced, not silent.

- Does the user know a cell crystallized? Is there a notification?
- Can the user see the SQL that replaced the LLM call? Can they review it?
- Can the user trigger crystallization manually? ("This cell always produces the same result, try to crystallize it.")
- Can the user revert a crystallization? ("The SQL view is wrong, go back to soft evaluation.")

Crystallization is the system's most novel feature. It deserves a first-class UX, not a silent schema change.

### 7e. The Piston Instructions Are Unspecified Load-Bearing UX

The design says the piston is "a Claude Code session that loops `cell_eval_step`, evaluates soft cells, calls `cell_submit`." The piston's behavior is entirely determined by its prompt/instructions. Those instructions are not in the design.

But those instructions ARE the UX for the first version. The piston's terminal is what the user watches. What the piston prints, how it formats its thinking, whether it narrates or silently computes -- all of this is determined by the system prompt that the design does not include.

This is not a "we will write it later" detail. The piston instructions determine:

- Whether the user sees progress ("Now evaluating cell 'sort'...")
- Whether errors are explained ("Oracle failed: output is not ascending")
- Whether the piston handles edge cases (no ready cells, submit rejection, database errors)
- Whether the piston respects model hints (use Haiku for cheap cells, Opus for complex ones)
- Whether the piston knows when to stop (quiescent state)

**Concrete ask**: Draft the piston system prompt as part of the design. It is the most user-facing artifact in the entire system.

---

## 8. What v2 Got Right

Credit where due. v2 made three moves that directly address my v1 concerns and I want to acknowledge them.

**Document-is-state via `cell_status`**: The design now explicitly says the procedure renders the `.cell` file with frozen values filled in. This is the correct answer to my section 5 critique. The remaining questions (source text storage, formatting fidelity) are implementation details, not design flaws.

**LLM holds no state**: The piston model (call procedure, get prompt, think, submit) eliminates an entire class of UX problems. The LLM cannot show stale state because it has no state. The procedure is the source of truth. This means observability only needs to query the database, not the LLM's memory.

**Deterministic oracles in SQL**: Oracle checking that does not require an LLM call means oracle results are instant and visible in the database. `cell_program_status` can show oracle pass/fail without waiting for an LLM round-trip. This was my section 6 concern about retry visibility -- deterministic oracles make failures immediately inspectable.

---

## 9. Summary of Asks

| # | Ask | Effort | Blocks |
|---|-----|--------|--------|
| 1 | Define the default interaction loop (what appears on screen when user runs a program) | Design decision | Everything |
| 2 | Add a CLI wrapper over the SQL procedures (even if trivial) | Small | Onboarding |
| 3 | Build `cell_eval_history` view over Dolt commits for user-facing history | Medium | History navigation |
| 4 | Add `claimed_by` / `claimed_at` to cells table for piston failure detection | Small | Multi-piston reliability |
| 5 | Make `cell_pour` two-phase: parse+stage, then confirm | Medium | Parse trust |
| 6 | Define `cell_eval_step` / `cell_submit` return values for human readability | Small | Piston observability |
| 7 | Draft the piston system prompt | Medium | First usable demo |
| 8 | Store original program source text for `cell_status` reconstruction | Small | Document-is-state fidelity |
| 9 | Define view naming convention for hard cells | Small | Namespace hygiene |
| 10 | Surface crystallization events to the user | Small | Feature visibility |

Items 1 and 7 are the highest priority. Without them, v2 is a well-designed engine with no cockpit. The user starts the engine by typing SQL, watches it run by reading raw procedure output, and checks the result by querying a view manually. That is not a product. That is a database with stored procedures.

The architecture is genuinely good. The piston model is elegant. The SQL-as-runtime bet is defensible. Now design the part that faces the human.

---

*Priya, 2026-03-14*

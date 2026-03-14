# Cell Interaction Loop: v0 UX Design

**Date**: 2026-03-14
**Status**: Proposed
**Bead**: do-rpc
**Addresses**: Priya v2 review asks #1, #6, #7

## Decision

**v0 uses piston terminal output with document-is-state rendering.**

The user watches the piston's Claude Code session. The piston prints structured
status after every `cell_eval_step` / `cell_submit` cycle, using the .cell
document format with yields filling in. The user's terminal IS the observability
surface.

This is Option 3 from Priya's review (piston output), combined with Option D
from her v1 review (document-is-state rendering). The piston narrates execution
using procedure-generated status lines, not LLM whim.

---

## Why This Option for v0

| Option | Pros | Cons | v0? |
|--------|------|------|-----|
| SQL-native (user types queries) | Zero wrapper code | "You are a DBA" — unusable | No |
| Wrapper CLI (watch-style redraw) | Live, decoupled from piston | Separate process, needs IPC | Later |
| **Piston output** | Zero infra, works today, natural for the architecture | Coupled to piston session | **Yes** |

The piston is a Claude Code session. The user is already watching it. Making the
piston print good output requires zero new infrastructure — just structured
return values from the stored procedures and clear piston instructions.

The wrapper CLI (Option 2) is the right v1 answer. But it requires a running
piston + a separate observer process + some way to trigger redraws on state
change. That's a distraction for v0.

---

## The Interaction Loop

### What the User Types

```bash
# Connect to Dolt and pour a program:
mysql -h 127.0.0.1 -P 3307 -u root retort <<< \
  "CALL cell_pour('sort-proof', '$(cat sort-proof.cell)');"

# Start a piston (a Claude Code session with the piston prompt):
claude --system-prompt piston.md \
  --tool dolt-sql \
  "Run program sort-proof on retort database at 127.0.0.1:3307"
```

For v0, the user starts one piston manually. The piston connects to Dolt,
enters its eval loop, and prints status to the terminal.

### What Appears On Screen

The piston prints three things:

1. **Program header** (once, at start)
2. **Step output** (after each eval_step + submit cycle)
3. **Final summary** (when quiescent)

#### 1. Program Header

When the piston first calls `cell_eval_step` and gets the program state:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 sort-proof  ·  3 cells  ·  0/3 frozen  ·  1 ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]                    ■ frozen

⊢ sort
  given data→items                                     ○ ready
  yield sorted
  ⊨ sorted is a permutation of items
  ⊨ sorted is in ascending order

⊢ report
  given sort→sorted                                    · blocked
  yield summary
```

This is the .cell document with status annotations on the right margin. The
procedure generates this, not the LLM. The LLM prints it verbatim.

#### 2. Step Output

After each `cell_eval_step` → think → `cell_submit` cycle:

```
──── step 1: sort ─────────────────────────────────────
  given data→items ≡ [4, 1, 7, 3, 9, 2]               ✓ resolved
  ∴ Sort «items» in ascending order.
  ...thinking (4.2s)
  yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ✓ submitted
  ⊨ sorted is a permutation of items                   ✓ pass
  ⊨ sorted is in ascending order                       ✓ pass
  → frozen                                             ■ committed

  sort-proof  ·  2/3 frozen  ·  1 ready
```

The step output shows:
- Which cell is being evaluated
- Resolved input values (from the procedure, not transcribed by LLM)
- The cell body (what the LLM is asked to do)
- Elapsed time
- The submitted yield value
- Oracle results (pass/fail with details on failure)
- Updated progress summary

#### 3. On Oracle Failure

```
──── step 1: sort (attempt 1/3) ───────────────────────
  given data→items ≡ [4, 1, 7, 3, 9, 2]               ✓ resolved
  ∴ Sort «items» in ascending order.
  ...thinking (3.1s)
  yield sorted ≡ [1, 7, 3, 2, 4, 9]                   ✓ submitted
  ⊨ sorted is a permutation of items                   ✓ pass
  ⊨ sorted is in ascending order                       ✗ FAIL
    [1, 7, 3, 2, 4, 9]: 7 > 3 at index 1

  ⚡ retrying with feedback...

──── step 1: sort (attempt 2/3) ───────────────────────
  ∴ Sort «items» in ascending order.
    Feedback: previous attempt [1, 7, 3, 2, 4, 9]
    failed ascending order check: 7 > 3 at index 1
  ...thinking (2.8s)
  yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ✓ submitted
  ⊨ sorted is a permutation of items                   ✓ pass
  ⊨ sorted is in ascending order                       ✓ pass
  → frozen                                             ■ committed
```

#### 4. On Bottom (All Retries Exhausted)

```
──── step 1: sort (attempt 3/3) ───────────────────────
  ...
  ⊨ sorted is in ascending order                       ✗ FAIL
    [1, 2, 3, 4, 9, 7]: 9 > 7 at index 4

  ⊥ sort: exhausted 3 attempts
    → propagates ⊥ to: report (via sort→sorted)

  sort-proof  ·  1/3 frozen  ·  0 ready  ·  1 ⊥
```

#### 5. Final Summary (Quiescent)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 sort-proof  ·  DONE  ·  3/3 frozen  ·  12.4s total
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]                    ■

⊢ sort
  given data→items ≡ [4, 1, 7, 3, 9, 2]               ✓
  yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ■
  ⊨ sorted is a permutation of items                   ✓
  ⊨ sorted is in ascending order                       ✓

⊢ report
  given sort→sorted ≡ [1, 2, 3, 4, 7, 9]              ✓
  yield summary ≡ "Sorted 6 items in ascending order.  ■
    All oracles passed."

History: 3 commits (dolt log --oneline retort)
```

The final output is the full .cell document with all yields filled in — the
document-is-state principle made visible.

---

## Procedure Return Values

The stored procedures must return structured data that the piston renders. The
piston does NOT compose these displays from raw query results — the procedures
return human-readable status as part of their result set.

### `cell_eval_step` Returns

```sql
-- Result set columns:
-- action: 'dispatch' | 'quiescent' | 'error'
-- cell_name: name of the cell to evaluate (if dispatch)
-- cell_body: the ∴ body text (if soft cell)
-- cell_body_type: 'soft' | 'hard'
-- resolved_inputs: JSON object of {given_name: value} pairs
-- program_status: one-line summary "sort-proof · 1/3 frozen · 1 ready"
-- document_state: full .cell document with current yield values filled in
-- attempt_number: which retry attempt this is (1-based)
-- max_attempts: max retries configured
-- feedback: prior failure context (if retry)
```

The `resolved_inputs` field is critical: the procedure resolves all `«»`
references and returns the interpolated values. The LLM sees exactly what inputs
it has. No transcription errors.

The `document_state` field enables the piston to print the full document view
at any point. This is what `cell_status` generates.

### `cell_submit` Returns

```sql
-- Result set columns:
-- result: 'frozen' | 'oracle_fail' | 'error'
-- cell_name: which cell
-- yield_name: which yield was submitted
-- yield_value: the submitted value (echo-back for confirmation)
-- oracle_results: JSON array of {name, passed, detail} objects
-- failed_oracle: name of first failing oracle (if oracle_fail)
-- failure_detail: human-readable failure explanation
-- commit_hash: Dolt commit hash (if frozen)
-- program_status: updated one-line summary
-- document_state: updated full document view
```

The `oracle_results` array lets the piston print each oracle's pass/fail
status. The `failure_detail` gives the piston retry context without the LLM
needing to interpret raw oracle assertions.

---

## Yield Rendering

Values that fit on one line render inline:

```
yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ■
```

Values longer than 60 characters are truncated with an expansion hint:

```
yield summary ≡ "Sorted 6 items in ascending order.   ■
  All oracles passed. The input list contained..."
  (287 chars, full value: SELECT value_text FROM yields
   WHERE cell_id = 'sort' AND field_name = 'summary')
```

For v0, truncation at 120 characters with `...` is sufficient. The user can
query the yields table directly for the full value. Rich rendering (syntax
highlighting, tables, images) is a future concern.

---

## v0 Scope and Non-Scope

### In Scope (v0)

- Single piston, single program
- Piston prints structured output after each step
- Document-is-state rendering in program header and final summary
- Step-by-step output with resolved inputs, yield values, oracle results
- Retry display with failure context
- Bottom propagation display
- Quiescent detection and final summary
- Procedure return values include human-readable status lines

### Out of Scope (v1+)

- Wrapper CLI (`cell run`, `cell status`, `cell history`)
- Live `--watch` mode with in-place redraw
- Multi-piston dashboard (which piston has which cell)
- Web UI / DAG visualization
- Streaming partial output during long evaluations
- History navigation (`cell_at_step`, `cell_diff_steps`)
- `cell_pour` two-phase confirm/cancel
- Crystallization event notifications
- Multiple verbosity levels (operator/debugger/developer)
- `cell_eval_history` view over Dolt commits

These are real needs (Priya is right about all of them). They are v1, not v0.
v0 proves the runtime works by making one piston's output readable.

---

## Piston Prompt Requirements

The piston system prompt (do-rdu, separate bead) must include:

1. **Print the `document_state` from `cell_eval_step` before starting work.**
   This is the program header. The user sees their program with current state.

2. **Print a step header before thinking.** Format:
   `──── step N: <cell_name> (attempt M/K) ────`

3. **Print resolved inputs.** From the procedure's `resolved_inputs` field.
   Format: `  given <name> ≡ <value>    ✓ resolved`

4. **Print the cell body.** The `∴` line (what the LLM will work on).

5. **Print elapsed time.** After thinking, before submitting.

6. **Print oracle results from `cell_submit`.** Each oracle on its own line
   with ✓/✗ and detail on failure.

7. **Print the one-line program status after each step.** From the procedure's
   `program_status` field.

8. **On quiescent, print the final `document_state`.** The complete .cell
   document with all yields filled in.

9. **Never invent status output.** All status text comes from procedure return
   values. The piston renders what the procedure gives it.

10. **On error (procedure returns error), print the error and stop.** Do not
    retry procedure calls. Errors mean the database state is inconsistent.

---

## Example: Full Session Transcript

```
$ claude --system-prompt piston.md --tool dolt-sql \
    "Run program sort-proof on retort at 127.0.0.1:3307"

> CALL cell_eval_step('sort-proof')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 sort-proof  ·  3 cells  ·  1/3 frozen  ·  1 ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]                    ■ frozen

⊢ sort
  given data→items                                     ○ ready
  yield sorted
  ⊨ sorted is a permutation of items
  ⊨ sorted is in ascending order

⊢ report
  given sort→sorted                                    · blocked
  yield summary

──── step 1: sort ─────────────────────────────────────
  given data→items ≡ [4, 1, 7, 3, 9, 2]               ✓ resolved
  ∴ Sort «items» in ascending order.

  ...thinking...

> CALL cell_submit('sort-proof', 'sort', 'sorted', '[1, 2, 3, 4, 7, 9]')

  yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ✓ submitted
  ⊨ sorted is a permutation of items                   ✓ pass
  ⊨ sorted is in ascending order                       ✓ pass
  → frozen (commit: a1b2c3d)                           ■

  sort-proof  ·  2/3 frozen  ·  1 ready

> CALL cell_eval_step('sort-proof')

──── step 2: report ───────────────────────────────────
  given sort→sorted ≡ [1, 2, 3, 4, 7, 9]              ✓ resolved
  ∴ Summarize the sort result in one sentence.

  ...thinking...

> CALL cell_submit('sort-proof', 'report', 'summary',
    '"Sorted 6 items in ascending order: [1, 2, 3, 4, 7, 9]."')

  yield summary ≡ "Sorted 6 items in ascending         ✓ submitted
    order: [1, 2, 3, 4, 7, 9]."
  → frozen (commit: d4e5f6a)                           ■

  sort-proof  ·  3/3 frozen  ·  0 ready

> CALL cell_eval_step('sort-proof')
  → quiescent

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 sort-proof  ·  DONE  ·  3/3 frozen  ·  6.8s total
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]                    ■

⊢ sort
  given data→items ≡ [4, 1, 7, 3, 9, 2]               ✓
  yield sorted ≡ [1, 2, 3, 4, 7, 9]                   ■
  ⊨ sorted is a permutation of items                   ✓
  ⊨ sorted is in ascending order                       ✓

⊢ report
  given sort→sorted ≡ [1, 2, 3, 4, 7, 9]              ✓
  yield summary ≡ "Sorted 6 items in ascending         ■
    order: [1, 2, 3, 4, 7, 9]."
```

---

## Relationship to Other Beads

- **do-h46** (PoC: stored procedures): Validates that `cell_eval_step` and
  `cell_submit` can work as stored procedures. This design specifies their
  return values — the PoC should include the `program_status` and
  `document_state` columns in its implementation.

- **do-rdu** (piston system prompt): The prompt must encode the rendering
  rules from this doc. The piston's output quality is entirely determined
  by the prompt.

- **do-27k** (build Cell REPL): This design answers Priya's ask #1 — the
  default interaction loop. The REPL build should implement this.

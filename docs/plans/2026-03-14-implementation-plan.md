# Cell Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a working Cell runtime on Dolt — pour a program, run the piston loop, see cells freeze.

**Architecture:** Dolt stored procedures are the runtime. Hard cells evaluate in SQL. Soft cells dispatch to an LLM piston. Programs are data (rows in Retort tables). The piston is a Claude Code session following simple instructions.

**Tech Stack:** Dolt sql-server, SQL stored procedures, bash (`dolt sql`), Claude Code as piston

---

## Prerequisites

- Dolt sql-server running on port 3307
- The PoC at `poc/` has been validated (30/30 tests pass)
- Schema additions at `schema/` are ready to merge

---

### Task 1: Create the Retort Database

**Files:**
- Create: `schema/retort-init.sql`

**Step 1: Write the init script**

Consolidate `poc/schema.sql` + `schema/cell_claims.sql` + `schema/cell_heartbeat.sql`
into a single `schema/retort-init.sql` that:
1. `CREATE DATABASE IF NOT EXISTS retort;`
2. `USE retort;`
3. Creates all tables: cells, givens, yields, oracles, trace, cell_claims, pistons
4. Creates views: ready_cells, cell_program_status
5. Sets DoltIgnoreTrace: `INSERT IGNORE INTO dolt_ignore VALUES ('trace', 1);`

Use VARCHAR types (not ENUM) per the PoC findings. Include the `computing_since`,
`assigned_piston`, and `model_hint` columns on cells from the heartbeat schema.

**Step 2: Apply to Dolt**

Run: `dolt sql -q "SOURCE schema/retort-init.sql;" --host 127.0.0.1 --port 3307 --user root`

Verify: `dolt sql -q "SHOW TABLES FROM retort;" --host ...`
Expected: cells, givens, yields, oracles, trace, cell_claims, pistons, ready_cells, cell_program_status

**Step 3: Commit**

```bash
git add schema/retort-init.sql
git commit -m "feat: consolidated Retort schema init script"
```

---

### Task 2: Install Production Stored Procedures

**Files:**
- Create: `schema/procedures.sql`

**Step 1: Write consolidated procedures**

Merge `poc/procedures.sql` + `schema/cell_heartbeat.sql` procedures into a single
`schema/procedures.sql`. Include these procedures:

| Procedure | Source | Notes |
|-----------|--------|-------|
| `cell_eval_step(program_id)` | poc/procedures.sql | Add INSERT IGNORE into cell_claims for multi-piston |
| `cell_submit(program_id, cell_name, field_name, value)` | poc/procedures.sql | Add claim cleanup on freeze |
| `cell_status(program_id)` | poc/procedures.sql | Keep as-is |
| `cell_reap_stale(timeout_minutes)` | schema/cell_heartbeat.sql | Keep as-is |
| `piston_register(id, program_id, model_hint)` | schema/cell_heartbeat.sql | Keep as-is |
| `piston_heartbeat(id)` | schema/cell_heartbeat.sql | Keep as-is |
| `piston_deregister(id)` | schema/cell_heartbeat.sql | Keep as-is |

Key changes from PoC to production:
- `cell_eval_step`: add `INSERT IGNORE INTO cell_claims` for atomic claiming
- `cell_eval_step`: add `computing_since = NOW(), assigned_piston = CONNECTION_ID()`
- `cell_submit`: add `DELETE FROM cell_claims WHERE cell_id = v_cell_id` on freeze
- `cell_submit`: add `UPDATE pistons SET cells_completed = cells_completed + 1`

**Step 2: Apply to Dolt**

Run: `dolt sql -q "USE retort; SOURCE schema/procedures.sql;" --host ...`

Verify: `dolt sql -q "SHOW PROCEDURE STATUS WHERE Db = 'retort';" --host ...`
Expected: cell_eval_step, cell_submit, cell_status, cell_reap_stale, piston_register, piston_heartbeat, piston_deregister

**Step 3: Commit**

```bash
git add schema/procedures.sql
git commit -m "feat: production stored procedures for Cell runtime"
```

---

### Task 3: Write cell_pour (Phase A — LLM Parser)

**Files:**
- Create: `tools/cell-pour.sh`

**Step 1: Write the cell_pour shell script**

A bash script that takes a program name and a .cell file, sends the content
to the LLM with a parsing prompt, and executes the resulting SQL.

```bash
#!/bin/bash
# tools/cell-pour.sh <program-name> <file.cell>
# Phase A: LLM parses turnstyle syntax into INSERT statements

PROGRAM_NAME="$1"
CELL_FILE="$2"
SOURCE_TEXT=$(cat "$CELL_FILE")

# The LLM generates SQL INSERTs from the cell source
# For v0, this is a manual step: the piston reads the file and
# generates the INSERTs as part of its startup sequence
```

Actually, for v0, cell_pour is simpler: the piston (Claude Code session) reads
the .cell file, understands the turnstyle syntax, and generates INSERT statements
itself. No separate tool needed. The piston instructions include "read the .cell
file and create rows."

**Step 2: Write a test program**

Create `examples/sort-proof.cell`:
```
⊢ data
  yield items ≡ [4, 1, 7, 3, 9, 2]

⊢ sort
  given data→items
  yield sorted
  ∴ Sort «items» in ascending order.
  ⊨ sorted is a permutation of items
  ⊨ sorted is in ascending order

⊢ report
  given sort→sorted
  yield summary
  ∴ Write a one-sentence summary of the sort result.
```

**Step 3: Write the manual pour SQL for this program**

Create `examples/sort-proof.sql`:
```sql
USE retort;

-- Program
INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-data', 'sort-proof', 'data', 'hard', 'literal:[4, 1, 7, 3, 9, 2]', 'declared');

INSERT INTO yields (id, cell_id, field_name) VALUES ('y-data-items', 'sp-data', 'items');

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-sort', 'sort-proof', 'sort', 'soft', 'Sort «items» in ascending order.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-sort-items', 'sp-sort', 'data', 'items');

INSERT INTO yields (id, cell_id, field_name) VALUES ('y-sort-sorted', 'sp-sort', 'sorted');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-1', 'sp-sort', 'deterministic', 'sorted is a permutation of items', 'length_matches:data');

INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-2', 'sp-sort', 'semantic', 'sorted is in ascending order', NULL);

INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('sp-report', 'sort-proof', 'report', 'soft', 'Write a one-sentence summary of the sort result.', 'declared');

INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-report-sorted', 'sp-report', 'sort', 'sorted');

INSERT INTO yields (id, cell_id, field_name) VALUES ('y-report-summary', 'sp-report', 'summary');

CALL DOLT_COMMIT('-Am', 'pour: sort-proof');
```

**Step 4: Commit**

```bash
git add examples/ tools/
git commit -m "feat: sort-proof example program with manual pour SQL"
```

---

### Task 4: Write the Piston System Prompt

**Files:**
- Create: `piston/system-prompt.md`

**Step 1: Write the piston instructions**

```markdown
# Cell Runtime Piston

You are a Cell runtime piston. You evaluate soft cells in a Cell program
running on a Dolt database.

## Connection

Database: retort
Host: 127.0.0.1:3307
User: root

Use `dolt sql` for all database operations:
  dolt sql --host 127.0.0.1 --port 3307 --user root --use-db retort -q "..."

## The Loop

Repeat until quiescent:

1. Call: `SET @@dolt_transaction_commit = 0; CALL cell_eval_step('PROGRAM_ID');`

2. Read the result:
   - action = 'quiescent' → Print final status, stop.
   - action = 'evaluated' → A hard cell was handled by SQL. Print:
     "■ {cell_name} frozen (hard)" and go to 1.
   - action = 'dispatch' → A soft cell needs you. Continue to 3.

3. Read the `prompt` field. This is the cell's ∴ body with resolved inputs.
   Think about it carefully. Produce the output.

4. Submit your result:
   `SET @@dolt_transaction_commit = 0; CALL cell_submit('PROGRAM_ID', 'CELL_NAME', 'FIELD_NAME', 'YOUR_OUTPUT');`

5. Read the result:
   - result = 'ok' → Print "■ {cell_name}.{field} frozen" and go to 1.
   - result = 'oracle_fail' → Print the failure, revise your answer, resubmit.
   - result = 'error' → Print the error, go to 1.

6. After each step, print the program status:
   `CALL cell_status('PROGRAM_ID');`

## Rules

- Do NOT track state between cells. Every step starts fresh from the procedure.
- Do NOT modify the database directly. Only use cell_eval_step and cell_submit.
- Do NOT evaluate hard cells. SQL handles them.
- When a soft cell asks you to do something, USE YOUR TOOLS (bash, read, grep, etc.)
  if the task requires it. You are a full Claude Code session, not just a text generator.
- For oracle failures: read the failure message, address the SPECIFIC issue, resubmit.
  Do not blindly retry with the same answer.
```

**Step 2: Commit**

```bash
git add piston/
git commit -m "feat: piston system prompt for Cell runtime"
```

---

### Task 5: Pour and Run sort-proof

**Step 1: Pour the program**

```bash
dolt sql --host 127.0.0.1 --port 3307 --user root --use-db retort \
  -q "SOURCE examples/sort-proof.sql;"
```

Verify: `dolt sql ... -q "SELECT name, state, body_type FROM cells WHERE program_id = 'sort-proof';"`
Expected: data/declared/hard, sort/declared/soft, report/declared/soft

Verify: `dolt sql ... -q "SELECT * FROM ready_cells WHERE program_id = 'sort-proof';"`
Expected: data (it has no givens, so it's ready)

**Step 2: Start the piston**

Start a Claude Code session with the piston prompt:
```bash
claude --system-prompt piston/system-prompt.md \
  "Run program sort-proof"
```

Or manually: open Claude Code, paste the system prompt, then say "Run program sort-proof".

**Step 3: Watch it run**

Expected sequence:
1. Piston calls `cell_eval_step('sort-proof')` → gets `data` (hard cell)
2. Procedure evaluates data (literal), freezes it → returns 'evaluated'
3. Piston calls `cell_eval_step('sort-proof')` → gets `sort` (soft cell, now ready)
4. Piston reads prompt: "Sort [4, 1, 7, 3, 9, 2] in ascending order."
5. Piston thinks → produces `[1, 2, 3, 4, 6, 7, 9]`
6. Piston calls `cell_submit('sort-proof', 'sort', 'sorted', '[1, 2, 3, 4, 6, 7, 9]')`
7. Procedure checks deterministic oracle (length_matches:data) → pass
8. Piston calls `cell_eval_step('sort-proof')` → gets `report` (soft cell, now ready)
9. Piston reads prompt: "Write a one-sentence summary of the sort result."
10. Piston thinks → produces summary
11. Piston calls `cell_submit('sort-proof', 'report', 'summary', '...')`
12. Piston calls `cell_eval_step('sort-proof')` → 'quiescent'
13. Piston prints final status and stops

**Step 4: Verify**

```bash
dolt sql ... -q "SELECT name, state FROM cells WHERE program_id = 'sort-proof';"
# Expected: all frozen

dolt sql ... -q "SELECT c.name, y.field_name, y.value_text FROM cells c JOIN yields y ON y.cell_id = c.id WHERE c.program_id = 'sort-proof' AND y.is_frozen = 1;"
# Expected: data.items, sort.sorted, report.summary — all with values

dolt sql ... -q "SELECT * FROM dolt_log LIMIT 5;"
# Expected: commits for each freeze step
```

**Step 5: Commit**

```bash
git commit -m "milestone: first Cell program runs end-to-end"
```

---

### Task 6: Write a More Complex Program

**Files:**
- Create: `examples/code-review.cell`
- Create: `examples/code-review.sql`

**Step 1: Write a 5+ cell program with mixed hard/soft cells**

A code review program:
```
⊢ repo-url
  yield url ≡ "https://github.com/ericfode/dolt-cell"

⊢ files
  given repo-url→url
  yield file-list
  ∴ List the key source files in «url» that would need review.

⊢ loc-count
  given files→file-list
  yield count
  ⊢= sql: SELECT LENGTH(value_text) - LENGTH(REPLACE(value_text, ',', '')) + 1
     FROM yields y JOIN cells c ON y.cell_id = c.id
     WHERE c.name = 'files' AND y.field_name = 'file-list' AND y.is_frozen = 1

⊢ review
  given files→file-list
  given repo-url→url
  yield findings
  ∴ Review the files in «file-list» from «url». Focus on architecture and design.
  ⊨ findings contains at least 3 bullet points

⊢ summary
  given review→findings
  given loc-count→count
  yield report
  ∴ Summarize the review. Mention that «count» files were reviewed.
```

This tests: hard cells (literal + SQL view), soft cells, oracle checking, 3-deep DAG.

**Step 2: Pour and run**

Same flow as Task 5. Verify the hard cell (loc-count) evaluates in SQL while
soft cells dispatch to the piston.

**Step 3: Commit**

```bash
git add examples/
git commit -m "feat: code-review example with mixed hard/soft cells"
```

---

### Task 7: Add cell_pour Phase A (LLM Parser)

**Files:**
- Create: `tools/pour.sh`

**Step 1: Write the pour script**

Instead of manually writing SQL for each program, create a tool that:
1. Reads a .cell file
2. Sends it to the LLM with a parsing prompt (using claude CLI or API)
3. Gets back SQL INSERT statements
4. Executes them against Dolt

```bash
#!/bin/bash
# tools/pour.sh <program-name> <file.cell>
set -euo pipefail

PROG="$1"
FILE="$2"
TEXT=$(cat "$FILE")

# Use the piston to parse
claude --print -m "Parse this Cell program into SQL INSERT statements for the retort database.
Program name: $PROG

$(cat tools/pour-prompt.md)

PROGRAM TEXT:
$TEXT"
```

Include `tools/pour-prompt.md` with the exact schema and parsing rules.

**Step 2: Test against all examples**

```bash
for f in examples/*.cell; do
  name=$(basename "$f" .cell)
  tools/pour.sh "$name" "$f" > "/tmp/$name.sql"
  echo "Parsed $name: $(wc -l < /tmp/$name.sql) lines of SQL"
done
```

Compare LLM-generated SQL against hand-written SQL for sort-proof. Diff should
be structurally equivalent (same cells, givens, yields, oracles).

**Step 3: Commit**

```bash
git add tools/
git commit -m "feat: cell_pour Phase A (LLM parser for .cell files)"
```

---

### Task 8: Migration — Bring Cell Specs and Examples from ericfode/cell

**Files:**
- Create: `spec/` directory with language specs
- Create: `examples/` with the 55 example programs
- Create: `lean4/` with formal proofs

**Step 1: Copy specs**

From `/tmp/cell-survey/` (the cloned ericfode/cell repo):
```bash
mkdir -p spec
cp /tmp/cell-survey/docs/design/cell-v0.2-spec.md spec/
cp /tmp/cell-survey/docs/design/cell-minimum-viable-spec.md spec/
cp /tmp/cell-survey/docs/design/cell-computational-model.md spec/
```

**Step 2: Copy examples**

```bash
cp -r /tmp/cell-survey/docs/examples/ examples/corpus/
cp -r /tmp/cell-survey/traces/ examples/traces/
```

**Step 3: Copy Lean4 proofs**

```bash
cp -r /tmp/cell-survey/lean4/ lean4/
```

**Step 4: Commit**

```bash
git add spec/ examples/corpus/ examples/traces/ lean4/
git commit -m "feat: migrate specs, examples, and Lean4 proofs from ericfode/cell"
```

---

## Summary

| Task | What it builds | Dependencies |
|------|---------------|-------------|
| 1 | Retort database + schema | None |
| 2 | Stored procedures | Task 1 |
| 3 | First example program | Task 2 |
| 4 | Piston system prompt | Task 2 |
| 5 | **First end-to-end run** | Tasks 1-4 |
| 6 | Complex program with hard+soft cells | Task 5 |
| 7 | cell_pour LLM parser | Task 5 |
| 8 | Migration from ericfode/cell | Task 5 |

Tasks 1-5 are the critical path to the first working demo.
Tasks 6-8 expand capability after the demo works.

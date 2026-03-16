# ct eval Exhaustive Test Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Exhaustively test the `ct eval` dynamic pour pipeline: submit .cell files at runtime to cell-zero-eval, have pour-one parse them and eval-one evaluate them.

**Architecture:** ct eval inserts a pour-request cell into cell-zero-eval. The pour-one stem cell reads it, parses .cell syntax into SQL, and pours the program. The eval-one stem cell then finds and evaluates the poured program's cells. This is the fully autonomous pipeline — no human in the loop.

**Tech Stack:** Go (ct tool), Dolt SQL, cell-zero-eval .cell program

---

### Task 1: Verify ct eval basic plumbing

**Files:**
- Read: `cmd/ct/main.go:353-401` (cmdEval)
- Read: `examples/cell-zero-eval.cell` (pour-one + eval-one bodies)

**Step 1: Setup — pour cell-zero-eval**
```bash
export RETORT_DSN="root@tcp(127.0.0.1:3307)/retort"
ct pour cell-zero-eval examples/cell-zero-eval.cell
ct status cell-zero-eval
```
Expected: 2 cells (eval-one, pour-one) in declared state.

**Step 2: Submit a minimal .cell file via ct eval**
```bash
ct eval test-hello examples/exp/echo-test.cell
```
Expected: "Submitted pour-request for test-hello (N bytes)"

**Step 3: Verify pour-request cell was created**
```bash
dolt sql -q "SELECT id, name, state FROM cells WHERE program_id = 'cell-zero-eval' AND name = 'pour-request';"
```
Expected: One row with state='declared', body contains .cell text.

**Step 4: Verify cache hit on duplicate**
```bash
ct eval test-hello examples/exp/echo-test.cell
```
Expected: "pour-request already exists (cache hit)"

---

### Task 2: Test pour-one parsing (piston evaluates pour-request)

**Step 1: Dispatch pour-one**
```bash
ct piston cell-zero-eval
```
Expected: Dispatches pour-one (stem cell). Body instructs piston to check for pour-request.

**Step 2: Evaluate pour-one as the piston**
The piston (LLM) follows pour-one's body:
1. Runs the SQL to find pour-request
2. Reads the .cell text from the body
3. Parses it into SQL INSERT statements
4. Executes the SQL to pour the program
5. Freezes the pour-request
6. Yields program_id and status

**Step 3: Submit pour-one yields**
```bash
ct submit cell-zero-eval pour-one program_id 'test-hello'
ct submit cell-zero-eval pour-one status 'poured'
```

**Step 4: Verify the program was poured**
```bash
ct status test-hello
```
Expected: test-hello cells exist (greeting, shout).

---

### Task 3: Test eval-one evaluates the poured program

**Step 1: Dispatch eval-one**
```bash
ct piston cell-zero-eval
```
Expected: Dispatches eval-one.

**Step 2: Evaluate — eval-one finds work in test-hello**
The piston follows eval-one's body:
1. Runs SQL to find ready cells in non-cell-zero programs
2. Finds test-hello greeting (hard literal) or shout (soft)
3. Claims, evaluates, submits

**Step 3: Submit eval-one yields**
```bash
ct submit cell-zero-eval eval-one cell_name '<evaluated cell>'
ct submit cell-zero-eval eval-one program_id 'test-hello'
ct submit cell-zero-eval eval-one status 'evaluated'
```

**Step 4: Verify auto-respawn and continue**
Repeat ct piston cell-zero-eval until test-hello is complete.

**Step 5: Verify test-hello is fully evaluated**
```bash
ct yields test-hello
```
Expected: All yields frozen.

---

### Task 4: Test with complex programs

**Step 1: Submit multi-yield program**
```bash
ct eval multi-yield examples/exp/multi-yield.cell
```
Then run piston cycles until multi-yield is complete.

**Step 2: Submit iteration program**
```bash
ct eval haiku-refine examples/haiku-refine.cell
```
This is the hardest test — pour-one must parse recur syntax, judges, gather.

**Step 3: Submit parallel-research program**
```bash
ct eval parallel-research examples/parallel-research.cell
```
Tests gather expansion in the pour-one parser.

---

### Task 5: Test error cases

**Step 1: ct eval without cell-zero-eval poured**
```bash
ct reset cell-zero-eval
ct eval test examples/exp/echo-test.cell
```
Expected: Error "cell-zero-eval not poured"

**Step 2: ct eval with invalid .cell file**
```bash
echo "this is not valid cell syntax" > /tmp/bad.cell
ct eval bad-program /tmp/bad.cell
```
Expected: pour-request created, but pour-one will fail to parse it.

**Step 3: ct eval with huge .cell file**
Test body size limits (cells.body is TEXT, but pour-one reads LEFT(body, 8192)).

---

### Task 6: Test concurrent eval submissions

**Step 1: Submit 3 programs rapidly**
```bash
ct eval echo1 examples/exp/echo-test.cell
ct eval chain1 examples/exp/chain-reason.cell
ct eval multi1 examples/exp/multi-yield.cell
```

**Step 2: Verify all 3 pour-requests created**
```bash
dolt sql -q "SELECT id, LEFT(body, 50) FROM cells WHERE name = 'pour-request' AND program_id = 'cell-zero-eval';"
```

**Step 3: Run piston — should pour all 3, then evaluate**

---

### Task 7: Integration test script

**Step 1: Write test-ct-eval.sh**
Create `tools/test-ct-eval.sh` that automates Tasks 1-5 as a script:
```bash
#!/bin/bash
set -e
export RETORT_DSN="root@tcp(127.0.0.1:3307)/retort"

# Fresh start
ct pour cell-zero-eval examples/cell-zero-eval.cell

# Submit echo-test
ct eval test-echo examples/exp/echo-test.cell
echo "✓ pour-request created"

# Verify
ct status cell-zero-eval | grep pour-request && echo "✓ pour-request visible"

# Note: full e2e requires a piston to evaluate pour-one + eval-one
echo "Manual piston steps required for full e2e test"
```

**Step 2: Commit**
```bash
git add tools/test-ct-eval.sh
git commit -m "test: ct eval exhaustive test plan + integration script"
```

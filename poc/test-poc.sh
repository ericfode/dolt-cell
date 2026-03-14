#!/usr/bin/env bash
# ============================================================================
# Cell Runtime PoC: Test Script
# ============================================================================
# Tests stored procedures against actual Dolt sql-server.
# Verifies:
#   1. Procedure creation
#   2. Result set returns from procedures
#   3. DOLT_COMMIT from within procedures
#   4. Transaction semantics (atomic claim + state transitions)
# ============================================================================

set -uo pipefail

PASS=0
FAIL=0
TESTS=()

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
    TESTS+=("PASS: $1")
}

fail() {
    echo "  FAIL: $1: $2"
    FAIL=$((FAIL + 1))
    TESTS+=("FAIL: $1: $2")
}

# Base dolt connection (no database selected)
dolt_base() {
    dolt --host 127.0.0.1 --port 3307 --user root --password "" --no-tls "$@"
}

# Dolt connection with cell_poc database
dolt_db() {
    dolt --host 127.0.0.1 --port 3307 --user root --password "" --no-tls --use-db cell_poc "$@"
}

# Query with CSV output — sets dolt_transaction_commit=0 for explicit commit control
dsql() {
    dolt_db sql -q "SET @@dolt_transaction_commit = 0; $1" -r csv 2>&1
}

# Simple query without the SET (for DDL etc)
dsql_raw() {
    dolt_db sql -q "$1" -r csv 2>&1
}

# Pipe SQL file to dolt
dsql_file() {
    cat "$1" | dolt_db sql 2>&1
}

echo "============================================"
echo "Cell Runtime PoC: Dolt Stored Procedures"
echo "============================================"
echo ""

# --------------------------------------------------------------------------
# SETUP: Clean slate
# --------------------------------------------------------------------------
echo "--- Setup: Clean database ---"
dolt_base --use-db do sql -q "DROP DATABASE IF EXISTS cell_poc;" 2>&1
dolt_base --use-db do sql -q "CREATE DATABASE cell_poc;" 2>&1
echo "  Created fresh cell_poc database"

# --------------------------------------------------------------------------
# TEST 1: Schema + Procedure Creation
# --------------------------------------------------------------------------
echo ""
echo "--- Test 1: Schema + Procedure Creation ---"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
dsql_file "$SCRIPT_DIR/schema.sql"
dsql_file "$SCRIPT_DIR/procedures.sql"

# Verify tables exist
TABLES=$(dsql_raw "SHOW TABLES;")
for TBL in cells yields givens oracles trace; do
    if echo "$TABLES" | grep -q "$TBL"; then
        pass "$TBL table created"
    else
        fail "$TBL table created" "table not found"
    fi
done

# Verify procedures exist
PROCS=$(dsql_raw "SHOW PROCEDURE STATUS WHERE Db = 'cell_poc';")
for PROC in cell_eval_step cell_submit cell_status; do
    if echo "$PROCS" | grep -q "$PROC"; then
        pass "$PROC procedure created"
    else
        fail "$PROC procedure created" "procedure not found"
    fi
done

# Verify views exist
VIEWS=$(dsql_raw "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'cell_poc';")
if echo "$VIEWS" | grep -q "ready_cells"; then
    pass "ready_cells view created"
else
    fail "ready_cells view created" "view not found"
fi

# --------------------------------------------------------------------------
# TEST 2: Hard cell evaluation via cell_eval_step
# --------------------------------------------------------------------------
echo ""
echo "--- Test 2: Hard Cell Evaluation (cell_eval_step) ---"

# Insert a program: data (hard) -> sort (soft, with oracles)
dsql "INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('c-data', 'sort-proof', 'data', 'hard', 'literal:[4, 1, 7, 3, 9, 2]', 'declared');" >/dev/null

dsql "INSERT INTO cells (id, program_id, name, body_type, body, state, model_hint)
VALUES ('c-sort', 'sort-proof', 'sort', 'soft', 'Sort the given items list in ascending order. Return ONLY the sorted JSON array.', 'declared', 'haiku');" >/dev/null

dsql "INSERT INTO givens (id, cell_id, source_cell, source_field, alias)
VALUES ('g-sort-data', 'c-sort', 'data', 'value', 'items');" >/dev/null

dsql "INSERT INTO yields (id, cell_id, field_name, is_frozen)
VALUES ('y-sort', 'c-sort', 'sorted', FALSE);" >/dev/null

dsql "INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-1', 'c-sort', 'deterministic', 'result is a JSON array', 'is_json_array');" >/dev/null

dsql "INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-sort-2', 'c-sort', 'deterministic', 'result has same length as input', 'length_matches:data');" >/dev/null

dsql "CALL DOLT_COMMIT('-Am', 'setup: insert sort-proof program');" >/dev/null

# Test: data cell should be ready (no givens)
READY=$(dsql "SELECT name FROM ready_cells WHERE program_id = 'sort-proof';")
if echo "$READY" | grep -q "data"; then
    pass "data cell shows as ready (no dependencies)"
else
    fail "data cell shows as ready" "not in ready_cells: $READY"
fi

# Test: sort cell should NOT be ready (data not frozen)
if echo "$READY" | grep -q "sort"; then
    fail "sort cell not ready yet" "sort appeared in ready_cells before data frozen"
else
    pass "sort cell not ready yet (data dependency unmet)"
fi

# Test: cell_eval_step evaluates the hard cell
EVAL1=$(dsql "CALL cell_eval_step('sort-proof');")
echo "  eval_step result: $EVAL1"
if echo "$EVAL1" | grep -q "evaluated"; then
    pass "cell_eval_step returned 'evaluated' for hard cell"
else
    fail "cell_eval_step hard cell evaluation" "unexpected result: $EVAL1"
fi

# Verify data cell is now frozen
STATE=$(dsql "SELECT state FROM cells WHERE id = 'c-data';")
if echo "$STATE" | grep -q "frozen"; then
    pass "data cell state = frozen after eval_step"
else
    fail "data cell state = frozen" "state is: $STATE"
fi

# Verify yield was written and frozen
YIELD=$(dsql "SELECT value_text, is_frozen FROM yields WHERE cell_id = 'c-data' AND field_name = 'value';")
if echo "$YIELD" | grep -q "true"; then
    pass "data cell yield written and frozen"
elif echo "$YIELD" | grep -q "1"; then
    pass "data cell yield written and frozen"
else
    fail "data cell yield frozen" "yield: $YIELD"
fi

# --------------------------------------------------------------------------
# TEST 3: DOLT_COMMIT from within procedures
# --------------------------------------------------------------------------
echo ""
echo "--- Test 3: DOLT_COMMIT from Procedures ---"

COMMITS=$(dsql "SELECT message FROM dolt_log ORDER BY date DESC LIMIT 10;")
echo "  recent commits: $(echo "$COMMITS" | head -5)"
if echo "$COMMITS" | grep -q "freeze hard cell data"; then
    pass "DOLT_COMMIT created from within cell_eval_step"
else
    fail "DOLT_COMMIT from cell_eval_step" "commit not found in log: $COMMITS"
fi

# --------------------------------------------------------------------------
# TEST 4: Soft cell becomes ready after dependency freezes
# --------------------------------------------------------------------------
echo ""
echo "--- Test 4: Dependency Resolution + Soft Cell Dispatch ---"

READY2=$(dsql "SELECT name FROM ready_cells WHERE program_id = 'sort-proof';")
if echo "$READY2" | grep -q "sort"; then
    pass "sort cell now ready (data dependency met)"
else
    fail "sort cell now ready" "ready_cells: $READY2"
fi

# Test: cell_eval_step dispatches the soft cell with prompt
EVAL2=$(dsql "CALL cell_eval_step('sort-proof');")
echo "  eval_step result: $(echo "$EVAL2" | head -3)"
if echo "$EVAL2" | grep -q "dispatch"; then
    pass "cell_eval_step returns 'dispatch' for soft cell"
else
    fail "cell_eval_step soft cell dispatch" "unexpected: $EVAL2"
fi

# Verify the prompt includes instructions
if echo "$EVAL2" | grep -q "Sort"; then
    pass "soft cell prompt includes instructions"
else
    fail "soft cell prompt includes instructions" "prompt missing instructions"
fi

# Verify sort cell is now in 'computing' state
STATE2=$(dsql "SELECT state FROM cells WHERE id = 'c-sort';")
if echo "$STATE2" | grep -q "computing"; then
    pass "sort cell state = computing after dispatch"
else
    fail "sort cell state = computing" "state: $STATE2"
fi

# --------------------------------------------------------------------------
# TEST 5: Quiescent state (no more ready cells)
# --------------------------------------------------------------------------
echo ""
echo "--- Test 5: Quiescent State ---"

EVAL3=$(dsql "CALL cell_eval_step('sort-proof');")
if echo "$EVAL3" | grep -q "quiescent"; then
    pass "cell_eval_step returns 'quiescent' when no ready cells"
else
    fail "quiescent state" "unexpected: $EVAL3"
fi

# --------------------------------------------------------------------------
# TEST 6: cell_submit with oracle checks
# --------------------------------------------------------------------------
echo ""
echo "--- Test 6: cell_submit + Oracle Verification ---"

# Submit a bad value (not a JSON array) — should fail oracle
SUBMIT_BAD=$(dsql "CALL cell_submit('sort-proof', 'sort', 'sorted', 'not an array');")
echo "  submit bad value: $SUBMIT_BAD"
if echo "$SUBMIT_BAD" | grep -q "oracle_fail"; then
    pass "cell_submit rejects bad value (oracle_fail)"
else
    fail "cell_submit oracle rejection" "unexpected: $SUBMIT_BAD"
fi

# Submit a good value (correct sorted array)
SUBMIT_GOOD=$(dsql "CALL cell_submit('sort-proof', 'sort', 'sorted', '[1, 2, 3, 4, 7, 9]');")
echo "  submit good value: $SUBMIT_GOOD"
if echo "$SUBMIT_GOOD" | grep -q "ok"; then
    pass "cell_submit accepts correct value"
else
    fail "cell_submit accept correct value" "unexpected: $SUBMIT_GOOD"
fi

# Verify DOLT_COMMIT happened for the submit
COMMITS2=$(dsql "SELECT message FROM dolt_log ORDER BY date DESC LIMIT 5;")
if echo "$COMMITS2" | grep -q "freeze sort.sorted"; then
    pass "DOLT_COMMIT created from within cell_submit"
else
    fail "DOLT_COMMIT from cell_submit" "commit not found: $COMMITS2"
fi

# --------------------------------------------------------------------------
# TEST 7: cell_status
# --------------------------------------------------------------------------
echo ""
echo "--- Test 7: cell_status ---"

STATUS=$(dsql "CALL cell_status('sort-proof');")
echo "  status: $STATUS"
if echo "$STATUS" | grep -q "frozen" && echo "$STATUS" | grep -q "data" && echo "$STATUS" | grep -q "sort"; then
    pass "cell_status returns full program state"
else
    fail "cell_status" "unexpected: $STATUS"
fi

# --------------------------------------------------------------------------
# TEST 8: Transaction semantics - sequential claim
# --------------------------------------------------------------------------
echo ""
echo "--- Test 8: Transaction Semantics (Sequential Claim) ---"

dsql "INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES
  ('c-a1', 'atomic-test', 'alpha', 'soft', 'Do alpha work', 'declared'),
  ('c-b1', 'atomic-test', 'beta', 'soft', 'Do beta work', 'declared');" >/dev/null

dsql "CALL DOLT_COMMIT('-Am', 'setup: insert atomic-test program');" >/dev/null

# First eval_step claims one cell
CLAIM1=$(dsql "CALL cell_eval_step('atomic-test');")
CELL1=$(echo "$CLAIM1" | grep "dispatch" | cut -d',' -f2)

# Second eval_step claims the other cell
CLAIM2=$(dsql "CALL cell_eval_step('atomic-test');")
CELL2=$(echo "$CLAIM2" | grep "dispatch" | cut -d',' -f2)

# Third eval_step should be quiescent
CLAIM3=$(dsql "CALL cell_eval_step('atomic-test');")

if echo "$CLAIM3" | grep -q "quiescent"; then
    pass "all cells claimed after 2 eval_steps (no double-claim)"
else
    fail "sequential claim" "third eval_step not quiescent: $CLAIM3"
fi

# Verify both cells are in computing state
COMPUTING=$(dsql "SELECT COUNT(*) as cnt FROM cells WHERE program_id = 'atomic-test' AND state = 'computing';")
if echo "$COMPUTING" | grep -q "2"; then
    pass "both cells in computing state"
else
    fail "claim states" "computing count: $COMPUTING"
fi

# --------------------------------------------------------------------------
# TEST 9: Dolt time-travel (commit history as execution trace)
# --------------------------------------------------------------------------
echo ""
echo "--- Test 9: Dolt Time Travel ---"

COMMIT_COUNT=$(dsql "SELECT COUNT(*) as cnt FROM dolt_log;")
echo "  total commits: $(echo "$COMMIT_COUNT" | tail -1 | tr -d ' ')"

CELL_HISTORY=$(dsql "SELECT message FROM dolt_log WHERE message LIKE 'cell:%' ORDER BY date;")
echo "  cell commits:"
echo "$CELL_HISTORY" | grep -v "^message" | while read -r line; do
    echo "    $line"
done

if echo "$CELL_HISTORY" | grep -q "cell:"; then
    pass "Dolt commit messages trace cell evaluation"
else
    fail "commit messages" "no cell: commits found"
fi

# Count cell-specific commits
CELL_COUNT=$(echo "$CELL_HISTORY" | grep -c "cell:" || true)
if [ "$CELL_COUNT" -ge 3 ]; then
    pass "at least 3 cell-specific commits ($CELL_COUNT found)"
else
    fail "cell commit count" "expected >= 3, got $CELL_COUNT"
fi

# --------------------------------------------------------------------------
# TEST 10: Oracle - Length Mismatch
# --------------------------------------------------------------------------
echo ""
echo "--- Test 10: Oracle - Length Mismatch ---"

dsql "INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('c-src', 'oracle-test', 'source', 'hard', 'literal:[1,2,3]', 'declared');" >/dev/null

dsql "INSERT INTO cells (id, program_id, name, body_type, body, state)
VALUES ('c-len', 'oracle-test', 'lencheck', 'soft', 'produce array', 'declared');" >/dev/null

dsql "INSERT INTO givens (id, cell_id, source_cell, source_field)
VALUES ('g-len', 'c-len', 'source', 'value');" >/dev/null

dsql "INSERT INTO yields (id, cell_id, field_name, is_frozen)
VALUES ('y-len', 'c-len', 'result', FALSE);" >/dev/null

dsql "INSERT INTO oracles (id, cell_id, oracle_type, assertion, condition_expr)
VALUES ('o-len', 'c-len', 'deterministic', 'same length as source', 'length_matches:source');" >/dev/null

dsql "CALL DOLT_COMMIT('-Am', 'setup: insert oracle length test');" >/dev/null

# Evaluate the hard cell first
dsql "CALL cell_eval_step('oracle-test');" >/dev/null
# Claim the soft cell
dsql "CALL cell_eval_step('oracle-test');" >/dev/null

# Submit with wrong length (4 items vs 3)
WRONG_LEN=$(dsql "CALL cell_submit('oracle-test', 'lencheck', 'result', '[1,2,3,4]');")
if echo "$WRONG_LEN" | grep -q "oracle_fail"; then
    pass "length_matches oracle rejects wrong-length array"
else
    fail "length oracle reject" "unexpected: $WRONG_LEN"
fi

# Submit with correct length (3 items)
CORRECT_LEN=$(dsql "CALL cell_submit('oracle-test', 'lencheck', 'result', '[3,2,1]');")
if echo "$CORRECT_LEN" | grep -q "ok"; then
    pass "length_matches oracle accepts correct-length array"
else
    fail "length oracle accept" "unexpected: $CORRECT_LEN"
fi

# --------------------------------------------------------------------------
# SUMMARY
# --------------------------------------------------------------------------
echo ""
echo "============================================"
echo "RESULTS: $PASS passed, $FAIL failed"
echo "============================================"
echo ""
for t in "${TESTS[@]}"; do
    echo "  $t"
done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED -- Dolt stored procedures are viable for Cell runtime"
    echo ""
    echo "Verified capabilities:"
    echo "  1. Stored procedure creation and execution"
    echo "  2. Result set returns from procedures (dispatch/evaluated/quiescent)"
    echo "  3. DOLT_COMMIT from within procedures (custom messages in commit log)"
    echo "  4. Transaction semantics (sequential claim, state transitions)"
    echo "  5. Deterministic oracle checking in SQL"
    echo "  6. Dependency resolution via ready_cells view"
    echo "  7. Time travel via Dolt commit history"
    echo ""
    echo "Key finding: dolt_transaction_commit must be set to 0 on the session"
    echo "before calling procedures that use DOLT_COMMIT with custom messages."
    exit 0
else
    echo "SOME TESTS FAILED -- investigate before proceeding"
    exit 1
fi

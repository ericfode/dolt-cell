#!/usr/bin/env bash
# Test harness for cell_pour Phase A (LLM parser)
#
# Runs pour.sh against test .cell files, compares structural output to
# hand-written ground truth .sql files, and reports accuracy.
#
# Usage: ./tools/test-pour.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
POUR="$SCRIPT_DIR/pour.sh"
RESULTS_DIR="$REPO_DIR/tools/.pour-results"
VERBOSE="${1:-}"

mkdir -p "$RESULTS_DIR"

# --- Helpers ---

# Extract structural facts from SQL pour output (normalized for comparison).
# Returns sorted list of: TABLE:key_columns
# This ignores exact IDs and whitespace — compares semantic structure.
extract_structure() {
    local sql_file="$1"
    # Extract: table name + key values from each INSERT
    grep -i '^INSERT INTO' "$sql_file" 2>/dev/null | while read -r line; do
        # Get table name
        table=$(echo "$line" | sed -E "s/INSERT INTO ([a-z_]+).*/\1/i")
        case "$table" in
            cells)
                # Extract: program_id, name, body_type
                prog=$(echo "$line" | grep -oP "(?<=', ')[^']*(?=', '[^']*', '(hard|soft)')" | head -1)
                name=$(echo "$line" | grep -oP "(?<=', ')[^']*(?=', '(hard|soft)')" | head -1)
                btype=$(echo "$line" | grep -oP "(hard|soft)" | head -1)
                echo "CELL:$name:$btype"
                ;;
            givens)
                # Extract: source_cell, source_field
                src_cell=$(echo "$line" | sed -E "s/.*'([^']+)', '([^']+)'\);?/\1/" | tail -1)
                src_field=$(echo "$line" | sed -E "s/.*'([^']+)'\);?/\1/" | tail -1)
                echo "GIVEN:$src_cell→$src_field"
                ;;
            yields)
                # Extract: field_name
                field=$(echo "$line" | sed -E "s/.*'([^']+)'\);?/\1/" | tail -1)
                echo "YIELD:$field"
                ;;
            oracles)
                # Extract: oracle_type, assertion (truncated)
                otype=$(echo "$line" | grep -oP "(deterministic|semantic)" | head -1)
                assertion=$(echo "$line" | grep -oP "(?<=$otype', ')[^']*" | head -1 | cut -c1-60)
                echo "ORACLE:$otype:$assertion"
                ;;
        esac
    done | sort
}

# Compare two structure files, return match percentage
compare_structures() {
    local expected="$1"
    local actual="$2"

    local total_expected=$(wc -l < "$expected")
    local total_actual=$(wc -l < "$actual")

    if [ "$total_expected" -eq 0 ]; then
        echo "0"
        return
    fi

    # Count lines in expected that appear in actual
    local matched=0
    while IFS= read -r line; do
        if grep -qF "$line" "$actual"; then
            matched=$((matched + 1))
        fi
    done < "$expected"

    # Score: matched / max(expected, actual) * 100
    local denom=$total_expected
    if [ "$total_actual" -gt "$denom" ]; then
        denom=$total_actual
    fi

    echo $(( matched * 100 / denom ))
}

# --- Collect test cases ---
declare -a TEST_CELLS=()
declare -a TEST_SQLS=()
declare -a TEST_NAMES=()

# sort-proof (primary test case)
if [ -f "$REPO_DIR/examples/sort-proof.cell" ] && [ -f "$REPO_DIR/examples/sort-proof.sql" ]; then
    TEST_CELLS+=("$REPO_DIR/examples/sort-proof.cell")
    TEST_SQLS+=("$REPO_DIR/examples/sort-proof.sql")
    TEST_NAMES+=("sort-proof")
fi

# corpus programs
for cell_file in "$REPO_DIR/examples/corpus/"*.cell; do
    [ -f "$cell_file" ] || continue
    name=$(basename "$cell_file" .cell)
    sql_file="$REPO_DIR/examples/corpus/$name.sql"
    if [ -f "$sql_file" ]; then
        TEST_CELLS+=("$cell_file")
        TEST_SQLS+=("$sql_file")
        TEST_NAMES+=("corpus/$name")
    fi
done

echo "=== cell_pour Phase A Test Suite ==="
echo "Test cases: ${#TEST_NAMES[@]}"
echo ""

# --- Run tests ---
PASS=0
FAIL=0
TOTAL=${#TEST_NAMES[@]}
declare -a SCORES=()
declare -a STATUSES=()

for i in "${!TEST_NAMES[@]}"; do
    name="${TEST_NAMES[$i]}"
    cell="${TEST_CELLS[$i]}"
    sql="${TEST_SQLS[$i]}"
    prog_name=$(basename "$cell" .cell)

    echo "--- Test: $name ---"

    # Run pour.sh
    output_file="$RESULTS_DIR/$prog_name.llm.sql"
    if ! "$POUR" "$cell" "$prog_name" > "$output_file" 2>/dev/null; then
        echo "  FAIL: pour.sh returned error"
        FAIL=$((FAIL + 1))
        SCORES+=("0")
        STATUSES+=("ERROR")
        continue
    fi

    # Check output is non-empty and contains INSERT
    if [ ! -s "$output_file" ] || ! grep -qi "INSERT" "$output_file"; then
        echo "  FAIL: empty or invalid output"
        FAIL=$((FAIL + 1))
        SCORES+=("0")
        STATUSES+=("EMPTY")
        continue
    fi

    # Extract structures
    expected_struct="$RESULTS_DIR/$prog_name.expected.struct"
    actual_struct="$RESULTS_DIR/$prog_name.actual.struct"
    extract_structure "$sql" > "$expected_struct"
    extract_structure "$output_file" > "$actual_struct"

    # Compare
    score=$(compare_structures "$expected_struct" "$actual_struct")
    SCORES+=("$score")

    if [ "$score" -ge 80 ]; then
        echo "  PASS ($score% structural match)"
        PASS=$((PASS + 1))
        STATUSES+=("PASS")
    else
        echo "  FAIL ($score% structural match)"
        FAIL=$((FAIL + 1))
        STATUSES+=("FAIL")
    fi

    if [ "$VERBOSE" = "--verbose" ]; then
        echo "  Expected structure:"
        sed 's/^/    /' "$expected_struct"
        echo "  Actual structure:"
        sed 's/^/    /' "$actual_struct"
        echo "  Diff:"
        diff "$expected_struct" "$actual_struct" | sed 's/^/    /' || true
    fi
    echo ""
done

# --- Summary ---
echo "=== Results ==="
echo ""
printf "%-25s %-8s %-6s\n" "Test" "Status" "Score"
printf "%-25s %-8s %-6s\n" "----" "------" "-----"
for i in "${!TEST_NAMES[@]}"; do
    printf "%-25s %-8s %3s%%\n" "${TEST_NAMES[$i]}" "${STATUSES[$i]}" "${SCORES[$i]}"
done
echo ""
echo "Total: $TOTAL | Pass: $PASS | Fail: $FAIL"

if [ "$TOTAL" -gt 0 ]; then
    total_score=0
    for s in "${SCORES[@]}"; do
        total_score=$((total_score + s))
    done
    avg=$((total_score / TOTAL))
    echo "Average structural accuracy: ${avg}%"
    echo "First-try parse rate: $PASS/$TOTAL ($(( PASS * 100 / TOTAL ))%)"
fi

echo ""
echo "LLM outputs saved in: $RESULTS_DIR/"

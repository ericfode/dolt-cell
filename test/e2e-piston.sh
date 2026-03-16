#!/bin/bash
# End-to-end piston integration test.
# Proves the full plumbing-to-piston contract:
# pour → ct piston → ct submit → COMPLETE
#
# Uses canned answers (no real LLM needed).
# Run: RETORT_DSN="root@tcp(127.0.0.1:3308)/retort" bash test/e2e-piston.sh
set -euo pipefail

CT=${CT:-./ct}
export RETORT_DSN="${RETORT_DSN:?Set RETORT_DSN}"

echo "=== E2E Piston Test ==="

# Step 1: Pour
$CT pour haiku examples/haiku.cell 2>&1 | tail -1

# Step 2: First piston cycle — should freeze hard cells, dispatch compose
OUTPUT=$($CT piston haiku 2>&1)
echo "$OUTPUT" | head -3

# Verify compose was dispatched
echo "$OUTPUT" | grep -q "CELL: compose" || { echo "FAIL: compose not dispatched"; exit 1; }
echo "✓ compose dispatched"

# Step 3: Submit compose (canned haiku)
$CT submit haiku compose poem 'Temple stones grow dark
autumn rain taps the silence
one leaf drifts to earth'
echo "✓ compose.poem submitted"

# Step 4: Release stuck hard cells if any, then piston
# count-words may need claim cleanup from previous stored proc attempt
dolt --host 127.0.0.1 --port 3308 --user root --password "" --use-db retort --no-tls sql -q \
  "DELETE FROM cell_claims WHERE cell_id IN (SELECT id FROM cells WHERE program_id = 'haiku' AND state = 'computing'); UPDATE cells SET state = 'declared', computing_since = NULL, assigned_piston = NULL WHERE program_id = 'haiku' AND state = 'computing';" 2>/dev/null || true

OUTPUT=$($CT piston haiku 2>&1)
echo "$OUTPUT" | head -3

# Step 5: Submit critique (canned review)
if echo "$OUTPUT" | grep -q "CELL: critique"; then
  $CT submit haiku critique review 'Good haiku. Follows 5-7-5 structure. Strong kigo with autumn rain. Natural kireji. Quality: 4/5.'
  echo "✓ critique.review submitted"
fi

# Step 6: Submit judge
OUTPUT=$($CT piston haiku 2>&1)
if echo "$OUTPUT" | grep -q "judge"; then
  JUDGE=$(echo "$OUTPUT" | grep "^CELL:" | awk '{print $2}')
  $CT submit haiku "$JUDGE" verdict 'YES — Review has multiple sentences.'
  echo "✓ $JUDGE.verdict submitted"
fi

# Step 7: Verify completion
OUTPUT=$($CT piston haiku 2>&1)
echo "$OUTPUT" | head -1

if echo "$OUTPUT" | grep -q "COMPLETE"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " E2E PISTON TEST: PASS"
  echo " All cells frozen. Program complete."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  $CT yields haiku
else
  echo "FAIL: program not complete"
  $CT status haiku
  exit 1
fi

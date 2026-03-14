#!/usr/bin/env bash
# cell_pour Phase A: LLM-based parser for .cell files → SQL INSERT statements
#
# Usage: ./tools/pour.sh <file.cell> [program_name]
#
# Sends the .cell file contents along with the parsing prompt to Claude,
# captures the SQL output. If program_name is omitted, derives from filename.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_TEMPLATE="$SCRIPT_DIR/pour-prompt.md"

# --- Args ---
if [ $# -lt 1 ]; then
    echo "Usage: $0 <file.cell> [program_name]" >&2
    exit 1
fi

CELL_FILE="$1"
if [ ! -f "$CELL_FILE" ]; then
    echo "Error: file not found: $CELL_FILE" >&2
    exit 1
fi

# Derive program name from filename if not provided
PROGRAM_NAME="${2:-$(basename "$CELL_FILE" .cell)}"

# --- Read inputs ---
PROGRAM_TEXT=$(cat "$CELL_FILE")
PROMPT_TEMPLATE_TEXT=$(cat "$PROMPT_TEMPLATE")

# --- Build prompt ---
# Substitute {program_text} and {program_name} into the template
PROMPT="${PROMPT_TEMPLATE_TEXT//\{program_text\}/$PROGRAM_TEXT}"
PROMPT="${PROMPT//\{program_name\}/$PROGRAM_NAME}"

# --- Call Claude ---
echo "--- Parsing: $CELL_FILE (program: $PROGRAM_NAME) ---" >&2

OUTPUT=$(echo "$PROMPT" | claude -p \
    --model haiku \
    --allowedTools "" \
    --no-session-persistence \
    2>/dev/null)

# --- Post-process: strip markdown fences if present ---
# Some models wrap output in ```sql ... ```
OUTPUT=$(echo "$OUTPUT" | sed '/^```/d')

echo "$OUTPUT"

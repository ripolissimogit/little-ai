#!/bin/bash
# Runs the Scarabot test suite via `swift test`. Output is tee-d to
# tools/reports/test-<timestamp>.log so each run leaves a persistent record
# you can diff against the previous one.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p tools/reports
TS=$(date +%s)
LOG="tools/reports/test-$TS.log"

{
    echo "=== swift test @ $(date) ==="
    swift test 2>&1
} | tee "$LOG"

STATUS=${PIPESTATUS[0]}

echo ""
echo "─── report ───"
echo "log:    $LOG"
echo "status: $STATUS ($([[ $STATUS -eq 0 ]] && echo PASS || echo FAIL))"

exit $STATUS

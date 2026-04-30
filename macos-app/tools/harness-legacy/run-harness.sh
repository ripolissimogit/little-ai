#!/bin/bash
# Runs the LittleAI UI harness. Compiles the Harness target (debug — fast rebuild),
# then executes it. Reports land in ./tools/reports/<timestamp>-<scenario>.{json,png,log}.
#
# First-time setup: macOS will block keyboard/AX events from the harness binary. Go to
#   Settings → Privacy & Security → Accessibility → enable "Harness"
# (you may need to add it manually the first time: + button, pick .build/debug/Harness).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --product Harness 2>&1 | tail -20

BIN=".build/debug/Harness"
if [[ ! -x "$BIN" ]]; then
    echo "✗ harness binary not built at $BIN"
    exit 1
fi

mkdir -p tools/reports
"$BIN"
STATUS=$?

LATEST_REPORT=$(ls -t tools/reports/*.json 2>/dev/null | head -1 || true)
if [[ -n "$LATEST_REPORT" ]]; then
    echo ""
    echo "─── latest report ───"
    cat "$LATEST_REPORT"
fi

exit $STATUS

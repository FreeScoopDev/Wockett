#!/usr/bin/env bash
#
# The canonical way to run Wockett's tests. Use this instead of calling
# xcodebuild by hand.
#
# Why this exists:
#   1. `xcodebuild test | tail` returns *tail's* exit code, not xcodebuild's,
#      so a failed run reports success. This happened on 2026-09-07 and a
#      "128 passed" claim was made off a truncated log that proved nothing.
#   2. The PoCSquat scheme runs BOTH WockettTests and WockettUITests, and
#      Xcode Cloud's Test action uses "Use Scheme Setting" — so it runs both.
#      Running only -only-testing:WockettTests locally is a different, smaller
#      suite than CI, and will not catch what CI catches.
#   3. With stdout and stderr merged, xcodebuild's own diagnostics can land on
#      the same line as a test result and eat its "passed" suffix. On
#      2026-09-09 that silently undercounted a full run by one and cost three
#      rounds of investigation. Streams are kept separate, and the script now
#      warns whenever the number of result lines disagrees with passed+failed.
#      The verdict is always xcodebuild's own ** TEST SUCCEEDED ** line; the
#      counts are a convenience and say so when they cannot be trusted.
#
# Usage:
#   scripts/test.sh              # full scheme — same as CI. Use before pushing.
#   scripts/test.sh --unit-only  # WockettTests only. Faster; NOT what CI runs.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ONLY=""
LABEL="full scheme (unit + UI) — same as CI"
if [[ "${1:-}" == "--unit-only" ]]; then
  ONLY="-only-testing:WockettTests"
  LABEL="WockettTests only — NOT what CI runs"
fi

SIM="$(bash scripts/ci_pick_simulator.sh)"
LOG="$(mktemp -t wockett-test)"
ERRLOG="${LOG}.stderr"
echo "Running: $LABEL"
echo "Log:     $LOG"
echo "Stderr:  $ERRLOG"
echo

set +e
xcodebuild test \
  -project PoCSquat.xcodeproj \
  -scheme PoCSquat \
  -destination "id=$SIM" \
  $ONLY \
  > "$LOG" 2> "$ERRLOG"
XC_EXIT=$?
set -e

PASSED=$(grep -cE "' passed on " "$LOG" || true)
FAILED=$(grep -cE "' failed on " "$LOG" || true)
RESULTS=$(grep -cE "^Test case '[^']+'" "$LOG" || true)   # every result line, whatever its verdict
ERRORS=$(cat "$LOG" "$ERRLOG" | grep -cE " error: " || true)

echo "xcodebuild exit : $XC_EXIT"
echo "tests passed    : $PASSED"
echo "tests failed    : $FAILED"
echo "compile errors  : $ERRORS"
if [[ $((PASSED + FAILED)) -ne "$RESULTS" ]]; then
  echo
  echo "WARNING: $RESULTS test-result lines, but only $((PASSED + FAILED)) parsed as passed/failed."
  echo "         A result line is corrupted or has an unexpected verdict. The counts above are"
  echo "         not reliable; the verdict below is xcodebuild's own. Inspect: $LOG"
fi
echo

if grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG" && [[ "$XC_EXIT" -eq 0 ]]; then
  echo "** TEST SUCCEEDED **  ($LABEL)"
  exit 0
fi

echo "** TEST FAILED **  ($LABEL)"
echo
echo "--- failures ---"
grep -E "' failed on |: error: " "$LOG" | head -25 || true
echo
echo "Full log: $LOG"
echo "Stderr:   $ERRLOG"
exit 1

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
echo "Running: $LABEL"
echo "Log:     $LOG"
echo

set +e
xcodebuild test \
  -project PoCSquat.xcodeproj \
  -scheme PoCSquat \
  -destination "id=$SIM" \
  $ONLY \
  > "$LOG" 2>&1
XC_EXIT=$?
set -e

PASSED=$(grep -cE "' passed on " "$LOG" || true)
FAILED=$(grep -cE "' failed on " "$LOG" || true)
ERRORS=$(grep -cE " error: " "$LOG" || true)

echo "xcodebuild exit : $XC_EXIT"
echo "tests passed    : $PASSED"
echo "tests failed    : $FAILED"
echo "compile errors  : $ERRORS"
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
exit 1

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
#   3. The xcodebuild log is not a reliable counter. During parallel testing,
#      session-level output can be written mid-way through a test-result line
#      and eat its "passed on ..." suffix. On 2026-09-09 that undercounted one
#      run by one, silently. Two earlier explanations for it — stderr
#      interleaving, and truncation of the final line — were each disproved
#      by the next run: it happened with stderr split off, and it happened to
#      a line that was not last. So the counts below come from the xcresult
#      bundle, which is structured and authoritative (it is what Xcode Cloud
#      reads). The log is kept for humans. When the log's line count differs
#      from the bundle, the script says so as information, not alarm.
#      The verdict is xcodebuild's exit code AND its ** TEST SUCCEEDED ** line
#      AND the bundle's result — all three, or it is a failure.
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
BUNDLE="$(mktemp -d -t wockett-test-bundle)/result.xcresult"   # must not pre-exist; xcodebuild refuses to overwrite
echo "Running: $LABEL"
echo "Log:     $LOG"
echo "Stderr:  $ERRLOG"
echo "Bundle:  $BUNDLE"
echo

set +e
xcodebuild test \
  -project PoCSquat.xcodeproj \
  -scheme PoCSquat \
  -destination "id=$SIM" \
  -resultBundlePath "$BUNDLE" \
  $ONLY \
  > "$LOG" 2> "$ERRLOG"
XC_EXIT=$?
set -e

# Authoritative counts, from the result bundle.
read -r B_PASSED B_FAILED B_SKIPPED B_TOTAL B_RESULT <<<"$(
  xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("passedTests", "?"), d.get("failedTests", "?"), d.get("skippedTests", "?"),
          d.get("totalTestCount", "?"), d.get("result", "?"))
except Exception:
    print("? ? ? ? ?")'
)"

# Log-derived counts, for comparison only.
LOG_LINES=$(grep -cE "^Test case '[^']+'" "$LOG" || true)
ERRORS=$(cat "$LOG" "$ERRLOG" | grep -cE " error: " || true)

echo "xcodebuild exit : $XC_EXIT"
if [[ "$B_RESULT" == "?" ]]; then
  echo "bundle          : UNREADABLE — falling back to the log, which can undercount"
  B_PASSED=$(grep -cE "' passed on " "$LOG" || true)
  B_FAILED=$(grep -cE "' failed on " "$LOG" || true)
  B_TOTAL=$LOG_LINES; B_SKIPPED="?"; B_RESULT="unknown"
fi
echo "tests passed    : $B_PASSED"
echo "tests failed    : $B_FAILED"
echo "tests skipped   : $B_SKIPPED"
echo "tests total     : $B_TOTAL  (bundle result: $B_RESULT)"
echo "compile errors  : $ERRORS"
if [[ "$B_TOTAL" != "?" && "$LOG_LINES" -ne "$B_TOTAL" ]]; then
  echo "note            : the log shows $LOG_LINES result lines vs $B_TOTAL in the bundle —"
  echo "                  xcodebuild's stdout can corrupt a result line during parallel"
  echo "                  testing. The bundle is authoritative; the log is for reading."
fi
echo

if [[ "$XC_EXIT" -eq 0 ]] && grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG" \
   && [[ "$B_RESULT" == "Passed" ]] && [[ "$B_FAILED" == "0" ]]; then
  echo "** TEST SUCCEEDED **  ($LABEL)"
  exit 0
fi

echo "** TEST FAILED **  ($LABEL)"
echo
echo "--- failures ---"
xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    for f in json.load(sys.stdin).get("testFailures", [])[:25]:
        print(f"  {f.get(\"testName\", \"?\")}: {f.get(\"failureText\", \"\")}")
except Exception:
    pass' || true
grep -E "' failed on |: error: " "$LOG" | head -25 || true
echo
echo "Full log: $LOG"
echo "Stderr:   $ERRLOG"
echo "Bundle:   $BUNDLE"
exit 1

#!/usr/bin/env bash
# Records one how-to video's raw clip: runs its UI test on the booted simulator
# while `simctl io recordVideo` films the screen.
#   scripts/how-to-videos/record.sh 01
# Output: $WKT_VIDEOS_DIR/raw/video-NN.mov (default ~/Desktop/Apps/Wockett-videos/raw).
# A failed or skipped test leaves NO raw clip (the failed take is kept as
# video-NN.failed.mov for diagnosis), so render.sh cannot be fed a bad take.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NN="${1:-}"
[[ -n "$NN" ]] || { echo "usage: record.sh NN   (01 02 03 04 05 06 07 10)" >&2; exit 2; }
valid_video "$NN"
TEST_NAME="$(slug_for "$NN")"

APP_SCHEME="PoCSquat"
APP_PROJECT="$REPO_ROOT/PoCSquat.xcodeproj"
UI_TARGET="WockettUITests"

# a. The simulator. SIM_UDID picks one when several are booted.
if [[ -n "${SIM_UDID:-}" ]]; then
  UDID="$SIM_UDID"
else
  BOOTED="$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)"
  COUNT="$(grep -c . <<<"$BOOTED" || true)"
  if [[ -z "$BOOTED" ]]; then
    echo "No simulator is booted. Boot one (open Simulator, or: xcrun simctl boot <udid>) and retry." >&2
    exit 1
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "$COUNT simulators are booted; pick one with SIM_UDID=<udid>:" >&2
    xcrun simctl list devices booted >&2
    exit 1
  fi
  UDID="$BOOTED"
fi
echo "Simulator: $UDID"

# One run per simulator at a time; test.sh uses the same lock, so a normal
# test run waits for a recording and the other way round.
LOCK="${TEST_LOCK_DIR:-${TMPDIR:-/tmp}}/app-toolkit-test-wockett-$UDID.lock"
until mkdir "$LOCK" 2>/dev/null; do
  OWNER="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$OWNER" ]] && ! kill -0 "$OWNER" 2>/dev/null; then rm -rf -- "${LOCK:?}"; continue; fi
  echo "Waiting: another Wockett test run holds this simulator (pid ${OWNER:-?})."; sleep 5
done
echo $$ > "$LOCK/pid"; echo "$REPO_ROOT" > "$LOCK/root"

WORK="$(mktemp -d -t wkt-howto)"
RAW="$RAW_DIR/video-$NN.mov"
FAILED_TAKE="$RAW_DIR/video-$NN.failed.mov"
REC_PID=""
LOC_ON=0
KEEP_WORK=0
mkdir -p "$RAW_DIR"
rm -f "$RAW" "$FAILED_TAKE"   # a stale clip from an earlier take must never survive a failed run

stop_recording() {
  if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" 2>/dev/null; then
    kill -INT "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true   # the file is only finalised once simctl exits
  fi
  REC_PID=""
}
cleanup() {
  stop_recording
  if [[ "$LOC_ON" -eq 1 ]]; then xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true; fi
  if [[ "$KEEP_WORK" -eq 0 ]]; then rm -rf -- "${WORK:?}"; fi
  rm -rf -- "${LOCK:?}"
}
trap cleanup EXIT

# b. The bundle id, read from the project (target PoCSquat), not guessed.
BUNDLE_ID="$(xcodebuild -project "$APP_PROJECT" -scheme "$APP_SCHEME" -showBuildSettings -json 2>/dev/null \
  | python3 -c 'import sys, json
for t in json.load(sys.stdin):
    if t.get("target") == "PoCSquat":
        print(t["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"]); break')"
[[ -n "$BUNDLE_ID" ]] || { echo "Could not read the app's bundle identifier from the project." >&2; exit 1; }
echo "App:       $BUNDLE_ID"

# Build first, outside the recording: a cold compile is minutes of nothing.
echo "Building for testing (not recorded)..."
set +e
xcodebuild build-for-testing -project "$APP_PROJECT" -scheme "$APP_SCHEME" -destination "id=$UDID" \
  -only-testing:"$UI_TARGET/HowToVideoTests/$TEST_NAME" > "$WORK/build.log" 2> "$WORK/build.err"
BUILD_EXIT=$?
set -e
if [[ $BUILD_EXIT -ne 0 ]] || ! grep -q '\*\* TEST BUILD SUCCEEDED \*\*' "$WORK/build.log"; then
  KEEP_WORK=1
  echo "Build failed (exit $BUILD_EXIT). Log: $WORK/build.log  Stderr: $WORK/build.err" >&2
  exit 1
fi

# The privacy grant needs the app installed; the test run's own install
# keeps the grant.
APP_PATH="$(xcodebuild -project "$APP_PROJECT" -scheme "$APP_SCHEME" -destination "id=$UDID" -showBuildSettings -json 2>/dev/null \
  | python3 -c 'import sys, json
for t in json.load(sys.stdin):
    if t.get("target") == "PoCSquat":
        s = t["buildSettings"]; print(s["TARGET_BUILD_DIR"] + "/" + s["FULL_PRODUCT_NAME"]); break')"
xcrun simctl install "$UDID" "$APP_PATH"
for svc in location motion; do
  xcrun simctl privacy "$UDID" grant "$svc" "$BUNDLE_ID"
done

# c. Video 5 records a real walk, which needs a moving location: ~1 km loop
# around the demo start (DemoMode.coordinate), 3 m/s, repeated so it outlasts
# the test's 240 s distance wait. Stopped by cleanup().
if [[ "$NN" == "05" ]]; then
  L1="35.7779,-78.6387"; L2="35.7804,-78.6387"; L3="35.7804,-78.6403"; L4="35.7779,-78.6403"
  xcrun simctl location "$UDID" start --speed=3 "$L1" "$L2" "$L3" "$L4" "$L1" "$L2" "$L3" "$L4" "$L1" "$L2" "$L3" "$L4" "$L1" >/dev/null
  LOC_ON=1
fi

# d. Recording, in the background.
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$RAW" > "$WORK/rec.log" 2>&1 &
REC_PID=$!
for _ in $(seq 1 30); do
  grep -q "Recording started" "$WORK/rec.log" 2>/dev/null && break
  kill -0 "$REC_PID" 2>/dev/null || { echo "Recorder exited early:" >&2; cat "$WORK/rec.log" >&2; exit 1; }
  sleep 0.5
done
grep -q "Recording started" "$WORK/rec.log" || { echo "Recorder never started." >&2; cat "$WORK/rec.log" >&2; exit 1; }
echo "Recording (pid $REC_PID) -> $RAW"

# e. The test. TEST_RUNNER_ variables reach the UI-test process without the
# prefix, which is how CI's TEST_RUNNER_WOCKETT_CI works too (tests.yml).
BUNDLE="$WORK/result.xcresult"
set +e
TEST_RUNNER_WKT_HOW_TO_RECORD=1 xcodebuild test-without-building \
  -project "$APP_PROJECT" -scheme "$APP_SCHEME" -destination "id=$UDID" \
  -resultBundlePath "$BUNDLE" \
  -only-testing:"$UI_TARGET/HowToVideoTests/$TEST_NAME" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  > "$WORK/test.log" 2> "$WORK/test.err"
XC_EXIT=$?
set -e

# f. Stop the recording only now.
stop_recording

# Authoritative verdict: exit code, the literal line, and the bundle's counts.
# test-without-building prints "** TEST EXECUTE SUCCEEDED **"; plain `xcodebuild test`
# prints "** TEST SUCCEEDED **". Never pipe xcodebuild: the pipe hides its exit code.
read -r PASSED FAILED SKIPPED TOTAL RESULT <<<"$(
  xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("passedTests", "?"), d.get("failedTests", "?"), d.get("skippedTests", "?"),
          d.get("totalTestCount", "?"), d.get("result", "?"))
except Exception:
    print("? ? ? ? ?")')"
echo "xcodebuild exit: $XC_EXIT   bundle: passed=$PASSED failed=$FAILED skipped=$SKIPPED total=$TOTAL result=$RESULT"

if [[ $XC_EXIT -eq 0 ]] && grep -q '\*\* TEST EXECUTE SUCCEEDED \*\*' "$WORK/test.log" \
   && [[ "$PASSED" == "1" && "$FAILED" == "0" && "$SKIPPED" == "0" && "$TOTAL" == "1" && "$RESULT" == "Passed" ]]; then
  [[ -s "$RAW" ]] || { echo "Test passed but the raw clip is missing or empty." >&2; exit 1; }
  echo "OK: $RAW ($(du -h "$RAW" | cut -f1))"
  exit 0
fi

mv "$RAW" "$FAILED_TAKE" 2>/dev/null || true
KEEP_WORK=1
echo "FAILED: no clip produced for video $NN. A skipped test (6 and 10) counts as a failure here." >&2
xcrun xcresulttool get test-results summary --path "$BUNDLE" 2>/dev/null \
  | python3 -c 'import sys, json
try:
    for f in json.load(sys.stdin).get("testFailures", [])[:10]:
        print("  %s: %s" % (f.get("testName", "?"), f.get("failureText", "")))
except Exception:
    pass' >&2 || true
echo "Logs and bundle kept in $WORK; failed take at $FAILED_TAKE" >&2
exit 1

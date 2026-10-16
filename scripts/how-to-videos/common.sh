#!/usr/bin/env bash
# Shared by record.sh, render.sh and build-batch.sh. Sourced, not run.

# The plain Homebrew ffmpeg has no `subtitles` or `drawtext` filter; ffmpeg-full does.
FFMPEG="${FFMPEG:-/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg}"
FFPROBE="${FFPROBE:-$(dirname "$FFMPEG")/ffprobe}"

# Outputs live outside the repo (the plan: rendered videos stay on the Mac).
OUT_DIR="${WKT_VIDEOS_DIR:-$HOME/Desktop/Apps/Wockett-videos}"
RAW_DIR="$OUT_DIR/raw"

HTV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HTV_DIR/../.." && pwd)"
CAPTIONS_DIR="$HTV_DIR/captions"

# video number -> the UI test's name in WockettUITests/HowToVideoTests.swift.
# `-only-testing:` needs it exactly.
slug_for() {
  case "$1" in
    01) echo "test_video_01_start_a_walk" ;;
    02) echo "test_video_02_find_a_loop" ;;
    03) echo "test_video_03_named_trails" ;;
    04) echo "test_video_04_build_your_own_route" ;;
    05) echo "test_video_05_save_a_walk_as_a_route" ;;
    06) echo "test_video_06_turn_around_here" ;;
    07) echo "test_video_07_hold_to_finish_keep_walking" ;;
    10) echo "test_video_10_start_a_challenge_and_share_it" ;;
    *)  return 1 ;;
  esac
}

# Seconds to cut from the start of the raw recording, per video. The raw clip
# opens on the simulator's Springboard, then the app launches (~4.7 s in) and
# shows a splash until Home crossfades in (~11.1 s in). The test cannot write
# timestamps, so these are MEASURED, not assumed (README: "Calibrating"). The
# value is the first moment Home is fully shown, i.e. the first frame the test
# acts on, with ~0.2 s margin past the end of the crossfade.
# Measured 2026-10-16, video 01, two real runs on iPhone 17e / iOS 27 sim:
# app launch 4.66 s and 4.64 s; splash->Home crossfade 10.81-11.09 s and ~11.07 s.
# Videos 02, 03, 04, 05, 07 use the same launch path (`-WKTDemo`, same splash),
# so they reuse 11.3 UNMEASURED until each has been recorded once. 06 and 10
# have never recorded (their tests skip).
offset_for() {
  case "$1" in
    01)                     echo "11.3" ;;   # measured, 2 runs
    02|03|04|05|07|06|10)   echo "11.3" ;;   # same launch path; not yet measured per video
    *)                      echo "0" ;;
  esac
}

need_ffmpeg() {
  [[ -x "$FFMPEG" ]] || { echo "ffmpeg not found at $FFMPEG. Install ffmpeg-full (brew install ffmpeg-full) or set FFMPEG=." >&2; return 1; }
  local filters
  filters="$("$FFMPEG" -hide_banner -filters 2>/dev/null)"   # captured, not piped to grep -q (SIGPIPE + pipefail)
  if ! grep -qE '[[:space:]]subtitles[[:space:]]' <<<"$filters"; then
    echo "$FFMPEG has no 'subtitles' filter. The plain Homebrew ffmpeg lacks it; use ffmpeg-full at /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg." >&2
    return 1
  fi
}

valid_video() {
  slug_for "$1" >/dev/null 2>&1 || { echo "Unknown video '$1'. Known: 01 02 03 04 05 06 07 10" >&2; return 1; }
}

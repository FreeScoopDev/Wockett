#!/usr/bin/env bash
# Records and renders batch 1.
#   scripts/how-to-videos/build-batch.sh [--force]
# --force is passed to render.sh (overwrite finished videos). Takes a while:
# each video is a build, a test run and an encode. One failure does not stop
# the rest; the exit code is 1 if any recordable video failed.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HERE="$HTV_DIR"
RENDER_ARGS=()
[[ "${1:-}" == "--force" ]] && RENDER_ARGS=(--force)
need_ffmpeg || exit 1

ROWS=(); FAILS=0
add_row() { ROWS+=("$(printf '%-6s %-9s %-9s %s' "$1" "$2" "$3" "$4")"); }

for NN in 01 02 03 04 05 07; do
  echo; echo "=== video $NN ==="
  if ! "$HERE/record.sh" "$NN"; then add_row "$NN" "FAILED" "-" "record"; FAILS=$((FAILS+1)); continue; fi
  if ! "$HERE/render.sh" "$NN" ${RENDER_ARGS[@]+"${RENDER_ARGS[@]}"}; then add_row "$NN" "FAILED" "-" "render"; FAILS=$((FAILS+1)); continue; fi
  OUT="$OUT_DIR/video-$NN.mp4"
  DUR="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")"
  add_row "$NN" "ok" "$(awk -v d="$DUR" 'BEGIN { printf "%.1f s", d }')" "$(awk -v b="$(stat -f %z "$OUT")" 'BEGIN { printf "%.2f MB", b/1048576 }')"
done
add_row 06 "skipped" "-" "test skips: no -WKTDemo location within 150 m of an out-and-back trail"
add_row 10 "skipped" "-" "test skips without a simulator signed in to iCloud (CloudKit)"

echo; echo "=== summary ==="
printf '%-6s %-9s %-9s %s\n' video status duration size
printf '%s\n' "${ROWS[@]}"
[[ $FAILS -eq 0 ]]

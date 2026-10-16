#!/usr/bin/env bash
# Turns a raw clip into the finished vertical video.
#   scripts/how-to-videos/render.sh 01 [--force]
# raw:    $WKT_VIDEOS_DIR/raw/video-NN.mov  (from record.sh)
# output: $WKT_VIDEOS_DIR/video-NN.mp4      (default ~/Desktop/Apps/Wockett-videos)
# Captions come from captions/video-NN.txt ("start | end | text"); they are DRAFTS.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NN=""; FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) NN="$a" ;;
  esac
done
[[ -n "$NN" ]] || { echo "usage: render.sh NN [--force]" >&2; exit 2; }
valid_video "$NN"
need_ffmpeg

RAW="$RAW_DIR/video-$NN.mov"
CAPS="$CAPTIONS_DIR/video-$NN.txt"
OUT="$OUT_DIR/video-$NN.mp4"
[[ -s "$RAW" ]] || { echo "No raw clip at $RAW. Run record.sh $NN first." >&2; exit 1; }
[[ -s "$CAPS" ]] || { echo "No captions at $CAPS." >&2; exit 1; }
if [[ -e "$OUT" && $FORCE -eq 0 ]]; then
  echo "$OUT exists. Pass --force to overwrite." >&2; exit 1
fi
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d -t wkt-render)"
trap 'rm -rf -- "${WORK:?}"' EXIT
SRT="$WORK/captions.srt"

# captions text -> SRT. Text after the second " | " is kept whole.
awk -F' \\| ' '
  function ts(s,   h, m, x) { h = int(s/3600); m = int((s - h*3600)/60); x = s - h*3600 - m*60
                              return sprintf("%02d:%02d:%06.3f", h, m, x) }
  NF >= 3 && $1 !~ /^#/ {
    text = $3; for (i = 4; i <= NF; i++) text = text " | " $i
    n++; printf "%d\n%s --> %s\n%s\n\n", n, ts($1), ts($2), text
  }' "$CAPS" | sed 's/\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)\.\([0-9]*\)/\1,\2/g' > "$SRT"
[[ -s "$SRT" ]] || { echo "No caption lines parsed from $CAPS." >&2; exit 1; }
LAST_END="$(awk -F' \\| ' 'NF >= 3 && $1 !~ /^#/ { e = $2 } END { print e + 0 }' "$CAPS")"

OFFSET="$(offset_for "$NN")"
RAW_DUR="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$RAW")"
CLIP_DUR="$(awk -v r="$RAW_DUR" -v o="$OFFSET" 'BEGIN { printf "%.3f", r - o }')"
# A caption that ends after the clip does would be cut off: fail, never pad.
if awk -v c="$CLIP_DUR" -v l="$LAST_END" 'BEGIN { exit !(l > c) }'; then
  echo "Caption file $CAPS ends at ${LAST_END}s but the clip is only ${CLIP_DUR}s (raw ${RAW_DUR}s minus offset ${OFFSET}s)." >&2
  echo "Re-time the captions to the clip; render.sh does not hold the last frame." >&2
  exit 1
fi

# Subtitle sizes are in libass PlayRes units (288 high for SRT), so 9 is
# ~60 px on a 1920 px frame. BorderStyle=3 draws an opaque box behind the text.
STYLE="FontName=Helvetica,FontSize=9,Bold=1,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BackColour=&H00000000,BorderStyle=3,Outline=3,Shadow=0,Alignment=2,MarginV=90,MarginL=20,MarginR=20"
VF="fps=30,scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,subtitles=$SRT:force_style='$STYLE'"

echo "Rendering video $NN: offset ${OFFSET}s, clip ${CLIP_DUR}s, last caption ends ${LAST_END}s"
"$FFMPEG" -hide_banner -loglevel error -y -ss "$OFFSET" -i "$RAW" -an -vf "$VF" \
  -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p -movflags +faststart "$OUT"

SIZE_MB="$(awk -v b="$(stat -f %z "$OUT")" 'BEGIN { printf "%.2f", b/1048576 }')"
DUR="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")"
echo "Wrote $OUT  (${SIZE_MB} MB, $(awk -v d="$DUR" 'BEGIN { printf "%.1f", d }') s)"

# How-to video pipeline

Records and renders Wockett's short how-to videos with no hand editing. A UI
test (`WockettUITests/HowToVideoTests.swift`) drives the screens; these scripts
film the simulator while it runs, then trim, caption and encode the clip.
Rendered videos and raw clips go to `~/Desktop/Apps/Wockett-videos/`, outside
the repo. Nothing here is committed except the scripts and caption text.

## Caption status: DRAFT, UNVERIFIED

The files in `captions/` were drafted by an agent and have **not** been checked
against the shipped UI labels or the plan's wording. Check each one before a
video is published. They are plain text, one caption per line, `start | end |
text` (seconds), and are kept apart from the script logic so correcting them
never touches the scripts.

Video 01's captions were re-timed to the real ~11 s clip: two captions only.
The other drafted lines are kept as comments in `captions/video-01.txt` and are
left out of the render, because nothing on screen matches them. Captions for
02, 03, 04, 05 and 07 are still the original drafts and do not fit their clips
(render.sh refuses 02, 03, 04 and 07; 05's render shows them on the wrong screens).

## Prerequisites

1. A booted iOS simulator (`xcrun simctl list devices booted`). If more than one
   is booted, choose with `SIM_UDID=<udid>`.
2. `ffmpeg-full` at `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`. The plain
   Homebrew ffmpeg has no `subtitles` filter; `render.sh` checks and stops
   with a message if it is missing. Override the path with `FFMPEG=`.
3. The UI test file `WockettUITests/HowToVideoTests.swift` (PR #259) on your
   branch. `-WKTDemo` (demo mode) is already on `main`.
4. No other test run on that simulator: `record.sh` takes the same lock as
   `scripts/test.sh`, so a second run waits.

## Commands

    scripts/how-to-videos/record.sh 01            # raw clip -> ~/Desktop/Apps/Wockett-videos/raw/video-01.mov
    scripts/how-to-videos/render.sh 01            # -> ~/Desktop/Apps/Wockett-videos/video-01.mp4
    scripts/how-to-videos/render.sh 01 --force    # overwrite an existing render
    scripts/how-to-videos/build-batch.sh          # videos 01 02 03 04 05 07, then a summary table

- `record.sh NN` builds the tests first (not filmed), installs the app, grants
  location and motion (bundle id read from the project), starts
  `simctl io recordVideo`, runs only that video's test with
  `TEST_RUNNER_WKT_HOW_TO_RECORD=1`, and stops the recorder only after
  `xcodebuild` exits. The clip is kept only if the xcresult shows exactly one
  test passed, none failed or skipped. Otherwise there is no clip (the failed
  take is kept as `video-NN.failed.mov`). Video 05 also starts a moving
  location (`simctl location start`, a ~1 km loop at 3 m/s from the demo
  start) and clears it at the end.
- `render.sh NN` trims the lead-in (`offset_for` in `common.sh`), converts to
  30 fps, scales and pads to 1080x1920, burns the captions in, encodes H.264
  yuv420p at CRF 23, and prints the size. It never pads or holds a frame: if a
  caption ends after the clip does, it fails and says so. It refuses to
  overwrite without `--force`. Caption box: MarginV=90 (libass units), which
  clears the walk screen's distance and time numbers but covers the Start
  Walk button on Home.
- `build-batch.sh` runs both for each recordable video, keeps going after a
  failure, and prints video / status / duration / size.

## Calibrating the offsets

The test cannot write timestamps, so the lead-in (recording starts, then the
runner installs and launches the app) is measured from a real clip, not
assumed. The table is `offset_for` in `common.sh`. To measure: run
`record.sh NN`, then find the first frame that differs from the first frame:

    /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -i raw/video-NN.mov \
      -vf "select='gt(scene,0.05)',showinfo" -f null - 2>&1 | grep pts_time | head -3

Re-measure after an Xcode, runtime or app-launch change. A video with no
measurement uses 0 (nothing trimmed).

## Known blockers

- **Video 06 (Turn Around here):** its test skips. Head back needs a walk that
  starts from a trail, which is offered only within 150 m of an out-and-back
  trail; the demo location (downtown Raleigh) is about 650 m from the nearest.
  Needs a different demo location or fix.
- **Video 10 (challenge and share):** its test skips unless the simulator is
  signed in to iCloud, because a challenge is saved to CloudKit's public
  database (Development, from a Debug build).
- Both are excluded from `build-batch.sh`. `record.sh 06` / `10` run the test
  and, because a skip is not a pass, produce no clip.

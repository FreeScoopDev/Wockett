### Internal
- `WockettUITests/HowToVideoTests.swift` drives the screens of each batch-1
  how-to video, one test per video (`test_video_<nn>_<slug>`), from the
  `-WKTDemo` starting state. The videos are recorded on the simulator by a
  script that wraps `simctl io booted recordVideo` around one test at a time,
  so the screens have to be walked the same way on every run rather than by
  hand. Each step waits for the screen it is about to act on first, so a
  wrong screen fails before a recording is wasted. The tests are skipped
  unless `WKT_HOW_TO_RECORD=1` reaches the test runner, so CI and an ordinary
  test run report them as skipped and never spend runner time on them.
  Videos 5 and 6 need the simulator's location to be moving, which the
  recording script supplies. Video 6 is skipped from the demo location, which
  is about 650 m from the nearest trail (a trail walk starts only within
  150 m). Video 10 is skipped on a simulator that is not signed in to iCloud.

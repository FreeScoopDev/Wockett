### Internal
- A `-WKTDemo` launch argument starts a debug build with the state the how-to
  videos need: one finished walk that can be saved as a custom route, one
  saved route under My Routes, and a fixed location (downtown Raleigh) that
  Find Routes and Trails search from. The Routes map leaves out the
  simulator's own location in demo mode, which would otherwise pull the
  framing across the world. The videos are recorded from UI tests on
  a fresh simulator, which has none of that, so each recording would otherwise
  start from a different, mostly empty screen. The seed lives in an in-memory
  store with CloudKit off, never the user's store, and Home skips the Health
  and notification requests, the badge celebration and the resume-walk alert
  so a recording starts clean. Nothing from a demo session outlives it: a walk
  recorded in demo mode writes no checkpoint (so a later launch cannot resume
  it or save it to the real store), and streaks and seen badges stay in
  memory. It is compiled only into debug builds, only the launch argument
  turns it on, and `-WKTUITest` on its own is unchanged.
- Recording tests should launch with `["-WKTDemo"]` alone, not through the
  smoke tests' launch helper, which adds `-WKTUITest` and with it no splash and
  no animations. If both flags are passed, `-WKTDemo` wins for the data and the
  location: its seed instead of the screenshot seed, its Raleigh location and
  real routes instead of Times Square and the stub "Test Route".

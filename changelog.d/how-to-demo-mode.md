### Internal
- A `-WKTDemo` launch argument starts a debug build with the state the how-to
  videos need: one finished walk that can be saved as a custom route, one
  saved route under My Routes, and a fixed location (downtown Raleigh) that
  Find Routes and Trails search from. The videos are recorded from UI tests on
  a fresh simulator, which has none of that, so each recording would otherwise
  start from a different, mostly empty screen. The seed lives in an in-memory
  store with CloudKit off, never the user's store, and Home skips the Health
  and notification requests, the badge celebration and the resume-walk alert
  so a recording starts clean. It is compiled only into debug builds and only
  the launch argument turns it on; `-WKTUITest` is unchanged.

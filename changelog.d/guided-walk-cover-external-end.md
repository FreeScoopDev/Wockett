### Fixed
- Ending a guided walk from the Live Activity while its screen is open now
  takes you back to Home. Until now the walk was saved, but the walk screen
  then started a new free walk in its place, with its own timer, Live
  Activity and Health workout, so the person was still "walking". The walk
  screen only remembered having a session if it had started a free walk
  itself; a guided walk, or any walk reopened from the mini tile, looked to
  it like a screen that had not started yet. It now remembers any session it
  has shown, and Home also closes the walk screen whenever the walk ends. A
  UI test presses the real Live Activity End button and fails on the old
  code.

### Fixed
- A guided walk that reaches its end is no longer lost if the walk screen
  was closed. Completion deleted the crash checkpoint before anything had
  saved the walk, and only the walk screen saved it, so a walk finished
  while minimised to the mini tile vanished if the app was then killed. The
  finished walk is now saved at once when the screen is not up, kept on
  disk until it is saved when it is, and a finished walk found at launch is
  saved rather than offered for resume.
- A finished guided walk no longer leaves a checkpoint behind. The write at
  the end of each waypoint ran after the checkpoint had been deleted and put
  it back, so the next launch asked to resume a walk that was already over,
  or, after four hours, saved it a second time.

### Fixed
- A walk, run or ride whose save fails is no longer lost while the screen says
  it was saved. Walk History wrote with `try?`: a write that threw left the walk
  in the list on screen but not on disk, and ending the walk then deleted the
  crash checkpoint, the only other copy, ended the Live Activity and finished
  the Health workout. Now a save counts only once it is on disk. If it fails,
  the walk keeps going with its checkpoint, Live Activity and Health workout,
  paused while an alert asks "Couldn't save your walk" with **Try again** and
  **Keep going** (Discard stays in the Finish sheet). It appears wherever the
  walk was ended: the walk screen, the mini tile, the Live Activity's End or a
  route completed while minimised. Try again finishes the Health workout at the
  time Finish was pressed, once.
- An indoor walk whose save fails is not marked saved: its summary says so and
  its Save button tries again, and its pets' credit is saved with it or not at
  all. A logged past walk keeps its sheet open with a message. The "Save walk"
  notification's walk is kept until it is saved: a failed save shows the same
  alert, and the next launch tries again (it used to be forgotten before the
  save was attempted). Activity History opens only once it is saved. A
  stale or finished walk recovered at launch keeps its checkpoint until it is
  saved, instead of deleting it first.
- Editing a walk's notes, type or route-stats setting, or deleting it, puts the
  old state back on screen when the write fails, so the list never shows what
  is not on disk. A failed delete no longer waits in the database to be carried
  out by the next save.

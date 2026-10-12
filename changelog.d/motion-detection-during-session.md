### Fixed
- Locking the phone during a walk, run or ride no longer switches off the
  driving check and auto-resume. Both read Core Motion's activity updates,
  and Home stopped those updates whenever the app went to the background, to
  save battery, with no exception for a session in progress. A session spends
  most of its time in a pocket, so a walk that auto-paused at a coffee stop
  stayed paused after you set off again unless you opened the app, and a
  drive in the middle of a walk was only caught from GPS speed. Updates now
  keep running in the background while a session is on, and stop as before
  once it ends.

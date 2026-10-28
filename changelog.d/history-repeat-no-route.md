### Fixed
- Repeat in Activity History no longer starts a walk that never records. A
  walk with no saved route (logged as a Past Walk, an Untracked Walk, a free
  walk that never got a GPS fix, or an old pet-credit entry) gave Repeat
  nothing to follow, so the walk screen opened with a timer stuck at 0:00 and
  nothing was saved. Its Repeat review now says it has no route to follow and
  offers no Start, the way indoor walks already did, and Repeat stays in the
  menu so the reason can be found. Activities with a route repeat as before.

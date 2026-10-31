### Changed
- The Health tab now starts with your own activity: Insights and Activity
  History under "Your activity", then the week and 30-day trend, then "Sleep
  and recovery", Walking health, the fun facts and the disclaimer. Recovery
  used to come first, so the tab opened on an interpretation (readiness from
  sleep and heart rate, which needs a Watch) before the steps and activities
  it is meant to sit beside; someone without a Watch met a row of dashes
  before anything of theirs. The fun facts now follow the real statistics.
- With no step data for 30 days, the trend now offers a "Check Health access"
  button that opens the Health app, and its hint says to check Wockett's
  access there (it said "in Settings", while the app's own row opens Health).
  iOS shows its Health access sheet only once, so the app cannot ask again:
  the Health app is the one place a person can change it.

### Fixed
- The month calendar with no steps for the month now says so ("No step data
  for this month.", with the same hint) instead of showing a bare grid. It
  says nothing until that month's steps have loaded, so a month with steps
  never flashes "no data", and a failed query reads "Step history is
  unavailable right now.", as the 30-day trend does.

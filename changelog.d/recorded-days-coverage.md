### Fixed
- The Health tab's "Last 30 days" and the month calendar's "This month" now
  say which days their numbers are based on: "18 of 30 days have steps". The
  average and the goals count were always taken over days with steps only,
  and nothing said so; with no Health data the card read "0/0 Goals" beside
  a flat line. Apple Health cannot tell a day you did not move from a day
  with no step data, and never says whether Wockett may read your steps, so
  the average is now labelled "avg on recorded days", goals read "3 of 18",
  and the month notes say "recorded days". With no steps at all the card
  says so in a sentence ("No step data for the last 30 days", with a pointer
  to Health access in Settings, or "No recorded activities" in App Only
  mode) instead of zeros, and a Health query that fails says "Step history
  is unavailable right now" instead of looking like an empty month. In App
  Only mode the 30-day card now reads your recorded activities, as the week
  strip and month calendar already did, instead of Apple Health. The day
  cells and the week strip are unchanged, and the charts look as before
  whenever there are steps to draw.

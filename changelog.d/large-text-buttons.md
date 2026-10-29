### Fixed
- Buttons read in full at the accessibility text sizes. Every main and
  secondary button kept its title to one line, so at Accessibility 2 they were
  cut off: "Connect Apple He…" on Health, "Schedule this walk a…" on a walk's
  summary, and on the Community You card, two to a row, "Start a c…" /
  "Share a r…". At the accessibility sizes a title now takes as many lines as
  it needs (a "Start the … hike" button carries a trail's full name, so two
  lines are not always enough), and two buttons that share a row stack, the
  first above, each the full width: the You card's pair and the route
  builder's Undo / Save Route. The normal text sizes look exactly as before.
  Both rows use one shared `WktButtonRow`, so the rule cannot drift between
  screens.

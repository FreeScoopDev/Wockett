### Changed
- A saved route's page now answers "can I do this, and how do I start?" first.
  Start sits in a bar at the foot of the screen with the activity picker, so
  it is always in reach without scrolling; before, it came after a fixed
  320 pt map, the weather and the elevation chart, at y 1030 on an iPhone 17e
  at the default text size and y 1478 at Accessibility 2, both below the
  fold. The map is now 240 pt and scrolls away with the page. Under the
  route's name, one card gives the distance, the time (labelled "About N min
  walking", because the estimate assumes walking whichever activity is
  picked), the steps, the climb and the difficulty, with one line saying why:
  "Hard because one part is 17 % steep" for the demo's half-mile city loop.
  The difficulty never said what it was based on, so a short, nearly flat
  loop marked Hard read as a mistake.

### Internal
- The difficulty of a profiled route is decided by one function,
  `RouteDifficulty.classify`, which `ElevationService.buildProfile` calls, so
  the thresholds exist once and the why-line comes from the same rule that
  picks the level. Thresholds and outcomes are unchanged
  (`RouteDifficultyTests`). The saved route's Start has the identifier
  `routes.detailStart`, and a smoke test checks its frame is on the first
  screen at both sizes before any swipe.

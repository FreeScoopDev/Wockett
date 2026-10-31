### Changed
- A saved route's page now answers "can I do this, and how do I start?" first.
  Start sits in a bar at the foot of the screen with the activity picker, so
  it is always in reach without scrolling; before, it came after a fixed
  320 pt map, the weather and the elevation chart, at y 1030 on an iPhone 17e
  at the default text size and y 1478 at Accessibility 2, both below the
  fold. The map is now 240 pt and scrolls away with the page. Under the
  route's name, one card gives the distance, the time (labelled "About N min
  walking", because the estimate assumes walking whichever activity is
  picked), the steps, the climb and the difficulty, with one line saying
  what decided it ("Hard because of 320 m of climb"). The label never said
  what it was based on. Saying it also shows a weakness the rule already
  had: the demo's half-mile, nearly flat city loop reads "Hard because one
  part is 17 % steep", which is probably elevation noise over a very short
  stretch, not a real slope. The rule is unchanged here; fixing it is a
  separate decision.

### Internal
- The difficulty of a profiled route is decided by one function,
  `RouteDifficulty.classify`, which `ElevationService.buildProfile` calls, so
  the thresholds exist once and the why-line comes from the same rule that
  picks the level. Thresholds and outcomes are unchanged
  (`RouteDifficultyTests`). The saved route's Start has the identifier
  `routes.detailStart`, and a smoke test checks its frame is on the first
  screen at both sizes before any swipe.

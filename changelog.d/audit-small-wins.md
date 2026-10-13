### Fixed
- US walkers now see miles in four places that were fixed to kilometres: the
  Fastest Pace personal record, the indoor walk's pace tile, the elevation
  chart's distance axis, and the milestone markers on the navigation map
  (now one per mile, matching the spoken cues). The release is US and Canada
  only, so a per-km pace beside miles everywhere else read as a bug. Both
  pace strings use the app's existing pace formatter, so they read `9:39/mi`
  like every other pace instead of `6'00"/km`. Elevation stays in metres.

### Internal
- Deleted code nothing called, found by the 2026-10-12 audit and re-checked
  with `git grep -w` across the app, widget and both test targets:
  `RouteMapView` (a near-copy of the live navigation map, so a fix could land
  in the wrong one), `RouteFeedbackStore` and its three types (holding the
  repo's only TODO), five TipKit tips that no view ever showed plus the
  `Tips.configure` call that served only them, four sheet wrappers kept "so
  existing callers compile" after their callers had gone (`BadgesView`,
  `ChallengesView`, `AchievementFeedView`, `GaitMetricDetailSheet`), the
  `RouteFinderView` wrapper, `POIEmojiLoader` and `CornerFoldShape`. About
  450 lines that every session read and reasoned about.
- `CLAUDE.md` gave about 164 raw `.font(.system(size:))` sites; there are 27,
  so the migration is nearly done rather than barely started.
- The critic now checks every PR for a Restore button or `AppStore.sync`
  offered for consumable tips, the reason 1.14 was rejected under 3.1.1.

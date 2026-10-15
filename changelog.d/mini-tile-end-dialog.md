### Fixed
- On iOS 26, End on the minimised walk tile now asks to save or discard the
  walk. Before, it did nothing. The question was attached inside the tile, which
  sits in the tab bar's bottom accessory, and iOS 26.5 never shows a dialog
  from there (iOS 27 does). It now comes from the app's root, so it appears on
  both. Found by the `testMiniTileSaveAndEndShowsTheSummary` smoke test, which
  failed on every CI run (iOS 26.5) and passed locally (iOS 27).

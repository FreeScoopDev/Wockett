### Fixed
- At the largest text sizes the Health and Home screens no longer break. The
  Home step ring showed "0..." instead of "0%", the Health weekly strip wrapped
  its dates ("1" over "0") and cut weekdays to "T...", the Sleep, Readiness and
  Active cal labels were cut off, and the month calendar's cells overlapped each
  other. These screens use fixed-size layouts, so their text now stops growing at
  the largest ordinary size (a new `wktDense` font) instead of overflowing.
- Future days in the month calendar are easier to read: their dates and goal
  labels were drawn at half strength, which is faint enough to be unreadable.

### Changed
- Settings has a large title like Health and Community, so the heading no longer
  changes size when you move between tabs.
- Cancel on the Add Walk Reminder sheet is grey like Cancel on every other sheet
  (it was the only green one).

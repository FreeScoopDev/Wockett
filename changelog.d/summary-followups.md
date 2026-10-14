### Changed
- Tapping an activity in a calendar day now opens its full summary, the same
  screen Activity History opens, so the day view is no longer a dead end.

### Fixed
- Rides no longer show a step count on the live ride screen or in the day,
  Your Progress and pet sheets, and the Your Progress 7-day steps total leaves
  rides out. A ride's "steps" were only its distance divided by a walking
  stride (a 14 km ride read as 18,000 steps); the summary stopped showing them
  in the last change, and these screens now follow the same rule.

### Internal
- The Community hub badge tests use a fresh UserDefaults suite. Badges read
  counters such as `wkt_manualEntries_count` from defaults, so leftover
  simulator state could change which badges counted and fail the suite.

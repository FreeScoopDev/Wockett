### Changed
- Settings and the screens it opens (Add Walk Reminder, Support Wockett and
  Trail Regions) now use the design the rest of the app moved to: the shared
  section headings, type sizes and status chip, and the same "pick one"
  controls for the step data source and a reminder's repeat.
- A weekly reminder's day is picked from chips that wrap onto two lines
  instead of seven squeezed segments.

### Fixed
- "Break prompt after N min" sat outside every section, so it floated between
  Tracking and Notifications with no heading. It is now under Tracking.
- In light mode, Add Walk Reminder's time picker was forced dark, a dark pill
  on a light sheet.

### Internal
- New shared piece: `WktListHeader`, a `WktSectionHeader` in a system List's
  section header slot.

### Changed
- Settings and the screens it opens (Add Walk Reminder, Support Wockett and
  Trail Regions) now use the design the rest of the app moved to: the shared
  section headings, type sizes and status chip, and the same "pick one"
  controls for the step data source and a reminder's repeat.
- A weekly reminder's day is picked from chips that wrap onto two lines
  instead of seven squeezed segments.
- The step goal editor (Settings → Tracking → Daily step goal, restored in
  #122) uses the same design: the shared picker for steps or distance, preset
  chips that wrap, and the weekly schedule and tags on the shared cards.

### Fixed
- "Break prompt after N min" sat outside every section, so it floated between
  Tracking and Notifications with no heading. It is now under Tracking.
- In light mode, Add Walk Reminder's time picker was forced dark, a dark pill
  on a light sheet.
- Two of the goal editor's preset chips had the wrong label: 5,000 steps read
  "5.5K" and 12,500 read "12K". They read "5K" and "12.5K".

### Internal
- New shared piece: `WktListHeader`, a `WktSectionHeader` in a system List's
  section header slot.

### Changed
- Home now opens on **Start an activity**, with **Recent activity** under it
  and the step goal card below both. A runner or a cyclist opened the app on a
  walking goal and had to scroll past it to start, and a saved activity could
  only be reached through Health → Activity History. The step card keeps
  everything it showed (ring, distance to go, crew, streak, pinned badges);
  it has only moved.
- Recent activity lists the three newest saved activities, worded exactly as
  Activity History words them, and each opens the same summary History opens.
  "All activities" opens History. With nothing saved the section is not shown
  at all, rather than an empty card pushing the rest down.

### Internal
- Activity History's row text and layout are now `ActivityRowText` and
  `ActivityRowContent`, shared with Home, so the two lists cannot describe
  one walk differently. `WktSection` takes an optional `actionIdentifier` for
  its link. The Recent card is rebuilt when its rows change: updated in
  place, its accessibility tree kept a newly logged walk below the one it
  sits above, so VoiceOver read them out of order.

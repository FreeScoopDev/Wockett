### Changed
- The Routes tab and everything it opens now use the design Home, Community,
  Health and the walk session moved to: the route search and results panels,
  route cards, weather and elevation, the Trails list, trail detail and the
  way to a trail, Nearby places and place search, My Routes and a saved
  route's detail, the route builder, sharing a route, and a route's history.
- Routes | Trails, Walk | Run | Ride and the trail filters use the same
  "pick one" controls as Home's activity picker.
- Starting a saved route is the green primary button, whatever the activity.
  It used to take the activity's colour, which is now kept for icons.
- Trail tags (dog rules, surface, bikes, loop) are the shared status chips and
  wrap onto a second line instead of running off the card.
- A difficulty of Moderate shows in the app's amber instead of system yellow,
  which was too faint to read on a light card.

### Fixed
- A route's history said "No Runs Yet" for every route, walking or cycling.
  It now names the route's own activity.
- In dark mode, the Save Route sheet showed its title in dark text on a dark
  background.
- The place list's "& Back" button now reads "There & Back", so it makes sense
  on its own, including to VoiceOver.

### Internal
- New shared pieces: `WktSegmentedPicker`, `WktChoiceChip`, `WktFlowRow` (wraps
  chips) and `WktIconStatTile`, which the walk summary, the indoor summary and
  Share Route now all use. `WktSymbol` gains `.hiking` and `.mountain`; route
  difficulty no longer names SF Symbols itself.

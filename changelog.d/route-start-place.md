### Added
- With location off or restricted, Routes offers **Choose a starting place**:
  search for an address, a park or a station, and Find Routes, Try nearby
  loops, Search a place and Nearby places all plan from there. Until now the
  only thing that worked without a location was tapping out a route by hand,
  and the route builder opened on a view of the whole continent. The panel
  says "Starting from <place>" in full, with Change, and Use my location once
  location is back on. Weather and the map follow the chosen place, and the
  map no longer frames routes together with a blue dot that may be far away.
  Plan on the map now opens the builder around the chosen place, and is a
  text link rather than a button in Routes and Trails: at the largest text
  sizes a third button left no room for the new one's title. The place is
  kept until the app quits, and never stands in for where you are: Community
  "near you" and trail directions still use your own location only. Recording
  a walk with location off is unchanged. Trails follows in a separate change.

### Internal
- `-WKTUITest -WKTLocationOff -WKTChosenStart` (debug builds only) starts with
  "Test Place" chosen, so a UI test can reach the chosen-place panel.

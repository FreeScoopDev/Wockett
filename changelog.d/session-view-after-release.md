### Fixed
- Tapping Done on a walk's summary could close the app (seen once on
  2026-10-12, after "Save as Custom Route" on a free walk with a pet in the
  crew). The walk screen read its walk and route from the store with a
  force-unwrap, on the belief that its `body` always checked the store
  first. SwiftUI can update one row of a list on its own, without running
  `body` again: a crew-row pet button was updated after Done had cleared the
  store, read the route that was no longer there, and trapped. The walk is
  saved before the summary appears, so the crash lost the app, not the walk.
  The screen now gets the walk and route as values, handed in only while
  both exist, so there is no unwrap left to fail.

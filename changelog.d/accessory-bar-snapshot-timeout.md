### Fixed
- Wockett no longer asks the location service a blocking question on the main
  thread, where it could leave the app on a blank screen at launch. Three places
  read the location-permission status directly: the route manager as the app
  started, Home's "GPS READY" label on every redraw, and Home's weather tile.
  Each read waits for iOS's location service to answer, and nothing can be drawn
  while it waits. On 2026-09-28 a stack sample caught a Wockett launch on the
  simulator stuck in the route manager's read for more than 15 s, the same
  blank, never-idle launch that made `testAccessoryBar` fail with "Timed out
  while evaluating UI query". All three now use the status CoreLocation
  delivers to the delegate, which does not block. The test failure is rare
  and did not reproduce in 10 runs either side of the change, so this removes
  a known cause without proving it was the only one.

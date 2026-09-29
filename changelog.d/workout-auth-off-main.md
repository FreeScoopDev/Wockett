### Fixed
- Starting a walk no longer freezes the walk screen while Wockett checks
  whether it may save the workout to Health. That check waits for iOS's Health
  service to answer, and it ran on the main thread, so nothing on screen could
  move until the answer came. On 2026-09-28 a stack sample of a UI test caught
  the main thread waiting there for about 100 s right after Walk was tapped,
  which is why `testAccessoryBar` sometimes stalled or timed out after
  starting a session. The check now runs off the main thread, and a unit test
  fails if it moves back.

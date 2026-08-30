# Unit tests: walk-session and snapshot-restore logic

## Why

The five existing test suites cover stores and anti-cheat, but the most
bug-prone logic in the app has zero tests: `NavigationSessionManager`'s
pause/elapsed math and snapshot restore, and `ActiveWalkSnapshot`'s
encode/decode. Both of this week's real bugs (the `Text(timerInterval:)`
`countsDown` default, the `isStarted` bootstrap flaw) were pure-logic errors
of exactly the kind unit tests catch without a device. These tests all run
in the existing `WockettTests` target, so CI picks them up automatically.

## 1. Small refactor to make restore math testable

In `PoCSquat/Services/Routes/NavigationSession.swift`, the gap-folding
computation inside `restore(from:)` is currently inline:

```swift
let referenceDate = snapshot.isPaused ? (snapshot.pauseStartDate ?? snapshot.checkpointDate) : snapshot.checkpointDate
pausedDuration = snapshot.pausedDuration + Date().timeIntervalSince(referenceDate)
```

Extract it into a pure static helper on `NavigationSessionManager` (same
logic, no behavior change), and have `restore(from:)` call it with `Date()`:

```swift
    /// Pure helper: how much pausedDuration a restored session should carry —
    /// the snapshot's completed pauses plus the entire dead-time gap between
    /// the reference point (pause start if the app died while paused,
    /// otherwise the checkpoint) and `now`. Kept static and pure so it's
    /// directly unit-testable.
    static func restoredPausedDuration(for snapshot: ActiveWalkSnapshot, now: Date) -> TimeInterval {
        let referenceDate = snapshot.isPaused
            ? (snapshot.pauseStartDate ?? snapshot.checkpointDate)
            : snapshot.checkpointDate
        return snapshot.pausedDuration + now.timeIntervalSince(referenceDate)
    }
```

In `restore(from:)` replace the two lines above with:

```swift
pausedDuration = Self.restoredPausedDuration(for: snapshot, now: Date())
```

## 2. New file: `WockettTests/SnapshotRestoreTests.swift`

Cover, adapting freely to the actual API where my sketches don't compile:

1. **Snapshot Codable round-trip** — build an `ActiveWalkSnapshot` with
   non-default values everywhere (real waypoints, `pausedDuration: 90`,
   `isPaused: true`, `pauseStartDate` set, `currentWaypointIndex: 3`,
   `currentLap: 2`, `triggeredCheckpoints: [1, 3]`, two split times,
   `liveSteps: 4200`), encode with `JSONEncoder`, decode, and assert every
   field survives.

2. **`RouteData` ↔ `NavigableRoute` round-trip** — `RouteData(route)` then
   `.navigableRoute` preserves name, waypoint coordinates, lapCount, isLoop,
   totalDistance, both route flags, activityMode, and customRouteId.

3. **Unknown activityMode falls back to `.walking`** — decode a snapshot
   whose route `activityMode` string is `"hoverboard"`; `navigableRoute`
   should come back `.walking`, not crash.

4. **`ActiveWalkSnapshotStore` save/load/clear** — save a snapshot, assert
   `hasPending` is true and `load()` returns matching values; `clear()`,
   assert `hasPending` false and `load()` nil. Call
   `ActiveWalkSnapshotStore.clear()` in both `setUp` and `tearDown` so tests
   never leak state into each other (or into the host app).

5. **`restoredPausedDuration` — died while actively walking**: snapshot with
   `pausedDuration: 60`, `isPaused: false`, `checkpointDate` 300s before
   `now` → expect `360` (±0.001).

6. **`restoredPausedDuration` — died while paused**: `pausedDuration: 60`,
   `isPaused: true`, `pauseStartDate` 500s before `now`, `checkpointDate`
   400s before `now` → expect `560` (gap counts from pause start, not the
   checkpoint).

7. **`restoredPausedDuration` — paused but `pauseStartDate` nil** (defensive
   path): falls back to `checkpointDate` → with the values from case 6 minus
   the pauseStartDate, expect `460`.

8. **Elapsed honesty invariant**: for case 5, compute
   `now.timeIntervalSince(startTime) - restoredPausedDuration(...)` with a
   `startTime` 1000s before the checkpoint and assert it equals the elapsed
   time the walk had *at the checkpoint* (1000 - 60 = 940s, ±0.001) — i.e. a
   restored timer never jumps by the dead time.

## 3. New file: `WockettTests/NavigationSessionTests.swift`

1. **Empty-waypoint route never has a next waypoint** — construct a
   `NavigationSessionManager` with a free-walk-style route (`waypoints: []`,
   `totalDistance: 0`) and assert `nextWaypoint` is nil. Do NOT call
   `start()` in any of these tests — construction alone must not start
   location/pedometer/timers.

2. **`completedSession` uses trackPoints for free walks** — same manager;
   append two known coordinates to `trackPoints`; assert
   `completedSession.waypoints` matches those coordinates.

3. **`completedSession` uses route waypoints for guided walks** — manager
   with a two-waypoint route and different coordinates in `trackPoints`;
   assert `completedSession.waypoints` matches the ROUTE's waypoints, not
   the breadcrumbs.

4. **`completedSession` carries the route's activity mode** — a `.cycling`
   route produces `activityType == ActivityMode.cycling.rawValue`.

If any of these need internal state that isn't reachable from the test
target, prefer widening access to `internal` (the default) over `private`
for just those members rather than contorting the tests — note in the
commit message if you do.

## Build & verify

Run the full `WockettTests` suite (`Cmd-U` / `xcodebuild test`). All new
tests pass, all existing tests still pass. Commit with a clear message. Do
not push — Joe pushes himself.

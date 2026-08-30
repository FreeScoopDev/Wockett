# Stale walk salvage: save expired checkpoints to history instead of deleting them

## Why

Joe's call: a walk that dies with the app and is never resumed should be
**saved, not erased** — the user can delete it from Walk History if they
don't want it. Today, a checkpoint older than 4 hours is deleted by
`load()` like the walk never happened.

Second fix in the same round: the checkpoint has never carried the GPS
breadcrumb trail (`trackPoints` was added to `NavigationSessionManager`
after the snapshot format was designed). So a resumed Free Walk currently
loses its polyline up to the checkpoint, and any salvaged free walk would
have a blank history map. One optional field fixes both.

Design decision: **the store stops silently deleting anything.** Deletion
becomes an explicit decision by `ActiveWalkStore` (salvage, decline, or
stop) — so no innocent `load()`/`hasPending` call can destroy a walk
before the salvage logic has seen it.

## 1. `PoCSquat/Services/Walk/ActiveWalkSnapshot.swift`

### Add breadcrumbs to the snapshot (backward-compatible)

Add to `ActiveWalkSnapshot`'s stored properties:

```swift
    let trackPoints: [WaypointCoord]?   // GPS breadcrumbs; optional so pre-existing checkpoint files still decode
```

### Store: stale means "not resumable," never "delete"

In `ActiveWalkSnapshotStore`, replace the stale branch of `load()` — it
must **no longer call `clear()`**:

```swift
    /// Returns the checkpoint only if it's fresh enough to offer for resume.
    /// A stale file is left in place — ActiveWalkStore decides its fate
    /// (salvage to history), never this store.
    static func load() -> ActiveWalkSnapshot? {
        guard let snapshot = loadAnyAge(),
              Date().timeIntervalSince(snapshot.checkpointDate) <= maxSnapshotAge
        else { return nil }
        return snapshot
    }

    /// Raw read with no age check — for the salvage path.
    static func loadAnyAge() -> ActiveWalkSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)
    }
```

`hasPending` stays `load() != nil` (fresh-only), `save`/`clear`/
`maxSnapshotAge` unchanged.

### Pure helper for the salvaged elapsed time

Add alongside `maxSnapshotAge` (mirrors the testable-helper pattern used
for `restoredPausedDuration`):

```swift
    /// Elapsed time a salvaged walk should record: the walk effectively
    /// ended at the last checkpoint (or at pause start, if it died while
    /// paused) — dead time after that never counts.
    static func salvagedElapsed(for snapshot: ActiveWalkSnapshot) -> TimeInterval {
        let endDate = snapshot.isPaused
            ? (snapshot.pauseStartDate ?? snapshot.checkpointDate)
            : snapshot.checkpointDate
        return max(0, endDate.timeIntervalSince(snapshot.startTime) - snapshot.pausedDuration)
    }
```

## 2. `PoCSquat/Services/Routes/NavigationSession.swift`

### Write breadcrumbs into every checkpoint (thinned)

In `writeSnapshot()`, build a thinned copy and pass it to the snapshot:

```swift
        // Thin the breadcrumb trail so very long walks keep the checkpoint
        // file small — cap ~2000 points, evenly strided.
        let maxPoints = 2000
        let thinned: [CLLocationCoordinate2D]
        if trackPoints.count > maxPoints {
            let stride = Double(trackPoints.count) / Double(maxPoints)
            thinned = (0..<maxPoints).map { trackPoints[Int(Double($0) * stride)] }
        } else {
            thinned = trackPoints
        }
```

and add to the `ActiveWalkSnapshot(...)` construction:

```swift
            trackPoints: thinned.map { WaypointCoord($0) },
```

### Restore breadcrumbs on resume

In `restore(from:)`, alongside the other state restoration:

```swift
        trackPoints = (snapshot.trackPoints ?? []).map { $0.clCoordinate }
```

## 3. `PoCSquat/Services/Walk/ActiveWalkStore.swift`

New method near `restoreIfNeeded()`:

```swift
    /// If a checkpoint exists but is too old to offer for resume, convert
    /// it into a normal Walk History entry (the user can delete it there)
    /// and clear the checkpoint. Silent — no PR fanfare, no completion UI.
    func salvageStaleWalkIfNeeded() {
        guard session == nil,
              let historyStore,
              let snapshot = ActiveWalkSnapshotStore.loadAnyAge(),
              Date().timeIntervalSince(snapshot.checkpointDate) > ActiveWalkSnapshotStore.maxSnapshotAge
        else { return }
        defer { ActiveWalkSnapshotStore.clear() }

        // Junk guard — same 50m threshold the Free Walk summary auto-save uses.
        guard snapshot.totalDistanceCovered >= 50 else { return }

        let route = snapshot.route.navigableRoute
        let path = route.waypoints.isEmpty
            ? (snapshot.trackPoints ?? [])
            : snapshot.route.waypoints
        let salvaged = WalkSession(
            id: UUID(),
            routeName: snapshot.route.name,
            date: snapshot.startTime,
            elapsedTime: ActiveWalkSnapshotStore.salvagedElapsed(for: snapshot),
            totalDistance: snapshot.totalDistanceCovered,
            waypoints: path,
            lapCount: snapshot.route.lapCount,
            isLoop: snapshot.route.isLoop,
            activityType: snapshot.route.activityMode,
            steps: snapshot.liveSteps,
            customRouteId: snapshot.route.customRouteId
        )
        historyStore.add(salvaged)
    }
```

(Use the actual `WalkHistoryStore.add` / `WalkSession` init as they exist —
the parameter list above matches the current initializer's required
arguments plus the relevant defaults; everything not listed keeps its
default. `snapshot.route.activityMode` is already the raw string. No
HealthKit write for salvaged walks — deliberately out of scope this round.)

## 4. `PoCSquat/Views/Walk/StepCounterView.swift`

In `handleAppear()`, between the existing `walkStore.configure(...)` line
and the `hasRestorableWalk` check, add:

```swift
        walkStore.salvageStaleWalkIfNeeded()
```

Order matters: configure (so historyStore is set) → salvage stale →
offer resume for fresh.

## 5. Tests — `WockettTests/SnapshotRestoreTests.swift`

**Update the two expiry tests** to the new contract:

- `store_freshSnapshot_survives` — unchanged behavior, should still pass.
- `store_staleSnapshot_selfDeletes` → rename to
  `store_staleSnapshot_notResumableButPreserved`: save a 5-hours-old
  snapshot; assert `load()` is nil and `hasPending` is false, **but**
  `loadAnyAge()` still returns it (file NOT deleted). Add an explicit
  `ActiveWalkSnapshotStore.clear()` at the end (or `defer`) since nothing
  auto-deletes anymore.

**New tests:**

1. `salvagedElapsed_activeDeath` — startTime 1000s before checkpoint,
   pausedDuration 60, not paused → 940 (±0.001).
2. `salvagedElapsed_pausedDeath` — pauseStartDate 200s before checkpoint,
   startTime 1000s before checkpoint, pausedDuration 60 → 740 (elapsed
   ends at pause start).
3. `snapshot_trackPointsRoundTrip` — encode/decode a snapshot with 3 known
   trackPoints; coordinates survive. Also decode a JSON with **no**
   `trackPoints` key (delete it from a serialized dict, like the
   `hoverboard` test does) → decodes fine with nil.
4. If `ActiveWalkStore` + `WalkHistoryStore` are constructible in the test
   target, add an end-to-end salvage test: stale snapshot with distance
   1234.5 → after `salvageStaleWalkIfNeeded()`, history contains one
   session with that distance, honest elapsed, `date == startTime`, and
   the checkpoint file is gone; plus a sub-50m stale snapshot → nothing
   added, file still cleared. If the stores can't be cleanly constructed
   in tests, skip these two and say so in the commit message — the pure
   helpers above still cover the math.

## Build & verify

1. Full test suite passes (updated + new tests, no regressions).
2. Manual: start a walk, move >50m, force-quit. Relaunch within the hour →
   resume prompt appears and (for a Free Walk) **the polyline now includes
   the pre-death path** after resuming.
3. Manual (simulated stale): temporarily change `maxSnapshotAge` to 60
   seconds, force-quit a walk, wait a minute, relaunch → no resume prompt,
   walk appears in Walk History with sane distance/time/date, no
   celebration UI. Revert `maxSnapshotAge` to 4 hours before committing.
4. Commit with a clear message. Do not push — Joe pushes himself.

# Round A: phantom Live Activities + abandoned HealthKit workouts

Two ship-blocking bugs from Joe's QA pass. Both root-caused; fixes below.

## Bug 1 — Phantom Live Activities that End Walk can't clear

`WalkLiveActivityManager` only ever talks to its in-memory
`private var activity` reference. After a force-quit that reference is gone
while the system still displays the Live Activity, so:
- `end()` no-ops forever → the End Walk button can't clear orphans
- the next walk's `start()` requests a NEW activity next to the orphans →
  multiple phantoms stack up

### `PoCSquat/Services/Walk/WalkLiveActivityManager.swift`

1. Add a reaper that works from the SYSTEM's list, not our reference:

```swift
    /// Ends every Wockett Live Activity the system knows about — including
    /// orphans left behind by a force-quit, which our in-memory `activity`
    /// reference can't reach.
    func endAllActivities() async {
        for orphan in Activity<WalkActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }
```

2. In `end(distanceCovered:elapsedSeconds:pausedDuration:)`: after the
   existing graceful end of `activity`, ALSO sweep the system list so any
   strays go too (skip the one just ended if it's still listed — ending an
   already-ended activity is harmless, so a simple loop over
   `Activity<WalkActivityAttributes>.activities` ending each with
   `.immediate` after the graceful end is fine). Replace the
   `guard let activity else { return }` with: if `activity` is nil, still
   run the sweep before returning.

3. In `start(...)`: before requesting the new activity (and before the
   `guard activity == nil` early-return — reorder as needed), end any
   activities already in `Activity<WalkActivityAttributes>.activities`.
   Our reference being nil while the system list is non-empty is exactly
   the orphan case.

### `PoCSquat/Intents/WalkLiveActivityIntents.swift`

In `EndWalkLiveActivityIntent.perform()`, handle the no-session case —
today `saveAndEndActiveSession()` finds no session and the button appears
dead. After the existing call, add:

```swift
        if ActiveWalkStore.shared.session == nil {
            await WalkLiveActivityManager.shared.endAllActivities()
        }
```

(Keep it inside the existing `#if !WOCKET_WIDGET` block.)

### Launch-time reconciliation — `PoCSquat/Views/Walk/StepCounterView.swift`

In `handleAppear()`, right after the `walkStore.salvageStaleWalkIfNeeded()`
call (or after `configure(...)` if the salvage round hasn't merged yet):

```swift
        if walkStore.session == nil {
            Task { await WalkLiveActivityManager.shared.endAllActivities() }
        }
```

A restorable walk doesn't change this: the orphaned activity shows stale
data from a dead process, so reap it — and start a fresh one on restore:

### Fresh Live Activity on restore — `PoCSquat/Services/Walk/ActiveWalkStore.swift`

At the end of `restoreIfNeeded()`, just before `return route`, start a new
activity for the reconstructed session and push one immediate update so it
shows real numbers:

```swift
        WalkLiveActivityManager.shared.start(
            routeName: route.name,
            totalDistanceMeters: route.totalDistance,
            activityMode: route.activityMode.rawValue,
            startDate: mgr.startTime
        )
        let dist = mgr.totalDistanceCovered
        let elapsed = Int(mgr.elapsedTime)
        let paused = mgr.totalPausedDuration
        Task { await WalkLiveActivityManager.shared.update(
            distanceCovered: dist,
            elapsedSeconds: elapsed,
            isPaused: false,
            paceSecsPerKm: nil,
            pausedDuration: paused,
            pauseTime: nil
        )}
```

(Since `start()` now reaps strays first, the ordering start-after-reap is
handled inside the manager; the launch-time reap above and this start can
coexist safely.)

## Bug 2 — HealthKit workouts abandoned on two end paths

`ActiveWalkStore.saveAndEndActiveSession()` — the Live Activity End Walk
button AND the mini tile stop — never calls `finishWorkoutSession()`, so
the HKWorkoutBuilder is abandoned and no workout reaches Apple Health.
(Joe's Bike logged because Free Walk's Finish button path does call it;
his Run, ended from the Live Activity, didn't.)

### `PoCSquat/Services/Walk/ActiveWalkStore.swift`

In `saveAndEndActiveSession()`, capture the session before `endSession()`
clears it and finish the workout alongside the existing Live Activity end:

```swift
        let capturedSession = session
        // ...existing stop/endSession/notification code unchanged...
        Task {
            await WalkLiveActivityManager.shared.end(distanceCovered: dist, elapsedSeconds: elapsed, pausedDuration: pausedDuration)
            await capturedSession?.finishWorkoutSession()
        }
```

(Fold the existing `Task { ...end... }` and this together into one Task —
don't leave two.)

**Idempotence check:** open `finishWorkoutSession()` in
`NavigationSession.swift` and confirm it nils `workoutWriter` (or
otherwise guards) so a path that ends via this method AND later hits
another `finishWorkoutSession()` call (e.g. Free Walk summary save) can't
double-finish. If it doesn't guard, add `guard let writer = workoutWriter
else { return }; workoutWriter = nil` semantics at the top.

Also audit the one other manual-end path for the same hole: whatever the
map's "End Walk?" dialog buttons call — if any of them stop the session
without `finishWorkoutSession()`, give them the same treatment.

## Build & verify

1. Unit suite still green.
2. **Phantom reproduction:** start a walk, force-quit, relaunch, discard
   the resume prompt → the stale Live Activity disappears at launch. Start
   and force-quit twice in a row → never more than one activity visible.
3. **End Walk on an orphan:** with a phantom present (force-quit, don't
   relaunch), tap End Walk on the lock screen → activity clears (app
   launches in background to run the intent).
4. **Restore:** force-quit mid-walk, relaunch, Resume → exactly ONE Live
   Activity, showing the restored walk's real distance/elapsed.
5. **HealthKit:** end a run via the Live Activity End Walk button, then
   end another via the mini tile → BOTH appear in Apple Health → Workouts
   with correct type and duration. Repeat once with Free Walk Finish to
   confirm no double-entry regression.
6. Commit with a clear message. Do not push — Joe pushes himself.

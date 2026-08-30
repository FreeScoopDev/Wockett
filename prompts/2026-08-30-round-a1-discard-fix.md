# Round A.1 (small follow-up): Discard Walk must not save to Apple Health

## Why

Round A's HealthKit fix applied `finishWorkoutSession()` to all of
`WalkNavigationView`'s end-dialog buttons — including **Discard Walk**.
Discard means "lose this data on purpose," so it must NOT write a workout
to Apple Health. It should explicitly discard the builder instead.
(The mini tile's Discard doesn't finish the workout, so it has no Health
write — but it abandons the builder; give it the same explicit discard.)

## Changes

### 1. `PoCSquat/Services/Walk/HealthWorkoutWriter.swift`

Add next to `finish(...)`:

```swift
    // Throws away the in-progress workout without saving anything to Health.
    func discard() {
        builder?.discardWorkout()
        builder = nil
        routeBuilder = nil
    }
```

### 2. `PoCSquat/Services/Routes/NavigationSession.swift`

Add next to `finishWorkoutSession()` (same idempotence pattern):

```swift
    func discardWorkoutSession() {
        guard let writer = workoutWriter else { return }
        workoutWriter = nil
        writer.discard()
    }
```

### 3. `PoCSquat/Views/Walk/WalkNavigationView.swift`

In the **"Discard Walk"** button only (line ~152): replace
`await capturedSession.finishWorkoutSession()` with
`capturedSession.discardWorkoutSession()` (it's synchronous — it can move
out of the Task or stay in it, either is fine). The three save buttons
keep `finishWorkoutSession()` exactly as Round A left them.

### 4. `PoCSquat/Views/Walk/ActiveMiniTile.swift`

In its "Discard Walk" button, add `session.discardWorkoutSession()` right
before `session.stop()` — explicit discard instead of silently abandoning
the builder.

## Verify

1. Start a walk, move a bit, use the map dialog's **Discard Walk** → no
   new workout in Apple Health → Workouts.
2. Same via the mini tile's Discard.
3. Save & End Walk (either surface) → workout DOES appear (Round A
   behavior unchanged).
4. Full test suite green. Commit clearly. Do not push.

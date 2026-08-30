# Walk-resume checkpoint: 4-hour expiry

## Why

The privacy policy promises walk-resume data is "temporarily saved to your
device for up to 4 hours, then automatically deleted" — but the checkpoint
system we shipped has no expiry at all. This round makes the policy true,
and it's better UX anyway: a "Resume Your Walk?" prompt from three days ago
is confusing, and folding days of dead time into pausedDuration produces a
meaningless restored session.

## Changes — `PoCSquat/Services/Walk/ActiveWalkSnapshot.swift`

All in `ActiveWalkSnapshotStore`, so every consumer (`hasPending`,
`load()`, and therefore `ActiveWalkStore.hasRestorableWalk` /
`restoreIfNeeded()`) gets the expiry for free with no other call-site
changes.

Add a max age and make `load()` self-cleaning:

```swift
enum ActiveWalkSnapshotStore {
    /// Checkpoints older than this are considered stale and are deleted on
    /// read instead of offered for resume. Matches the privacy policy's
    /// "saved for up to 4 hours, then automatically deleted."
    static let maxSnapshotAge: TimeInterval = 4 * 60 * 60
```

Replace `load()` with:

```swift
    static func load() -> ActiveWalkSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ActiveWalkSnapshot.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(snapshot.checkpointDate) <= maxSnapshotAge else {
            clear()
            return nil
        }
        return snapshot
    }
```

Replace `hasPending` (currently a bare file-exists check) so a stale file
doesn't trigger the resume prompt only for `load()` to then return nil:

```swift
    static var hasPending: Bool {
        load() != nil
    }
```

(`hasPending` is only read on app-launch/appear paths, so decoding the
small JSON file there is fine.)

## Tests — `WockettTests/SnapshotRestoreTests.swift`

Add two tests next to the existing store tests (reuse the `makeSnapshot`
helper, which already accepts `checkpointDate`):

1. **Fresh snapshot survives:** save a snapshot with `checkpointDate` 1
   hour ago → `hasPending` is true and `load()` returns it.
2. **Stale snapshot self-deletes:** save a snapshot with `checkpointDate`
   5 hours ago → `load()` returns nil, `hasPending` is false, AND the file
   is gone afterward (a second raw `FileManager.default.fileExists` check
   on the store's path, or simply that a subsequent `hasPending` stays
   false without another `clear()`).

## Build & verify

Run the full test suite — the 2 new tests pass, all existing tests still
pass. Quick manual check: start a walk, force-quit, relaunch within the
hour → resume prompt still appears (no regression to the normal path).
Commit with a clear message. Do not push — Joe pushes himself.

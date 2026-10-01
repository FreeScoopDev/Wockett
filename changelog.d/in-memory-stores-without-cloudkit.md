### Fixed
- The in-memory SwiftData stores no longer try to sync with iCloud. A
  `ModelConfiguration` defaults to `cloudKitDatabase: .automatic`, so in any
  signed build the test stores in `SnapshotRestoreTests` and
  `CustomRouteStoreTests` got a CloudKit mirroring delegate. With no iCloud
  account on the simulator its setup failed, CoreData tore the store down
  mid-test, and the next save threw "No eligible connection available",
  crashing the test host and every test running beside it. That is why a local
  `scripts/test.sh` lost 2–7 tests a run while GitHub Actions, which builds
  unsigned, stayed green. The app's last-resort in-memory store in
  `AppModelContainer` had the same omission and now says `.none` as well,
  like the local store fixed on 2026-09-29.

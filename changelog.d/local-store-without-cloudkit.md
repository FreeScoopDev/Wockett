### Fixed
- The on-device fallback store really is on-device now. When the iCloud-synced
  store cannot open, Wockett falls back to a local one, but that fallback never
  said "no CloudKit", and SwiftData's default turns CloudKit sync on whenever
  the app has the iCloud entitlement. So the fallback still tried to sync, and
  so did every locally signed test run, which is meant to skip CloudKit
  entirely: on 2026-09-29, stack samples found CloudKit sync running in 4 of 5
  UI-test launches, where it could send the tests' demo walks to the
  simulator's iCloud account. The fallback now sets CloudKit off explicitly,
  and a unit test checks it.

### Internal
- Measured, and left alone: the Live Activity calls at walk start (about 20 ms
  of main-thread waiting per walk under heavy load) and creating a
  `CKContainer` (4 ms across five launches). Both are synchronous system calls
  on the main thread, like the permission reads fixed in #111 and #112, but
  far too short to freeze the app.

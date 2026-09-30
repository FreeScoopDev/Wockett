### Fixed
- Bookmarked places now sync through iCloud on App Store and TestFlight
  builds, and long walks and large custom routes keep syncing as they grow.
  iCloud's live schema had never been given the bookmark record type, or the
  overflow fields a walk's or route's GPS track moves into once it is too big
  for the record itself, so those records could not upload. The fields were
  added and deployed in CloudKit Console on 2026-09-29; no app update was
  needed.

### Internal
- `CLAUDE.md` records why that gap happened (Production only gets what a
  Debug build synced to Development before a deploy) and how to catch it:
  run the toolkit's `cloudkit-schema-check.sh` against a fresh Production
  export whenever a release adds or changes a SwiftData model.

### Added
- After a hike or a walk on a named trail, the summary may ask "Help the next
  walker": one-tap answers about dogs, stroller and wheelchair access, the
  surface, and whether you liked it. The map data states these facts on only
  6-15% of trails, and someone who has just walked one knows. Each answer is
  optional and sends only the trail, the question and the answer (no name, no
  free text, no location, not the walk) as a report only the Wockett team can
  read. It asks at most once per trail and once a week, never during a walk,
  never for a trail already answered, and never after "Don't ask again"
  (also a switch in Settings > Community). The first answer gets a thank-you.
  A walk on a trail restored after the app was closed mid-walk does not ask:
  the trail is held only in memory, so nothing new is stored on the walk or
  synced. Each report gets a random record name, so nobody can test from
  public ids whether someone reported on a trail.
- The Trail facts card has a "Walkers say" section below the map facts, with
  one line per answer the Wockett team has published once at least 3 walkers
  agree, such as "Dogs on leash (4 walkers)". It is kept apart from the map
  data with its own caption, cached for offline use and refreshed at most
  once a day. "How was it?" answers are collected but never shown.
- Settings > Community > Delete my community data shows your identifier, with
  a Copy button, and the removal email includes it on its own line: trail
  reports can't be deleted from the app (only the Wockett team can read
  them), and the staff dashboard finds them by that identifier.

### Changed
- "Trail suggestions" in the delete screen is now "trail nominations", the
  name the privacy policy will use, so "trail suggestions" can mean the later
  "suggest a missing trail" feature without a clash.

### Internal
- The answer vocabulary is mirrored from `docs/staff/walker-facts.js`, and a
  test compares the two. A Debug build checks that `TrailFactReport` already
  exists in the CloudKit container before its first save, so a test build
  can't create the type with CloudKit's default, world-readable grants.

### Added
- Wockett Staff has a Walker reports tab, ready for the app's "Help the next
  walker" card (a later release). Walkers who just finished a trail know what
  the map data rarely says (dogs, stroller, wheelchair, surface), but their
  answers can't be world-readable: grouped by creator they would list the
  trails one account walked. So each answer is a `TrailFactReport` only a
  moderator can read, the tab counts them per trail and fact (each walker
  once), and Joe publishes a `TrailFactSummary` only when at least 3 walkers
  gave the same answer and they are at least 2 in 3 of those who answered; a
  tie or split publishes nothing. A summary holds the trail, the fact, the
  answer, how many walkers gave it and when, never who, so "(3 walkers)"
  in the app always means three said so. Un-publish withdraws one. "How was it?" is counted but not
  published until Joe decides how to use it. Reports older than 12 months
  can be deleted from the tab, with a count and a confirm, and so can one
  walker's reports when they email asking: the privacy text will offer that,
  so the tab finds a person's reports by the identifier the app will show
  them, counts them, and deletes them on confirm. The facts and
  answers are written down once, in `docs/staff/walker-facts.js`, for the app
  to mirror. History records each publish, un-publish and deletion.

### Internal
- `cloudkit/schema.ckdb` gains `TrailFactReport` (create: any signed-in
  user; read and write: Moderator; its creator is QUERYABLE, so one
  person's reports can be found) and `TrailFactSummary` (read: everyone;
  create and write: Moderator). Not yet in CloudKit: they need importing to
  Development and deploying to Production before the app version that writes
  reports ships. A test reads the schema file and fails if a report becomes
  readable by anyone but a moderator.

### Fixed
- Wockett Staff no longer prints the word "null" under some lists (an empty
  queue's hint, the "showing the newest" note) when there was nothing to show.

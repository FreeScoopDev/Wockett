### Added
- Wockett Staff has a Walker reports tab, ready for the app's "Help the next
  walker" card (a later release). Walkers who just finished a trail know what
  the map data rarely says (dogs, stroller, wheelchair, surface), but their
  answers can't be world-readable: grouped by creator they would list the
  trails one account walked. So each answer is a `TrailFactReport` only a
  moderator can read, the tab counts them per trail and fact (each walker
  once), and Joe publishes a `TrailFactSummary` only when at least 3 walkers
  answered and at least 2/3 agree; a tie or split publishes nothing. A
  summary holds the trail, the fact, the answer, how many walkers and when,
  never who. Un-publish withdraws one. "How was it?" is counted but not
  published until Joe decides how to use it. Reports older than 12 months
  can be deleted from the tab, with a count and a confirm. The facts and
  answers are written down once, in `docs/staff/walker-facts.js`, for the app
  to mirror. History records each publish, un-publish and deletion.

### Internal
- `cloudkit/schema.ckdb` gains `TrailFactReport` (create: any signed-in
  user; read and write: Moderator) and `TrailFactSummary` (read: everyone;
  create and write: Moderator). Not yet in CloudKit: they need importing to
  Development and deploying to Production before the app version that writes
  reports ships. A test reads the schema file and fails if a report becomes
  readable by anyone but a moderator.

### Fixed
- Wockett Staff no longer prints the word "null" under some lists (an empty
  queue's hint, the "showing the newest" note) when there was nothing to show.

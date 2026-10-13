### Added
- Settings > Community > Delete my community data removes everything your
  iCloud account shared in Community in one go: shared routes, achievement
  posts, challenge entries, challenges only you are in, your likes and
  Wocketts, and your community name. It asks once, shows what it is
  deleting, and says plainly per kind what was deleted and what failed.
  Until now routes, posts, entries and challenges went one at a time, and
  your name and votes could only go by email (audit 2026-10-12, finding
  15). A challenge other people joined is not deleted, since that would
  take their progress: the Wockett team is asked to remove it, as with
  Delete on the challenge itself. Reports and trail suggestions you sent
  can't be deleted from the app (only the Wockett team can read them), so
  the screen says so and offers an email that carries the account ID a
  moderator needs. Your walks, pets and routes are not touched.
- Settings > Community > Blocked people lists everyone you blocked, with
  Unblock. There was no way to unblock before.

### Changed
- Blocks now sync through your private iCloud, so the people you blocked
  stay blocked after a reinstall and on your other devices. They lived only
  on the phone before. Blocks made on this phone move over on first launch.
  Two devices' lists are merged person by person, with the newer change
  winning, so a block made on one appears on the other and an unblock is not
  undone by an older block elsewhere.

### Internal
- `cloudkit/schema.ckdb`: new private type `CommunityBlockList` (one
  `entries` string), and `___createdBy` QUERYABLE on `SharedRoute`,
  `WocketAchievement`, `ChallengeEntry`, `Challenge` and `CommunityVote`,
  which the delete needs to find your records. Imported to Development;
  Production needs a deploy before 1.16. Until then the delete still removes
  what the phone remembers creating and reports the rest as not found.

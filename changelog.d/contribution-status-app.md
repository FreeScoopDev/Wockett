### Added
- My contributions (Settings > Community, and a button on the nomination
  thank-you): every trail you nominated from this device, the day you sent it,
  and Sent or Featured. Until now a nomination got "Thanks for the tip" and
  nothing ever came back, and people keep contributing when they can see it
  mattered. There is no "not chosen" status: a nomination that isn't featured
  stays Sent. The list is kept on this device and in its backups, not synced
  through iCloud, so it starts empty and a reinstall without a restore loses
  it (no new iCloud data). Pull to refresh; it also asks whenever it opens.
- When the Wockett team features a trail you nominated, the Trails list says
  so once ("Your nomination of Lake Loop was featured by the Wockett team").
  If the app finds out in the background first (the background refresh that
  already looks for untracked walks, so it can be hours late), one local
  notification says it as well; if it finds out while you are using it, the
  banner is the only announcement. Each nomination is announced once on the
  Trails list, and at most once by notification. No remote push: the phone asks, nobody tells it. It never asks for
  notification permission; quiet delivery counts, and with notifications off
  the banner still shows.

### Changed
- Each nomination now carries a random claim token, readable only by the
  Wockett team like the rest of the nomination. When a trail is featured the
  staff dashboard publishes a status named after a hash of that token, holding
  no account and no token, so only the phone that sent it can find its own.
- Nominations get a random record name instead of a hash of the trail and the
  account. Both of those are public, so anyone could work out the old name for
  someone else and learn from a refused save whether that account had
  nominated that trail. This device still sends each trail once; the staff
  dashboard keeps one nomination per person per trail.
- The nomination thank-you says what happens next: "If it is featured you will
  see it here, in My contributions."
- One nomination per trail is now kept by this device rather than by
  CloudKit. A second device can nominate the same trail again; only the newest
  nomination is told when it is featured for now (a staff dashboard change to
  tell every one is a follow-up).

### Internal
- The status vocabulary is mirrored from `docs/staff/contribution-status.js`
  and the status name from the dashboard's test vector; tests read both
  files. A Debug build checks that `ContributionStatus` exists in the CloudKit
  container before it saves a nomination with a claim token, so a test build
  can't add the field to Development before the schema is imported.
- Release: `TrailNomination.claimToken` and `ContributionStatus` must be
  deployed to CloudKit Production as a Console step before Start Build.
  Without the field, every nomination from a Release build is refused and the
  person sees the usual "check your connection" message (the log names the
  likely cause).

### Added
- My contributions (Settings > Community, and a button on the nomination
  thank-you): every trail you nominated from this iPhone, the day you sent it,
  and Sent or Featured. Until now a nomination got "Thanks for the tip" and
  nothing ever came back, and people keep contributing when they can see it
  mattered. There is no "not chosen" status: a nomination that isn't featured
  stays Sent. The list is kept on this iPhone only, so it starts empty, and a
  reinstall loses it (no new iCloud data). Pull to refresh; it also asks
  whenever it opens.
- When the Wockett team features a trail you nominated, the Trails list says
  so once ("Your nomination of Lake Loop is now Featured"), and one local
  notification says it too, from the background refresh that already looks
  for untracked walks, so it can be hours late. Each nomination is announced
  once. No remote push: the phone asks, nobody tells it. It never asks for
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
  nominated that trail. This iPhone still sends each trail once; the staff
  dashboard keeps one nomination per person per trail.
- The nomination thank-you says what happens next: "If it is featured you will
  see it here, in My contributions."

### Internal
- The status vocabulary is mirrored from `docs/staff/contribution-status.js`
  and the status name from the dashboard's test vector; tests read both
  files. A Debug build checks that `ContributionStatus` exists in the CloudKit
  container before it saves a nomination with a claim token, so a test build
  can't add the field to Development before the schema is imported.

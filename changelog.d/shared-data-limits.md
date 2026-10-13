### Fixed
- A shared route is only opened when it has no more points than the app
  ever publishes (12,000, the cap `SharedRouteTrim` applies when sharing),
  and any point that is not a real coordinate is dropped. Anyone with an
  iCloud account can write a public route record, so a crafted one with
  millions of points could otherwise slow or hang a walk that started it.
- Trail data credits and a map result's "Visit Website" open only `http`
  and `https` links. A tampered trail pack or map entry could otherwise make
  a tap start a call (`tel:`), a text (`sms:`) or open another app.
  (2026-10-12 security audit, finding 21.)

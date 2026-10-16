### Changed
- Wockett Staff counts each person once per reported item, keeping their
  first report, and at most two of a challenge owner's requests to delete per
  UTC day (the app allows one per local day, and a local day spans at most
  two UTC days, so a request the next morning, after a dismissal, still
  reopens the challenge). The app now names reports randomly, so a person
  reporting from a second device, or after a reinstall, leaves a second
  record that CloudKit used to refuse; without this, one account could
  inflate an item's count, or reopen an item it had already reported after a
  dismissal.

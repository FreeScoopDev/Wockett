### Changed
- Wockett Staff counts each person once per reported item (an owner's
  request to delete once per person per day), keeping their first report.
  The app now names reports randomly, so a person reporting from a second
  device, or after a reinstall, leaves a second record that CloudKit used to
  refuse; without this, one account could inflate an item's count, or reopen
  an item it had already reported after a dismissal. Erasing a person's
  reports still finds every one.

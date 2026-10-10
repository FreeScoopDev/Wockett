### Changed
- Reporting a post, shared route or challenge now asks why (spam, offensive,
  unsafe, personal info or something else, with an optional note) and sends
  the report straight to the Wockett team as a private CloudKit record, instead
  of opening an email the reporter had to send. Reports used to depend on the
  reporter finishing that email, and each one had to be found by hand in
  CloudKit Console; as records, the new staff dashboard can list them by item
  and act on them. Only a Moderator can read a report, and it carries nothing
  about the reporter beyond CloudKit's own creator reference. If the report
  can't be saved (signed out of iCloud, offline, any CloudKit error), the sheet
  offers the old email, prefilled with the reason and note, so a report still
  always reaches us. One person can report an item once: a second report, from
  any of their devices, is recognised as already sent.

### Internal
- `cloudkit/schema.ckdb` is the public database schema as CloudKit exports it,
  now kept in the repo. It adds the `Moderator` role, the `CommunityReport` and
  `ModerationAction` record types, Moderator read/write on the community types
  (so a moderator can remove anyone's item), and the creation-time and
  record-ID indexes the dashboard sorts and looks up by. Imported into
  Development on 2026-10-10; Joe deploys it to Production.

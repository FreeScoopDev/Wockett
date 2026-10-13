### Changed
- Step challenges count the steps of walks and runs recorded in Wockett since
  the challenge began, the way distance and pace challenges already count
  Wockett's own walks, instead of the step total from Apple Health. A
  challenge entry is public, and publishing a Health figure contradicted the
  privacy policy and Apple's rule against health data in iCloud (2026-10-12
  audit, finding 2). Rides never count toward steps. Each challenge's sync
  button now says where its total comes from and that it is public.
- Challenge entries no longer publish a per-install device identifier, which
  let anyone link one install's entries across challenges (audit finding 22).
  The field is written empty, because 1.14 and 1.15 skip an entry without it,
  and an existing entry of yours loses its old value the next time you sync
  it. Your own entry is recognised by your iCloud account instead, as every
  other kind of community content already is.

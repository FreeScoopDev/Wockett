### Internal
- Every community service a unit test builds (votes, moderation, suspension,
  blocks, reports, deletion, challenge links and the share-privacy offset) now
  listens on its own `NotificationCenter`, as `CommunityNamesTests` has since
  #213. The test host is the app, and the system posts `.CKAccountChanged` on
  `.default` when the simulator's iCloud state settles; a service listening
  there forgets its cached user or account mid-test, which is how
  `concurrentWritesShareClaim` flaked on CI. `SharePrivacyOffsetStore` gains
  the same `notifications:` parameter the other services have, defaulting to
  `.default`, so the app behaves exactly as before. Checked by posting
  `.CKAccountChanged` on `.default` between two votes in `voteSaves`: red
  (two user lookups) with the service on `.default`, green with its own centre.

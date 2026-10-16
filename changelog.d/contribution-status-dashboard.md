### Added
- Wockett Staff: featuring a nominated trail now tells its nominators. For
  each nomination that carries a claim token (a random code the app will
  send with new nominations), the dashboard writes a world-readable
  `ContributionStatus` named after the token's SHA-256, saying only that the
  trail was featured and when, so the nominator's phone can show "Featured"
  in My contributions (the app part follows in a later PR). The name comes
  from the token alone, so nobody can work out from someone's public account
  id which trails they nominated; the token and the nominator never reach a
  status record, History or the page. Unfeature withdraws the statuses, with
  the count in its confirm. Schema: `ContributionStatus` (read by everyone,
  written only by a Moderator) and `claimToken` on `TrailNomination`; both
  need importing into Development before any app build writes them.

### Fixed
- Wockett Staff: Feature and Suspend always failed with "Unknown length:
  undefined" since they were added (#178, #180): the dialogs read their
  "length" choice as `form.elements.length`, which is the number of controls
  in the form. Found while running the new Feature step against a fake
  CloudKit.

### Added
- Wockett Staff: featuring a nominated trail now tells its nominators. For
  each nomination that carries a claim token (a random code the app will
  send with new nominations), the dashboard writes a world-readable
  `ContributionStatus` named after the token's SHA-256, saying only that the
  trail was featured and when, so the nominator's phone can show "Featured"
  in My contributions (the app part follows in a later PR). The status
  record's name comes from the token alone, so it can't be worked out from
  anyone's public account id; the token and the nominator never reach a
  status record, History or the page. (The nomination record's own name is
  still derived from the account and the trail; the app PR changes that.)
  Unfeature withdraws the statuses, with the count in its confirm. Schema:
  `ContributionStatus` (read by everyone, written only by a Moderator) and
  `claimToken` on `TrailNomination`. Both must be imported into Development
  before the Development dashboard features a trail and before any app build
  sends `claimToken`, or CloudKit creates them with its default grants. The
  dashboard checks the type exists before writing a status.

### Fixed
- Wockett Staff: Feature and Suspend always failed with "Unknown length:
  undefined" since they were added (#178, #180), so no trail could be
  featured and no account suspended from the dashboard. The dialogs read
  their "length" choice as `form.elements.length`, which is the number of
  controls in the form. Found while running the new Feature step against a
  fake CloudKit; both now work there.

### Added
- Wockett Staff: a Trail suggestions tab, and the schema for trail
  suggestions (Phase 2, Feature B, first of five PRs). The app does not send
  suggestions yet; this is where Joe will review them once it does, so the
  review tool and the record's shape are settled first. A `TrailSuggestion`
  (name, note, region, the Feature A fact chips, the trimmed and simplified
  line as an encoded polyline, its point count and length, and a claim
  token) can be created by any signed-in iCloud user and read only by a
  Moderator, like a nomination: a suggested line is a place someone walked.
  The tab groups suggestions of the same path by how much their lines
  overlap rather than by name, because two walkers rarely name an unmapped
  path alike; draws the lines; links the start to Maps and the
  OpenStreetMap editor; warns about very short or very long paths,
  straight-line GPS gaps and anything over the size caps the app will
  enforce (re-checked here, since anyone can write a record); and offers
  Accept, Decline and a GPX download made on the page. Accept tells each
  device that suggested the path through the same `ContributionStatus`
  mechanism as featured nominations (kind `suggestion`, status `added`; the
  status carries no name, since anyone can read it), and publishes nothing
  else: accepted paths reach other walkers only in a later
  PR, after a collect-only trial (Joe, 2026-10-16). Decline tells no one,
  because there is no negative status. A removal request can be met by
  deleting one person's suggestions by the identifier the app shows them.
  No claim token, account or status name reaches History or the page.

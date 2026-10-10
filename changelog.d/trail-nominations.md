### Added
- "Nominate this trail" on a named trail's details: walkers tell the Wockett
  team which trails are worth it, with an optional note. One nomination per
  person per trail; it carries the trail (its key, name, one point on it and
  its length) and nothing about the person beyond CloudKit's own creator
  reference, and only a moderator can read it.
- "Featured near you" at the top of the Trails list: trails the team
  features, with a short note on why, when they are within the list's
  10 miles. They also stay in "Trails near you". The list of features is
  fetched at most every 30 minutes, never holds the list up for more than
  3 seconds, and is kept for offline use.

### Internal
- `cloudkit/schema.ckdb` adds `TrailNomination` (create: any signed-in
  user; read and write: Moderator) and `FeaturedTrail` (read: everyone;
  write: Moderator). Imported into Development on 2026-10-10.

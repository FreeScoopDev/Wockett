### Changed
- The Community tab and every screen it opens (Badges, Challenges, New
  Challenge, the Achievement Feed, Community Routes, the badge-earned
  celebration and the share sheet) now use the design Home moved to in the
  redesign. Section headings sit above their cards instead of inside them,
  labels are sentence case instead of small capitals, and buttons, tags and
  empty states look the same as they do on Home. Before, Community was the last
  tab still in the old style, so moving between it and Home felt like two
  apps.
- In New Challenge, the activity choice says "Ride" instead of "Bike", as it
  does everywhere else in the app.
- Like buttons on the Achievement Feed match the ones on the Community tab,
  and show their count even at zero.

### Internal
- New shared pieces: `WktSection` (a heading over its cards), `WktDivider`,
  `wktChoiceBackground(selected:)` (one option in a set the user picks from),
  `WktSecondaryButton`, `WktPillButton` (a small action inside a row),
  `WktEmptyState`, and `WktPrimaryLabel` / `WktSecondaryLabel` for a
  `ShareLink` or other control that is not a plain `Button`. Home now uses
  `WktSection`, `WktDivider`, `WktPillButton` and `wktChoiceBackground` too, so
  the two tabs cannot drift apart.

### Added
- A moderator can now suspend an account. While it is suspended, its posts,
  shared routes, challenges and leaderboard entries are hidden for everyone
  else, and it can't post, share a route, create or join a challenge, or give
  a Wockett: those say "Your community access is paused" (with the end date,
  unless it is permanent) and that walking and tracking still work. Removing
  one item at a time didn't stop someone who posted again a minute later.
  Suspensions are public `Suspension` records only a Moderator can write,
  holding just the account and when it ends; the reason stays in the
  Moderator-only history. Each phone refreshes the list before a community
  load (at most every 10 minutes, waiting no more than 3 seconds) and keeps
  it for offline use. Your own content is never hidden from you.

### Internal
- `cloudkit/schema.ckdb` adds the `Suspension` record type (READ for
  everyone; READ, CREATE, WRITE for Moderator). Imported into Development on
  2026-10-10; deploy to Production before a build with this ships.

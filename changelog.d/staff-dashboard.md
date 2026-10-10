### Added
- Wockett Staff, a moderation dashboard at wockett.app/staff. Signed in with
  the moderator Apple ID, it lists reported posts, routes and challenges
  grouped by item (with the reasons, notes and a route's shape), removes an
  item for everyone or dismisses its reports, browses recent community
  content by author, counts the last 7 and 30 days of activity, and keeps a
  history of every action with a snapshot of what was removed. Until now a
  report was an email, and acting on it meant finding the raw record in
  CloudKit Console. It is a static page with no server and no secret:
  CloudKit's Moderator role decides what the signed-in Apple ID may do, and
  the snapshot is saved before anything is deleted. User-written text is
  only ever shown as text, never run as page code.

### Internal
- `node --test tests/staff` covers the dashboard's rules, run in CI as
  "Staff dashboard tests" on the Linux runner. Each rule was break-checked.

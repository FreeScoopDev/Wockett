### Added
- **Challenge links.** A shared challenge now carries a link,
  `https://wockett.app/c/?id=…`, that opens the challenge in Wockett, or,
  for someone without the app, a page on wockett.app with the challenge's
  name and a Get Wockett button. Until now the invitation could only say
  "find it in Community → Challenges", which a friend installing the app
  for the first time had to remember. A challenge that has ended, was
  removed, or is hidden by a block opens the Challenges list with a
  message instead. The page reads the name from the challenge itself, never
  from the link, so a link cannot make wockett.app show words of its own.

### Internal
- Associated Domains (`applinks:wockett.app`) and
  `docs/.well-known/apple-app-site-association` for `/c/` paths only. The
  link's id is checked by the same rule in the app (`ChallengeLink`) and the
  page (`docs/c/link.js`), and the page's rules run in CI with the staff
  dashboard's Node tests.

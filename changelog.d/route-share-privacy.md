### Changed
- A route shared to Community is published without its first and last 200 m,
  measured along the path, and a shared loop is published as an open route so
  no app draws the missing ends back in. Most walks start and end at home, and
  anyone can read a shared route: the 2026-10-12 audit found one account whose
  nine shared routes all started within 9 m of each other. The route kept in
  My Routes is unchanged. The published distance is the trimmed route's, so a
  shared route never claims more than it shows. A route shorter than 600 m
  can't be shared, because trimming would leave too little to hide the start.
- Both Share Route buttons now say that shared routes are public, that the
  ends are left off, and how long the shared version is; for a route too short
  to share they say why and the button is disabled.

### Fixed
- Posting a route from a route card while community access is paused no longer
  leaves the Post button spinning: the sheet shows the message and lets you
  close it.

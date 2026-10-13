### Changed
- A route shared to Community is published without at least its first and
  last 200 m, measured along the path, because most walks start and end at
  home and anyone can read a shared route. Each end loses a further 0-100 m
  that differs from route to route, only the route's own points are
  published (never a point made up partway along a leg, which on a planned
  route would sit on the straight line from home), and a shared loop is
  published as an open route so no app draws the missing ends back in. A
  route from the route finder shares its walking-directions path, one lap of
  it, rather than its straight planning legs. The route kept in My Routes is
  unchanged. The published distance is the trimmed route's. A route shorter
  than 600 m, or a planned route with too few stops to trim, can't be shared.
- Both Share Route buttons now say that shared routes are public, that the
  ends are left off, and how long the shared version is; for a route that
  can't be shared they say why and the button is disabled.

### Fixed
- Posting a route from a route card while community access is paused no longer
  leaves the Post button spinning: the sheet shows the message and lets you
  close it.

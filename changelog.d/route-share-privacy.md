### Changed
- A route shared to Community no longer shows where it starts and finishes.
  Most walks start and end at home, and anyone can read a shared route.
  Everything within at least 200 m of the start or the finish is left off,
  whether measured along the route or in a straight line, so a walk that
  passes the house again doesn't publish it either. Each end loses a further
  0-100 m that differs from route to route. Only the line the route follows
  is published (a recording, or the walking directions for a planned route),
  never the points a route was planned from: a suggested loop's points are
  corners around where it was planned. What's left is one unbroken stretch
  redrawn every 10 m, which other phones follow as a recorded line. A shared
  loop is published as an open route, so no app draws the missing ends back
  in. The route kept in My Routes is unchanged, and the published distance
  is the trimmed route's. A route shorter than 600 m, or one that never gets
  far enough from its start, can't be shared. This hides the exact start,
  not the neighbourhood.
- Both Share Route buttons now say that shared routes are public, that the
  start and finish are left off, and how long the shared version is; for a
  route that can't be shared they say why and the button is disabled. In My
  Routes the button waits until the route's directions have loaded.

### Fixed
- Posting a route from a route card while community access is paused no longer
  leaves the Post button spinning: the sheet shows the message and lets you
  close it.

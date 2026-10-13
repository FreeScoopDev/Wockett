### Added
- Both Share Route buttons now warn that a route which starts or ends at
  home shows where you live, and offer **Hide start and finish**. It is off
  until you turn it on, and Wockett remembers your choice for the next
  share. Anyone can read a shared route, and most walks start at home, but
  many shared routes start at a trailhead or a park, so hiding is a choice
  rather than forced on every route. With it on, everything within at least
  200 m of the start and finish is left off. The hidden area is a circle
  whose centre is moved 50-150 m in a random direction by a private offset
  made once for you and kept in your own iCloud, so it is the same on all
  your devices; without it, a few loops from the same door would point
  straight at it. If iCloud can't be reached, a hidden share waits rather
  than making a different offset on this phone, with a Try again button.
  A route that would have
  less than 400 m (or a quarter of it) left can't be shared hidden, and a
  hidden loop is published as an open route so no app draws the missing
  ends back in. This hides the door, not the neighbourhood.

### Changed
- A shared route publishes the path it follows (the recording, or the
  walking directions for a planned route), drawn every 10 m, never the few
  points it was planned from: a suggested loop's points are corners around
  where it was planned. Other phones follow it as a recorded line. The
  published distance is the length of what is published; a saved
  multi-lap suggestion used to publish every lap's distance for one lap.
  A route too long for one shared record (over about 120 km) is refused
  with a message instead of failing to save. In My Routes the button waits until the route's directions have loaded,
  and says so if they couldn't be.

### Fixed
- Posting a route from a route card while community access is paused no longer
  leaves the Post button spinning: the sheet shows the message and lets you
  close it.

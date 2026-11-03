### Fixed
- A route's hourly weather and the Home weather chip start at the current
  hour. WeatherKit's hourly forecast can begin 10-11 hours before now, and
  the strip showed its first six hours, so a morning forecast started the
  previous evening ("Yesterday 10 PM – today 3 AM") and the rain status
  described an hour that was already over. A walker deciding whether to go
  out needs the next few hours, so past hours are now left out and the rain
  chance is the current hour's.

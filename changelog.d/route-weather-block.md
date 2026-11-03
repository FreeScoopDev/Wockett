### Changed
- A route's weather opens as its one-line summary on every screen, the saved
  route included. The row already says whether conditions are good; the hours
  are a tap away, so the route itself is what fills the first screen.
- The hourly forecast now says where it is for, which hours it covers and
  when it was updated ("Near the middle of this route" / "Today, 3 PM – 8 PM
  · Updated 2:41 PM"). Six bare hours crossing midnight read as a
  list of numbers, with no day, place or time to judge them by.

### Fixed
- Forecast hours follow the phone's 12/24-hour setting on Routes and Home.
  They used a fixed "3PM" format, which a US phone with 24-Hour Time on
  did not ask for.
- The weather row's advisory ("Good conditions") takes a second line instead
  of being cut to "Good conditi…" on a small phone at the default text size.

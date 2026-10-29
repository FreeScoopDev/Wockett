### Fixed
- The Routes results fit the screen at the largest text sizes. One row was
  the cause: the weather tile kept the temperature, the status and Apple's
  Weather attribution side by side at a fixed size, which added up to more
  than the screen, and that one row made the whole results panel wider than
  the window (401 pt on a 390 pt iPhone 17e; with the tile taken out the
  panel was exactly 390). Nothing was cut off yet, but it is how Save and
  Share went off-screen before the type scale stopped at Accessibility 2, so
  any more text would have hidden something. At the accessibility sizes the
  attribution now has a line of its own, where it stays whole and tappable
  (WeatherKit's terms require it wherever its data is shown), and the
  weather status wraps, so "Good conditions" reads in full instead of a
  check mark and a clipped letter.
- At those sizes "New search" reads whole instead of "New / searc / h": the
  button no longer sits in a fixed 110 pt slot, and the panel's grabber
  moves above it. Route cards stack distance above time, so each value keeps
  its unit ("6.3 mi", "2h 17m") instead of one character a line. The default
  text size is unchanged.

### Internal
- A UI test opens Routes at Accessibility 2 and checks that the results
  panel, the first card's Save and Share, and the weather attribution are
  inside the window. It failed on `main` (panel 401 pt on the 390 pt 17e,
  404 pt on the 402 pt 17) and fails again when the attribution goes back
  into the fixed-size row. Cut-off or one-character lines are not in the
  accessibility tree, so screenshots are the evidence for those.

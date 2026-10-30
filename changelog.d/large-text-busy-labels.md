### Fixed
- At the accessibility text sizes a button no longer changes size while it
  works. Each busy state ("Finding routes…", "Creating…", "Syncing…",
  "Sharing…", and the spinners on Share Route's and Share Achievement's Post
  and the walk card's Share) was drawn by hand in a 56 pt button, while the
  idle buttons grow with the text: at Accessibility 2 "Post & Save to My
  Routes" is two lines and 90 pt, so the button shrank the moment it was
  tapped and everything below it jumped up. The busy state now draws over the
  idle button's own space, so the size cannot change. The normal text sizes
  look exactly as before.

### Internal
- `WktBusyLabel` is the one way to give a shared button a busy state, and
  `wktButtonTitleLayout()` is the title rule both the button and its busy
  state use. `-WKTUITest -WKTHoldBusy` holds every busy state on, so the new
  UI test can measure them (always off in release builds).

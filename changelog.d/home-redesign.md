### Changed
- Home is redesigned around one "Today" card: the date, GPS and weather
  chips, your step ring, your crew's progress and your streak now sit
  together. They used to be spread over a rotating tagline, a stat card, a crew
  card, a progress track with a dog on it and a weather card, which said the
  same things several times and pushed starting a walk below the fold.
- Starting an activity is now two steps: pick Walk, Run, Ride or Indoor, then
  press Start. The old tiles started a session on the first tap, so a stray
  tap began a walk.
- Routes are two equal cards (Find a Route, My Routes), and a new "This week"
  card shows seven days of steps, with today in green.
- Weather is a chip in the Today card instead of a card of its own. Tapping it
  opens the forecast, a link to Apple Weather and the Apple Weather
  attribution.
- The motivational quotes that rotated in the navigation bar now appear one
  at a time under your streak, and your own affirmations are still among them.
  Settings → Motivational Banner is now called Motivational Quotes.
- The app's colours, cards and section headings are updated everywhere, not
  just on Home: neutral greys instead of warm ones, white text instead of
  cream, brighter activity colours, cards with 22 pt corners and a hairline
  edge, and sentence-case section headings instead of small capitals. Shared
  pieces look the same on every screen.

### Fixed
- Orange text in light mode, such as "3.3 mi to go", was too faint to read
  comfortably (3.6:1). It is now 4.9:1, above the 4.5:1 that small text needs.

### Internal
- New shared design pieces in `DesignSystem.swift` and `PoCSquat/Design/`: a
  named type scale (`wktMetric` … `wktLabel`), `WktSpacing`, the `earthRaised`,
  `earthTrack` and `earthStroke` colours, `WktStatusChip`, `WktPrimaryButton`
  and `WktIconBadge`. `wktCard`, `WktSectionHeader` and `WktProgressBar` were
  upgraded in place, so the roughly 15 screens that use them changed too.
- Removed code that only the old Home used: `JourneyTrackView` and its hourly
  step service, `BannerTitleView` and the timer that rotated it, and the three
  weather cards.
- The walk UI tests now select Walk, check that no session has started, then
  press `home.start`. Seeing them fail when the picker starts a session by
  itself was part of verifying this change.

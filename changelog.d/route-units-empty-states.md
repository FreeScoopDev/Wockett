### Fixed
- Heights on the Routes screens now follow the app's unit rule, the one its
  distances use: feet in the US, metres everywhere else. The elevation
  chart's gain, loss and axis, a saved route's climb and the line saying why
  it is rated as it is ("Moderate because of 395 ft of climb"), and the
  route result cards all said metres, so a US walker read "2.1 mi" beside
  "+98m".
  The result cards used Apple's distance formatter, which follows the region
  instead of the app's rule: in the UK it said "130 yd" for a 120 m climb,
  and in the US it rounded to "400 ft". Every height now goes through the
  summary's formatter, which rounds to the nearest whole metre or foot, so a
  98.6 m climb reads "99 m" where the chart used to cut it to "98m". The
  chart's shape is unchanged; only the numbers on its axis change. Heights are
  still stored in metres. One case is left: a result card's distance still
  uses Apple's formatter, so in a region with UK units it reads miles beside
  a height in metres (Wockett is sold in the US and Canada only).

### Changed
- An empty Route History now says why and offers a way on. When finished
  walks on the route are left out (excluded from route stats, or flagged as a
  trip in a vehicle), it says how many, where before it looked as if none had
  been walked. It says "activities", not the route's own word, because a
  walking route can be started as a run or a ride. **Start this route** opens the same mode picker and Start as
  the route's own page, in a sheet, so nothing records until Start is tapped
  there; **Back to route** returns to the route. The route page and the sheet
  share one start bar, so the two cannot drift.

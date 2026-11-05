### Fixed
- Heights on the Routes screens now use the same unit as the distance next to
  them: feet where distances are in miles, metres everywhere else. The
  elevation chart's gain, loss and axis, a saved route's climb and the route
  result cards all said metres, so a US walker read "2.1 mi" beside "+98m".
  The result cards used Apple's distance formatter, which follows the region
  instead of the app's rule: in the UK it said "130 yd" for a 120 m climb,
  and in the US it rounded to "400 ft". Every height now goes through the
  summary's formatter, which rounds to the nearest whole metre or foot, so a
  98.6 m climb reads "99 m" where the chart used to cut it to "98m". The
  chart's shape is unchanged; only the numbers on its axis change. Heights are
  still stored in metres.

### Changed
- An empty Route History now says why and offers a way on. When finished
  walks on the route are left out (excluded from route stats, or flagged as a
  trip in a vehicle), it says how many, where before it looked as if none had
  been walked. **Start this route** opens the same mode picker and Start as
  the route's own page, in a sheet, so nothing records until Start is tapped
  there; **Back to route** returns to the route. The route page and the sheet
  share one start bar, so the two cannot drift.

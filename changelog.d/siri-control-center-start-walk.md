### Fixed
- "Hey Siri, start a walk with Wockett" and the Control Center "Start Walk"
  button now start a walk. Both set a flag that nothing in the app read, so
  they only opened Wockett. The app now acts on the request at launch and
  whenever it comes to the front: Home opens the walk screen in the mode
  asked for, or brings back a walk already in progress. A request older than
  five minutes is ignored, so a tap that never opened the app does not start
  a walk days later, and neither does the flag 1.13 left behind.
- "How many steps today in Wockett" asks Health for today's count (over the
  same 3 AM-to-now day as the Home ring) instead of reading a value nothing
  wrote there, which made Siri answer 0 every time. Siri now says the number
  as well as showing it. Without Health access it falls back to the count the
  widget shows, if that was refreshed today.

### Changed
- The Siri "Start a Walk" shortcut no longer offers a Duration option. It
  was collected and never used; a free walk has no time target to set.

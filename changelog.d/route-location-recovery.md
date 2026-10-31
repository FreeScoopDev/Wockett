### Fixed
- With location turned off for Wockett, Routes now says so before you search,
  instead of letting you tap Find Routes and only then showing "Unable to get
  your location". Find Routes is greyed out, and the panel offers what can
  still work: Open Settings (left out when location is restricted on the
  iPhone, which the person usually can't change) and Plan on the map, which
  opens the route builder, since tapping waypoints needs no location. "Try
  nearby loops", "Search a place" and "Nearby places" are hidden then,
  because each starts from where you are and failed the same way. Trails
  gives the same explanation and actions, and says "Finding your location…"
  while an allowed phone is still waiting for its first fix, rather than
  telling someone whose location is on to turn it on.
- The first route search on a fresh install waits for the answer to the
  location prompt. It used to check the permission on the line after asking,
  see "not decided yet", and fail behind the prompt (read from the source;
  not reproduced on a simulator).

### Internal
- `-WKTUITest -WKTLocationOff` (debug builds only) makes Routes behave as if
  location were denied, so a UI test can reach that panel.

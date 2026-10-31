### Fixed
- With location turned off for Wockett, Routes now says so before you search,
  instead of letting you tap Find Routes and only then showing "Unable to get
  your location". Find Routes is greyed out, and the panel offers what can
  still work: Open Settings (left out when location is restricted on the
  iPhone, which the person usually can't change) and Plan on the map, which
  opens the route builder, where a route is made from points tapped on the
  map rather than from where you are. "Search a place" and "Nearby places"
  are hidden then, because each starts from where you are and failed the
  same way. Trails gives the same explanation and actions, and shows no
  trails around a location the app no longer has. While an allowed phone is
  still waiting for its first fix, Trails says "Finding your location…"
  rather than telling someone whose location is on to turn it on.
- "Try nearby loops instead" no longer appears after a search failed for
  want of a location (including a location error with permission allowed),
  since it needs the same location and failed the same way.
- The first route search on a fresh install waits for the answer to the
  location prompt. It used to check the permission on the line after asking,
  see "not decided yet", and fail behind the prompt (read from the source;
  not reproduced on a simulator).

### Internal
- `-WKTUITest -WKTLocationOff` (debug builds only) makes Routes behave as if
  location were denied, so a UI test can reach that panel.

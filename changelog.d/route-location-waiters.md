### Fixed
- Two things asking for the phone's location at once (Routes opening and a Start tap, or a trail's directions) now share one request and both get its answer. Before, the second pushed the first out with "no location", so a Start could go ahead without checking how far away the route begins.

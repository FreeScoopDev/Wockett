### Fixed
- Trail and route names read in full at the accessibility text sizes. The
  name is the point of these rows, but each had one line beside something
  else: at Accessibility 2 Community's Trails near you showed "Little R…",
  "Rocky…" and "Walnut…" next to their Official chips, the Top community
  routes cards cut their details to "9.1 mi · Hard · 1…", and Home's two
  Routes cards, half the width each, read "Find a Ro…" and "Recommend…". At
  the accessibility sizes the Official chip now sits under the trail's name,
  names and details take as many lines as they need (broken between words,
  and never between a number and its unit, so "0.4 mi" stays together), the
  route cards grow taller instead of cutting, and Home's Routes cards stack
  one above the other. The normal text sizes look exactly as before. The
  rule lives in one place (`WktNameLayout`) so the rows cannot drift apart.

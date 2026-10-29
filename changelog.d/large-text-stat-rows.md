### Fixed
- Rows of stats read in full at the accessibility text sizes. Three or four
  stats side by side each had a third or a quarter of the width, so at
  Accessibility 2 the labels were cut or broken mid-word: "Distanc / e" on a
  walk's summary, "This w…" in Activity History's header, "Day str…",
  "Challe…" and "Wocke…" on the Community You card, "Goal str…",
  "Apple a…" and "Best str…" on Streaks & Badges (three zeros nobody could
  tell apart), and on a trail's detail the values themselves, "About 29…"
  and "~3,…". At the accessibility sizes these rows now go two to a row, as
  the pet detail already did and read cleanly, and a label may take a second
  line, broken between words; values stay on one line. The normal text sizes
  look exactly as before. All five follow one shared rule (`WktStatColumns`,
  laid out by `WktStatRow`), so it cannot drift between screens.

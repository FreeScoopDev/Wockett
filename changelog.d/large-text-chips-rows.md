### Fixed
- Status chips, activity rows, community names and pet rows read in full at
  the accessibility text sizes. Each kept one line, or split a line in the
  wrong place, in a space that was too narrow. At Accessibility 2 Insights
  said "Nothing last week to…", the Next badge chips said "Warming…" and
  "On a Roll…", History and Home's recent activity split "0.7 / mi" and
  "12m / 58s" across lines, the community feed's round initials showed
  "C…", a username broke mid-word ("GentleMos / s earned"), and My Pets
  showed "0 / walks" with the breed's dot floating beside it. Now the status
  chip wraps between words and becomes a rounded rectangle (every screen that
  uses it changes together), the Next badge chips flow onto new lines, a
  distance and a time stack rather than break, the initials shrink to fit
  their circle, and the breed goes under the pet's name without the dot.
  A username is one word, so in the community feed, the You card, route and
  challenge cards and the leaderboard it is never broken: it moves to a line
  of its own, shrinks a little if it is too wide for it, and only a name that
  still does not fit is cut with "…". The normal text sizes look as before.

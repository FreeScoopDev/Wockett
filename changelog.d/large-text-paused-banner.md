### Fixed
- A paused walk no longer covers the map's North up button at the largest
  text sizes. At those sizes the "Walk paused" banner wrapped onto several
  lines with its own Resume pill, which made the bottom panel about 100 pt
  taller: on an iPhone 17e at Accessibility 2 it reached 80 pt over North up
  (84 pt pulled up), and 36 pt on an iPhone 17. A one-line banner without the
  pill was tried first and still reached 40 pt over on the 17e, so at the
  accessibility sizes the panel's header now says "Paused" (a guided walk's
  progress line gives way to it while paused) and the banner row is gone.
  The pill only repeated the main button, which already says Resume while
  paused and is full width at those sizes, so there is now one Resume.
  VoiceOver still hears "Walk paused". Normal text sizes are unchanged.

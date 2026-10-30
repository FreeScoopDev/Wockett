### Fixed
- At the accessibility text sizes the Post buttons on Share Route and Share
  Achievement, and Share on a walk's share card, no longer shrink while they
  work. Their busy state was a bare spinner in a 56 pt button, so a two-line,
  90 pt "Post & Save to My Routes" dropped to 56 pt the moment it was tapped
  and everything below it jumped up. The spinner now sits in the space the
  title takes, so the button keeps its size (measured at Accessibility 2 on
  iPhone 17e and 17). The normal text sizes look exactly as before.

### Internal
- The hand-drawn busy labels ("Finding routes…", "Creating…", "Syncing…",
  "Sharing…") now use the shared button's title layout
  (`wktButtonTitleLayout()`): wrapped, centred and padded at the
  accessibility sizes, like the button they replace. At Accessibility 2 on
  the two test phones these short titles already fit, so nothing moves
  there; the rule keeps them in step with the shared button at larger sizes
  and for any future busy title.

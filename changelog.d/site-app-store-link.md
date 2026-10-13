### Changed
- wockett.app's home page now links to the App Store and to support, and
  describes the app as it is in 1.14: loops from your door sized to your
  step goal or a spare 20, 30 or 45 minutes, a daily goal for every pet,
  trails (North Carolina for now), walk, run, ride or indoor, and step
  challenges. The page had no way to get the app and still described an
  older version (the 2026-10-12 design audit, finding 4). Every feature line
  is taken from the live App Store description.

### Internal
- The staff dashboard (`docs/staff/`) refuses to run inside another site's
  frame and tries to break out to its own tab. GitHub Pages cannot send the
  header that forbids framing, so a hostile page could otherwise load the
  dashboard invisibly and trick a signed-in moderator into clicking Remove
  or Suspend (2026-10-12 security audit, finding 30). A Content-Security-Policy
  meta tag was left out: browsers ignore `frame-ancestors` in a meta tag, and
  a wider policy risks breaking Apple sign-in.

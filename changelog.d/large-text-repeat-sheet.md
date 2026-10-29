### Fixed
- At the largest text sizes, Repeat in Activity History opens with Start and
  Cancel on the screen. The review opened at half height, which left Start
  half below the bottom edge on an iPhone 17e (its bottom at 858 pt on an
  844 pt screen) and Cancel out of sight on every phone, so the one thing the
  sheet is for needed a drag nobody would know to make. At the accessibility
  sizes it now opens full height, as the finish-walk sheet already does; at
  the standard sizes it opens at half height as before.
- Health's "This week" header shows its dates in full at the largest text
  sizes. Beside the title there was room only for "Oct 2…", so the header
  named no week at all. At the accessibility sizes the dates sit under the
  title and may wrap; at the standard sizes they stay beside it on one line.

### Internal
- A UI test opens the Repeat review at Accessibility 2 and checks that Start
  and Cancel are inside the window. It failed on `main` (Start's bottom at
  858 pt on the 17e; Cancel at 919 pt on the 874 pt iPhone 17) and fails the
  same way when the half-height detent comes back at those sizes.

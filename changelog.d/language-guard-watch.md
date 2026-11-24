### Internal
- The language-consistency guard now scans the Apple Watch app (`WockettWatch/`)
  as well as the phone's views, intents and the widget. The Watch remote drives
  runs and rides too, so a hardcoded "End Walk" there would be the same bug the
  guard already catches everywhere else.

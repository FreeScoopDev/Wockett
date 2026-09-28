### Fixed
- The home-screen widget now updates without opening Wockett. The
  background refresh wrote today's steps under a name the widget never
  read, so the widget only changed when the app itself was opened; it now
  writes exactly what the widget shows and asks it to redraw. The app also
  registers for Health's background delivery of new step samples and
  acknowledges each one (the acknowledgement was missing, which makes
  Health stop delivering), so steps recorded by the Watch or the phone
  reach the widget within the hour.

### Internal
- Every app-group key lives in one file compiled into both the app and the
  widget (`AppGroup.swift`, beside `DesignSystem.swift` and
  `ProEntitlement.swift`), so the two processes cannot disagree about a
  name again. `WidgetSnapshot` is the one writer of the widget's numbers.

### Internal
- The Control Center request keys, the Siri steps fallback and the
  background refresh's day boundary now go through `AppGroup.swift` and
  `StepManager.trackingDayStart()` instead of their own copies of the
  strings and the 3 AM rule, finishing the widget-refresh change.

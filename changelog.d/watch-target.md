### Internal
- The project has an Apple Watch app target, `WockettWatch`, embedded in the
  iPhone app. It is only a placeholder screen (the Wockett mark and "Start a
  walk on your iPhone.") so the walk remote and the complications can each
  be built on a real watch target in their own branch. It shares
  `DesignSystem.swift` with the app and widget (watchOS is always dark, so it
  gets each colour's dark value from the same palette) and takes its version
  and build number from `Versions.xcconfig`, so the watch app can never ship
  with numbers that differ from the iPhone app's. Nothing user-visible yet: a
  release must not be cut from `main` until `feat/watch-walk-remote` merges.

### Changed
- The home screen widget and the Live Activity (lock screen and Dynamic
  Island) now match the app: SF Pro Rounded throughout, sentence-case labels
  instead of small capitals, and the step ring in orange on the track, as on
  Home's Today card. The small widget's header says "Today", as that card
  does, instead of repeating "Wockett", which iOS already shows under it.
- On the Live Activity, Pause is the green button and End is red, as on the
  session screen, where Pause is the main action and finishing is red. Before,
  Pause was orange and End was green, the opposite of the app.

### Internal
- The v1.10 `wktDisplay` (Rounded Black) and `wktTechnical` (SF Mono, all caps)
  fonts are deleted from `DesignSystem.swift`. With the widget converted,
  nothing used them, and keeping them invited the old style back in.
- This completes the rollout of the 2026-09-30 design system to every screen
  (#115–#123).

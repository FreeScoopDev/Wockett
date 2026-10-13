### Changed
- wockett.app (home, Help, Privacy Policy, Terms of Service and the challenge
  link page) uses the app icon's colours: forest green, cream and waypoint
  orange, copied exactly from `DesignSystem.swift`, the same palette
  scoopsdevstudios.com now uses. The pages had drifted into three looks
  (black with Apple blue, plain white, and a green button on the challenge
  page); they now share one stylesheet, `docs/assets/site.css`, the same
  footer and the same cream button, so a colour changes in one place. Every
  text colour clears WCAG AA contrast; the bright orange stays decorative
  because it is too low-contrast for text on the green. Page wording is
  unchanged. The staff moderation tool keeps its own styles.

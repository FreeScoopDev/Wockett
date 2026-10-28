### Fixed
- At the largest text sizes (Accessibility 3 to 5), Wockett's text now stops
  growing at Accessibility 2, as the app already said it did. The limit on
  the tab view only reached system-styled text: Wockett's own fonts work out
  their point size before SwiftUI applies it, so they kept growing, and at
  the largest size an audit found seven blocked actions and fourteen cut-off
  values
  ("Hold… / 1 second" on the Finish button, the route Save and Share buttons
  off-screen, the WeatherKit attribution cut to "Wea"). The fonts now clamp
  themselves to their Accessibility 2 size in one place. Nothing changes at
  Accessibility 2 or smaller, which covers the widget at its usual sizes.
  This is a floor, not the end: the screens can still be made to work at
  every size, and the limit raised once they do.

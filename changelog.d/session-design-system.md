### Changed
- The walk session and the screens after it now use the design Home,
  Community and Health moved to: the live session panel, the finish
  confirmation, the summary, the share sheet, the mini tile shown while a
  session is minimised, and the indoor walk with its summary.
- The banners that appear mid-session (paused, off the trail, at the trail,
  "this looks faster than a walk", heat advisory) share one look, with their
  buttons on their own row so they keep their size at large text sizes.
- Pause is the session's primary button. Hold to finish keeps its red
  outline, now the same size and shape, so ending a session still never looks
  like pausing it.
- On the summary, Done is the one primary button; sharing and scheduling are
  the quieter buttons above it.
- The indoor walk's step ring is orange, as everywhere else your own goal is
  shown, and its Finish button is the green primary button. Indoor's purple is
  kept for its icons, like every activity colour.
- The shared summary image uses the new palette and SF Pro Rounded. Its text
  sizes stay fixed, because the image is drawn at a fixed size whatever text
  size the sharer uses.

### Internal
- New shared pieces: `WktBanner`, and a `tint` on `WktPillButton` (red to end
  something, cream for "Not now"). `WktSymbol` gains `.cadence`; the indoor
  walk's 9 hard-coded SF Symbol names go through `WktSymbol`.

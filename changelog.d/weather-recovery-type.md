### Changed
- The hourly forecast (the Home weather sheet and the Routes weather tile) and the Apple Weather credit use the shared type scale, so they grow with the phone's text size like the rest of the app. Until now they were fixed at 9–13 pt, the smallest text left in Wockett and the last parts of the weather screens the 2026-09-30 redesign had not reached. Each hour's symbol now sits in one fixed, text-size-aware height, and the rain percentage is always laid out (hidden below 30%), so every column's temperature lines up: a short cloud symbol had pushed its column a few points off its neighbours. Checked in light and dark on the simulator with a stubbed forecast.

### Fixed
- The Routes weather tile no longer cuts its condition down to one letter ("P…") when the row is narrow. With the larger Apple Weather credit, the condition is the first thing to go: the symbol already shows it and VoiceOver still reads it, so "Good conditions" stays readable in full.

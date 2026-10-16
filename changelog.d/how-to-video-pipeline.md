### Internal
- `scripts/how-to-videos/` records and renders the short how-to videos with one
  command per video, so none is edited by hand. Each video's UI test already
  drives the screens; the pipeline films the simulator while the test runs,
  trims the lead-in, burns in captions and writes a 1080x1920 MP4 outside the
  repo. A failed or skipped test produces no video, so a bad take can never be
  rendered by accident. The caption files are unverified drafts and are kept
  apart from the script logic so they can be corrected without touching it.

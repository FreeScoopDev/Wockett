### Internal
- Ending a walk is now tested for the two steps users would notice first if
  they broke: the Health workout and the Live Activity. A saved walk finishes
  its workout once, a discarded one throws it away once, and the Live Activity
  ends once either way, even if a second path tries to end the walk again.
  Before this, deleting those lines left every test green (checked on
  2026-10-13), and those were the steps that went missing when seven screens
  each ended walks their own way. The Live Activity and the workout writer
  now sit behind two small protocols so a test can count the calls; the app
  still uses the same objects as before.

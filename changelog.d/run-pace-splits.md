### Added
- **Current pace** on walks and runs, beside the average. The one pace a walk or run showed was its average since the start, and the voice cue called that average "current pace". Instant pace is the figure runners complain about most when it jumps with GPS noise (research for the Run plan, 2026-10-14), so current pace is smoothed: moving time over distance across the last 45 seconds, from fixes the app already trusts, and blank ("--:--") when there is too little to go on or you have stopped for 15 seconds. The live screen glances at current pace; pulled up, it shows "current pace" and "avg pace". Rides keep their one average speed. The 45 s window is a starting value to tune on a real run.
- **Splits on every outdoor walk and run**, per mile in the US and per kilometre elsewhere. Until now a free run, most runs, had none; only guided routes recorded checkpoint times. Each split's time is worked out at the exact crossing, between the two GPS fixes either side of it, and a last part-mile of at least a tenth is kept ("0.43 mi"). Splits are saved with the activity, so the summary shows them right after finishing and again from Activity History, and they survive the app being closed mid-run. Saved as a new field on the walk record in iCloud.
- The **Live Activity** shows both paces for a walk or run: current pace with "Avg 9:20" beneath on the Lock Screen and in the Dynamic Island, and "9:05 · avg 9:20" on the Apple Watch Smart Stack (not yet measured on a real watch).

### Changed
- The **voice cue** says each split and names each pace for what it is: "Mile 2. Time 18 minutes 40 seconds. Last mile 9 minutes 12 seconds. Average pace 9 minutes 20 seconds per mile." A ride hears its average speed instead of a pace it never showed. The cue now follows the split, so a run restored after the app was closed doesn't repeat a mile.
- A guided route's checkpoint times on the summary are titled "Checkpoints", so the new per-mile "Splits" are the only section of that name.

### Internal
- The Live Activity's paces come from one place, `NavigationSessionManager.liveActivityState`. Nine callers each recomputed the pace before, with two different distance thresholds, and four sent no pace at all after a restore, a head-back or the start of a trail.
- `RollingPace` and `SplitTracker` (`RunPacing.swift`) are plain values fed numbers, with 52 tests (`RunPacingTests`).

# Round B: auto-pause on ignored break prompt + cycling shows speed, not pace

Two behavior fixes from QA. Joe's decisions: ignored "Still walking?"
prompt → auto-pause after ~5 more stationary minutes; cycling displays
speed (mph / km/h) instead of foot pace on every surface.

## Part 1 — Auto-pause when the break prompt is ignored

Today `showBreakPrompt` fires once and nothing else ever happens — the
alert sits forever while the session keeps running, which defeats the
feature's purpose.

### `PoCSquat/Services/Routes/NavigationSession.swift`

1. New state near `showBreakPrompt`:

```swift
    private var breakPromptShownAt: Date?
    var autoPausedForInactivity = false
```

2. Where the timer tick currently does
   `if self.stopTracker.tick(...) != nil { self.showBreakPrompt = true }`,
   also record when it fired (only on the transition to true):

```swift
                if self.stopTracker.tick(isMoving: isMoving, now: now) != nil {
                    if !self.showBreakPrompt {
                        self.showBreakPrompt = true
                        self.breakPromptShownAt = now
                    }
                }
```

3. In the same per-second tick, after that block, add the escalation —
   if the prompt has been up 5+ minutes, the user hasn't responded, and
   the session is still running, pause it:

```swift
                if self.showBreakPrompt, !self.isPaused,
                   let shownAt = self.breakPromptShownAt,
                   now.timeIntervalSince(shownAt) >= 300 {
                    self.autoPausedForInactivity = true
                    self.pause()
                    self.postAutoPauseNotification()
                }
```

4. Clear the tracking wherever the prompt is answered/reset:
   `dismissBreakPrompt()` sets `breakPromptShownAt = nil`; `resume()` and
   `stop()` set `autoPausedForInactivity = false` (and `resume()` also
   nils `breakPromptShownAt`).

5. Local notification helper (so a backgrounded user learns why their
   timer stopped) — pattern-match the existing water-break notification
   code for authorization handling:

```swift
    private func postAutoPauseNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Session paused"
        content.body = "You've been stopped for a while, so we paused your session to keep your stats honest. Resume anytime."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "autoPause", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

### `PoCSquat/Views/Walk/WalkNavigationView.swift` (and the alert generally)

The "Still walking?" alert's affirmative button must handle the case where
auto-pause already happened before the user answered: if
`session.autoPausedForInactivity` (or simply `session.isPaused` with that
flag), call `session.resume()` so answering "yes I'm walking" un-pauses.
The Live Activity already reflects pause via the existing
`.onChange(of: session.isPaused)` handlers in both views — verify the
auto-pause path triggers them (it should, since `pause()` is the same
method), no extra push needed.

FreeWalkView note: free sessions use the same `NavigationSessionManager`,
so auto-pause fires there too — but FreeWalkView has no "Still walking?"
alert wired up. Add the same `.alert` + `.onChange(of: session.showBreakPrompt)`
pattern WalkNavigationView uses (with its End/affirm buttons adapted to
the free-walk end flow: End = the same action as the Finish button). If
that adaptation balloons, say so in the commit and we'll split it out.

## Part 2 — Cycling shows speed, not pace

Pace (min/km or min/mi) is a foot-activity stat; rides should show speed.
Internal math (challenges, PR comparisons) stays in secs/km — this is
display-only.

### `PoCSquat/Services/Routes/NavigationSession.swift`

Make `paceText` activity-aware. Keep the existing foot-pace body for
walking/running/indoor; for `.cycling` return speed from the same inputs:

```swift
        if route.activityMode == .cycling {
            guard totalDistanceCovered > 50, elapsedTime > 5 else { return "--" }
            let useMetric = Locale.current.measurementSystem != .us
            let speed = (totalDistanceCovered / elapsedTime) * 3.6   // km/h
            let value = useMetric ? speed : speed / 1.609344
            return String(format: "%.1f %@", value, useMetric ? "km/h" : "mph")
        }
```

Also add `var paceLabel: String { route.activityMode == .cycling ? "speed" : "pace" }`
and use it for the HUD label in `WalkNavigationView` (`hudStat(value:
session.paceText, label: session.paceLabel, ...)`).

### `WocketWidget/WocketWidgetLiveActivity.swift`

`context.attributes.activityMode` already carries the mode string —
no ContentState schema change needed. Make `fmtPace` mode-aware
(`fmtPace(_ secsPerKm: Double?, mode: String)`): for `"cycling"`, convert
`secsPerKm` to speed for display (`km/h = 3600 / secsPerKm`, mph divide
by 1.609344), formatted like Part 2 above; other modes unchanged. Update
all three call sites (Lock Screen stats row, Dynamic Island trailing
pace slot, compact/minimal) to pass the mode, and switch their "pace"
labels + speedometer captions to "speed" when cycling (the SF Symbol
`speedometer` is fine for both).

### `PoCSquat/Views/Walk/ActivitySummaryShareSheet.swift` and `PoCSquat/Views/Routes/RouteSessionHistoryView.swift`

Both compute a local `paceText` from a saved `WalkSession` — make each
check `session.activityType == "cycling"` and format speed the same way
(shared small helper if there's a sensible common home, e.g. a
`WalkSession` extension `paceOrSpeedText` — prefer that over three
copies). Labels "Pace" → "Speed" for rides.

`StationaryWalkView` (indoor) keeps its own pace display as-is — indoor
is never cycling.

## Verify

1. Threshold 1 min: start a walk, stand still, let the prompt appear,
   ignore it ~5 min → session auto-pauses (timer freezes, "Walk Paused"
   banner, Live Activity shows paused), notification arrives if
   backgrounded. Answer "still walking" afterward → resumes.
2. Same on a Free Walk → prompt now appears there and auto-pause works.
3. Start a Free Ride → HUD (if pace shown), Lock Screen, and Dynamic
   Island all show `x.x mph` (or km/h) labeled "speed"; a walk/run still
   shows `m:ss /mi` pace. Check a saved ride's share card and Route
   Detail attempt row too.
4. Full test suite green. Commit clearly (two commits fine — one per
   part — if you prefer). Do not push.

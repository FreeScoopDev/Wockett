# Changelog

All notable changes to Wockett are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- One unified active-session experience for every activity — guided routes, free walks, runs, and rides now share a single session screen built on the guided-walk design (stats bar, pause control, end dialog, map), instead of two visibly different implementations; route guidance appears only when the route has waypoints, POI chips and the breadcrumb trail only on free sessions
- One end-of-activity summary for every in-app end path — Finish, End, Save Route & End, the inactivity prompt's End, and reaching a route's endpoint all show the same summary (stats, personal records, pet progress, share, Save as Route, Schedule Again); previously guided walks ended manually saved silently with no summary
- Activity-aware language everywhere — every card, banner, prompt, button, Live Activity label, and icon now speaks the selected activity's language ("Run Complete!", "Still Riding?", "End Run", running/cycling symbols) instead of hardcoded "walk"; "Walk History" is now "Activity History"
- Active walk sessions persist across the whole app instead of being tied to the map view — minimize any session (swipe down or tap the chevron) and keep tracking from a persistent mini tile visible on every screen, with tap-to-reopen and a stop control
- All four ways to start a session (Route Finder, the dashboard tile, My Routes, Activity History) present the same sheet-based screen with native swipe-to-minimize
- Live Activity / lock screen has interactive Pause, Resume, and End buttons that work without opening the app
- Resume-after-force-quit: if the app closes unexpectedly mid-session (crash, memory pressure, or a manual force-quit), a lightweight checkpoint written every ~15 seconds — now including the GPS breadcrumb trail — lets you pick the session back up on next launch via a "Resume Your Activity?" prompt, folding any downtime into paused duration so the numbers stay honest
- Checkpoints not resumed within 4 hours are automatically saved to Activity History as a completed activity (dated by start time, elapsed cut off honestly at the last checkpoint) instead of being discarded — delete it from history if you don't want it; sub-50m accidental starts are dropped
- Auto-pause: if the "Still walking?" inactivity prompt goes unanswered for ~5 minutes while you're still stationary, the session pauses itself (with a notification if the app is in the background) so a forgotten session doesn't inflate your time and pace; answering "Keep Tracking" resumes it
- Cycling sessions show speed (mph or km/h) instead of foot pace on the in-session stats, Lock Screen, Dynamic Island, share card, and Route Detail
- Free sessions gained Pause/Resume, working Live Activity buttons, minimize/reopen, resume-after-force-quit, and the "Still walking?" inactivity prompt — all of which previously existed only for guided routes

### Changed
- Version and build numbers now come from a single `Versions.xcconfig` shared by the app, widget extension, and tests (the widget had drifted to reporting 1.0 while the app reported 1.9)
- Privacy policy updated to accurately describe private-iCloud sync of walk history, community content publishing, and silent sync signals; the walk-resume section now describes the save-to-history behavior
- Live Activity intents' Shortcuts-facing titles are now "End Activity" / "Pause or Resume Activity"
- Accessibility pass on the rebuilt session and summary screens: every icon-only control (stop, pause/resume, minimize, mini-tile reopen, audio/water/checkpoint toggles, pet and POI buttons, banner dismissals) now has a VoiceOver label; stat cells, summary tiles, pet rings, and PR cards read as single phrases; POI pins and filter chips meet the 44pt tap target

### Fixed
- **[Fix]** Phantom Live Activities survived a force-quit and could not be cleared with the End Walk button
  - What was broken: the Live Activity manager only tracked its in-memory reference; after a force-quit that reference was gone while the system still showed the banner, so End did nothing and each new session stacked another orphan on the lock screen.
  - What changed: all end/reap paths now work from the system's own activity list — at launch, in the End intent when no session exists, and before starting a new activity; resuming a checkpointed session starts a fresh, correctly-populated Live Activity.
  - Affected versions: since Live Activities were introduced (1.8.1); surfaced by the resume-after-force-quit QA pass.
- **[Fix]** Workouts ended from the Live Activity End button or the mini tile never reached Apple Health
  - What was broken: those two end paths stopped the session without finishing the HealthKit workout builder, silently abandoning the workout for every activity type. Only the in-screen Finish button saved to Health.
  - What changed: every save path finishes the workout; every discard path explicitly discards it (a first fix briefly wrote discarded walks to Health — corrected before release).
  - Affected versions: 1.8.1–1.9 (Unreleased).
- **[Fix]** Walks ended manually (rather than by reaching the route's actual endpoint) were silently discarded instead of saved to history
  - What was broken: every manual "end early" path called `session.stop()` without writing the session to history; only completing a route saved anything.
  - What changed: every manual exit saves by default through one shared method, with an explicit "Discard" as the only way to lose data on purpose.
  - Affected versions: since guided walks were introduced; found in code review.
- **[Fix]** Live Activity Pause, Resume, and End buttons did nothing on a physical device
  - What was broken: `openAppWhenRun` needed to be `false`; a force-unwrap crash surfaced once buttons fired; the banner's state never refreshed outside SwiftUI's foreground render cycle; the elapsed timer briefly showed a year-4001 value (`Text(timerInterval:)` counts down by default) and then hugged the left edge.
  - What changed: intents push `ActivityContent` updates directly; the timer uses SwiftUI's native live-ticking text with `countsDown: false` and explicit centering.
  - Affected versions: since interactive buttons were added in 1.9 (Unreleased).
- The walk-resume checkpoint file (which holds GPS breadcrumbs) is now excluded from iCloud backup, and write failures are logged instead of swallowed
- The motion-permission description had two conflicting sources (a stale build setting shadowing the correct Info.plist string); the stale copy is removed
- Live Activity's "remaining distance" stat, which showed a misleading "0 ft" for a free session, is hidden — the Dynamic Island shows live pace (or speed) in that slot instead
- Share button's loading spinner now has an accessibility label

### Internal
- Test suite grew from ~70 to 123 tests: snapshot/restore math, session logic, activity vocabulary, pace/speed formatting, auto-pause timing, breadcrumb thinning, personal records, and challenge progress/filtering are all unit-tested; CI gained a language-consistency guard and a report-only SwiftLint step
- Xcode-agent prompts are committed under `prompts/` as an audit trail; the pre-release security and accessibility audit is preserved under `audits/`

---

## [1.9] - 2026-08-28

### Added
- Running is now a first-class activity mode alongside Walking, Cycling, and Indoor — wired through HealthKit workout logging, the activity tile/picker, and the pre-session "want to track this?" suggestion (which already detected running via Core Motion, just wasn't surfaced yet)
- Walks and runs started from a saved route are now linked to that route, with a new Route Detail screen showing every past attempt on it, sorted by date
- Stop-detection during guided sessions: a light "fewer stops than last time" encouragement line, plus a "Still walking?" prompt if you've been stationary for a while (default 3 minutes, adjustable 1–15 min in Settings) so a forgotten walk doesn't keep running in the background
- Driving-detection: sessions where sustained speed or Core Motion's automotive signal suggest you're in a vehicle now show an in-session "Still walking or driving?" banner; if unresolved, the session is flagged and excluded from personal records, route history, and challenge/badge progress (the walk itself is still saved, just not counted)
- Unified activity share card replacing the old pet-walk-only share image — choose Silhouette (route line only, default) or Map (real geography, cropped) style, with an optional App Store link toggle
- Run challenges now support distance and pace goals, not just step counts, with activity-type filtering — existing step-based challenges are unaffected

### Changed
- Activity type on a completed session (Walking/Running/Cycling/Indoor) can now be edited after the fact, in case of a mis-tap when starting

---

## [1.8.1] - 2026-08-26

### Added
- 17 new badges across 6 new categories — Rides (Two Wheels, Century Ride, Pedal Power, Cross Trainer, Road Warrior), Pets (First Walkies, Pack Leader, Paw Prints), Explorer (Cartographer, Community Builder, Trailblazer, Route Scout), Consistency (Rain Check), Collection (Note Taker, Historian, Wockett Giver), Social (Challenge Accepted)
- Live Activity on lock screen now appears during free walks and free rides, not just guided routes
- Tapping the weather chip opens Apple Weather for the full local forecast
- Report and block controls on community route cards, challenge cards, and achievement feed posts — flagged content disappears immediately
- Content filter on all community text (route names, challenge titles, feed messages) prevents profanity and enforces length limits before publishing to CloudKit
- Wocketts received counter — publishing a community route tracks how many upvotes it earns; visible on the badges screen

### Fixed
- Splash screen now appears instantly on cold launch; the dashboard no longer flashes before it
- Force-unwrap crashes removed in the custom route builder, weekly and monthly calendar views, and challenge scheduling
- CloudKit sync now triggers correctly on push notification (resolves a silent background sync failure)
- Control Center start-walk shortcut correctly signals the main app via shared App Group UserDefaults

### Changed
- "Century" badge renamed to "Century Walk" — earned state is preserved; "Century Ride" (100 km cycled) is now a separate badge
- Weather temperatures display as whole numbers throughout the app

---

## [1.7] - 2026-08-24

### Added
- Real step counting via CMPedometer during walks (replaces distance-estimated steps)
- Cadence display (steps/min) in walk HUD
- Hourly weather forecast strip (next 6 hours) on home screen weather chip and route finder weather widget
- `WalkSession.steps` field persists actual pedometer count; older sessions fall back to distance estimate automatically
- WocketWidget extension: home screen widget, Live Activity on lock screen during walks, Control Center shortcut (iOS 18+)
- `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates` added to Info.plist — lock screen walk tracking now works
- Walk Reminders via EventKit: schedule recurring walk reminders from Settings
- Activity detection banner on home screen — suggests starting a walk when motion is detected
- Fun Stats card: total distance expressed as Golden Gate Bridge crossings, marathons, Empire State Building climbs, and % around Earth
- Milestone markers every 1 km on routed walks
- `PrivacyInfo.xcprivacy` privacy manifest

### Changed
- WeatherKit attribution link corrected to `weatherkit.apple.com/legal-attribution.html`
- Weather chip now shows denied / failed / retry states instead of silently disappearing
- Location permission requested on first launch so weather chip appears for new users
- Map zoom range expanded to 30 m – 50 km (was capped at 600 m)
- `NSMotionUsageDescription` updated to reflect CMPedometer usage
- `NSCalendarsWriteOnlyAccessUsageDescription` added (required for iOS 17+ calendar write access)
- Firebase removed — crash reporting and analytics now provided by App Store Connect and MetricKit natively; reduces binary size ~15–20 MB and simplifies privacy declarations

### Fixed
- Force unwrap crashes: `allCoords.last!`, `lens.last!`, `GaitMetricConfig.all.first!`, centroid division-by-zero on empty waypoints
- `BackgroundTaskManager`: replaced strong self and force casts (`as!`) with `[weak self]` and safe `as?` casts
- SwiftData `@Model` properties all have default values (CloudKit compatibility requirement)
- AppModelContainer: four-tier fallback (CloudKit → local → wipe+retry → in-memory); no more `try!` on non-memory paths
- Step dashboard now re-reads HealthKit after a walk completes
- `print()` statements wrapped in `#if DEBUG` to keep production logs clean

---

## [1.6] - 2026-08-10

### Added
- Walk HUD with live step count, distance, duration, and pace
- Walk pause / resume
- POI map during walks (nearby points of interest)
- Pet walk tracking — walk with pets, track their steps and streaks
- Personal records (PRs) — fastest pace, longest walk, most steps in a day
- Streak nudge notifications
- Background location tracking (screen-off)
- Crashlytics crash reporting (later removed in 1.7)

### Fixed
- Walk session persistence — interrupted walks can be resumed

---

## [1.5.1] - 2026-07-27

### Changed
- Route intelligence overhaul: elevation profiles, difficulty badges (Easy → Expert), weather widget in route finder

---

## [1.5] - 2026-07-27

### Added
- Walk session persistence and resume
- Look Around previews for route start points
- Monthly calendar heatmap
- Achievement feed

### Changed
- Splash screen updated to match app icon

---

## [1.4] - 2026-07-26

### Added
- Wocketts (collectible in-app items)
- Badge pinning — pin up to 2 badges to the home screen ring column
- Walk notes — add a note when saving a walk
- Indoor walk mode (stationary, no GPS)
- Animated splash screen (W letterform)

### Changed
- Action grid polish and spacing standardisation

---

## [1.3] - 2026-07-26

### Added
- Bike ride mode with distance and pace tracking
- HealthKit workout saving (distance, calories, GPS route) for walks and rides
- Rolling badge column on home screen cycles through unearned badges
- Map tile style toggle (standard / satellite)

### Fixed
- Smooth view transitions throughout the app
- Ride mode icon and history label

---

## [1.2] - 2026-07-25

### Added
- Streak system with streak badges
- Badge collection with earned/progress rings
- Revolving animated banner
- Manual walk entry
- Calendar week swipe navigation

### Fixed
- App display name shows "Wockett" instead of "PoCSquat"

---

## [1.1] - 2026-07-25

### Added
- Multi-pet support
- Walk navigation (turn-by-turn)
- Route intelligence: nearby route suggestions with distance, elevation, and difficulty
- Step calendar (weekly view with daily breakdown)
- Community route sharing via CloudKit
- Route bookmarking
- Free walk mode with live GPS tracking and walk summary
- 2×2 action grid replacing single start button

---

## [1.0] - 2026-07-24

### Added
- Daily step goal with animated progress ring (reads from Apple Health)
- WeatherKit current conditions on home screen
- Custom route builder with waypoints
- In-app map navigation
- Walk history
- Pet profiles with individual goals
- Privacy policy and App Store submission

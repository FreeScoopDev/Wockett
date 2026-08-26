# Changelog

All notable changes to Wockett are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- CloudKit push notification mode: added `remote-notification` to `UIBackgroundModes` — resolves "BUG IN CLIENT OF CLOUDKIT" warning and enables proper CloudKit sync via push
- Widget control center intent now writes to shared App Group UserDefaults so the main app can receive the start-walk signal

### Changed
- Weather temperatures now display as whole numbers (no decimal places) in home chip and route weather widget

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

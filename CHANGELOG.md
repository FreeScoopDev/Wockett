# Changelog

All notable changes to Wockett are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- UI smoke test target (5 XCUITest tests) covering launch, tab navigation, walk lifecycle, the active-walk accessory, and Routes reachability; launch argument `-WKTUITest` enables deterministic mode (no animations, no permission dialogs, seeded demo data)
- CI runs the UI smoke tests in their own job, so a navigation/layout regression is distinguishable at a glance from a logic failure; the unit-test job is pinned to `WockettTests` so it stays fast

### Fixed
- SwiftData no longer initialises CloudKit mirroring during test runs. `ModelContainer(...)` returns successfully and CoreData then sets CloudKit up *asynchronously*, trapping rather than throwing when no iCloud entitlement is present — which is the case in CI, where code signing is disabled. The existing `try?` fallbacks in `AppModelContainer` could not catch a trap on another queue, so the host app died ~3 s into every test run.
- Marker views the UI tests rely on (`home.statCard`, the tab roots, session and summary roots, the Routes results panel) are now real accessibility containers via `.accessibilityElement(children: .contain)`. No change for VoiceOver users — children remain individually accessible — but without it a plain SwiftUI container carrying only an identifier never appears in the accessibility tree at all.
- CI now discovers an available iPhone simulator at runtime (`scripts/ci_pick_simulator.sh`) instead of hardcoding `name=iPhone 17`. The two jobs run on two different runner VMs whose simulator sets can differ, which is how the unit job passed and the UI job failed in 79 s on the identical destination specifier, before a single test ran.
- Two modal screens were silently blocking almost every UI test. The seeded demo history immediately awarded the "First Steps" badge, whose celebration is a `fullScreenCover` that covers the tab bar; and a test that terminates the app mid-walk leaves a checkpoint behind, so the next launch opened straight into the modal "Resume Your Activity?" alert. Underlying views still satisfy `exists` queries beneath a cover, which is why the tests failed on taps rather than on the assertions that came first. Under `-WKTUITest` the celebration is no longer presented and a stale checkpoint is discarded instead of prompted. Both guards compile out of release builds, so shipping behaviour is unchanged.
- `testRoutesReachable` asserted that the Start Walk button existed as soon as routes were generated. It never did: `startWalkButton` is gated on `selectedRoute`, which only a tap on a `RouteCard` sets, so the test was checking for behaviour the app was never designed to have. The test now selects a route first, and route cards carry a `routes.routeCard` identifier so it can. The button's hittability check — the guard against the v1.10 tab-bar clipping regression — is unchanged.
- Fixed a latent crash in `coordAlong`, the helper that finds a coordinate a given fraction along a route line (duplicated in `RouteFinderMapView` and `NavigationMapView`). Its fallback read `polyline.points()[0]`, and `points()` is an unchecked C array — on a polyline with zero points that reads past the end and traps the process rather than returning nil. `MKDirections` can return a degenerate route when there is no walkable path, the location fix is poor, or connectivity is bad, so this was reachable in ordinary use. Empty polylines now return nil, which every call site already handles. Covered by new unit tests in `PolylineGeometryTests`.

## [1.10] - 2026-09-01

### Added
- Five-slot tab bar (Health · Routes · Home · Community · Settings) with the Wockett waypoint as the custom Home tab icon (wkt.home.pin vector imageset)
- Routes tab: RouteFinderContentView is now a first-class tab root — no fullScreenCover or state juggling in StepCounterView; route discovery is always one tap away
- WktSymbol enum + `.wktIcon()` modifier as the single catalogue for every icon in the app; `Image(wkt:)` initializer dispatches to asset catalog or SF Symbols automatically
- Unified v1.10 design system, rolled out across the whole app: a 3-tier typography hierarchy (Display / Heading-Body / Technical, using SF Pro Rounded + tracked SF Mono) and per-activity accent colors (Run/Ride/Indoor, alongside the existing Walk green) now apply consistently to the Dashboard, Active Session, Badges, Settings, the Home Screen widget, and the Live Activity — previously only a handful of screens used the shared tokens and most call sites had their own one-off font/color choices
- Dashboard restructured to match the design: four direct-select activity tiles (Walk/Run/Ride/Indoor) replace the old action grid, a new dashed "Find a Route" tile folds in route discovery, the stat card shows goal progress/steps/distance/streak together, and pets are promoted to their own "Crew" card
- Map polylines and guided-route waypoint markers now color by the session's activity mode (previously only cycling had its own color; everything else silently drew as walking-green)
- Custom (built) routes now remember the activity mode they were built for; the Start screen shows a walk/run/ride chip row defaulted to that mode, changeable per-launch without altering the route's saved default
- App and widget/Live Activity now read colors and fonts from one shared `DesignSystem.swift` file (dual target membership) instead of the widget keeping its own separate, non-adaptive palette — incidentally fixes the widget's background being hardcoded dark regardless of system theme, and the Live Activity's progress bar/dividers being nearly invisible in light mode
- Bottom tab bar — Home, Health, Community, and Settings are now top-level tabs instead of everything living on one dashboard with a dozen pop-up sheets; the tab bar tucks away as you scroll on iPhone and adapts to a sidebar/top-tab layout on iPad
- Community hub: streaks & badges, the achievement feed, challenges, and community routes now have a permanent home in the Community tab, with the streak on the dashboard jumping straight to your badges
- Health hub: recovery metrics (sleep / readiness / active calories), gait detail, the weekly and monthly calendar, lifetime stats, and activity history now live in the Health tab

### Changed
- Activity icons updated to HealthKit-aligned SF Symbols: `figure.outdoor.cycle` for cycling, `figure.walk.treadmill` for indoor (previously `bicycle` / `figure.walk.motion`)
- Settings tab icon changed from `gearshape` to `slider.horizontal.3`; Community tab icon changed from `person.2` to `pawprint`
- Full WCAG contrast audit across every design-system color token, in both light and dark mode: fixed `accentNotice`'s illegible light-mode value, then — more substantially — split every accent color that's used as a solid button/toggle/marker fill into two variants: the original bright value for text and icons, and a new, separately-tuned "Fill" value for white content sitting on top of a solid fill. A single color value can't serve both roles well at once (bright enough to read as text, dark enough for white content on top to read well); this removes that trade-off everywhere it showed up — roughly 50 call sites across 20 files (buttons, selected chips, toggles, the guided-nav map's markers)
- Settings is a tab rather than a sheet behind the gear icon; the active-walk tile now floats above the tab bar and stays visible on every tab, and tapping it reopens the session from anywhere
- Dashboard trimmed to the at-a-glance hub: activity tiles, Find a Route, the stat card, the Crew, journey track, weather, and the close-the-gap card — sections that duplicated the new tabs were removed, along with leftover dead layout code from the earlier dashboard rebuild
- Shared data stores (steps, routes, history) are created once at app launch and shared across screens instead of each screen keeping its own copy — seeded demo data and edits now show up immediately without relaunching

### Fixed
- Routes tab bottom sheet no longer clipped by the tab bar: panels are presented via `.safeAreaInset(edge: .bottom)` on the map so the config and results sheets sit above the tab bar rather than beneath it
- Icon-only buttons now have VoiceOver labels (29 sites: navigation controls, toolbar actions, toggle buttons, route save/share, session controls)
- Text and icons now scale with the user's preferred text size; capped at Accessibility 2 so tiles and the tab bar remain usable at the largest sizes
- Blank capsule bar appearing when no walk is active — `tabViewBottomAccessory(isEnabled:)` completely hides the capsule when idle instead of leaving an empty slot
- Active walk tile chrome (background material, corner radius, shadow, outer padding) stripped — the system capsule provides the container; tile renders a compact inline form when the tab bar is minimised
- Several flat, non-adaptive color literals that had drifted from the shared design tokens over time — scattered across ~15 files (map pins, chip borders, a milestone-marker teal, POI category colors) — consolidated back onto the light/dark-adaptive tokens they were supposed to match
- Build error after custom routes gained a saved activity mode: `ActivityMode` needed to conform to `Codable` for `CustomRoute`'s automatic Encodable/Decodable synthesis to work
- The route-finder results panel sized itself against the physical device screen instead of its own window, which can misbehave in iPad multitasking (Split View, Slide Over, Stage Manager) where the app's window is smaller than the screen; now reads its actual container size
- Minor build-warning cleanup: three unused local values removed (no behavior change)
- Badges had lost their dedicated entry point in the dashboard rebuild (only reachable by tapping the streak number); they now have a proper home in the Community tab
- Community routes were unreachable until you ran a route search, and then sat at the bottom of the results panel; they're now a first-class screen in the Community tab, reachable on a fresh launch

## [1.9] - 2026-08-31

### Added
- Running is now a first-class activity mode alongside Walking, Cycling, and Indoor — wired through HealthKit workout logging, the activity tile/picker, and the pre-session "want to track this?" suggestion (which already detected running via Core Motion, just wasn't surfaced yet)
- Walks and runs started from a saved route are now linked to that route, with a new Route Detail screen showing every past attempt on it, sorted by date
- Stop-detection during guided sessions: a light "fewer stops than last time" encouragement line, plus a "Still walking?" prompt if you've been stationary for a while (default 3 minutes, adjustable 1–15 min in Settings) so a forgotten walk doesn't keep running in the background
- Driving-detection: sessions where sustained speed or Core Motion's automotive signal suggest you're in a vehicle now show an in-session "Still walking or driving?" banner; if unresolved, the session is flagged and excluded from personal records, route history, and challenge/badge progress (the walk itself is still saved, just not counted)
- Unified activity share card replacing the old pet-walk-only share image — choose Silhouette (route line only, default) or Map (real geography, cropped) style, with an optional App Store link toggle
- Run challenges now support distance and pace goals, not just step counts, with activity-type filtering — existing step-based challenges are unaffected
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
- Activity type on a completed session (Walking/Running/Cycling/Indoor) can now be edited after the fact, in case of a mis-tap when starting
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
  - Affected versions: 1.8.1–1.9.
- **[Fix]** Walks ended manually (rather than by reaching the route's actual endpoint) were silently discarded instead of saved to history
  - What was broken: every manual "end early" path called `session.stop()` without writing the session to history; only completing a route saved anything.
  - What changed: every manual exit saves by default through one shared method, with an explicit "Discard" as the only way to lose data on purpose.
  - Affected versions: since guided walks were introduced; found in code review.
- **[Fix]** Live Activity Pause, Resume, and End buttons did nothing on a physical device
  - What was broken: `openAppWhenRun` needed to be `false`; a force-unwrap crash surfaced once buttons fired; the banner's state never refreshed outside SwiftUI's foreground render cycle; the elapsed timer briefly showed a year-4001 value (`Text(timerInterval:)` counts down by default) and then hugged the left edge.
  - What changed: intents push `ActivityContent` updates directly; the timer uses SwiftUI's native live-ticking text with `countsDown: false` and explicit centering.
  - Affected versions: since interactive buttons were added in 1.9.
- The walk-resume checkpoint file (which holds GPS breadcrumbs) is now excluded from iCloud backup, and write failures are logged instead of swallowed
- The motion-permission description had two conflicting sources (a stale build setting shadowing the correct Info.plist string); the stale copy is removed
- Live Activity's "remaining distance" stat, which showed a misleading "0 ft" for a free session, is hidden — the Dynamic Island shows live pace (or speed) in that slot instead
- Share button's loading spinner now has an accessibility label

### Internal
- Test suite grew from ~70 to 123 tests: snapshot/restore math, session logic, activity vocabulary, pace/speed formatting, auto-pause timing, breadcrumb thinning, personal records, and challenge progress/filtering are all unit-tested; CI gained a language-consistency guard and a report-only SwiftLint step
- Xcode-agent prompts are committed under `prompts/` as an audit trail; the pre-release security and accessibility audit is preserved under `audits/`

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

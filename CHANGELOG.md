# Changelog

All notable changes to Wockett are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Internal
- Notifications have an owner. `NotificationService` (`Services/Core`) is the single place that requests permission, registers categories, and schedules or cancels every notification the app sends, each behind a stable identifier from `NotificationKind`. Scheduling logic used to live in six files with three separate permission requests and two identifier strategies; hydration and route reminders were `UUID`s and could never be cancelled. The service sits behind a `NotificationCentering` seam so it is unit-tested against a fake center — the first tests this feature has had (13). The delegate now snapshots the Sendable fields of a delivered notification before hopping to the main actor, so no non-Sendable `UNNotificationContent` crosses an isolation boundary. No notification copy or timing changed.
- `scripts/test.sh` takes its pass/fail counts from the xcresult bundle (`xcrun xcresulttool get test-results summary`) instead of the xcodebuild log, and requires xcodebuild's exit code, its `** TEST SUCCEEDED **` line, and the bundle's result to agree. On 2026-09-09 a run of 146 with no failures was reported as 145: one test-result line in the log had lost its `passed` suffix. The first explanation, stderr interleaving, was disproved when it recurred with stderr split to its own file; the second, truncation of the final line, was disproved when it recurred on a line that was not last. What is established is narrower: during parallel testing xcodebuild can write session-level output mid-way through a result line, so the log is not a counter. The bundle is structured and is what Xcode Cloud reads. When the log's line count differs from the bundle the script says so as information, not alarm. stderr is still kept separate for readability.
- `CLAUDE.md` and `docs/ci.md` updated for the SwiftLint job becoming a required check: `main` now has three required checks, not two, and the job table and reading guidance no longer describe it as `continue-on-error`.
- Cleared all 32 error-severity SwiftLint violations and made the CI job blocking. Of the 26 force-unwraps, eleven were `Calendar` arithmetic (`date(byAdding:)!`, `range(of:in:for:)!`, `nextDate(...)!`) that only return nil under pathological calendar setups — each now falls back to the date it was computed from, identical in every real case and non-crashing in the impossible one. Two in `NavigationSession` were guaranteed by the line above (`if x == nil { x = now }` then `x!`); restructured so the compiler sees the guarantee instead of trusting it. Four in `NearbySearchViews` (`min()!`/`max()!` on a polyline's points) were already guarded by `ptCount > 1` but are now a `guard let` — an empty polyline is exactly the `coordAlong` crash class fixed earlier in this release, and the guard should be visible at the site. Two `cumulative.last!` in the share-card cropper now use a running total. Four `randomElement()!` on literal arrays got literal fallbacks. The two in `ActiveSessionView` are correct — `body` renders nothing unless `walkStore.session != nil`, and `ActiveWalkStore` writes and clears `session`/`activeRoute` together at every site — so they are annotated with that invariant rather than rewritten; it was real but had never been written down. The `force_cast` in the notification snooze path is now `as?` with `break`, which still reaches the `completionHandler()` iOS requires. The `force_try` on the final in-memory `ModelContainer` fallback is now an explicit `do/catch` + `fatalError` carrying the error: same trap, since a broken schema has no runtime recovery, but the crash log now says why. `large_tuple` and `function_parameter_count` were disabled in `.swiftlint.yml` — style rules from the same family as the four size rules already off, never opted in, four hits in dev seed data. The gate was break-tested before `continue-on-error` came off: a planted force-unwrap is reported as an error. Note the SwiftLint job is not yet in the ruleset's required checks, so it goes red but does not block a merge until it is added there. Follow-up the same day: CI reported exactly one remaining force-unwrap that a local run of the identical SwiftLint 0.65.1 could not reproduce, and the job log carries no file or line. The check-run annotations API does: `HomeWeatherView.swift:91`, `URL(string: "…")!` on the WeatherKit attribution link — the only line of that shape in the codebase. Made optional with an `if let`, keeping the attribution label present in the else branch since WeatherKit's terms require it. A first attempt wrongly blamed a `#Preview` lint-suppression comment in `BadgeEarnedView`; that change stays as an improvement (a plain `if let` needs no exemption) but was not the cause. Local and CI SwiftLint can disagree on this rule at the same version; CI is the arbiter, and the fix is to remove the unwrap, never to annotate it.
- Turned on `SWIFT_STRICT_CONCURRENCY = targeted` and cleared everything it reported. The project already sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` but compiled with no concurrency checking at all, so 89 unstructured `Task { }` sites across HealthKit callbacks, Core Motion, CloudKit and Live Activity updates were unverified by the compiler — the bug class that surfaces as rare, unreproducible corruption. Two fixes: three pure static helpers in `RecoveryService` (`asleepValueSet`, `sumAsleepSeconds`, `mergeAndSum`) are now `nonisolated`, since they touch no actor state and run from HealthKit query callbacks on a background queue; and `locationManagerDidChangeAuthorization` no longer captures the `CLLocationManager` itself inside a `@Sendable` closure — it reads `authorizationStatus` on the delegate's queue and sends only that value. The latter is an error rather than a warning under the Swift 6 language mode, and `didUpdateLocations` two methods above already did exactly this, so the file's own idiom had drifted in one place. Verified by reintroducing the bad capture on purpose and confirming the warning returns.
- Added `scripts/test.sh` and `scripts/lint.sh` as the canonical ways to run the suite and the linter, plus a `Verifying claims` section in `CLAUDE.md` and a PR template. These exist because several claims made during the 2026-09-06/07 review turned out to be wrong in the same way: a cheap check was available and reasoning was used instead. `xcodebuild test | tail` returns `tail`'s exit code, so a failed run reports success; the `PoCSquat` scheme runs `WockettUITests` as well as `WockettTests` and Xcode Cloud uses "Use Scheme Setting", so `-only-testing:WockettTests` is a smaller suite than CI; and SwiftLint resolves `excluded:` relative to the config file's own directory, so `--config` pointing elsewhere silently lints the excluded targets and inflates every count. `scripts/test.sh` runs the full scheme by default and checks for the literal `** TEST SUCCEEDED **`; `scripts/lint.sh` refuses to report numbers unless it can prove the exclusions took effect, with the expected list hardcoded rather than read from the config it is verifying — a check that derives its expectations from the thing it checks passes vacuously, which is the same failure as an assertion that cannot fail. Both guards were verified by breaking them on purpose.
- SwiftLint runs in CI again. `.swiftlint.yml` was added on 2026-08-30 with `force_unwrapping`, `force_cast` and `force_try` set to `error`, but the step that executed it lived in `tests.yml`, which the 2026-09-04 Xcode Cloud migration deleted along with the macOS jobs. From that date the config existed and nothing ran it, so the guard against the crash class it was written for was silently absent. It is back in `guards.yml` on the 1x Linux runner (SwiftLint needs a Swift toolchain, not Xcode, so it does not belong on a 10x macOS runner) and is deliberately non-blocking for now — the first runs are there to report the real force-unwrap count before the rule starts gating merges.
- Removed four `INFOPLIST_KEY_NS*UsageDescription` build settings from the app target. They duplicated keys that `PoCSquat/Info.plist` already defines, and two of them had drifted to different wording than the file — the build-setting location string omitted the disclosure that route coordinates are sent to opentopodata.org, and one was a leftover from the squat-counter prototype declaring a camera permission "to detect your body position and count squat and push-up reps". Verified against a built product that none of them were reaching the app: the target sets `GENERATE_INFOPLIST_FILE = NO`, so `INFOPLIST_KEY_*` settings are inert and `Info.plist` was always the source of truth — `NSCameraUsageDescription` does not appear in the built `Info.plist` at all. No shipped behaviour or permission prompt changes. This is the same duplicate-source problem that was diagnosed and fixed for the motion string during the 1.9 compliance pass, applied to the remaining four rather than one at a time.
- Added `docs/ci.md`, a written reference for what CI actually does. The Xcode Cloud half of the pipeline is configured in App Store Connect and has no workflow-as-code format, so since the 2026-09-04 migration the definition of what gates `main` has lived in a web UI and nowhere else — unreviewable, undiffable, and unrecoverable if edited. The file records both workflows (`CI Tests`, `Release Flow`), how to read the non-blocking SwiftLint result without misreading its green tick, and two SwiftLint autocorrect rules that break this codebase's build.
- Tuned `.swiftlint.yml` so the rules it exists for are actually visible. `colon` and `comma` were 669 of 863 violations and in this codebase almost all of them are deliberate column alignment in property blocks, so they buried everything else; `redundant_discardable_let` is wrong inside a `@ViewBuilder`, where `let _ = x` is a declaration the builder skips and the bare `_ = x` it wants is a statement of type `()` the builder tries to render; and `empty_count` flagged `alert.buttons.count > 0` in the UI tests, which cannot be rewritten as the rule asks because `XCUIElementQuery` has no `isEmpty` — at `error` severity that would have blocked merges on correct code. With those off the count is 191, and the 32 error-severity violations are the crash class the config was written for: 26 force-unwraps, 1 `force_try`, 1 `force_cast`, plus 3 `large_tuple` and 1 `function_parameter_count`. No source files were touched. Also documented that `excluded` paths resolve relative to the config file's own directory, which is why running SwiftLint with `--config` pointed elsewhere silently lints the test targets.

### Added
- UI smoke test target (5 XCUITest tests) covering launch, tab navigation, walk lifecycle, the active-walk accessory, and Routes reachability; launch argument `-WKTUITest` enables deterministic mode (no animations, no permission dialogs, seeded demo data)
- CI runs the UI smoke tests in their own job, so a navigation/layout regression is distinguishable at a glance from a logic failure; the unit-test job is pinned to `WockettTests` so it stays fast

### Changed
- In-walk notifications — water breaks, checkpoints, auto-pause, route events and the hydration nudge — are now delivered as Time Sensitive, so they break through a Focus mode. The user started the walk; a "drink now" or "you're off route" that waits until Focus ends is worthless. The streak nudge, pet nudge and route reminders stay at the normal level (that's Wockett interrupting, not the walk), and the weekly recap stays passive. The mapping is one exhaustive switch keyed on `NotificationKind`, so a future kind has to choose. Requires the entitlement from the previous change; without it iOS quietly delivers at the normal level.
- Time Sensitive Notifications entitlement added to the app target (`com.apple.developer.usernotifications.time-sensitive`). Added through Xcode's Signing & Capabilities with automatic signing, which also registers the capability on the App ID — adding the key to the plist by hand does not, and Xcode Cloud then fails to sign. No code sets `.timeSensitive` yet; the next notifications PR flips the in-session kinds (water breaks, checkpoints, auto-pause, route events) to it, and only those — it breaks through Focus, so it stays off the streak nudge and the weekly recap.
- Starting a guided session no longer shows the notification permission prompt. It asks for quiet delivery instead; the real prompt is reserved for moments the user asks for something — enabling water breaks, setting a route reminder, or a Settings toggle.
- Minimum iOS version lowered from 26.5 to 26.1. Nothing in the codebase required 26.5 — the highest floor any API actually imposes is `tabViewBottomAccessory(isEnabled:content:)`, which is iOS 26.1, and a build at 26.0 fails on that one call and nothing else. The previous value appears to have followed the installed SDK rather than a decision, and it excluded everyone on 26.1 through 26.4 who had not taken the latest point update. Verified by building the app and running the unit suite at 26.1.
- Routes results panel: the weather tile is now a single compact row — icon, temperature, condition and the conditions verdict — that expands to the hourly forecast on tap. The panel itself grew from 35% to 45% of screen height. Previously a fresh route search filled the panel with a full-height weather card and one partially visible route card, putting the route list and Start Walk below the fold on the screen whose entire purpose is picking a route. Apple's required WeatherKit attribution stays visible in the collapsed state.

### Fixed
- **[Fix]** Weekly summary, streak nudge and pet nudge never fired for anyone who had not enabled water breaks
  - What was broken: all three ambient notifications bailed unless permission was already `.authorized`, and the only code that ever *asked* for permission was three in-session features (session start, water breaks, the route scheduler). Settings never asked — at `.notDetermined` it showed "Disabled" and linked to iOS Settings, where an app that has never requested may not be listed. On a fresh install, a user who didn't switch on water breaks never received a single ambient notification, and could not fix it from Settings.
  - What changed: the app requests quiet (`.provisional`) delivery once at first launch, so ambient nudges reach Notification Center silently by default; the ambient guards now accept provisional delivery; and Settings can prompt for full alerts itself — a "Turn On Alerts" row, and switching any notification toggle on while delivery is quiet triggers the real prompt. The iOS Settings link is now shown only after an actual denial, the one case it can help with.
  - Affected versions: since the weekly summary and streak nudge shipped (1.6); the pet nudge since it was added.
- The pet walk nudge can be switched off. Its `notif_petNudge` preference key existed but had no Settings toggle; it also had no notification category, so it carried no action buttons. Both added.
- Post-walk hydration reminders and "schedule this route" reminders are cancellable and replace themselves — they used random identifiers, so three walks in an hour stacked three hydration pings, and scheduling the same route twice queued two reminders.
- "Start Walk" on a streak or pet nudge now does something: it lands on Home and, if a session is already running, reopens it. It previously only foregrounded the app. "Done" on a water-break or hydration reminder now clears it and any snooze of it; it was styled as a destructive action and did nothing.
- Notifications that arrive while the app is open no longer banner over the dashboard unless they belong to the active session. The Sunday recap goes quietly to the list.
- `testRoutesReachable` no longer claims to guard against tab-bar clipping. Two successive versions of that assertion were written, and both passed green against a deliberately broken layout. Measured on an iPhone 17: every candidate element in both Routes panels sits 90–101pt above the tab bar with no scrolling at all, so `isHittable` is true whatever the padding does. The test now stops at the functional check — selecting a route reveals Start Walk — and states in a comment that the below-the-fold regression it was meant to catch is a visual problem requiring snapshot tests, not XCUITest. An assertion that cannot fail is worse than no assertion, because it gets counted as coverage.
- SwiftData no longer initialises CloudKit mirroring during test runs. `ModelContainer(...)` returns successfully and CoreData then sets CloudKit up *asynchronously*, trapping rather than throwing when no iCloud entitlement is present — which is the case in CI, where code signing is disabled. The existing `try?` fallbacks in `AppModelContainer` could not catch a trap on another queue, so the host app died ~3 s into every test run.
- Removed a phantom "tab-bar clipping" fix from both Routes panels. Each padded its content by the bottom safe-area inset *on top of* `.safeAreaInset(edge: .bottom)`, which already places its content inside the container's safe area even though the map beneath it calls `.ignoresSafeArea()` — the real fix for this shipped in 1.10 and was still working. Measured on an iPhone 17: with the extra inset the config panel's bottom row sat 101pt above the tab bar instead of 18pt, an empty band rather than a fix; on the results panel it had no measurable effect at all, because it sits below the content inside a scroll view and can only add trailing scroll space. Neither panel was ever clipped. What fixed the "cards cut off" report was the 45% panel height and the compact weather tile, both in the same commit.
- `WeatherWidget` no longer keeps `initiallyExpanded` as a stored property. It seeds `@State` once in `init` and is otherwise unread; SwiftUI `@State` initialised from a parameter does not track later changes to that parameter, so keeping it around read as live configuration while silently ignoring updates.
- Apple's required WeatherKit attribution now has higher layout priority than the conditions label in the collapsed weather row, so it is not the element that truncates at large Dynamic Type sizes.
- Marker views the UI tests rely on (`home.statCard`, the tab roots, session and summary roots, the Routes results panel) are now real accessibility containers via `.accessibilityElement(children: .contain)`. No change for VoiceOver users — children remain individually accessible — but without it a plain SwiftUI container carrying only an identifier never appears in the accessibility tree at all.
- CI now discovers an available iPhone simulator at runtime (`scripts/ci_pick_simulator.sh`) instead of hardcoding `name=iPhone 17`. The two jobs run on two different runner VMs whose simulator sets can differ, which is how the unit job passed and the UI job failed in 79 s on the identical destination specifier, before a single test ran.
- Two modal screens were silently blocking almost every UI test. The seeded demo history immediately awarded the "First Steps" badge, whose celebration is a `fullScreenCover` that covers the tab bar; and a test that terminates the app mid-walk leaves a checkpoint behind, so the next launch opened straight into the modal "Resume Your Activity?" alert. Underlying views still satisfy `exists` queries beneath a cover, which is why the tests failed on taps rather than on the assertions that came first. Under `-WKTUITest` the celebration is no longer presented and a stale checkpoint is discarded instead of prompted. Both guards compile out of release builds, so shipping behaviour is unchanged.
- `testRoutesReachable` asserted that the Start Walk button existed as soon as routes were generated. It never did: `startWalkButton` is gated on `selectedRoute`, which only a tap on a `RouteCard` sets, so the test was checking for behaviour the app was never designed to have. The test now selects a route first, and route cards carry a `routes.routeCard` identifier so it can. The trailing hittability check has since been removed; see below.
- Fixed a latent crash in `coordAlong`, the helper that finds a coordinate a given fraction along a route line (duplicated in `RouteFinderMapView` and `NavigationMapView`). Its fallback read `polyline.points()[0]`, and `points()` is an unchecked C array — on a polyline with zero points that reads past the end and traps the process rather than returning nil. `MKDirections` can return a degenerate route when there is no walkable path, the location fix is poor, or connectivity is bad, so this was reachable in ordinary use. Empty polylines now return nil, which every call site already handles. Covered by new unit tests in `PolylineGeometryTests`.
- The Routes smoke test is now deterministic and offline: under `-WKTUITest` route generation returns a fixed stub instead of calling MKDirections, and the community-routes fetch is skipped, so the test can't fail because a CI runner had flaky network. All five UI smoke tests now pass locally.
- Raised the UI smoke test timeouts that follow a map-bearing screen. The same commit passed 5/5 on a developer Mac while `testTabNavigation` failed 3/3 on a GitHub macOS runner waiting for the Community tab, and one `testAccessoryBar` attempt took 162 s — a shared CI VM is several times slower, and 10–15 s waits were marginal there rather than wrong. A smoke test should fail when a screen is broken, not when the machine is having a bad minute.
- UI smoke tests no longer fail on a stray notification banner. Since #19, starting a walk makes a silent `.provisional` request that the simulator grants, so the test build could render session banners — and the smoke tests' interruption monitor, written for permission alerts, tapped a banner that had already gone. Session start now skips the request under `-WKTUITest` (as launch already did) and the monitor ignores anything that isn't an alert. Before #19 the monitor answered the old prompt "Don't Allow", which is why this never showed up.

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

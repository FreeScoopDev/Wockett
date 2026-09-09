# Wockett — project memory

Read this first. It exists so each session doesn't re-derive the same facts.
Written 2026-09-05. Correct it when it goes stale — a wrong note is worse than none.

## What this is

**Wockett** — iOS walking/running/cycling app with pet step tracking. Live on the
App Store (Apple ID 6794364736), US and Canada only. Solo project; Joe is not a
developer by trade and asks for the reasoning, not just the command.

**The repo is called `PoCSquat`, and so are the app target and the scheme.** The
product is Wockett. This is legacy naming from a prototype. Renaming would risk
signing, entitlements, the widget bundle ID and the App Store record for zero
user benefit — scored and deliberately declined. Don't "fix" it.

| Thing | Name |
| --- | --- |
| GitHub repo | `FreeScoopDev/Wockett` |
| Local folder | `~/Desktop/PoCSquat` |
| App target / scheme | `PoCSquat` |
| Widget + Live Activity | `WocketWidgetExtension` (one `t`) |
| Unit tests | `WockettTests` |
| UI tests | `WockettUITests` |

Zero third-party dependencies — every import is an Apple framework. Keep it that
way unless there's a strong reason; adding the first one is a real decision.

## Non-obvious things that have already cost time

- **`Versions.xcconfig` owns version and build numbers.** Never edit them in
  per-target build settings. `Info.plist` resolves `CFBundleVersion` from
  `$(CURRENT_PROJECT_VERSION)`, so that key must stay defined.
- **Xcode Cloud ignores the build number** and auto-increments its own. A manual
  Xcode archive uses the file's value verbatim. App Store Connect is
  authoritative for what shipped. 1.10 went out as build 24 while the file said
  23 — provenance of that build was never established.
- **CloudKit traps, it doesn't throw.** `ModelContainer(...)` with a
  `cloudKitDatabase:` config returns fine, then CoreData sets CloudKit up
  *asynchronously* and traps on failure. `try?` cannot catch that. This killed
  every CI test run for days. `AppModelContainer.isRunningUnderTests` skips it.
- **`.safeAreaInset` already respects the safe area** even when the view it is
  attached to calls `.ignoresSafeArea()`. The modifier places its content inside
  the container's safe area regardless; `.ignoresSafeArea()` governs the view
  underneath. This entry previously claimed the opposite, and that wrong belief
  produced two commits of `padding(.bottom, 14 + geo.safeAreaInsets.bottom)` that
  double-counted the inset. Measured on an iPhone 17 (2026-09-05): the Routes
  panels' content already ends at y=791, exactly the top of the tab bar. Do not
  add the inset by hand. If a panel looks cut off, measure before theorising —
  the real cause in v1.10 was content below the fold in a 35%-height panel.
- **An assertion that cannot fail is worse than no assertion**, because it is
  counted as coverage. Two versions of the Routes "clipping" check passed green
  against a deliberately broken layout. Before claiming a test guards something,
  break the thing on purpose and watch the test go red. If it doesn't, the test
  is decorative — say so out loud rather than leaving it in place.
- **`isHittable` cannot see below-the-fold or visual-layout regressions.** Every
  element in both Routes panels sits 90-101pt above the tab bar with no
  scrolling, so hittability is true whatever the layout does. That class of bug
  needs snapshot testing (`fastlane snapshot`, still on the backlog).
- **Modal screens silently break UI tests.** A `fullScreenCover` still lets views
  beneath it satisfy `exists` queries — so tests fail on *taps*, not on the
  assertions that came first. Two of these (badge celebration, resume-walk
  alert) are suppressed under `-WKTUITest`.
- **Notification banners wake the UI-test interruption monitor.** The monitor
  exists for permission alerts; a banner also arrives there, and tapping one
  that has slid away fails the test at the tap, not at any assertion. The app
  must never hold notification authorization under `-WKTUITest` (launch and
  session start both skip the request), and the monitor ignores non-alerts.
  Cost a CI run on 2026-09-09.
- **The iOS Simulator has no Health app**, so HealthKit is always empty there.
  Step rings read 0. Expected, not a bug.

## Conventions

- **Icons** go through `WktSymbol` + `.wktIcon()`. No hardcoded `systemName:`
  strings (there are currently zero — keep it that way). Variable-driven
  `systemName:` from a model property is fine and intended.
- **Colours and fonts** come from `DesignSystem.swift`, which has dual target
  membership so the widget can't drift. There are ~164 legacy raw
  `.font(.system(size:))` sites; fix opportunistically, don't sweep.
- **Shared UI components look the same everywhere they appear.** Joe's explicit
  standard (2026-09-04). If a component gains a variant, roll it to every screen
  that uses it rather than keeping two.
- **`CHANGELOG.md` entry ships with the change**, in the same commit, explaining
  *why* — not just what. Keep a Changelog format.
- **Accessibility identifiers** on marker views need
  `.accessibilityElement(children: .contain)` or they never reach the
  accessibility tree. UI tests depend on: `home.statCard`, `home.tile.walk`,
  `session.root`, `session.minimize`, `session.finish`, `summary.root`,
  `summary.done`, `accessory.miniTile`, `health.root`, `community.root`,
  `settings.root`, `routes.findRoutes`, `routes.resultsPanel`,
  `routes.routeCard`, `routes.startWalk`, `routes.weatherTile`.
- **Tab bar buttons are addressed by visible title**, not identifier — iOS 26
  discards `.accessibilityIdentifier` on `Tab`.
- **Notifications go through `NotificationService`.** It owns permission,
  categories, and every schedule/cancel, each behind a stable identifier in
  `NotificationKind`. Don't call `UNUserNotificationCenter` directly outside it;
  the one exception is the delegate assignment at launch. Quiet (`.provisional`)
  delivery is requested once at first launch. The real prompt belongs to moments
  the user asks for something — a Settings toggle, water breaks, a route
  reminder. Any guard on delivery must accept `.provisional`, or quiet delivery
  is a no-op; that was the dead-end fixed on 2026-09-09.

## Process

`main` is protected: no direct pushes, no force-push, no deletion, and three
required checks (`Wockett | CI Tests | Test - iOS`, `Language-consistency
guard`, and `SwiftLint` — the last added 2026-09-09 once its error-severity
backlog reached zero). One change per branch; `feat/`, `fix/` or `chore/` prefix. Merge
`origin/main` into the branch *before* opening the PR. Squash-merge.

Testing runs on **Xcode Cloud** (25 hours/month, included in the Developer
Program). GitHub Actions runs only a Linux wording guard — the macOS jobs were
removed 2026-09-04 because they billed at 10x and were slower and flakier.

Run the tests locally before pushing:

    xcodebuild test -project PoCSquat.xcodeproj -scheme PoCSquat \
      -destination "id=$(bash scripts/ci_pick_simulator.sh)"

Full step-by-step procedure lives in the Session Runbook artifact.

## Verifying claims

Every mistake worth writing down here so far has the same shape: a cheap check
was available and reasoning was used instead. Before stating a finding, ask what
would make it false and whether that can be checked in under two minutes. It
usually can.

**State how a claim is known.** These are not equivalent, and the weakest one is
where the errors live:

| Level | Worth |
| --- | --- |
| Read the source | A hypothesis. Say so. |
| Inspected the built artifact | Real, for anything about what ships |
| Ran it | Real, for behaviour |
| Broke it on purpose and watched it fail | The only proof a guard guards anything |

Real examples of the first level going wrong, all on 2026-09-06/07: a "crash" in
`ActiveSessionView` that a `guard` 35 lines below the force-unwraps already
prevented; a "declared camera permission" that `GENERATE_INFOPLIST_FILE = NO`
made inert and that does not appear in the built `Info.plist` at all.

**Before reporting, try to disprove the strongest finding.** Not as an attitude —
as a step. A coherent story starts attracting corroboration: a redundant `if let`
got read as "someone already fixed one of three doors" when it was simply
redundant.

**An assertion that cannot fail is worse than none.** This applies to guards and
scripts, not just tests. A check that derives its expectations from the same
thing it is verifying passes vacuously — `scripts/lint.sh` hardcodes its expected
exclusion list for exactly this reason, and has been verified to fire when the
config is removed.

## Running things

Use the scripts. They exist because the obvious invocations are wrong in
non-obvious ways.

    scripts/test.sh              # full scheme (unit + UI) — what CI runs
    scripts/test.sh --unit-only  # faster, but NOT what CI runs
    scripts/lint.sh              # SwiftLint with verified exclusions

- **`xcodebuild test | tail` reports the exit code of `tail`.** A failed run
  looks green. Never pipe when the exit code matters; check for the literal
  `** TEST SUCCEEDED **`.
- **The `PoCSquat` scheme runs `WockettTests` *and* `WockettUITests`,** and Xcode
  Cloud's Test action uses "Use Scheme Setting". Running `-only-testing:WockettTests`
  is a smaller suite than CI and will not catch what CI catches.
- **SwiftLint resolves `excluded:` relative to the config file's own directory.**
  `swiftlint --config /tmp/x.yml` silently lints the excluded test targets and
  inflates every count, with output that looks completely normal.
- **Local and CI SwiftLint can disagree on `force_unwrapping` at the same
  version.** On 2026-09-09, 0.65.1 on macOS reported 0 error-severity violations
  while 0.65.1 in the Linux CI container reported 1 (`HomeWeatherView.swift:91`,
  a `URL(string:)!`). CI is the arbiter. To find the line, read the check-run
  **annotations** — `gh api repos/FreeScoopDev/Wockett/check-runs/<id>/annotations`
  — because the job log, and the raw log via the API, both strip `file=`/`line=`
  from the reporter's output. Never fix a CI-only lint failure with a
  `swiftlint:disable` comment: the two platforms are exactly what may treat
  those differently. Remove the unwrap.
- **`swiftlint --fix` has broken this build twice** — `redundant_discardable_let`
  inside a `@ViewBuilder`, and `empty_count` against `XCUIElementQuery`. Both
  rules are disabled now. Any autofix run must be followed by `scripts/test.sh`.
- **In multi-step shell, `set -euo pipefail`.** A guard script that fails does not
  stop a `&&` chain on the next line; this shipped a commit without its changelog
  entry, twice.
- **Fast-forward `main` before branching.** `git fetch` alone leaves local `main`
  stale, and a branch cut from it silently omits merged work — once nearly
  reverting a shipped build setting.
- **Never count tests from the xcodebuild log.** During parallel testing it
  can write session-level output mid-way through a result line and eat the
  verdict; on 2026-09-09 that undercounted a clean run by one, and two
  plausible explanations (stderr, last-line truncation) were each disproved
  by the next run. `scripts/test.sh` counts from the xcresult bundle via
  `xcrun xcresulttool get test-results summary`. The verdict is xcodebuild's
  exit code, its `** TEST SUCCEEDED **` line, and the bundle's result, together.

## Working with Joe

- Give the reasoning alongside the instruction; he's learning the system, not
  just operating it.
- Terminal commands as one complete copy-paste block, with a plain-English note
  on what it does.
- **He pushes; Claude never pushes.** Don't run `git commit` or `git push` on his
  machine without asking — past sessions left `.git/index.lock` files behind.
  Read-only git only, with `--no-optional-locks`.
- Tracking lives in Notion, "Scoops Dev Command Center": Releases, Testing/QA,
  Dev Session Notes, SOP Usage Log.

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
- **`.safeAreaInset` on a view that `.ignoresSafeArea()`** lays content out over
  the floating tab bar, not above it. Panels need explicit bottom padding from
  `geo.safeAreaInsets.bottom` or their last row gets clipped.
- **Modal screens silently break UI tests.** A `fullScreenCover` still lets views
  beneath it satisfy `exists` queries — so tests fail on *taps*, not on the
  assertions that came first. Two of these (badge celebration, resume-walk
  alert) are suppressed under `-WKTUITest`.
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
  `routes.routeCard`, `routes.startWalk`, `routes.weatherTile`,
  `routes.nearbyPlaces`, `routes.communityToggle`.
- **Tab bar buttons are addressed by visible title**, not identifier — iOS 26
  discards `.accessibilityIdentifier` on `Tab`.

## Process

`main` is protected: no direct pushes, no force-push, no deletion, and two
required checks (`Wockett | CI Tests | Test - iOS`, `Language-consistency
guard`). One change per branch; `feat/`, `fix/` or `chore/` prefix. Merge
`origin/main` into the branch *before* opening the PR. Squash-merge.

Testing runs on **Xcode Cloud** (25 hours/month, included in the Developer
Program). GitHub Actions runs only a Linux wording guard — the macOS jobs were
removed 2026-09-04 because they billed at 10x and were slower and flakier.

Run the tests locally before pushing:

    xcodebuild test -project PoCSquat.xcodeproj -scheme PoCSquat \
      -destination "id=$(bash scripts/ci_pick_simulator.sh)"

Full step-by-step procedure lives in the Session Runbook artifact.

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

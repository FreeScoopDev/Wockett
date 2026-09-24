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

- **`Versions.xcconfig` owns the version numbers.** Never edit them in
  per-target build settings. `MARKETING_VERSION` is bumped in the release PR.
  `CURRENT_PROJECT_VERSION` is read only by a manual Xcode archive (emergency
  only since 2026-09-23), so it is **not** bumped after releases any more. It
  must stay defined, because `Info.plist` resolves `CFBundleVersion` from it.
- **Product → Archive in Xcode must not touch the working tree.** Until
  2026-09-15 the shared scheme had an Archive pre-action running
  `agvtool next-version -all`; every local archive left `CFBundleVersion`
  hardcoded to `2` in `Info.plist` and bumped the test targets' numbers in
  `project.pbxproj` — twice mistaken for a hand edit. Removed. If those two
  files show up modified with no one editing them, check the scheme's
  pre-actions first (`xcshareddata/xcschemes/PoCSquat.xcscheme`).
- **Xcode Cloud's build number is one counter across all workflows.** Every
  PR `CI Tests` run consumes a number, so a Release Flow archive after a few
  PRs jumps by that many (77 → 82 on 2026-09-15). Never predict the next
  number; read it off the finished archive (Slack `#wockett_release_updates`
  or App Store Connect).
- **Xcode Cloud ignores the file's build number** and auto-increments its own;
  a manual Xcode archive uses the file's value verbatim. That split is why
  post-release bookkeeping PRs existed (#35, #39, #57). With Release Flow as the
  only release path they are unnecessary. If an emergency manual archive is ever
  refused for a build number already used, raise `CURRENT_PROJECT_VERSION`
  above the latest in App Store Connect at that moment. The refusal is loud,
  not silent.
- **Release Flow could not ship to the App Store until 2026-09-23.** Its
  Distribution Preparation was "TestFlight (Internal Testing Only)", and Apple
  never accepts those builds for review. That is why 1.11 (builds 77, 82) only
  ever reached internal TestFlight, and why the public App Store went from 1.10
  straight to 1.12. It is also why 1.12 was a manual archive. Joe changed the
  setting to "TestFlight and App Store" that day. If Release Flow builds ever
  stop being offered under "Add Build" on an App Store version, check that
  setting first.
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
  `session.root`, `session.minimize`, `session.finish` (hold 1 s, then
  `session.confirmFinish`), `summary.root`,
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
- **Walk reminders are notifications** (`WalkReminder`, owned by
  `NotificationService`), not calendar events — since 2026-09-09.
  `WalkSchedulerService` exists only to delete the `EKEvent`s that 1.7–1.10
  created; it must never add one.
- **The app cannot detect activity while suspended.** `ActivityDetectionService`
  streams Core Motion only while Wockett has CPU time, and iOS suspends it
  seconds after it leaves the foreground; the only background lifetime it has is
  during a session, via `allowsBackgroundLocationUpdates`. Anything "detect and
  notify" therefore runs in the background-refresh task after the fact
  (`UntrackedWalkDetector`), on iOS's schedule — a few times a day, not on
  demand. Real-time would need continuous background location outside a session:
  "Always" permission, battery, the location indicator. Considered and rejected
  2026-09-09. Write the copy for the delay.
- **A notification tap that launches the app runs the delegate before the app
  root exists**, so `onChange` never sees what it set. Anything a tap leaves
  pending must be consumed in `.task` at launch as well, and anything the user
  would lose by the race (a walk they asked to save) persisted, not held in
  memory. Cost: "Start Walk" silently did nothing on a cold launch until
  2026-09-09.
- **A walk with no route is an established shape**, not a special case:
  `waypoints: []` ships as Indoor Walks (`StationaryWalkView`) and manually
  added Past Walks (`WalkHistoryView`), and now saved untracked walks. Give it a
  `routeName` that explains itself — a detail screen with no map should not look
  broken.

## Process

Simplified on 2026-09-23, after 1.12 took a changelog cut, two stacked PRs, a
flaky-test PR, a missed CI event, a manual archive that missed a merged fix, and
a build-number PR. The picture is the "Wockett Ship Path" artifact
(https://claude.ai/artifact/7XiSmyWHE78VkVhrajyzR7). **Joe clicks; Claude does
the git work and the bookkeeping; checks run by themselves.**

`main` is protected: no direct pushes, no force-push, no deletion, and three
required checks (`Wockett | CI Tests | Test - iOS`, `Language-consistency
guard`, and `SwiftLint` — the last added 2026-09-09 once its error-severity
backlog reached zero). Squash-merge.

### Every change: Joe's one step is Merge

Claude, in its own worktree (see "Working with Joe"):

1. Branches from `origin/main`, one change per branch, `feat/`, `fix/` or
   `chore/` prefix. **Never stack a PR on another branch.** `CI Tests` only
   builds PRs whose base is `main`, so a stacked PR gets no CI until
   retargeted (#53, #54).
2. Makes the change with its `CHANGELOG.md` line and runs `scripts/test.sh`.
3. Merges `origin/main` in, pushes the branch and opens the PR.
4. About 2 minutes later, confirms a `Wockett | CI Tests` status exists on the
   PR. If there is none, it re-fires with `gh pr close N && gh pr reopen N`
   (`docs/ci.md` explains why). It fixes any red check itself.
5. Gives Joe the PR link. Joe clicks **Squash and merge** once all three
   checks are green. Claude never merges.

### Shipping a version: five Joe steps

Claude opens the **release PR**: it cuts `[Unreleased]` into `[x.y] - date`,
bumps `MARKETING_VERSION`, and runs the `release-checker` agent. The PR
description starts with a **Ship Card**:

- **What's New**: App Store copy covering everything users have not seen
  since the version that is *live* (check
  `https://itunes.apple.com/lookup?id=6794364736`), not just since the last cut.
- **What to Test**: TestFlight copy.
- **QA cards**: the Testing/QA cards linked from the Notion Releases page.
- **Console steps**: anything only Joe can do (CloudKit schema deploy,
  publishing a record, an App Store Connect product). Each is written as exact
  clicks. Omit the section when there are none.
- **Release check**: the `release-checker` report. This replaces the SOP
  Usage Log as the record that the checks ran.

Joe then:

1. Merges the release PR.
2. Does the console steps, if the Ship Card lists any.
3. App Store Connect → Apps → Wockett → Xcode Cloud → Release Flow →
   **Start Build** (`main` is the only branch it offers). Waits for Slack
   `#wockett_release_updates` and notes the build number.
4. Installs it from TestFlight, works through the QA cards, and marks each one
   Passed in Notion. A failure goes back through "Every change", then step 3
   again.
5. App Store Connect → Distribution → new version → Add Build → pastes What's
   New → Add for Review → Submit. Tells Claude "submitted build N".

After step 5, Claude tags the build's commit `vX.Y` (lightweight, like `v1.9`
to `v1.11`) and pushes the tag. It also sets the Notion Releases row to
Status `In Review` and Build `N`. That is the whole post-release process: no
`Versions.xcconfig` PR.

**A manual Xcode archive is emergency-only**, for when Xcode Cloud itself is
down. It builds whatever is on disk in `~/Desktop/PoCSquat`, which is how
build 84 went out without #53.

Testing runs on **Xcode Cloud** (25 hours/month, included in the Developer
Program). GitHub Actions runs only a Linux wording guard — the macOS jobs were
removed 2026-09-04 because they billed at 10x and were slower and flakier.

Run the tests locally before pushing:

    xcodebuild test -project PoCSquat.xcodeproj -scheme PoCSquat \
      -destination "id=$(bash scripts/ci_pick_simulator.sh)"

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
- **An Xcode Cloud run that fails in seconds is the environment pin, not
  the code.** The `Wockett | CI Tests` status goes queued → failed before the
  `… | Test - iOS` child check-run exists on GitHub; nothing compiled. Apple
  had retired the pinned macOS (2026-09-15: 26.6.2 gone, re-pinned to 26.5.1
  on both workflows). Fix it in App Store Connect → Xcode Cloud → Manage
  Workflows → Environment, on *both* workflows, then Rebuild. Details in
  `docs/ci.md`.
- **In multi-step shell, `set -euo pipefail`.** A guard script that fails does not
  stop a `&&` chain on the next line; this shipped a commit without its changelog
  entry, twice.
- **Branch from `origin/main` after a `git fetch`, never from a local `main`.**
  A local `main` goes stale, and a branch cut from it silently omits merged
  work. That once nearly reverted a shipped build setting.
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
- **Claude commits, pushes branches and pushes release tags; Joe merges.**
  Agreed 2026-09-23. Joe's approval of a change is the Merge button, and
  `main` is protected, so a pushed branch cannot ship anything by itself.
  Claude never pushes to `main`, never force-pushes, and never merges a PR.
  Joe no longer runs git commands for routine work.
- **Never move what is checked out in `~/Desktop/PoCSquat`.** That folder is
  Joe's; git there is read-only with `--no-optional-locks`, because past
  sessions left `.git/index.lock` files behind. Do all branch work in a
  separate worktree (`git worktree add ~/Desktop/PoCSquat-claude -b <branch>
  origin/main`), and remove it once the PR merges. No `switch`, `checkout`,
  `merge`, `pull` or `commit` in Joe's folder. If it needs updating before an
  emergency archive, give Joe the command instead. Cost: on
  2026-09-23 a fast-forward landed 14 s into Joe's 1.12 archive, and build 84
  shipped without #53. It was proved from the archive's dSYM; see
  `Versions.xcconfig`.
- **Anything Joe has to do is written as numbered steps**: where to click,
  what to type, what he should see, and what to do if he doesn't. "Be careful
  when X" is not a step. If a risk can be removed on Claude's side instead,
  remove it rather than handing Joe a rule to remember.
- Tracking lives in Notion, "Scoops Dev Command Center": **Releases** and
  **Testing/QA** are the two Joe uses. Claude can search a data source, fetch
  a page (including its QA-card relations) and update a page's properties.
  Only filtered `query-data-sources` calls need the Business plan, so find rows
  with search plus fetch instead. The SOP Usage Log is no longer written as of
  2026-09-23; the release PR's Ship Card is the record.

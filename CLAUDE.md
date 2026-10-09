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
| Local folder | `~/Desktop/Apps/PoCSquat` (was `~/Desktop/PoCSquat` until 2026-09-26) |
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
  **A `ModelConfiguration` with no `cloudKitDatabase:` is not local**: the
  default is `.automatic`, which syncs whenever the app has the iCloud
  entitlement. The "local" fallback lacked `.none` until 2026-09-29, so every
  locally signed test run synced anyway (CI, unsigned, did not).
  `AppModelContainerTests` guards it, but only fails in a signed build.
- **`CKContainer(identifier:)` traps at creation without the iCloud entitlement**,
  and `TrailPackLibrary.shared` creates one inside `SquatCounterApp.init()`.
  A build with `CODE_SIGNING_ALLOWED=NO` has no entitlements at all, so the
  app dies before its first screen and every test in the scheme fails with
  "crashed before establishing connection". Simulator builds ad-hoc sign
  with their entitlements and need no certificate; leave signing alone in
  CI. Cost a full local run on 2026-09-28.
- **CloudKit Production only has what was deployed from Development**, and
  Development only gains a record type or field when a Debug build syncs a
  value for it. Production cannot add either by itself, so a model nobody
  exercised in Debug silently never syncs for users; the failure shows only in
  the device's sync logs. `CD_BookmarkedLocationRecord` was missing from
  Production for a month, along with the four `CD_<name>_ckAsset` fields a
  `Data` property overflows into when it is large (long walks, big custom
  routes); fixed by hand in Development and deployed on 2026-09-29. Check it:
  export Production (CloudKit Console → iCloud.Scoops.PoCSquat → Production →
  Schema → Export Schema…) and run
  `~/.claude/toolkit/bin/cloudkit-schema-check.sh <checkout> <export.ckdb>`;
  it exits 0 when Production has every field the SwiftData models need
  (verified to exit 1 on the pre-fix export). It covers only `CD_` types; the
  hand-written `CKRecord` types (SharedRoute, Challenge, …) are compared by
  hand. Deploying cannot be undone, so read the Deploy dialog's full list
  before confirming.
- **Public-database permissions are part of the schema, and `cktool` can't
  test them.** Since 2026-10-09 only the custom role `TrailPublisher` (given
  to Joe's user record in both environments) may create `TrailRegionPack`
  records; `_icloud` (any signed-in user) no longer can. The other public
  types keep CloudKit's defaults: any signed-in user creates, only the
  creator writes, everyone reads. `cktool` runs as the container's developer,
  which gets past security roles: a create without the role succeeded in
  Development and in Production. So a `cktool` run proves publishing works,
  never that a role blocks anyone; that needs an ordinary iCloud account
  (Console → Act As iCloud Account…), not yet done. Check the grants with
  `xcrun cktool export-schema … --environment production`.
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

- **Trail regions follow `scripts/trail-pack/STANDARDS.md`**: the gates a
  pack must clear (coverage of at least 50% of a state's towns, and no
  coverage regression against the published version), what each build prints
  for review, the curation rules by builder version, and the loop for adding
  and improving states. A state that cannot clear the bar waits (Joe,
  2026-10-08). Update the page when a rule changes.
- **Icons** go through `WktSymbol` + `.wktIcon()`. No hardcoded `systemName:`
  or `systemImage:` strings. Variable-driven `systemName:` from a model
  property is fine and intended. There are zero again since 2026-10-01; keep
  it that way. This entry said "currently zero" on 2026-09-30 while five
  files had them, because the search missed
  `Label(…, systemImage: cond ? "a" : "b")`: search for both spellings.
- **Colours and fonts** come from `DesignSystem.swift`, which has dual target
  membership so the widget can't drift. There are ~164 legacy raw
  `.font(.system(size:))` sites; fix opportunistically, don't sweep.
- **App-group keys live in `AppGroup.swift`** (repo root, dual target
  membership like `DesignSystem.swift`), and `WidgetSnapshot` is the one
  writer of the widget's numbers. No `"group.com.scoops.wockett"` or
  `"wkt_widget_*"` literals elsewhere: until 2026-09-28 the background
  refresh wrote `bg_todaySteps`, the widget read `wkt_widget_steps`, and the
  widget only changed when the app was opened. A new root file needs the
  four `project.pbxproj` entries `ProEntitlement.swift` has (file reference,
  two build files, root group, both Sources phases); the synchronized
  folders only cover their own target.
- **Shared UI components look the same everywhere they appear.** Joe's explicit
  standard (2026-09-04). If a component gains a variant, roll it to every screen
  that uses it rather than keeping two.
- **Screens are built from the shared design pieces** (2026-09-30 Home redesign):
  `DesignSystem.swift` for colours, the type scale (`wktMetric` … `wktLabel`,
  sentence case, no SF Mono) and `WktSpacing`; `PoCSquat/Design/` for
  `wktCard`, `WktSection` (heading above its cards, never inside),
  `WktDivider`, `WktProgressBar`, `WktStatusChip` (status is a chip, never a
  card), `WktPrimaryButton` (one per screen) / `WktSecondaryButton`,
  `WktPillButton`, `WktIconBadge`, `wktChoiceBackground` and `WktEmptyState`.
  A metric screen uses `Design/WktDetailPieces.swift`; a step ring is
  `WktGoalRing`; a mid-session notice is a `WktBanner`; pick-one controls
  are `WktSegmentedPicker` / `WktChoiceChip`; tags that may not fit one line
  go in a `WktFlowRow`; a system List's section heading is `WktListHeader`.
  Every screen, the widget and the Live Activity are converted (2026-10-01),
  and the old all-caps `wktTechnical` / Rounded Black `wktDisplay` fonts are
  deleted. The widget target shares only `DesignSystem.swift`: it uses the
  type scale and colours but not `PoCSquat/Design/` or `WktSymbol`, so it
  keeps its own short `WS` symbol list. The share card
  (`ActivitySummaryCard`) keeps fixed point sizes on purpose: it is drawn into
  a fixed-size image. New screens build from these pieces from the start.
- **The changelog entry ships with the change**, in the same commit, explaining
  *why* — not just what. Since 2026-09-27 it goes in its own file in
  `changelog.d/`, not in `CHANGELOG.md`. `changelog.d/README.md` has the format.
  The release PR gathers the files into `CHANGELOG.md`. Two open PRs that both
  edited `[Unreleased]` conflicted every time, and a conflicted PR cannot
  auto-merge.
- **Accessibility identifiers** on marker views need
  `.accessibilityElement(children: .contain)` or they never reach the
  accessibility tree. UI tests depend on: `home.statCard`, `home.tile.walk`
  (selects only), `home.start` (starts the selected activity), `session.root`, `session.minimize`, `session.finish` (hold 1 s, then
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
- **A walk ends through `ActiveWalkStore.end(.save / .discard)`**, whoever
  ends it. It saves with pet credit (kept on the session, not the walk
  screen), finishes or discards the Health workout, stops tracking, deletes
  the checkpoint, cancels water breaks and ends the Live Activity. Until
  2026-09-28 seven places re-implemented that and each left something out;
  free walks never reached Health. The walk screen passes
  `releaseSession: false` and releases the session when its summary goes.
- **A walk with no route is an established shape**, not a special case:
  `waypoints: []` ships as Indoor Walks (`StationaryWalkView`) and manually
  added Past Walks (`WalkHistoryView`), and now saved untracked walks. Give it a
  `routeName` that explains itself — a detail screen with no map should not look
  broken.

## Process

@~/.claude/toolkit/PROCESS.md

The process is shared by every app and lives in the toolkit
(`FreeScoopDev/app-toolkit`, checked out at `~/.claude/toolkit`): every
change, auto-merge, `changelog.d/`, the release PR and Joe's five release
steps, git rules. **If you cannot see its "Every change: no Joe step"
section, the import did not load: read `~/.claude/toolkit/PROCESS.md` now,
before any git work.** Change the process there, not here.

Wockett's specifics:

- **Required checks** on `main` (`.claude/app.json` → `requiredChecks`):
  `Unit tests (iOS)` (GitHub Actions, since 2026-09-28),
  `Language-consistency guard`, `SwiftLint` (required since 2026-09-09, once
  its error-severity backlog reached zero), and `Critic verdict` (since
  2026-10-09; fails a major PR with no critic verdict or a BLOCK one). `~/.claude/toolkit/bin/repo-check.sh .`
  confirms GitHub still matches. `UI smoke tests (iOS)` runs on every PR but
  is advisory until the runner has proven it can run the UI target
  (`docs/ci.md` has the numbers and the rule for promoting it).
- **The picture** is the "Wockett Ship Path" artifact
  (https://claude.ai/artifact/7XiSmyWHE78VkVhrajyzR7). The process was
  simplified on 2026-09-23, after 1.12 took a changelog cut, two stacked PRs
  (#53, #54, which got no CI until retargeted), a flaky-test PR, a missed CI
  event, a manual archive that missed a merged fix, and a build-number PR.
- **Release**: What's New is checked against the live version at
  `https://itunes.apple.com/lookup?id=6794364736`. Release Flow reports to
  Slack `#wockett_release_updates`. Tags are lightweight, like `v1.9` to
  `v1.11`. There is no post-release `Versions.xcconfig` PR.
  If the release adds or changes a SwiftData model property, the release
  PR runs `cloudkit-schema-check.sh` against a fresh Production export, and
  any missing field goes on the Ship Card as a Console step before Start
  Build.
- **An emergency manual archive** builds whatever is on disk in
  `~/Desktop/Apps/PoCSquat`, which is how build 84 went out without #53.
- **CI** is GitHub Actions since 2026-09-28: `tests.yml` runs `WockettTests`
  and `WockettUITests` as two parallel jobs on `macos-26` (the same Xcode
  26.6 Xcode Cloud pins) through the toolkit's `bin/test.sh`, free because the
  repository is public; docs-only changes skip both. The runner is slow: a
  full-scheme run took 32 minutes against Xcode Cloud's 7, and the UI target
  was flaky on it, which is why only the unit job is required. Xcode Cloud
  runs the full scheme once a day on `main` and Release Flow archives, which
  keeps its 25 included hours a month. The macOS jobs had been removed on
  2026-09-04 because they billed at 10x on a private repo.

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
thing it is verifying passes vacuously — `scripts/lint.sh` takes its expected
exclusion list from `.claude/app.json`, a separate file from `.swiftlint.yml`, for
exactly this reason, and aborts when the two disagree (verified 2026-09-27 by
removing one entry from `.swiftlint.yml` only).

## Running things

Use the scripts. They exist because the obvious invocations are wrong in
non-obvious ways. Since 2026-09-27 each is a thin wrapper around Joe's shared
toolkit in `~/.claude/toolkit/bin/`, configured by `.claude/app.json`; the same
runner serves his other app without either repo depending on the other. CI does
not call them, so a clone without the toolkit still builds and passes CI.
`scripts/test.sh` also treats a run of 0 tests as a failure.

    scripts/test.sh              # full scheme (unit + UI) — what CI runs
    scripts/test.sh --unit-only  # faster, but NOT what CI runs
    scripts/lint.sh              # SwiftLint with verified exclusions

- **`xcodebuild test | tail` reports the exit code of `tail`.** A failed run
  looks green. Never pipe when the exit code matters; check for the literal
  `** TEST SUCCEEDED **`.
- **The `PoCSquat` scheme runs `WockettTests` *and* `WockettUITests`.** CI
  runs each target as its own job through the same `bin/test.sh`, and only
  the unit job blocks a merge, so a UI regression can reach `main` if nobody
  reads the advisory job. Run `scripts/test.sh` (the full scheme) locally
  before pushing anything that touches the UI; `--unit-only` will not catch
  what the smoke tests catch.
- **SwiftLint resolves `excluded:` relative to the config file's own directory.**
  `swiftlint --config /tmp/x.yml` silently lints the excluded test targets and
  inflates every count, with output that looks completely normal.
- **CI's SwiftLint version is pinned in `guards.yml`; keep it equal to the
  local one.** On 2026-09-09 macOS reported 0 error-severity violations and CI
  reported 1 (`HomeWeatherView.swift:91`, a `URL(string:)!`). This file called
  that a platform difference "at the same version", but CI was running 0.57.0
  (pinned since #10) against 0.65.1 locally. Tested 2026-09-26: 0.65.1 exempts
  `URL(string: "literal")!` (a plain string literal) on macOS and on the Linux
  CI image alike, and flags every other force-unwrap, including an interpolated
  or variable URL; 0.57.0 flagged the literal too. CI now pins 0.65.1, so the
  two runs agree. CI is the arbiter. To find the line, read the check-run
  **annotations** — `gh api repos/FreeScoopDev/Wockett/check-runs/<id>/annotations`
  — because the job log, and the raw log via the API, both strip `file=`/`line=`
  from the reporter's output. Never fix a CI-only lint failure with a
  `swiftlint:disable` comment: two runs that disagree are exactly what may
  treat those differently. Remove the unwrap.
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
- **`-only-testing:` can match nothing and still pass.** Swift Testing tests
  are not addressed by their function name alone, so
  `-only-testing:WockettTests/TrailGuideTests/someTest` ran 0 tests and printed
  `** TEST SUCCEEDED **` during a break-check on 2026-09-24. Filter to the
  suite (`WockettTests/TrailGuideTests`) instead, and confirm the count in the
  bundle (`xcrun xcresulttool get test-results summary`) before believing a
  green result.
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
- **Claude commits, pushes branches, queues auto-merge and pushes release
  tags; Joe merges only the release PR.** Agreed 2026-09-23, auto-merge added
  2026-09-27. A routine PR merges itself once the required checks pass. A merge
  on `main` reaches users only through Joe's Release Flow build, QA and Submit.
  Claude never pushes to `main`, never force-pushes, never merges past a
  failing or missing check, and never auto-merges the release PR. Joe no
  longer runs git commands for routine work.
- **Never move what is checked out in `~/Desktop/Apps/PoCSquat`.** That folder is
  Joe's; git there is read-only with `--no-optional-locks`, because past
  sessions left `.git/index.lock` files behind. Do all branch work in a
  worktree of its own per branch, at `~/Desktop/Apps/Wockett-claude/<branch>`
  with the slash as a dash (`git worktree add -b fix/x
  ~/Desktop/Apps/Wockett-claude/fix-x origin/main`, shared PROCESS.md step 1),
  so several sessions can work on Wockett at once, and remove it once the PR
  merges. No `switch`, `checkout`,
  `merge`, `pull` or `commit` in Joe's folder. If it needs updating before an
  emergency archive, give Joe the command instead. Cost: on
  2026-09-23 a fast-forward landed 14 s into Joe's 1.12 archive, and build 84
  shipped without #53. It was proved from the archive's dSYM; see
  `Versions.xcconfig`.
- **Keep repos out of iCloud-synced folders.** On 2026-09-26 the Desktop,
  then synced by iCloud's Desktop & Documents, was moved to a local
  `~/Desktop/Apps`. Only the files iCloud had downloaded made the move: the
  repos lost `.git/HEAD`, most refs and 30 tracked files, and git no longer
  recognised them. Wockett was re-cloned from GitHub with nothing lost, because
  every change was pushed. Pushing every branch is what made that true; a repo
  with no remote (SqwatrApp) had no such copy. If a git command here says "not
  a git repository", check for a missing `.git/HEAD` before anything else.
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

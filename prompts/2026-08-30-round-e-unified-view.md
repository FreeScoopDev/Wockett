# Round E: one unified active-session view + one end-of-activity summary

The V2-5 finale. Two commits, in order; if commit 2 balloons, stop after
commit 1 and say so — they're independently shippable.

## Commit 1 — `ActiveSessionView` replaces both active-session screens

### Goal

One view for every activity, built on Round D's components and the guided
walk's look (the one Joe prefers). Route-specific chrome appears only
when the route has waypoints; free-session chrome only when it doesn't.
`FreeWalkView`'s hand-rolled UI is retired the way `FreeWalkManager` was.

### Shape

New `PoCSquat/Views/Walk/ActiveSessionView.swift`, assembled from:

- **Base (from WalkNavigationView):** map container, `SessionStatsBar`,
  `PauseResumeControl`, `SessionEndDialog`, `BreakPromptAlert`,
  `DrivingSuspectedBanner`, heat banner, water-break logic, pet distance
  tracking, checkpoint/audio-cue handling, the crash-guard
  `if walkStore.session != nil` + `hasAttemptedStart` bootstrap pattern,
  `endSessionOnDismiss` teardown.
- **Guided-only sections** (`!route.waypoints.isEmpty`): computed route
  legs / on-screen directions, waypoint arrival + progress,
  `SessionStatsBar(showsRemaining: true)`, route-completion detection.
- **Free-only sections** (`route.waypoints.isEmpty`): breadcrumb
  polyline from `session.trackPoints`, POI chip row + POI detail card
  (`POIOverlayManager` and friends move to their own file or stay in a
  clearly-marked section), `SessionStatsBar(showsRemaining: false)`,
  the Finish button flow.
- **Bootstrap:** merge `WalkNavigationView.startWalk()` and
  `FreeWalkView`'s start logic into one `startSession()` — guided path
  keeps weather fetch/legs/checkpoint setup; free path keeps the
  route-stub construction. The `isStarted` re-adopt guard and Live
  Activity start are shared.

### Rewiring

- `StepCounterView`'s `showResumeWalk` sheet: the `waypoints.isEmpty`
  branch collapses to always presenting `ActiveSessionView`.
- Every entry point that presents `WalkNavigationView` or `FreeWalkView`
  (Route Finder, dashboard tile, My Routes, Walk/Activity History,
  free-walk/ride/run starts) presents `ActiveSessionView` instead —
  grep for both view names to find them all.
- Delete `WalkNavigationView.swift` and `FreeWalkView`'s view structs
  once nothing references them. `FreeWalkSummarySheet` survives commit 1
  (commit 2 replaces it). If `WalkCompleteView` is presented from the
  old guided view, rewire it identically for now.

### Non-negotiables

- Zero data-layer changes: `WalkSession`, stores, snapshot, Live
  Activity plumbing all untouched.
- Behavior parity checklist — everything that works today must work
  identically from the unified view: pause/resume (incl. auto-pause),
  all end paths, minimize → mini tile → reopen, force-quit → resume,
  Live Activity buttons, driving detection, water breaks, pets, POIs,
  save-as-route, route completion.

## Commit 2 — one `ActivitySummaryView` on every in-app end

### Goal

Joe's QA finding: manually ending a guided walk saves silently with no
summary, while Free Walk shows one — inconsistent and confusing. After
this commit, EVERY in-app end shows the same summary experience.

### Shape

New `ActivitySummaryView` merging the best of `WalkCompleteView` (PR
celebration, pet completions, streak/badge feel) and
`FreeWalkSummarySheet` (save/share/save-as-route flow):

- Stats header (distance / time / pace-or-speed via
  `paceOrSpeedText` / steps), activity-aware title from Round C.
- PR badges when earned; pet summary rows when pets were active.
- Share (existing `ActivitySummaryShareSheet` flow).
- "Save as Route" only when the session has breadcrumbs and didn't come
  from a saved route.
- Auto-save >50m / manual save for shorter — the FreeWalk rules become
  universal; route-completion and manual ends both funnel through the
  same save call that already exists (`buildAndSaveSession` /
  `saveAndEndActiveSession`) — do NOT create a new save path.

### Wire-up

- All `ActiveSessionView` end paths (Finish button, end-dialog End +
  Save-Route-and-End, break-prompt End, route completion) present
  `ActivitySummaryView` before dismissal. Discard paths never show it.
- Background ends (Live Activity End button, mini tile) stay
  silent-save as today — no UI can be shown; note this in a comment.
- Retire `FreeWalkSummarySheet` and `WalkCompleteView` when nothing
  references them (move, don't lose, any celebration assets/logic worth
  keeping).

## Build & verify (both commits)

1. Full test suite green; app + widget build.
2. Matrix pass in the simulator — for each of guided walk, free walk,
   free run, free ride: start → stats correct → pause/resume → minimize/
   reopen → end via EVERY path → summary appears (in-app ends) with
   correct activity language → history entry correct.
3. Force-quit → resume → the unified view restores (both guided and
   free).
4. Guided walk to route completion → summary shows (previously
   WalkCompleteView's job).
5. Commit(s) with clear messages listing anything deliberately deferred.
   Do not push.

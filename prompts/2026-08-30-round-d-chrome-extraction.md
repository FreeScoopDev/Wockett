# Round D: extract the guided walk's chrome into shared components (zero visual change)

## Why

Round E will rebuild the active-session experience as one unified view,
using the guided walk's look (the one Joe likes). This round de-risks
that by extracting `WalkNavigationView`'s chrome into reusable
components and rewiring `WalkNavigationView` itself onto them — with a
**hard requirement: the guided walk must be pixel- and
behavior-identical after this round.** No new features, no styling
tweaks, no "while I'm here" improvements.

**Do NOT touch `FreeWalkView` or `ActiveMiniTile` this round** — even
though they duplicate some of this. They get rebuilt on these components
in Round E; changing them now would mix refactor and redesign.

First build a quick inventory: read `WalkNavigationView.swift` top to
bottom and list its distinct UI pieces before extracting. The known
candidates below are from an earlier read — adapt names/details to
what's actually there.

## New file: `PoCSquat/Views/Walk/ActiveSessionComponents.swift`

Move (not copy — the originals get deleted from `WalkNavigationView` and
replaced by uses) these pieces, keeping their exact current styling:

1. **`SessionStatCell`** — the `hudStat(value:label:icon:)` cell style
   (and the step-count variant with cadence if the guided view has one).
   Parameterize exactly what varies today, nothing more.
2. **`SessionStatsBar`** — the HStack/stack arrangement of stat cells
   the guided walk shows (distance / elapsed / remaining / pace with
   `session.paceText` + `session.paceLabel`). Take the session and a
   `showsRemaining: Bool` (guided passes true) so Round E can pass false
   for free sessions — but this round only the `true` path is exercised.
3. **`PauseResumeControl`** — the pause/play circle button + the
   "{Activity} Paused" capsule banner, driven by the session and its
   route's activityMode.
4. **`SessionEndDialog`** — the confirmation dialog (Save Route & End /
   End / Discard / Keep) as a ViewModifier or a View-returning helper
   that takes the four action closures. The activity-aware strings from
   Round C come with it. Keep the exact button set and roles; the
   closures own everything the buttons currently do (the extracted
   component contains NO business logic).
5. **`BreakPromptAlert`** — the "Still {gerund}?" alert (End +
   Keep-Tracking-with-auto-pause-resume behavior from Round B) as a
   modifier taking the session and an `onEnd` closure.
6. **`DrivingSuspectedBanner`** — already parameterized in Round C; just
   move it into this file if it lives inside WalkNavigationView.swift.

Also promote the duplicated time/distance formatting: `NavigationSessionManager`
gains `var elapsedText: String` and `func distanceText(_ meters: Double)`
equivalents ONLY IF the guided view currently formats these locally —
match whatever it renders today exactly (don't unify with FreeWalkView's
local helpers yet; Round E retires those).

## Rewire `WalkNavigationView`

Replace each extracted piece's inline definition with the component,
passing the same data and the same closures. The four end-dialog button
bodies, the break-prompt End body, water-break logic, pet logic,
checkpoint handling, map content — all stay in `WalkNavigationView`,
passed in as closures where a component needs them.

## Guardrails

- No string changes (Round C just set them), no color/font/spacing/
  padding changes, no reordering of elements.
- `WockettTests` untouched and green.
- If any piece resists clean extraction (e.g. tangled state), leave it
  in place and note it in the commit message rather than forcing it —
  Round E can deal with the leftovers.

## Verify

1. Build app + widget; tests green.
2. Screenshot the guided walk screen (active, paused, end dialog open,
   break prompt visible) BEFORE this change (git stash or prior build)
   and AFTER — they must match. At minimum, eyeball each state
   side-by-side in the simulator.
3. Functional pass: pause/resume, all four end-dialog buttons, break
   prompt End + Keep Tracking, driving banner still appears (simulate or
   just confirm the code path compiles into the same call).
4. Commit with a clear message listing what was extracted and anything
   deliberately left behind. Do not push.

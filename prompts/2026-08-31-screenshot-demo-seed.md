# Screenshot demo seed (DEBUG-only): one tap → the app looks lived-in

## Why

The App Store screenshots are being reshot. Every shot needs a lived-in
app — named pets with step counts, a couple of weeks of walks/runs/rides,
earned badges and a streak, saved routes — with no zeros and no empty
states. `DevSeedStore` (DEBUG-only) already generates test data but is
**not wired to any UI** (nothing references it), and its records are
prefixed "[TEST]", which can't appear in screenshots.

Everything here is `#if DEBUG` — nothing ships to release builds.

## 1. `PoCSquat/Services/Core/DevSeedStore.swift` — add a screenshot profile

Add `seedScreenshotDemo(history:pets:routes:)` and `clearScreenshotDemo(...)`
alongside the existing functions. Demo records must look real, so tag them
via `notes` (`"[DEMO]"`) rather than the route name; clear by that tag.

### Pets (via `PetStore.add`)
- **Nala** — Dog, "Golden Retriever", goalSteps 8_000, `isActiveOnWalk = true`, accent index 0
- **Beef** — Dog, "Corgi", goalSteps 6_000, `isActiveOnWalk = false`, accent index 2
(these names match Joe's existing screenshots — keep them)

### Sessions (via `WalkHistoryStore.addAll`) — last 14 days, no gaps in the last 9 (builds a visible streak)
Route names without any tag — pick from: "Sunrise Loop", "Riverside Out & Back",
"Park Circuit", "Neighborhood Loop", "Evening Stroll", "Hill Repeats" (runs),
"Bay Trail Ride" (ride). Mix:
- ~2 walks per day, 3–6 km each, `activityType: "walking"`, **both pets on
  most walks** (`activePetIds` = both, `petDistances` split ~55/45 in
  Nala's favor), `steps` ≈ distance × 1.3
- 2 runs in the last week, 4–6 km, `activityType: "running"`, no pets,
  steps ≈ distance × 1.1
- 1 ride 5 days ago, ~14 km, `activityType: "cycling"`, no pets, steps 0
- **Today: one short morning walk** (~2.1 km, both pets) so today's pet
  step counts and the dashboard read non-zero.
- Give every session a plausible `waypoints` polyline (reuse the route
  coordinate templates from `seedCustomRoutes`, offset slightly per
  session) so history maps aren't blank.
- **Pace trick for the PR shot:** seed all walking paces deliberately
  slow (~16–18 min/km via `elapsedTime`) so a real 10-minute test walk on
  the day of shooting earns a genuine "fastest pace" personal record on
  the summary screen (shot #3).
- `notes: "[DEMO]"` on every session.

### Custom routes (via `CustomRouteStore.save`)
Reuse the four templates from `seedCustomRoutes` with clean names
("Central Park Loop", "Waterfront Out & Back", "Morning 5K",
"Neighborhood Stroll") — no "[TEST]" prefix. Clear by these exact names.

### Steps for the dashboard ring (optional, HealthKit)
If practical: in the seed, write an `HKQuantitySample` of ~6_400 steps
spread over this morning via `HKHealthStore.save` (request stepCount
write auth first; skip silently if denied). If this is fiddly, skip it —
Joe can take shot #7 on device after a real walk instead. Say which in
the commit.

### Clear
`clearScreenshotDemo` removes sessions with `notes == "[DEMO]"`, the two
pets by name, and the four demo routes by name. Also keep the existing
`[TEST]` clear functions working.

## 2. Trigger — `PoCSquat/Views/Settings/SettingsView.swift`

Add a `#if DEBUG` "Developer" section at the bottom of Settings with:
- **Seed screenshot demo** → clears any previous demo data, then seeds
- **Clear demo data**
- (optionally) the existing "Seed [TEST] streak data" / "Clear [TEST] data"
  so the old generator is reachable too

Wrap the whole section so it does not exist in Release builds.

## 3. Screenshot-day checklist (put this as a comment at the top of the seed function so it travels with the code)

```
// Screenshot day:
//   1. Simulator: xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
//   2. Settings → Developer → Seed screenshot demo
//   3. Shots 1,5,6,7,8,9 in the simulator; 2,3,4 on device after a real ~10-min walk (Live Activity + PR need real hardware)
//   4. Settings → Developer → Clear demo data when done
```

## Verify

1. DEBUG build: seed → dashboard, Activity History, My Pets (both pets,
   non-zero steps today), Badges/streak, My Routes all look lived-in; no
   "[TEST]"/"[DEMO]" text visible anywhere except the notes field.
2. Clear → everything demo-tagged is gone; real data untouched.
3. Release configuration builds with the section and functions absent
   (`#if DEBUG` verified).
4. Test suite green. Commit clearly. Do not push.

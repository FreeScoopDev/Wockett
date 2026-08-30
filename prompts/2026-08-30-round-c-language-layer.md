# Round C: activity-aware language everywhere (V2-5 round 1)

## Why

Joe's direction: whatever activity the user selected, every card, tile,
stat, prompt, and share surface should speak that activity's language —
"Run complete!", "Finish Ride", "Still riding?" — never a hardcoded
"walk." Plus the approved rename: **Walk History → Activity History**.

This round is USER-FACING STRINGS AND ICONS ONLY. Do not rename types,
files, properties, or identifiers (WalkNavigationView, WalkSession,
walk_breakPromptMinutes, notification identifiers, etc.) — structural
unification is a later round, and renaming persisted keys would break
existing data.

## 1. The vocabulary — `PoCSquat/Models/WalkModels.swift`

Extend `ActivityMode` (near `hkActivityType`):

```swift
    /// Noun for this activity: "walk", "run", "ride", "walk" (indoor).
    var noun: String {
        switch self {
        case .running: return "run"
        case .cycling: return "ride"
        default:       return "walk"
        }
    }

    /// Gerund: "walking", "running", "riding".
    var gerund: String {
        switch self {
        case .running: return "running"
        case .cycling: return "riding"
        default:       return "walking"
        }
    }

    /// SF Symbol for this activity.
    var symbolName: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        default:       return "figure.walk"
        }
    }
```

(Adjust the switch to the enum's actual cases — `.stationary` maps to the
walk defaults. If some of these already exist under other names, reuse
rather than duplicate.)

For the widget, which only has the raw string in
`context.attributes.activityMode`, add a small mirror in
`WocketWidget/WocketWidgetLiveActivity.swift` (the widget target may not
compile WalkModels.swift — check target membership; if it does, use the
enum directly):

```swift
private func activityNoun(_ mode: String) -> String {
    mode == "running" ? "run" : mode == "cycling" ? "ride" : "walk"
}
private func activitySymbol(_ mode: String) -> String {
    mode == "running" ? "figure.run" : mode == "cycling" ? "bicycle" : "figure.walk"
}
```

## 2. The sweep

Run `grep -rn -i '"[^"]*walk' PoCSquat/Views PoCSquat/Intents PoCSquat/Services WocketWidget --include="*.swift"`
and judge every hit. The categories, with the known sites (the grep will
find more — fix all *user-facing* ones, not just these):

### Session-scoped strings → use the session/route's activityMode

- **WalkCompleteView**: "Walk complete!" (and any other in-copy "walk") →
  `"\(mode.noun.capitalized) complete!"` etc. The completed `WalkSession`
  carries `activityType` — build an `ActivityMode(rawValue:)` from it.
- **"Walk Paused" banners** in WalkNavigationView + FreeWalkView →
  `"\(session.route.activityMode.noun.capitalized) Paused"`.
- **"Still walking?" alerts** (both views) → `"Still \(gerund)?"`; the
  driving banner's "Still walking or driving?" → `"Still \(gerund) or
  driving?"`.
- **End dialogs** (map dialog + mini tile): "End Walk?", "Save & End
  Walk", "Discard Walk", "Save this walk to your history..." →
  activity-aware nouns.
- **Live Activity widget**: both "End Walk" buttons → `"End
  \(activityNoun(mode).capitalized)"`; the hardcoded `figure.walk` /
  `figure.walk.motion` icons → `activitySymbol(mode)` (keep `.motion`
  variant only if an equivalent exists for the mode; plain symbol is
  fine).
- **Mini tile** label/copy if it says "walk".
- **Resume prompt** (StepCounterView): "Resume Your Walk?" + message →
  the checkpoint knows its mode (`ActiveWalkSnapshotStore.load()?.route`
  — but don't load twice; simplest is a computed label from
  `walkStore`-exposed snapshot info; if plumbing that through is ugly,
  make it activity-neutral instead: "Resume Your Activity?" / "...during
  an active session...").
- **Auto-pause notification** (Round B) is already activity-neutral —
  leave it.
- **Share card / ActivitySummaryShareSheet**: any hardcoded "walk" in
  labels or generated share text → noun/gerund from the session.

### Activity-neutral renames (the Activity History decision)

- **StepCounterView**: "Walk History" → "Activity History"; "No walks
  yet" → "No activities yet"; "\(count) walk(s)" → "\(count)
  activit\(count == 1 ? "y" : "ies")"; "Discover walks shared by other
  users" → "Discover routes shared by other users"; "Total distance
  walked" → "Total distance covered".
- Any other headers/empty states that say "walks" meaning "activities".

### Leave alone

- Pet copy ("Walking with Biscuit") — pets are walked; fine even during
  a ride, don't touch this round.
- Motivational/educational copy in TodayHeroView (NEAT text etc.) — it's
  genuinely about walking.
- Widget/Control Center "Start Walk" entry points — they start a walk
  specifically; leave.
- Badge names ("Century Walk"), challenge copy, community strings — out
  of scope this round unless a string is session-scoped.
- ALL identifiers, UserDefaults keys, file/type names.

## 3. Sanity guards

- `ActivityMode(rawValue:)` fallback: wherever a mode is rebuilt from a
  stored string, default to `.walking` (matches existing patterns).
- Strings built per-session must read from THAT session/route, not a
  global — a minimized run reopened later must still say "run".

## Build & verify

1. Build app + widget targets; full test suite green.
2. Simulator pass per mode — start a run, a ride, and a walk; check:
   paused banner, still-?-prompt title, end dialogs, Live Activity button
   + icon, completion screen headline, share sheet labels.
3. Check the history tab now reads Activity History with the new empty
   state/counts.
4. Commit clearly. Do not push.

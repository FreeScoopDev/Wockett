# v1.9 audit fixes (Security + Accessibility) — triaged subset

Source: `v1.9-prerelease-audit.md` (Claude in Xcode, 08-30). Joe-approved
triage: fix the items below now; the rest are deferred or rejected with
reasons at the end. All fixes are small; no behavior changes except where
noted.

## Security

**H-1 — exclude the walk checkpoint from iCloud backup.**
`ActiveWalkSnapshot.swift`, in `ActiveWalkSnapshotStore.fileURL` (or right
after the file is written in `save`, whichever is cleaner): set
`URLResourceValues.isExcludedFromBackup = true` on the file URL. Setting it
on a not-yet-existing path is a no-op, so apply it after `save()` writes
the file (once is enough — the attribute persists on the file). Add a
one-line comment: the file holds GPS breadcrumbs and must never leave the
device.

**L-2 — log snapshot write failures (no PII).** Replace
`try? data.write(...)` in `save()` with `do/catch` that logs
`"Snapshot write failed"` via the project's OSLog pattern — message only,
no path, no error description that could include a path.

**L-3 — make the protection class explicit.** Add a comment above the
write: `// File protection: .completeUntilFirstUserAuthentication (default)
— required because checkpoints are written in the background mid-walk.`
Comment only; do not change the protection class.

## Accessibility — High (all XS)

- **A-H1** stop buttons: `ActiveSessionView` HUD stop + `ActiveMiniTile`
  stop → `.accessibilityLabel("End \(mode.noun)")` (activity-aware, per
  Round C).
- **A-H2** pause/resume toggle → `.accessibilityLabel(isPaused ? "Resume
  \(mode.noun)" : "Pause \(mode.noun)")`.
- **A-H3** dismiss chevron → `.accessibilityLabel("Minimize session")`.
- **A-H4** mini tile reopen area → `.accessibilityLabel("Return to
  \(route.name)")` + `.accessibilityHint("Opens the active session")`.

## Accessibility — Medium

- **A-M1** HUD toggles: audio (`audioEnabled ? "Mute audio cues" :
  "Enable audio cues"`), water breaks ("Toggle water break reminders"),
  checkpoints ("Toggle checkpoint markers").
- **A-M2** pet emoji toggles → `pet.isActiveOnWalk ? "Remove \(pet.name)
  from \(mode.noun)" : "Add \(pet.name) to \(mode.noun)"`.
- **A-M3** POI annotation buttons → `"\(poi.category.label): \(poi.name)"`.
- **A-M4** POI annotation tap target → 44×44 hit area via
  `.frame(width: 44, height: 44)` + `.contentShape(Circle())`, keeping the
  34pt visual circle.
- **A-M5** POI filter chips → `.frame(minHeight: 44).contentShape(Rectangle())`
  (keep the visual padding; grow the hit area, not the look).
- **A-M6** `SessionStatCell` → `.accessibilityElement(children: .ignore)`
  + `.accessibilityLabel("\(value) \(label)")`; same for the steps/cadence
  cell in `SessionStatsBar` ("\(steps) steps, \(cadence) per minute").
- **A-M7** `ActivitySummaryView` stat tiles → same grouping pattern.
- **A-M8** pet progress rings → grouped, label = pet name, value =
  "\(percent)% of daily step goal".
- **A-M9** PR cards → grouped, label = "\(pr.title): \(pr.valueText)".

## Accessibility — Low (labels/hints only)

- **A-L3** heat banner dismiss → "Dismiss heat advisory".
- **A-L4** driving banner buttons → hints: "Dismisses the alert and
  continues your session" / "Stops and saves this session".
- **A-L5** POI detail close → "Close \(poi.name) details".

## Deferred / rejected (do NOT do these — listed so they aren't re-raised)

- **M-1 (Reminders key orphaned): FALSE POSITIVE** — `DayDetailSheet`
  creates `EKReminder`; the key is used. Keep it.
- **M-2 (two schedulers): not a permissions issue** — `WalkSchedulerService`
  is reachable from Settings (recurring schedule); the summary sheet uses
  local notifications for one-offs. Both keys are legitimate. UX
  consolidation is a v1.10 idea at most.
- **M-3 (24h hard delete in `loadAnyAge`): REJECTED** — it would delete
  the user's walk instead of salvaging it on next launch, which is the
  opposite of the approved behavior. H-1 removes the cloud-exposure
  concern; on-device persistence until next launch is intended.
- **L-1 (`aps-environment`)**: Xcode rewrites it at export; no CI export
  path exists. Leave.
- **L-4 (route name on lock screen)**: accepted risk — user-authored
  names; a Settings toggle is logged for v1.10.
- **A-L1 (fixed fonts in Live Activity)** and **A-L2 (`.earthMuted`
  contrast)**: visual/layout changes to a space-constrained surface and
  the app palette — v1.10, with Joe's eyes on the result.

## Verify

1. Tests green; both targets build.
2. VoiceOver on-device: swipe through the active session HUD, mini tile,
   and a summary screen — every control announces a purpose, stat cells
   read as one phrase, no bare symbol names.
3. Run once with the app in the background mid-walk → confirm the
   checkpoint file still writes (protection class unchanged) — resume
   still works after a force-quit.
4. Commit clearly. Do not push.

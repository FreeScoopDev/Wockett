# Round E.1: restore the "Schedule This {Activity} Again" flow

## Why

Round E commit 2 deleted `WalkCompleteView.swift` and with it the
`ScheduleWalkSheet` struct and the "Schedule This Walk Again" button —
noted as deferred in the commit. That's a user-facing feature loss on the
summary screen (and the App Store description advertises scheduling).
`WalkSchedulerService` and the calendar's scheduling UI are intact — only
this entry point vanished.

## Changes

1. Recover `ScheduleWalkSheet` from git history
   (`git show ee50b3b^:PoCSquat/Views/Walk/WalkCompleteView.swift` — the
   struct near the bottom) into a new file
   `PoCSquat/Views/Walk/ScheduleWalkSheet.swift`, unchanged except
   anything that referenced WalkCompleteView-local state.
2. In `ActivitySummaryView`, add the button back where it fits the
   layout (it sat with the share/save actions before):

```swift
Label("Schedule This \(mode.sessionLabel) Again", systemImage: "calendar.badge.plus")
```

   presenting `ScheduleWalkSheet(routeName: session.routeName)` — same
   behavior as before, using the session's activity-aware label from
   Round C.

## Verify

1. Finish any activity → summary shows the schedule button → tapping it
   opens the sheet → scheduling creates the reminder (check the calendar
   / pending notification as the old flow did).
2. Tests green, both targets build. Commit clearly. Do not push.

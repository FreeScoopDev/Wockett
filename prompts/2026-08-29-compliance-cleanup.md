# Small cleanup: motion-permission string conflict + share-button accessibility

## Why

Two leftovers blocking the v1.9 compliance items, both tiny:

1. **Conflicting NSMotionUsageDescription sources.** `PoCSquat/Info.plist`
   already has the good, driving-detection-aware string (commit `e76d2ab`),
   but the app target's build settings still carry a stale
   `INFOPLIST_KEY_NSMotionUsageDescription` ("…counts your steps when Apple
   Health is unavailable") in both Debug and Release. Two sources for the
   same key is exactly how the wrong string ends up in a shipped build —
   remove the build-setting copies so the Info.plist entry is the only
   source.

2. **Share button accessibility** (open Accessibility Audit finding): in
   `PoCSquat/Views/Walk/ActivitySummaryShareSheet.swift`, the share
   button's `ProgressView` (shown while `isRendering`, around line 416) has
   no accessibility label — VoiceOver users hear nothing while the button
   renders. The "Loading map…" `ProgressView` (~line 383) is fine as-is
   (its sibling Text carries the meaning), but add a label to the share one.

## Changes

### 1. Remove the stale build-setting key

In the PoCSquat app target's build settings (both Debug and Release),
delete the `INFOPLIST_KEY_NSMotionUsageDescription` entries entirely
(currently around lines 590 and 634 of `project.pbxproj`). Do NOT touch
the `NSMotionUsageDescription` entry in `PoCSquat/Info.plist` — that one
is correct and becomes the single source.

### 2. Label the rendering spinner

In `ActivitySummaryShareSheet.swift`, on the `ProgressView().tint(.white)`
inside the share button's `isRendering` branch, add:

```swift
.accessibilityLabel("Preparing share image")
```

## Build & verify

1. Build and run once. Trigger the motion permission prompt if you can
   (fresh install), or check the built app's Info.plist
   (`Products → PoCSquat.app → Show in Finder → Show Package Contents`)
   and confirm `NSMotionUsageDescription` is the driving-detection-aware
   string, with no trace of the "Apple Health is unavailable" variant.
2. VoiceOver quick check: on the activity share sheet, start a share and
   confirm the button announces "Preparing share image" while rendering.
3. Commit with a clear message. Do not push — Joe pushes himself.

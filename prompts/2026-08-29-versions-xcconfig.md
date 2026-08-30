# Single source of truth for version/build numbers (Versions.xcconfig)

## Why

Version numbers are currently hand-maintained in four separate places in
`project.pbxproj`, and they've drifted: the app targets say
`MARKETING_VERSION = 1.9` but the **widget extension still says 1.0** — App
Store validation requires an extension's `CFBundleShortVersionString` to
match its host app's, so this can block an upload. Build numbers have
drifted too (Xcode says 3; Notion's v1.9 release row says 15). One shared
xcconfig means one file to bump per release and the targets can never
disagree again.

## Changes

### 1. New file: `Config/Versions.xcconfig`

Create a `Config` folder at the repo root (sibling of `PoCSquat/`) with:

```
// Single source of truth for app + widget version numbers.
// Bump these here, never in target build settings.
MARKETING_VERSION = 1.9
CURRENT_PROJECT_VERSION = 16
```

**Why build 16:** Notion's v1.9 release row records build 15, and if a
build 15 was ever uploaded to App Store Connect, a re-upload must be
strictly higher. 16 is safe in every case (ASC only requires increasing
build numbers; gaps are fine). If you know for certain nothing above 3 was
ever uploaded, 4 would also be fine — 16 is the no-research-needed choice.

### 2. Wire it up in the project

- Add `Versions.xcconfig` to the project (file reference only — it must
  NOT be added to any target's membership).
- In the project editor → Info tab → Configurations, set
  `Versions.xcconfig` as the **project-level** base configuration for both
  Debug and Release. (If a base configuration is ever needed for something
  else later, xcconfigs support `#include`.)
- Delete every `MARKETING_VERSION = ...` and
  `CURRENT_PROJECT_VERSION = ...` line from all four target build-setting
  blocks (PoCSquat Debug/Release, WocketWidgetExtension Debug/Release) so
  both targets inherit the project-level values. The build-settings editor
  shows inherited values in plain (non-bold) text once this is right.

### 3. Sanity check the Info.plist wiring

Confirm both targets resolve version from build settings (generated
Info.plist keys or `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`
references). If either Info.plist hardcodes a version string, replace it
with the build-setting reference.

## Build & verify

1. Build both targets. Then check
   `xcodebuild -showBuildSettings -scheme PoCSquat | grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION"`
   shows 1.9 / 16, and the same for a
   `-target WocketWidgetExtension` query — the widget must now report 1.9,
   not 1.0.
2. Run the app once in the simulator and confirm it launches (version
   plumbing only, no behavior change expected).
3. Commit with a clear message. Do not push — Joe pushes himself.

## Note for Joe (not for the agent)

After this lands, reconcile the build number with App Store Connect when
you're next in there: if ASC shows a different latest build for 1.9,
update `Config/Versions.xcconfig` to be above it, and update the Notion
Releases row's Build field to match whatever you actually upload next.
From then on: one release = one edit to this file + the Notion row.

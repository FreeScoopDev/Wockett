# CI — what runs, where, and why

Written 2026-09-07. Correct it when it goes stale.

Wockett's CI is split across two providers on purpose. This file exists because
the Xcode Cloud half is configured in App Store Connect and **cannot be
expressed as a file in this repo** — Xcode Cloud has no workflow-as-code format.
Without this document, the definition of what gates `main` lives in one web UI
and nowhere else.

## The two required checks on `main`

`main` is protected: no direct pushes, no force-push, no deletion, and these two
checks must pass before a PR can merge.

| Required check | Provider | Runner | Bills at |
| --- | --- | --- | --- |
| `Wockett \| CI Tests \| Test - iOS` | Xcode Cloud | macOS | Included in Developer Program (25 h/month) |
| `Language-consistency guard` | GitHub Actions | `ubuntu-latest` | 1× |

Anything else reported on a PR is advisory and does not gate the merge.

## GitHub Actions — `.github/workflows/guards.yml`

Cheap repo guards that need no Apple toolchain. The macOS jobs that used to live
in `tests.yml` were removed on 2026-09-04: they billed at 10×, so a 14-minute UI
test job cost 140 of the 2,000 free minutes a month.

| Job | Required? | What it does |
| --- | --- | --- |
| `language-guard` | **Yes** | Greps `Views/`, `Intents/` and `WocketWidget` for hardcoded walk-specific copy (`"End Walk"`, `"Walk History"`, …). Fails the build if any reappear — user-facing copy must read the session's `ActivityMode`. |
| `swiftlint` | No | Runs SwiftLint from `ghcr.io/realm/swiftlint` against `.swiftlint.yml`. Currently `continue-on-error: true`, so it reports without gating. |

### Reading the SwiftLint result correctly

While `continue-on-error` is set, **the job shows a green tick even when
SwiftLint exits non-zero.** Do not read that tick as "no violations" — open the
job log and read the `Found N violations, M serious` line instead.

Baseline on 2026-09-07 with SwiftLint 0.65.1 (80 files):

```
863 violations, 33 serious
  top rules: 387 comma · 282 colon · 47 implicit_optional_initialization
             38 opening_brace · 26 force_unwrapping · 16 switch_case_alignment
```

Two thirds of that total is `comma` + `colon`, which in this codebase is almost
entirely deliberate column alignment in property blocks. Disabling those two
rules drops the count to 127 and puts the crash-class violations
(`force_unwrapping`, `force_cast`, `force_try`) at the top where they belong.

Once the serious ones are triaged, delete `continue-on-error` and the job
starts gating.

### Do not run `swiftlint --fix` on this codebase without verifying the build

Tried on 2026-09-07. It broke compilation twice, on two different rules:

- **`redundant_discardable_let`** rewrote `let _ = f.unitStyle = .abbreviated`
  to `_ = f.unitStyle = .abbreviated` inside a `@ViewBuilder`. `let _ =` is a
  declaration the builder skips; bare `_ =` is a statement of type `()` that it
  tries to render → `type '()' cannot conform to 'View'`.
- **`empty_count`** rewrote `alert.buttons.count > 0` to
  `!alert.buttons.isEmpty` in the UI tests. `XCUIElementQuery` has no `isEmpty`.

The second one matters beyond autofix: `empty_count` is an opt-in rule set to
`error`, and at least one of its violations **cannot be fixed the way the rule
wants**. Disable it, or exclude `WockettUITests`, before making the job
blocking — otherwise it gates merges on correct code.

Autofix is not free here. Any run needs a full build and test afterwards.

## Xcode Cloud

Configured at App Store Connect → Wockett → Xcode Cloud → Manage Workflows. Team
`1b320b4a-f12c-4521-89ca-fa2dcfb8ee19`, app `6794364736`. Two workflows, both
pointed at `https://github.com/FreeScoopDev/Wockett.git` / `PoCSquat.xcodeproj`.

Neither has "Restrict Editing" enabled, so any team member can change them —
which is the other half of why this file exists.

### `CI Tests` — the workflow that gates `main`

| | |
| --- | --- |
| Start condition | **Pull Request Changes** — source `Any Branches`, target `main`, starts if any file changes |
| Auto-cancel | On. A newer push to the same source branch cancels the running build. |
| Action | **Test - iOS** — platform iOS, scheme `PoCSquat`, **Required to Pass**, Test Option `Test (Use Scheme Setting)`, 1 destination |
| Clean | **Off** — restores derived data and caches, so runs stay fast |
| Notifies | Slack `#ci_tests`, all successes and failures. No email recipients. |

This is the source of the required `Wockett | CI Tests | Test - iOS` check. Note
that "Use Scheme Setting" means **the `PoCSquat` scheme decides which test
targets run** — if a target is added to or removed from the scheme's Test
action, CI coverage changes with no visible edit to this workflow or to CI
config. Check the scheme, not this page, when asking "what does CI actually
run?"

### `Release Flow` — manual TestFlight archive

| | |
| --- | --- |
| Start condition | **Manual Start** only — branch `Any Branches`; Pull Request and Tag both **Not Enabled** |
| Action | **Archive - iOS** — platform iOS, scheme `PoCSquat`, Distribution Preparation **TestFlight (Internal Testing Only)** |
| Clean | **On** — no cache restore, slower but reproducible. Correct for a release build. |
| Notifies | Slack `#wockett_release_updates`, all successes and failures. No email recipients. |

Releases are therefore never automatic: nothing archives on a tag or a merge,
only when someone presses Start. Combined with Xcode Cloud's build-number
auto-increment, this is the most likely explanation for 1.10 shipping as build
24 while `Versions.xcconfig` read 23 — a manual Release Flow run took the next
number from App Store Connect and the file was never reconciled.

**Two things worth changing when convenient:**

1. **Xcode and macOS are not pinned.** Both workflows are set to
   `Latest Release` (currently Xcode 26.6 / macOS Tahoe 26.6.2). A new Xcode
   ships and the toolchain under CI changes with no commit in this repo —
   builds can start failing, or behaviour can shift, with nothing in `git log`
   to explain it. Pinning an explicit version makes toolchain upgrades a
   deliberate, revertible act.
2. **`Release Flow` can archive from any branch.** Start condition is
   `Any Branches`, so a mis-click can push a feature branch to TestFlight
   internal testing. Restricting it to `main` costs nothing and removes the
   footgun.

### Still unrecorded

- The single test **destination** for `CI Tests` (simulator model / OS) is shown
  only as "1 destination" on the workflow page. Worth writing down here, since
  it determines what device CI actually tests on.

## Running the tests locally before pushing

```
xcodebuild test -project PoCSquat.xcodeproj -scheme PoCSquat \
  -destination "id=$(bash scripts/ci_pick_simulator.sh)"
```

`scripts/ci_pick_simulator.sh` discovers an available iPhone simulator at
runtime rather than hardcoding a device name, because runner images drift and a
hardcoded `-destination` dies in ~60 s without running a test.

Pipe the output through nothing when you care about the result — `xcodebuild |
tail` returns `tail`'s exit code, not `xcodebuild`'s, and will report success on
a failed run. Check for `** TEST SUCCEEDED **` in the full log.

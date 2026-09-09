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

**The protection is a repository *ruleset*, not legacy branch protection.** This
matters when checking it: `gh api repos/FreeScoopDev/Wockett/branches/main/protection`
returns **404 "Branch not protected"** even though `main` very much is. That 404
was read as "protection was removed" on 2026-09-08. Use this instead:

    gh api repos/FreeScoopDev/Wockett/rulesets
    gh api repos/FreeScoopDev/Wockett/rulesets/22245839

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

**Current, as of 2026-09-08** (SwiftLint 0.65.1, run via `scripts/lint.sh`):

```
191 violations, 32 at error severity
  errors: 26 force_unwrapping · 3 large_tuple · 1 function_parameter_count
          1 force_try · 1 force_cast
```

Those 32 are the triage list. Once they are cleared, delete `continue-on-error`
from the job and it starts gating — `.swiftlint.yml` already sets the
force-unwrap rules to `error`, so that deletion is the whole change.

The pre-tuning baseline was **863 violations, 33 serious**, of which 669 were
`comma` + `colon` — in this codebase almost entirely deliberate column alignment
in property blocks. Those two rules were disabled in the 2026-09-08 config pass,
which is what took the count to 191.

> An earlier version of this file predicted 127 rather than 191. That figure was
> measured with `swiftlint --config /tmp/…`, which silently disabled the
> `excluded:` paths and linted `WockettTests` as well. Always measure with
> `scripts/lint.sh`, which refuses to report numbers unless it can prove the
> exclusions took effect.

### Do not run `swiftlint --fix` on this codebase without verifying the build

Tried on 2026-09-07. It broke compilation twice, on two different rules:

- **`redundant_discardable_let`** rewrote `let _ = f.unitStyle = .abbreviated`
  to `_ = f.unitStyle = .abbreviated` inside a `@ViewBuilder`. `let _ =` is a
  declaration the builder skips; bare `_ =` is a statement of type `()` that it
  tries to render → `type '()' cannot conform to 'View'`.
- **`empty_count`** rewrote `alert.buttons.count > 0` to
  `!alert.buttons.isEmpty` in the UI tests. `XCUIElementQuery` has no `isEmpty`.

The second one mattered beyond autofix: `empty_count` was an opt-in rule set to
`error`, and at least one of its violations **could not be fixed the way the
rule wants**, so it would have gated merges on correct code the moment the job
stopped being advisory. It was dropped from `opt_in_rules` in the 2026-09-08
config pass, along with `colon`, `comma` and `redundant_discardable_let`.

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
| Environment | Xcode **26.6 (17F113)**, macOS **Tahoe 26.6.2 (25G83)** — pinned explicitly, not `Latest Release` |
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
| Start condition | **Manual Start** only, restricted to **`main`**; Pull Request and Tag both **Not Enabled** |
| Action | **Archive - iOS** — platform iOS, scheme `PoCSquat`, Distribution Preparation **TestFlight (Internal Testing Only)** |
| Environment | Xcode **26.6 (17F113)**, macOS **Tahoe 26.6.2 (25G83)** — pinned explicitly, not `Latest Release` |
| Clean | **On** — no cache restore, slower but reproducible. Correct for a release build. |
| Notifies | Slack `#wockett_release_updates`, all successes and failures. No email recipients. |

Releases are therefore never automatic: nothing archives on a tag or a merge,
only when someone presses Start. Combined with Xcode Cloud's build-number
auto-increment, this is the most likely explanation for 1.10 shipping as build
24 while `Versions.xcconfig` read 23 — a manual Release Flow run took the next
number from App Store Connect and the file was never reconciled.

### Two settings that were deliberately changed on 2026-09-08

1. **Xcode and macOS are pinned**, on both workflows. They previously tracked
   `Latest Release`, which meant a new Xcode could change the CI toolchain with
   no commit in this repo — a build starts failing, or behaviour shifts, and
   nothing in `git log` explains it. Pinned, a toolchain upgrade becomes a
   dated, revertible decision.

   The cost is that upgrades are now manual, and Apple retires older Xcode
   versions from Xcode Cloud periodically. Expect to move the pin forward a
   couple of times a year; worth folding into the weekly QA pass so it is not
   something to remember.

2. **`Release Flow` is restricted to `main`.** It previously accepted
   `Any Branches`, so a mis-click on the Start dialog could archive a feature
   branch straight to TestFlight internal testing. There is no longer a branch
   to pick but the one that ships.

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

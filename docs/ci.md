# CI — what runs, where, and why

Written 2026-09-07. Correct it when it goes stale.

Wockett's CI is split across two providers on purpose. This file exists because
the Xcode Cloud half is configured in App Store Connect and **cannot be
expressed as a file in this repo** — Xcode Cloud has no workflow-as-code format.
Without this document, the definition of what gates `main` lives in one web UI
and nowhere else.

## The three required checks on `main`

`main` is protected: no direct pushes, no force-push, no deletion, and these three
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
| `SwiftLint` | GitHub Actions | `ubuntu-latest`, `ghcr.io/realm/swiftlint` container | 1× |

Anything else reported on a PR is advisory and does not gate the merge.

## GitHub Actions — `.github/workflows/guards.yml`

Cheap repo guards that need no Apple toolchain. The macOS jobs that used to live
in `tests.yml` were removed on 2026-09-04: they billed at 10×, so a 14-minute UI
test job cost 140 of the 2,000 free minutes a month.

| Job | Required? | What it does |
| --- | --- | --- |
| `language-guard` | **Yes** | Greps `Views/`, `Intents/` and `WocketWidget` for hardcoded walk-specific copy (`"End Walk"`, `"Walk History"`, …). Fails the build if any reappear — user-facing copy must read the session's `ActivityMode`. |
| `swiftlint` | **Yes** (since 2026-09-09) | Runs SwiftLint 0.65.1 from `ghcr.io/realm/swiftlint` against `.swiftlint.yml`. Fails on any error-severity violation. |

### Reading the SwiftLint result

The job fails on any error-severity violation and is a required check, so red
is red. Warnings do not fail it; read the `Found N violations, M serious` line
in the job log for those. (Until 2026-09-09 the job ran with
`continue-on-error` and its green tick meant nothing — that caveat is gone.)

**Current, as of 2026-09-09** (SwiftLint 0.65.1, `scripts/lint.sh`):

```
151 violations, 0 at error severity
```

The 32 error-severity violations that stood on 2026-09-08 (26 `force_unwrapping`,
3 `large_tuple`, 1 `function_parameter_count`, 1 `force_try`, 1 `force_cast`)
were cleared in #17 and `continue-on-error` removed the same day. `large_tuple`
and `function_parameter_count` were disabled rather than fixed — style rules from
the same family as the four size rules already off. The remaining 151 are
warnings and do not fail the job.

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

### When CI fails and local passes

It happens at the same SwiftLint version. On 2026-09-09, 0.65.1 on macOS said
0 error-severity violations; 0.65.1 in the Linux container said 1. The line was
`HomeWeatherView.swift:91`, a `URL(string:)!` — a plain force-unwrap that the
macOS run simply did not report. CI is the arbiter.

Finding the line: the job log shows `##[error]Force unwrapping should be
avoided` with **no file or line**, and fetching the raw log through the API
does not restore them. The **check-run annotations** do:

    gh api repos/FreeScoopDev/Wockett/check-runs/<job id>/annotations \
      --jq '.[] | select(.annotation_level=="failure") | "\(.path):\(.start_line) \(.message)"'

The job id is the `id` of the check run on the commit
(`gh api repos/FreeScoopDev/Wockett/commits/<sha>/check-runs`).

Fixing it: remove the unwrap. Do not add a `swiftlint:disable` comment — an
annotation is precisely the thing the two platforms may honour differently,
and it was the wrong first guess here.

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
| Environment | Xcode **26.6 (17F113)**, macOS **Tahoe 26.5.1** — pinned explicitly, not `Latest Release`. macOS moved from 26.6.2 (25G83) on 2026-09-15, see below. |
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
| Environment | Xcode **26.6 (17F113)**, macOS **Tahoe 26.5.1** — pinned explicitly, not `Latest Release`. macOS moved from 26.6.2 (25G83) on 2026-09-15, see below. |
| Clean | **On** — no cache restore, slower but reproducible. Correct for a release build. |
| Notifies | Slack `#wockett_release_updates`, all successes and failures. No email recipients. |

Releases are therefore never automatic: nothing archives on a tag or a merge,
only when someone presses Start. Combined with Xcode Cloud's build-number
auto-increment, this is the most likely explanation for 1.10 shipping as build
24 while `Versions.xcconfig` read 23 — a manual Release Flow run took the next
number from App Store Connect and the file was never reconciled.

### The build number is one counter for the whole app

Xcode Cloud's "Build N" is a single sequence per app, shared by **every**
workflow. A `CI Tests` run on a pull request consumes a number exactly as a
`Release Flow` archive does, and so does a run that fails in 14 seconds.
The archive's `CFBundleVersion` is whatever number Release Flow happened to
draw. On 2026-09-15 build 77 shipped to TestFlight; the re-archive for the
same version, after two PRs (four CI runs) and one local archive attempt,
came out as **82**. Nothing was wrong.

Consequences:

- "The next build will be N" is never a safe statement. Read the number off
  the finished archive in App Store Connect, then write it into the Notion
  Releases row and `Versions.xcconfig`.
- Gaps in the TestFlight build list are normal and carry no information.
- The three failure signatures are still recognisable regardless of number:
  parent status fails in seconds with no child check-run → environment pin
  retired; child check-run appears, `action_required` in ~30 s, message
  "conflict with changes made on the pull request target branch" → merge
  `main` into the branch and push (seen on #33 and #36); **no parent status
  at all** — see the next section.

### Xcode Cloud never received the pull-request event

The third shape, met twice on 2026-09-16 (#42 and #44). The two GitHub
Actions checks run within seconds of the PR opening, and Xcode Cloud posts
**nothing**: no `Wockett | CI Tests` parent status, not even `pending`, and no
`Test - iOS` child check-run. The PR sits at "1 expected, 2 successful checks"
indefinitely — 51 minutes on #42, 1 h 47 m on #44 — while other PRs opened
minutes either side get their `pending` status within seconds. The workflow's
start condition is *Pull Request Changes*, so no event means no build.

Tell it apart from the pin failure by the parent status: the pin failure
*posts* a parent status and fails it; this one never posts. Tell it apart from
a slow queue by comparing with a neighbouring PR: a queued run still shows
`pending — queued` immediately.

Fix: re-fire the event. Closing and reopening the PR is enough and adds no
commit — both times the parent status appeared as `pending — queued` within
seconds of the reopen. From a terminal:

    gh pr close <N> && gh pr reopen <N>

An empty commit (`git commit --allow-empty`) also works but leaves noise that
the squash merge has to absorb. Starting the build by hand in App Store
Connect works too, but only if someone notices; the point of writing this down
is that the wait itself is the symptom.

Cause not established. Both cases were PRs opened with `gh pr create` within
about a minute of the branch being pushed; whether that timing matters is
unknown. If it recurs, check the webhook deliveries under the repository's
Settings → Webhooks for the App Store Connect endpoint before assuming the
same fix.

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

   **This happened on 2026-09-15.** PR #28's `CI Tests` run went queued →
   failed in 14 seconds, before the `Test - iOS` action check-run was ever
   created on GitHub — no source was compiled. Cause: the pinned macOS
   **26.6.2 (25G83)** was no longer offered by Xcode Cloud; 26.5.1 was the
   newest available. Both workflows were re-pinned to **macOS 26.5.1** (Xcode
   26.6 unchanged) and the build was re-run green.

   How to recognise it next time: the parent `Wockett | CI Tests` status
   fails within seconds of the PR event and the child `… | Test - iOS`
   check-run never appears. A real test or build failure creates the child
   check-run and takes minutes. GitHub carries no detail either way — the
   error is a banner on the build's Overview page in App Store Connect, and
   Xcode Cloud's Slack post in `#ci_tests` says only "Build N failed".

2. **`Release Flow` is restricted to `main`.** It previously accepted
   `Any Branches`, so a mis-click on the Start dialog could archive a feature
   branch straight to TestFlight internal testing. There is no longer a branch
   to pick but the one that ships.

### Still unrecorded

- The single test **destination** for `CI Tests` (simulator model / OS) is shown
  only as "1 destination" on the workflow page. Worth writing down here, since
  it determines what device CI actually tests on.

## Running the tests locally before pushing

Use the script. It runs the full scheme (unit + UI — the same suite CI runs)
and takes its pass/fail counts from the **xcresult bundle**, not the log. The
xcodebuild log is not a reliable counter: during parallel testing, session-level
output can be written mid-way through a test-result line and eat its verdict —
it happened on 2026-09-09 with stderr split off and to a line that was not last,
so neither of the obvious explanations holds. The bundle is what Xcode Cloud
reads; the log is for humans. The verdict requires xcodebuild's exit code, its
literal `** TEST SUCCEEDED **`, and the bundle's `result` to all agree:

    scripts/test.sh              # what CI runs
    scripts/test.sh --unit-only  # faster; NOT what CI runs

The raw invocation it wraps, for reference:

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

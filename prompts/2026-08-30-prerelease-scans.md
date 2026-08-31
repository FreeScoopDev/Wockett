# Pre-release scans for v1.9: Security & PII + Accessibility (report only)

Both gating SOPs last ran 08-28, before the active-session UI was rebuilt
and the HealthKit / Live Activity / intent code changed. Re-run both now.
**Report-only — do not fix anything.** Joe reviews findings and decides.

Scope emphasis: the code that changed since 08-28 gets a full pass; the
rest gets a lighter drift check. Changed since then:
`ActiveSessionView.swift`, `ActivitySummaryView.swift`,
`ActiveSessionComponents.swift`, `ScheduleWalkSheet.swift`,
`ActiveWalkSnapshot.swift`, `ActiveWalkStore.swift`, `NavigationSession.swift`,
`WalkLiveActivityManager.swift`, `WalkLiveActivityIntents.swift`,
`HealthWorkoutWriter.swift`, `WocketWidgetLiveActivity.swift`,
`WalkModels.swift`, `StepCounterView.swift`, `ActiveMiniTile.swift`,
`ActivitySummaryShareSheet.swift`, `Versions.xcconfig`, `Info.plist`.

## Part 1 — Security & PII Scan (SOP)

Do a full security and privacy scan of this codebase. Don't fix anything
yet — report findings first. For each finding give: Severity
(Critical/High/Medium/Low), Location (file:line), What's wrong, Why it
matters, Suggested fix.

Check for:
1. Hardcoded secrets — API keys, tokens, passwords, private keys, or
   credentials in source, plist, config, or entitlements files.
2. Insecure storage — sensitive data (health data, PII, precise location)
   kept in UserDefaults, plain files, or unencrypted storage. **Pay
   specific attention to the new walk-resume checkpoint file
   (`active-walk-snapshot.json` in Application Support): it now contains
   GPS breadcrumbs. Assess: is Application Support acceptable for this,
   is the file excluded from iCloud backup if it should be, and does the
   4-hour expiry + clear-on-stop actually bound its lifetime on every
   path?**
3. Network security — non-HTTPS endpoints, ATS exceptions, certificate
   validation.
4. PII exposure — print()/os_log that leak names, emails, precise
   location, or health data; PII in identifiers, filenames, or CloudKit
   public-database records. **Check the salvaged-walk path and the
   Live Activity attributes/content state for anything that shouldn't be
   there.**
5. CloudKit permissions — public/shared record types readable/writable by
   users who shouldn't; missing record-level checks. (No schema changes
   this release — confirm that.)
6. Third-party SDKs — confirm still zero.
7. Debug leftovers — logging or bypasses in or outside `#if DEBUG`.
8. Permissions vs. entitlements — anything requested but unused; usage
   strings that misdescribe. **Confirm the single remaining
   `NSMotionUsageDescription` source in Info.plist is accurate, and that
   no INFOPLIST_KEY_* build-setting duplicates crept back.**
9. Input handling — content filter bypasses; user input reaching a query,
   URL, or file path unsanitized.

Summarize with a total count by severity at the top.

## Part 2 — Accessibility Audit (SOP)

Do an accessibility pass, prioritizing the rebuilt active-session surface
(`ActiveSessionView`, `ActivitySummaryView`, `ActiveSessionComponents`,
`ScheduleWalkSheet`, `ActiveMiniTile`) and the Live Activity views, then
a lighter drift check elsewhere:
1. Every interactive element (buttons, tappable cards, custom controls —
   including the pause/resume control, end-dialog triggers, POI chips,
   Finish button, summary actions) has an accessibilityLabel describing
   what it does.
2. Text scales with Dynamic Type — nothing truncated or overlapping at the
   largest accessibility sizes, especially the `SessionStatsBar` cells and
   the summary stat tiles.
3. Color isn't the only carrier of information (paused state, PR banner,
   driving/heat banners).
4. Tap targets ≥ 44×44pt.
5. Custom views (stat cells, pet progress rings, PR banner, map overlays)
   have meaningful VoiceOver descriptions.
6. Contrast in light and dark mode, including the cream/green/muted
   palette on the map overlays.

Report each issue with file/view name and a suggested fix. Don't change
anything yet.

## Output

Two clearly separated reports (Security, Accessibility), each with a
severity/issue count at the top. No commits from this round — it's
read-only. Joe will paste the reports back for triage.

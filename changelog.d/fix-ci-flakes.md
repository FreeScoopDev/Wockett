### Internal
- Three CI failures on correct builds are gone. A UI test's tab tap could be
  swallowed when a system alert (a location prompt) arrived at the same
  moment: XCTest answered the alert, lost the tap, and the test timed out
  waiting for a screen it never opened. That was every failure of the Health
  disclaimer test (6) and some of the Live Activity test's. Tabs are now
  selected through one helper that taps again only when an alert took the
  tap; a tab that ignores a tap with nothing in the way still fails.
  The Pro entitlement test's 30 s wait is a five-minute hang guard, because
  on a loaded runner the wait counts every other test queued ahead of it.
  The community-name tests listened for iCloud account changes on the
  app-wide notification centre, where the system itself posts one while the
  simulator settles; a name claim held open in a test was then dropped as
  "account changed". Each test now has its own notification centre.
- The Live Activity UI test is skipped on GitHub's runner only, where driving
  Notification Centre is unreliable (it failed 6 of 15 UI jobs, passing the
  other 9); it still runs locally. The UI job sets `TEST_RUNNER_WOCKETT_CI` for this.

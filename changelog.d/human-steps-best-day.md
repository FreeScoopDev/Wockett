### Fixed
- The "Best day" personal record in Community no longer counts rides as
  steps. A ride's "steps" are only its distance divided by a 0.762 m stride
  (the pedometer never runs on a bike), so a 20 km ride day could become
  your Best day with about 26,000 steps nobody walked, on a day the App Only
  calendar shows as 0. Best day now totals each day with the same rule the
  calendars use, `ActivitySummaryContent.humanSteps(on:in:calendar:)`, so the
  two cannot disagree. If you have only ever ridden, the Best day row is
  hidden rather than showing "0 steps" as a record. When two days tie, the
  more recent one is shown (before, either could appear). Longest walk and
  Best pace are unchanged, and no saved activity is changed.

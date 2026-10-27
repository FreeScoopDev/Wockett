### Fixed
- Rides no longer count as steps in the step streak, the month calendar, the
  Home week strip (App Only tracking) or the Sunday "Your week in review"
  notification. A ride's "steps" were only its distance divided by a 0.762 m
  stride (the pedometer never runs on a bike), so a 14 km ride counted as
  about 18,000 steps and could keep a 10,000-step streak alive on its own.
  These totals now use the same rule Insights and the summary screens already
  use, `ActivitySummaryContent.humanSteps`. **A current streak that a ride day
  was holding up will be shorter after updating, possibly 0**, because the
  streak is worked out from history each time; the longest streak and badges
  already earned are kept. A week of rides only now gets "This week: N km.
  Keep it up!" in the summary instead of "A new week starts today". Calendars
  in Apple Health mode are unchanged: they come from Health. No saved
  activity is changed.

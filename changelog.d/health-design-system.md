### Changed
- The Health tab and everything it opens (the recovery card, the week and
  month calendars, a day's detail, Sleep / Readiness / Active Calories,
  walking health and its four metrics, and Your Progress) now use the design
  Home and Community moved to. Section headings sit above their cards, labels
  are sentence case, and status, trend and goal tags are the shared chips.
  Health was the next tab still in the old style.
- The week view is one card with its seven days side by side, instead of a
  strip you could scroll sideways, with the week's name as the heading and
  previous, calendar and next beside it. The month calendar matches it.
- Your step ring is orange everywhere, as on Home. "Your Progress" and a day's
  detail still drew the old green-to-orange gradient.

### Internal
- New shared pieces: `WktGoalRing` (now also on Home), `WktRoundIconButton`,
  and the metric-screen set in `Design/WktDetailPieces.swift` (`WktMetricHero`,
  `WktStatGrid`, `WktBulletList`, `WktNumberedList`, `WktInfoSection`).
  Recovery's detail sheet and the gait detail screen each drew their own copy
  of these. `WktIconBadge` takes a size and a model-supplied symbol name.
- `TodayHeroView.swift` is now `Health/RecoveryViews.swift`: since #115 it only
  held the Health tab's recovery card and its sheet. Its 17 hard-coded SF
  Symbol names, and 4 in `DayDetailSheet`, go through `WktSymbol` (new case:
  `.night`).

### Changed
- Walking health only gives a gait status ("On track", "Watch", "Check in")
  when the metric has data on at least 4 of the last 7 days, on its card, on
  its detail page and as "Gait: …" on the Recovery card. Before, a single day
  of data was enough, and one day says little about how someone walks. With
  fewer days the card shows the average and "3 days of data" instead, and the
  chart's dots and day-of-week bars stay one neutral green. People whose Watch
  or iPhone records gait only now and then will see fewer verdicts than
  before. The thresholds and their wording are unchanged.
- The 7-day and 30-day averages say how many days they are based on ("based
  on 5 of the last 7 days"), because an average of one day looked the same as
  an average of seven.
- The change against the week before shows only when both weeks have data on
  at least 3 days, and it is no longer green or orange: a gait number going up
  or down is not by itself good or bad news.
- "Personal best" is now "Highest recorded" or "Lowest recorded" over the last
  30 days, since a gait extreme is not an achievement, and the improvement
  tips on a gait metric's page are collapsed under "Tips" until opened.

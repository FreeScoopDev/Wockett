### Fixed
- Readiness now gives a level (Push, Active or Recover) only when it has all
  three of: last night's sleep, an HRV reading from the last 48 hours, and HRV
  on at least 7 of the last 30 days for the personal baseline. Before, one
  signal alone could produce "Push", an HRV reading weeks old fed today's
  answer, a missing baseline fell back to fixed HRV thresholds nobody had
  justified, and a baseline built on a day or two of data counted as
  "personal". Readiness should not claim more than the readings support. The
  scoring itself is unchanged: with the same numbers it gives the same level.
  As a result, people who wear their Watch only now and then, or who have a
  new Watch, will see "–" (not enough data) more often than before. The
  Recovery card and the Readiness detail now say what is missing ("No HRV in
  the last 2 days", "Not enough HRV history yet: 3 of 7 days"); the card
  stays quiet only when there is no sleep or HRV at all. Readiness treats
  a night with only In Bed or Awake time as no sleep, not as 0 hours slept.
- The readiness hints describe the readings ("HRV above your 30-day average;
  slept 7h 20m") instead of telling people what to do ("push a little harder
  today", "Light activity recommended"). The score breakdown no longer labels
  HRV High, Normal or Low from fixed thresholds when there is no baseline; it
  shows the number, and it compares against the baseline only once that
  baseline has the 7 days readiness itself needs.

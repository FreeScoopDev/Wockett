### Fixed
- Insights no longer counts a ride as steps. A ride's "steps" were only its
  distance divided by a 0.762 m stride (the pedometer never runs on a bike),
  so a 14 km ride added about 18,000 steps to the week. Rides still count in
  Insights' activities, distance, time and active days; the Steps tile now
  says "estimated · rides excluded". Steps for a person's total now come from
  one rule, `ActivitySummaryContent.humanSteps`, the same one the summary,
  day, step and pet screens already used to hide a ride's steps.
- The Health tab's "Your journey in perspective" card now uses recorded
  activities only. It used to add today's Health steps on top of every
  recorded session, so a walk recorded today was counted twice; it gave rides
  distance-derived steps; and it kept sessions flagged as possible driving,
  which Insights leaves out. Its wording also overclaimed: "marathons
  completed" was really total distance, and "up the Empire State Building"
  presented ordinary steps as stairs. It now reads "Distance equal to N
  marathons" and "Step count equal to N Empire State climbs", says which
  figures are recorded distance across all activities and which are estimated
  steps from walks and runs. No saved activity is changed.

### Fixed
- The 13-mile and 62-mile distance challenges no longer read "12 mi" and
  "61 mi". The options are stored as 20,921 m and 99,779 m, a hair under 13
  and 62 miles, and the goal text cut the fraction off instead of rounding it,
  so the goal, progress and leaderboard all showed one mile less. Goals now
  round to the nearest mile or kilometre. Progress still rounds down until the
  goal is reached, so 12.6 of 13 miles reads "12 mi / 13 mi" rather than
  looking finished early, the same rule as the percentages. A distance just
  under ten (9.96 mi) now reads "10 mi" rather than "10.0 mi".

### Fixed
- Choosing Distance when creating a challenge in US units now highlights
  "6 mi" instead of showing five options with none selected. The default was
  10,000 m in every locale, which is "10 km" in metric but matches none of the
  mile options (3, 6, 13, 26, 62), so tapping Create without picking made a
  6.2-mile challenge the user never chose and could not see selected. The
  default now comes from the option list itself, so it is always one of the
  choices shown; metric still starts on 10 km.

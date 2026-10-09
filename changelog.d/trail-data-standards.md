### Internal
- Trail regions have written standards, `scripts/trail-pack/STANDARDS.md`, and the tools to hold each update to the last (Joe, 2026-10-09: the logic should improve with each update):
  - No coverage regression: a new version of a state may not cover more than 2 points fewer towns than the published one, unless shipped with `ACCEPT_REGRESSION="<why>"`, which is recorded.
  - Every build prints what to review before the next builder rule: one name on many separate trails (descriptions, name variants) and very long single "trails" (a place name painted on every way).
  - The published record keeps an archived copy of exactly what users have (`published/<region>-v<N>.wktpack`) and a history of each version's builder and coverage. Until now it pointed at the build folder's pack, which the next build overwrites, so "what changed against the published version" compared a new pack with itself. The ten live states were archived and their coverage recorded as the baseline on 2026-10-09 (each archive checked against the published sha256).
  - 5 new tests; removing the regression gate, the archive, the archive clean-up, or either review list turned its test red.

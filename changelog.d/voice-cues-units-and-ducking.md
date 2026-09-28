### Fixed
- Voice cues now count miles on a US phone. The milestone counter ticked
  every kilometre and only then named the unit by locale, so "1 mile
  completed" was spoken after 0.62 miles and the pace was always read per
  kilometre. Each whole mile (or kilometre elsewhere) is announced once, with
  the pace in the same unit.
- Music no longer stays quiet for a whole walk when voice cues are on. The
  audio session was activated at the first cue and never released, so other
  apps' audio was ducked until the walk ended. It is now activated for each
  cue and released once the cue has been spoken, so music comes back up
  between announcements.

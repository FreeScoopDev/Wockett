### Fixed
- A cycleway's "Shared with cyclists" / "Shared with walkers" line is no
  longer hidden by a stretch tagged `foot=destination` or `foot=permissive`.
  Those values still let walkers on, so they are not the map "saying
  otherwise"; only an explicit `foot=no` (or `foot=private`, as before)
  hides the line. They do not count toward the 80% of the trail that must
  say `yes` or `designated` either. Walnut Creek Trail in Raleigh had lost
  the line over 54 m of `foot=destination` in 14.5 km, and is the one North
  Carolina trail that gets it back. Wheelchair, lighting and every other
  fact are unchanged.

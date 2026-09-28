### Fixed
- Free walks, runs and rides finished from the walk screen now reach Apple
  Health as workouts. Every session starts a Health workout, but the walk
  screen's Finish for a free walk never completed it, so only guided walks
  and walks ended from the mini tile or Live Activity were written to Health.
- Pets get credit for the whole walk however it ends. Their distances lived
  in the walk screen, so minimising it reset them, and ending from the mini
  tile or the Live Activity saved none. The "update the owner" message also
  counts the stretch in progress, not only finished ones.
- Water-break reminders stop the moment a walk ends. The walk screen
  cancelled them only when its summary was closed, so a phone pocketed on
  the summary kept reminding.
- Ending a guided walk from the "driving?" banner no longer announces a
  personal record or schedules the hydration nudge as if the route had been
  completed on foot, and ends the Live Activity once instead of twice.

### Internal
- A walk ends one way: `ActiveWalkStore.end(.save / .discard)`. The walk
  screen's Finish and Discard, the break prompt, the driving banner, route
  completion, the mini tile and the Live Activity each re-implemented the
  sequence, and each left something out.

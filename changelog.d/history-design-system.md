### Changed
- Activity History and the screens around it now use the design the rest of
  the app moved to: the history list and its stats, an activity's detail,
  Log a Past Walk, Schedule Walk, a pet's detail, My Pets and the pet editor.
- An activity's type is chosen with the same picker as everywhere else, and
  says Ride, not Bike, like the rest of the app.
- An empty Activity History says "No activities yet" rather than "No Walks
  Yet": the list holds runs, rides and indoor walks too. The detail's note
  hint and Share button name the activity's own type.

### Fixed
- My Pets showed each pet's built-in emoji even when the pet had a custom one,
  which every other screen used.
- In dark mode, the Schedule Walk sheet showed its title in dark text on a dark
  background.

### Internal
- A pet's detail ring is the shared `WktGoalRing`, which now takes a tint (a
  pet's own colour; the user's goal stays orange). The last hard-coded SF
  Symbol names in the app, in `PetDetailSheet`, go through `WktSymbol`, so
  there are none left.

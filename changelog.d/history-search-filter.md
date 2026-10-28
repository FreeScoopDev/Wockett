### Added
- Activity History has a **search** field (route names and notes, ignoring
  case and accents) and a **filter** menu for activity, period (this week,
  this month, last 7 days) and pet. The list was every activity ever
  recorded with no way to find one. The menu shows how many filters are on
  and has a Reset; a search or filter that matches nothing says "No
  activities match" with **Clear filters**, which is a different state from
  having no history at all. Nothing is hidden by default: short,
  zero-distance and possibly-driven records stay listed unless the person
  filters them out. Filters are not saved.

### Changed
- The History header's count, distance, time and "this week" follow the
  search and filters, and its title names the scope ("This month · Run"),
  so the figures are always the sums of the rows listed beneath them.

### Internal
- Swipe-to-delete in History deletes by the activity's identity, not its
  position. It deleted by offset into the whole history, which was only
  safe while the screen showed the whole history: in a filtered list the
  same offset is a different activity, so filtering without this would have
  deleted the wrong one. A delete whose write fails still puts the activity
  back, as before.

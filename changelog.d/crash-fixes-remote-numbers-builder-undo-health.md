### Fixed
- A community route or challenge with an impossible size (a distance of
  `1e30` metres, say) can no longer crash the app for everyone who opens the
  Community tab. Public records are written by anyone with an iCloud account
  and a modified client, and the distance, pace and step conversions trapped
  on a value that large, so one bad record kept crashing every launch until a
  moderator deleted it. Such records are now refused when they are read
  (routes over 2,000 km, challenge goals over 10,000 km), and the conversions
  themselves no longer trap.
- Tapping Undo, adding a point or closing the loop while the route builder is
  still working out directions could crash it ("Index out of range") or file a
  leg under the wrong point. The builder now finishes the calculation before
  taking the next edit, and Undo is greyed out while it works.
- Ending a walk within the first moments of starting it no longer loses its
  Apple Health workout. The workout writer was only remembered once Health had
  answered, so a walk saved or discarded before then found nothing to finish,
  and the workout that started afterwards stayed open. The end now waits for
  the start. The workout's end time is also the moment the walk ended, not the
  moment cleanup finished.

### Internal
- `CustomRouteBuilder` takes its directions lookup as a parameter, so tests
  can hold a calculation open and edit the route while it waits.

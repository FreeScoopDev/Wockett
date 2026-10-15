// What a walker can report about a trail after walking it: the closed
// vocabulary of `TrailFactReport` (spec feat/trail-walker-reports, criterion 2,
// confirmed by Joe 2026-10-15). This file is the one place it is written down.
// The dashboard reads it from here; the app (a later PR) mirrors it in Swift,
// and its test should compare against this file, so the two cannot drift.
//
// A report's `fact` is one key below and its `value` one of that fact's value
// keys, exactly as written (case matters). Anything else is ignored: reports
// are written by any signed-in iCloud user, so a crafted one may say anything.
//
// Chips only: no free text, so there is nothing offensive to moderate.
// Transient conditions (mud, flooding, closures) are deliberately absent:
// they go stale.
//
// `publish: false` means counted and shown on the dashboard, but no
// `TrailFactSummary` is ever published for it. `liked` is collected now so it
// can be built on later (Featured ranking, say); Joe decides how in a later
// spec (2026-10-15).

export const WALKER_FACTS = Object.freeze({
  dogs: Object.freeze({
    label: 'Dogs',
    publish: true,
    values: Object.freeze({
      leashRequired: 'Dogs on leash',
      offLeashOK: 'Dogs off leash OK',
      noDogs: 'No dogs',
    }),
  }),
  stroller: Object.freeze({
    label: 'Stroller OK',
    publish: true,
    values: Object.freeze({
      yes: 'Stroller OK',
      no: 'Not for strollers',
    }),
  }),
  wheelchair: Object.freeze({
    label: 'Wheelchair OK',
    publish: true,
    values: Object.freeze({
      yes: 'Wheelchair OK',
      no: 'Not for wheelchairs',
    }),
  }),
  surface: Object.freeze({
    label: 'Surface',
    publish: true,
    values: Object.freeze({
      paved: 'Paved',
      packedDirt: 'Packed dirt',
      rockyOrRooty: 'Rocky or rooty',
    }),
  }),
  liked: Object.freeze({
    label: 'How was it?',
    publish: false,
    values: Object.freeze({
      up: 'Thumbs up',
      down: 'Thumbs down',
    }),
  }),
});

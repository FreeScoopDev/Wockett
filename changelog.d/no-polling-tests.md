### Internal
- The suspension and featured-trail "slow fetch still lands" tests wait for
  the events themselves (the fetch being held, then finishing) instead of
  polling with yields, which lost the race on a loaded CI machine (PR 186).
  Both services gain `fetchInFlight()`, used only by these tests.

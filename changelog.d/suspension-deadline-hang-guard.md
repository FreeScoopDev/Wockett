### Internal
- The suspension "slow fetch still lands" test now fails instead of hanging if
  the suspension list's deadline is ever removed. It waited on the load
  directly, so a missing deadline would have stalled the unit-test job until
  its 45-minute timeout with no failure to read. It gets the same five-minute
  guard as its featured-trails twin, long enough not to fire on a slow CI
  machine.

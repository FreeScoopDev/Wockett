### Internal
- Three contribution-status tests can no longer fail a correct build on a
  busy CI runner. Each had a one-minute time limit, and two waited for a
  held fetch by yielding the main actor in a loop. On CI a test's clock
  also counts the time it queues behind every other main-actor test, which
  is how the same limit failed the walker-report test twice (#252). The fake
  store now tells the test when the fetch is held, and the limits are
  five-minute hang guards.

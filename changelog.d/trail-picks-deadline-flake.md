### Internal
- The featured-trails deadline test no longer fails on a slow CI machine. Its
  one-minute hang guard counted time spent queued behind other tests, and on
  PR 196 it fired on a correct build while every deadline test took over two
  minutes. The deadline itself was already driven without waiting, so the
  guard only has to tell a hang from a slow machine; it is now five minutes.
  Removing the deadline from the code still turns the test red.

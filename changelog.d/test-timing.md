### Internal
- Two tests no longer fail on a slow CI machine. The featured-trails
  deadline test dropped its one-minute time limit (it counted time queued
  behind other tests) and now fails by itself if the deadline is removed;
  the Health disclaimer UI test waits 30 seconds for the Health screen, like
  the other tabs. Both failed on PR 186 with no change to the code they test.

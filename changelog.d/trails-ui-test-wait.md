### Internal
- The Trails UI smoke test waits for the trail's directions button instead
  of checking it the instant the detail opens. It failed on CI with no
  change to the screen (a docs-only commit on main, then PR 181).
